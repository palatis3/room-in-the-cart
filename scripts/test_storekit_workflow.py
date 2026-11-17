"""Offline checks for one shared StoreKit build and both required locale runs."""
import copy
import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import check_storekit_runtime_mount as runtime_mount
from check_ci_workflows import FIXTURE_RUNNER, STOREKIT_JOB, POLICY, bitrise_group, parse_workflow
from is_storekit_launch_failure import is_launch_failure

ROOT = Path(__file__).resolve().parents[1]
EXPECTED = {
    'US English — local StoreKit': ('en', 'en-US', 'en_US'),
    'US Spanish app · Spanish (Mexico) offer · USA storefront': ('es', 'es-US', 'es_MX'),
}


class StoreKitWorkflowTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.workflow, _, _ = parse_workflow(ROOT / '.github/workflows/ios-deep.yml')
        cls.jobs = cls.workflow['jobs']
        cls.plan = json.loads((ROOT / 'ios/Tests/LocalStoreKit.xctestplan').read_text())

    def step(self, job, *, name=None, identifier=None):
        return next(step for step in self.jobs[job]['steps']
                    if (name is not None and step.get('name') == name)
                    or (identifier is not None and step.get('id') == identifier))

    def python_block(self, step):
        return step['run'].split("python3 - <<'PYCODE'", 1)[1].split('\n', 1)[1].split('\nPYCODE', 1)[0]

    def execute(self, code, root, **environment):
        previous = Path.cwd()
        try:
            os.chdir(root)
            with patch.dict(os.environ, environment):
                exec(compile(code, 'workflow-inline-validation', 'exec'), {})
        finally:
            os.chdir(previous)

    def compiled_fixture(self, root):
        plan = root / 'ios/Tests/LocalStoreKit.xctestplan'
        plan.parent.mkdir(parents=True)
        plan.write_text(json.dumps(self.plan))
        selectors = root / 'scripts/ios_storekit_test_selectors.txt'
        selectors.parent.mkdir()
        selectors.write_bytes((ROOT / 'scripts/ios_storekit_test_selectors.txt').read_bytes())
        products = root / '.build/StoreKitDerivedData/Build/Products'
        resource = products / 'Debug-iphonesimulator/RoomInTheCart.app/PlugIns/RoomInTheCartTests.xctest/HouseholdLocalTesting.storekit'
        resource.parent.mkdir(parents=True)
        resource.write_text('{}')
        (products / 'Debug-iphonesimulator/RoomInTheCart.app/Info.plist').write_bytes(plistlib.dumps({
            'DTSDKName': 'iphonesimulator27.1', 'DTXcodeBuild': '27A9275', 'MinimumOSVersion': '17.0',
        }))
        configurations = []
        for entry in self.plan['configurations']:
            options = entry['options']
            configurations.append({'Name': entry['name'], 'IsEnabled': True, 'TestTargets': [{
                'BlueprintName': 'RoomInTheCartTests',
                'OnlyTestIdentifiers': ['StoreKitScenarioTests'],
                'TestHostPath': '__TESTROOT__/Debug-iphonesimulator/RoomInTheCart.app',
                'TestBundlePath': '__TESTHOST__/PlugIns/RoomInTheCartTests.xctest',
                'TestLanguage': options['language'], 'TestRegion': options['region'],
                'EnvironmentVariables': {row['key']: row['value'] for row in options['environmentVariableEntries']},
            }]})
        return products / 'LocalStoreKit.xctestrun', {'TestConfigurations': configurations}, resource

    def test_source_plan_and_steps_keep_both_locales_and_all_scenarios(self):
        configurations = self.plan['configurations']
        self.assertEqual(len(configurations), 2)
        self.assertEqual({row['name'] for row in configurations}, set(EXPECTED))
        for entry in configurations:
            _, language, offer_locale = EXPECTED[entry['name']]
            options = entry['options']
            self.assertEqual(options['language'], language)
            self.assertEqual(options['region'], 'US')
            self.assertEqual({row['key']: row['value'] for row in options['environmentVariableEntries']}, {
                'RITC_LOCAL_STOREKIT_TESTS': '1', 'RITC_STOREKIT_LOCALE': offer_locale,
                'RITC_APP_LANGUAGE': language,
            })
        self.assertEqual(len(self.plan['testTargets']), 1)
        self.assertEqual(self.plan['testTargets'][0]['selectedTests'], ['StoreKitScenarioTests'])
        selectors = (ROOT / 'scripts/ios_storekit_test_selectors.txt').read_text().splitlines()
        self.assertEqual(len(selectors), 15)
        self.assertEqual(len(set(selectors)), 15)
        self.assertTrue(all(value.startswith('RoomInTheCartTests/StoreKitScenarioTests/') for value in selectors))
        job = self.jobs['storekit']
        self.assertEqual(job['strategy'], {'fail-fast': False, 'matrix': {'locale': ['en', 'es']}})
        self.assertEqual(job['env']['STOREKIT_LOCALE'], '${{ matrix.locale }}')
        english, spanish = EXPECTED
        self.assertEqual(job['env']['STOREKIT_CONFIGURATION'],
                         "${{ matrix.locale == 'en' && '" + english + "' || '" + spanish + "' }}")

    def test_one_build_exact_artifact_and_test_without_building(self):
        build = self.jobs['storekit-build']
        tests = self.jobs['storekit']
        self.assertEqual(build['needs'], 'storekit-plan')
        self.assertEqual(tests['needs'], 'storekit-build')
        self.assertEqual(build['runs-on'], 'xcode-27')
        self.assertNotIn('concurrency', build)
        self.assertEqual(tests['runs-on'], FIXTURE_RUNNER)
        self.assertEqual(tests['concurrency'], {'group': bitrise_group(STOREKIT_JOB, POLICY[STOREKIT_JOB]),
                                               'queue': 'max', 'cancel-in-progress': False})
        commands = '\n'.join(step.get('run', '') for step in build['steps'])
        self.assertEqual(commands.count('build-for-testing'), 1)
        self.assertIn('-scheme RoomInTheCart-LocalStoreKit', commands)
        self.assertNotIn('-only-test-configuration', commands)
        self.assertEqual(build['outputs']['artifact'], "${{ steps.upload.outputs['artifact-id'] }}")
        download = next(step for step in tests['steps'] if step.get('uses', '').startswith('actions/download-artifact@'))
        self.assertEqual(download['with']['artifact-ids'], '${{ needs.storekit-build.outputs.artifact }}')
        self.assertNotIn('run-id', download['with'])
        self.assertEqual(tests['timeout-minutes'], 65)
        self.assertEqual(sum(step.get('id') == 'storekit-runtime' for step in tests['steps']), 1)
        self.assertEqual(sum(step.get('id') == 'storekit-restore' for step in tests['steps']), 1)
        native = self.step('storekit', identifier='storekit-native')
        command = native['run']
        self.assertIn('-xctestrun "${test_runs[0]}"', command)
        self.assertIn('test-without-building', command)
        self.assertNotIn('-project', command)
        self.assertNotIn('build-for-testing', command)
        self.assertIn('if [ "$STOREKIT_OS_BUILD" = 23C54 ]; then', command)
        self.assertLess(command.index('python3 scripts/check_storekit_runtime_mount.py'),
                        command.index('python3 scripts/boot_ios_simulator.py'))
        self.assertIn('python3 scripts/boot_ios_simulator.py "$SIMULATOR_ID"', command)
        self.assertEqual(command.count('python3 scripts/boot_ios_simulator.py --restart "$SIMULATOR_ID"'), 1)
        self.assertEqual(command.count('tee "$output/launch-failure/StoreKitRecoveryBoot.log"'), 2)
        self.assertIn('"$output/first-tests.json" "$native_status" "$SIMULATOR_ID"', command)
        self.assertIn('-only-test-configuration "$STOREKIT_CONFIGURATION"', command)
        self.assertIn('-default-test-execution-time-allowance 120', command)
        self.assertIn('-maximum-test-execution-time-allowance 120', command)
        self.assertIn('-collect-test-diagnostics on-failure', command)
        self.assertEqual(native['timeout-minutes'], 35)
        verifier = self.step('storekit', identifier='storekit-verify')
        self.assertIn('--expected-count 15', verifier['run'])
        self.assertIn('testPlanConfiguration', verifier['run'])
        self.assertEqual(verifier['if'], "${{ !cancelled() && steps.storekit-results.outcome == 'success' }}")
        upload = next(step for step in tests['steps'] if step.get('with', {}).get('name') ==
                      'storekit-${{ matrix.locale }}-${{ github.run_attempt }}')
        self.assertEqual(upload['if'], 'always()')
        self.assertIn('.build/storekit-${{ matrix.locale }}/', upload['with']['path'])
        self.assertIn('.build/StoreKitRuntime.log', upload['with']['path'])
        self.assertIn('.build/storekit-product-inventory.json', upload['with']['path'])
        self.assertFalse(any(step.get('continue-on-error') for step in tests['steps']))

    def test_pretest_boot_failure_keeps_locale_log_and_exit_status(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            helper = root / 'scripts/boot_ios_simulator.py'
            helper.parent.mkdir()
            helper.write_text('import sys\nprint("migration stopped", file=sys.stderr)\nsys.exit(70)\n')
            for locale in ('en', 'es'):
                step = self.step('storekit', identifier='storekit-native')
                result = subprocess.run(['bash', '-e', '-c', step['run']], cwd=root,
                                        env={**os.environ, 'STOREKIT_LOCALE': locale, 'SIMULATOR_ID': 'fixture'},
                                        capture_output=True, text=True, timeout=10)
                self.assertEqual(result.returncode, 70)
                self.assertIn('migration stopped', result.stdout)
                output = root / '.build' / f'storekit-{locale}'
                self.assertEqual((output / 'StoreKitBoot.log').read_text(), 'migration stopped\n')
                self.assertFalse((output / 'StoreKit.log').exists())

    def test_every_native_attempt_checks_the_booted_version_and_build(self):
        command = self.step('storekit', identifier='storekit-native')['run']
        for version, build, retry, expected_calls, expected_status in [
            ('26.2', '23C54', False, 1, 0),
            ('26.2', '23C52', False, 0, 1),
            ('27.0', '23C54', False, 0, 1),
            ('26.2', '23C52', True, 1, 1),
        ]:
            with self.subTest(version=version, build=build, retry=retry), tempfile.TemporaryDirectory() as temp:
                root = Path(temp)
                scripts = root / 'scripts'
                scripts.mkdir()
                for helper in ['check_storekit_runtime_mount', 'boot_ios_simulator', 'is_storekit_launch_failure']:
                    (scripts / (helper + '.py')).touch()
                products = root / '.build/StoreKitDerivedData/Build/Products'
                products.mkdir(parents=True)
                (products / 'LocalStoreKit.xctestrun').touch()
                simctl = root / 'xcrun'
                simctl.write_text("""#!/bin/sh
if [ "$1" = xcresulttool ]; then echo '{}'; exit 0; fi
[ "$1 $2 $3" = 'simctl getenv selected-device' ] || exit 99
case "$4" in
  SIMULATOR_RUNTIME_VERSION) echo "$OBSERVED_VERSION";;
  SIMULATOR_RUNTIME_BUILD_VERSION)
    if [ "$RETRY" = 1 ] && [ ! -f calls ]; then echo 23C54; else echo "$OBSERVED_BUILD"; fi;;
  *) exit 99;;
esac
""")
                xcode = root / 'xcodebuild'
                xcode.write_text("""#!/bin/sh
echo xcodebuild >> calls
mkdir -p .build/storekit-es/StoreKit.xcresult
if [ "$RETRY" = 1 ]; then exit 65; fi
""")
                for executable in [simctl, xcode]:
                    executable.chmod(0o755)
                result = subprocess.run(['bash', '-e', '-c', command], cwd=root, capture_output=True, text=True,
                                        env={**os.environ, 'PATH': str(root) + ':' + os.environ['PATH'],
                                             'SIMULATOR_ID': 'selected-device', 'STOREKIT_LOCALE': 'es',
                                             'STOREKIT_OS_VERSION': '26.2', 'STOREKIT_OS_BUILD': '23C54',
                                             'OBSERVED_VERSION': version, 'OBSERVED_BUILD': build,
                                             'RETRY': '1' if retry else '0'})
                self.assertEqual(result.returncode, expected_status, result.stderr)
                self.assertIn(f'Booted selected-device iOS {version}/{build}; required 26.2/23C54', result.stdout)
                calls = root / 'calls'
                self.assertEqual(len(calls.read_text().splitlines()) if calls.exists() else 0, expected_calls)

    def test_locale_jobs_check_native_and_export_after_failures(self):
        job = self.jobs['storekit']
        self.assertEqual(job['needs'], 'storekit-build')
        self.assertIs(job['strategy']['fail-fast'], False)
        native = self.step('storekit', identifier='storekit-native')
        self.assertEqual(native['if'], "${{ !cancelled() && steps.storekit-restore.outcome == 'success' && steps.storekit-runtime.outcome == 'success' }}")
        export = self.step('storekit', identifier='storekit-results')
        self.assertEqual(export['if'], "${{ !cancelled() && steps.storekit-native.outcome != 'skipped' }}")
        self.assertLess(export['run'].index('get test-results summary'), export['run'].index('get test-results tests'))

    def test_created_simulator_cleanup_and_fresh_device_for_both_locales_on_each_runtime(self):
        cleanup = self.step('storekit', name='Remove the simulator created by this locale job')
        self.assertEqual(cleanup['if'], "${{ always() && steps.storekit-runtime.outcome == 'success' && env.STOREKIT_CREATED_SIMULATOR != '' }}")
        self.assertEqual(cleanup['run'], 'xcrun simctl delete "$STOREKIT_CREATED_SIMULATOR"')
        for request, version, build in [('', '26.2', '23C54'), ('true', '27.0', '24A434')]:
            runtime = self.runtime_fixture(version, build)
            for locale in ('en', 'es'):
                with self.subTest(version=version, locale=locale):
                    environment, native, _ = self.prepare_runtime(request, 'pull_request', [runtime], locale=locale)
                    self.assertEqual(environment['SIMULATOR_ID'], '22222222-3333-4444-8555-666666666666')
                    self.assertEqual(environment['STOREKIT_CREATED_SIMULATOR'], environment['SIMULATOR_ID'])
                    self.assertEqual(native.call_args.args[0][-1], runtime['identifier'])
                    with self.assertRaises(AssertionError):
                        self.prepare_runtime(request, 'pull_request', [runtime], locale=locale,
                                             created='11111111-2222-4333-8444-555555555555')

    def test_only_an_unstarted_storekit_plan_with_the_launch_service_crash_can_retry(self):
        reason = ('Failed to install or launch the test runner. (Underlying Error: '
                  'The operation couldn’t be completed. (Mach error -308 - (ipc/mig) server died))')
        failure = {'nodeType': 'Failure Message', 'name': reason}
        runner = {'nodeType': 'Test Case', 'name': 'RoomInTheCart encountered an error',
                  'result': 'Failed', 'children': [failure]}
        suite = {'nodeType': 'Test Suite', 'name': 'System Failures', 'children': [runner]}
        bundle = {'nodeType': 'Unit test bundle', 'name': 'RoomInTheCartTests', 'children': [suite]}
        tests = {'testNodes': [{'nodeType': 'Test Plan', 'name': 'LocalStoreKit', 'children': [bundle]}]}
        log = '\tRoomInTheCart encountered an error (' + reason + ')\n'
        self.assertTrue(is_launch_failure(log, tests))
        for marker in ("Test Suite 'Selected tests' started", "interleaved: Test Case '…' started.",
                       'File.swift:2: error: -[Suite testPurchase]', 'Restarting after unexpected exit, crash, or test timeout;'):
            with self.subTest(marker=marker):
                self.assertFalse(is_launch_failure(marker + '\n' + log, tests))
        self.assertFalse(is_launch_failure(log.replace('-308', '-309'), tests))
        self.assertFalse(is_launch_failure(log, {'testNodes': []}))
        with patch.dict(runner, nodeIdentifierURL='test://target/StoreKitScenarioTests/testPurchase()'):
            self.assertFalse(is_launch_failure(log, tests))
        with patch.dict(failure, name='StoreKit entitlement assertion failed'):
            self.assertFalse(is_launch_failure(log, tests))
        with patch.dict(bundle, children=[suite, {'nodeType': 'Test Suite', 'name': 'StoreKitScenarioTests'}]):
            self.assertFalse(is_launch_failure(log, tests))

    def test_only_the_selected_undiscovered_destination_with_zero_tests_can_retry(self):
        simulator = '537CD1E8-8CC9-469A-A068-A966CAA1F02A'
        log = f"""xcodebuild: error: Unable to find a device matching the provided destination specifier:
            {{ platform:iOS Simulator, id:{simulator} }}
            The requested device could not be found because no available devices matched the request.
            Destinations compatible with the "RoomInTheCart-LocalStoreKit" scheme:
            {{ platform:iOS Simulator, id:dvtdevice-DVTiOSDeviceSimulatorPlaceholder-iphonesimulator:placeholder, name:Any iOS Simulator Device }}"""
        devices = [dict.fromkeys(('architecture', 'deviceId', 'deviceName', 'modelName', 'osVersion', 'platform'), '')]
        tests = {'testNodes': [], 'testPlanConfigurations': [], 'devices': devices}
        self.assertTrue(is_launch_failure(log, tests, 70, simulator))
        self.assertFalse(is_launch_failure(log, tests, 65, simulator))
        self.assertFalse(is_launch_failure(log, tests, 70, 'different-device'))
        self.assertFalse(is_launch_failure(log + '\nxcodebuild: error: Other error', tests, 70, simulator))
        self.assertFalse(is_launch_failure(log + '\n{ platform:iOS Simulator, id:another }', tests, 70, simulator))
        self.assertFalse(is_launch_failure("Test Case 'purchase' started.\n" + log, tests, 70, simulator))
        for field in tests:
            with self.subTest(field=field):
                self.assertFalse(is_launch_failure(log, {**tests, field: ['nonempty']}, 70, simulator))
                self.assertFalse(is_launch_failure(log, {k: v for k, v in tests.items() if k != field}, 70, simulator))

    def test_locale_gate_rejects_every_failed_skipped_cancelled_or_missing_outcome(self):
        gate = self.step('storekit', identifier='storekit-locale-gate')
        self.assertEqual(gate['if'], 'always()')
        self.assertEqual(gate['env']['STOREKIT_STEP_RESULTS'], '${{ toJSON(steps) }}')
        code = self.python_block(gate)
        successful = {f'storekit-{phase}': {'outcome': 'success'} for phase in ('native', 'results', 'verify')}
        self.execute(code, ROOT, STOREKIT_STEP_RESULTS=json.dumps(successful))
        for name in successful:
            for outcome in ('failure', 'skipped', 'cancelled', '', None):
                values = copy.deepcopy(successful)
                values[name] = {'outcome': outcome, 'conclusion': 'success'}
                with self.subTest(step=name, outcome=outcome), self.assertRaises(SystemExit):
                    self.execute(code, ROOT, STOREKIT_STEP_RESULTS=json.dumps(values))
            missing = copy.deepcopy(successful); missing.pop(name)
            with self.subTest(missing=name), self.assertRaises(SystemExit):
                self.execute(code, ROOT, STOREKIT_STEP_RESULTS=json.dumps(missing))

    def test_linux_preflight_installs_hash_pinned_yaml_before_test(self):
        job = self.jobs['storekit-plan']
        self.assertEqual(job['runs-on'], 'ubuntu-24.04')
        command = '\n'.join(step.get('run', '') for step in job['steps'])
        self.assertIn('--require-hashes --only-binary=:all: -r scripts/ci_yaml_requirements.txt', command)
        self.assertIn('.build/storekit-workflow-venv/bin/python scripts/test_storekit_workflow.py', command)

    def test_release_requires_current_os_and_defaults_do_not_inherit_pr_policy(self):
        for event in ('workflow_call', 'workflow_dispatch'):
            option = self.workflow['on'][event]['inputs']['require_current_storekit']
            self.assertEqual(option['type'], 'boolean')
            self.assertIs(option['default'], True)
        release = parse_workflow(ROOT / '.github/workflows/release-checks.yml')[0]
        self.assertEqual(release['jobs']['diagnostics']['uses'], './.github/workflows/ios-deep.yml')
        self.assertIs(release['jobs']['diagnostics']['with']['require_current_storekit'], True)
        self.assertIn('diagnostics', release['jobs']['release-checks']['needs'])
        self.assertNotIn('if', release['jobs']['diagnostics'])
        self.assertNotIn('continue-on-error', release['jobs']['diagnostics'])
        self.assertEqual(self.jobs['storekit']['env']['REQUIRE_CURRENT_STOREKIT'],
                         '${{ inputs.require_current_storekit }}')
        self.assertEqual(self.jobs['storekit-build']['env']['CI_IPHONE_RUNTIME'],
                         'com.apple.CoreSimulator.SimRuntime.iOS-27-0')
        self.assertNotIn('-downloadPlatform', '\n'.join(s.get('run', '') for s in self.jobs['storekit-build']['steps']))
        self.assertEqual(self.step('storekit', identifier='storekit-runtime')['timeout-minutes'], 20)

    def runtime_fixture(self, version, build):
        return {'identifier': 'com.apple.CoreSimulator.SimRuntime.iOS-' + version.replace('.', '-'),
                'version': version, 'buildversion': build, 'isAvailable': True}

    def prepare_runtime(self, request, event, runtimes, *, after_download=None, existing_device=True, download_error=None,
                        locale='en', created='22222222-3333-4444-8555-666666666666', provider='self-hosted'):
        """Execute the actual workflow block with only native subprocesses replaced."""
        code = self.python_block(self.step('storekit', identifier='storekit-runtime'))
        simulator = '11111111-2222-4333-8444-555555555555'
        reads = [runtimes] + ([after_download] if after_download is not None else [])
        device = {'udid': simulator, 'name': 'iPhone 17', 'isAvailable': True,
                  'deviceTypeIdentifier': 'com.apple.CoreSimulator.SimDeviceType.iPhone-17'}
        def fake_simctl(command, *, text):
            self.assertTrue(text)
            self.assertEqual(command[:2], ['xcrun', 'simctl'])
            if command[2:] == ['list', '-j']:
                installed = reads.pop(0)
                return json.dumps({'runtimes': installed, 'devices': {
                    r['identifier']: [device] if existing_device else [] for r in installed}})
            if command[2:3] == ['create']:
                self.assertEqual(command[3:5], [f'RITC-StoreKit-{locale}', device['deviceTypeIdentifier']])
                return created + '\n'
            self.fail(f'Unexpected native command: {command}')
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            environment = root / 'environment'
            with patch('subprocess.check_output', side_effect=fake_simctl) as native, \
                    patch('subprocess.run', side_effect=download_error) as download:
                self.execute(code, root, REQUIRE_CURRENT_STOREKIT=request, GITHUB_EVENT_NAME=event,
                             CI_IPHONE_NAME='iPhone 17', GITHUB_ENV=str(environment), STOREKIT_LOCALE=locale,
                             RUNNER_ENVIRONMENT=provider, STOREKIT_IMPORTED_RUNTIME='')
            return dict(line.split('=', 1) for line in environment.read_text().splitlines()), native, download

    def test_storekit_mount_distinguishes_replacement_from_healthy_images(self):
        runtime = self.runtime_fixture('26.2', '23C54')
        fallback = str(runtime_mount.FALLBACK / 'Library/Developer/CoreSimulator/Profiles/Runtimes/iOS 26.2.simruntime')
        preferred = fallback.replace(str(runtime_mount.FALLBACK), '/private/var/run/com.apple.security.cryptexd/mnt/iOS_23C54')
        image = {'identifier': 'original', 'runtimeIdentifier': runtime['identifier'], 'build': '23C54',
                 'state': 'Ready', 'kind': 'Patchable Cryptex Disk Image', 'runtimeBundlePath': fallback,
                 'path': '/System/Library/AssetsV2/com_apple_MobileAsset_iOSSimulatorRuntime/local.asset/AssetData'}
        displaced = {**image, 'state': 'Unusable', 'unusableSubstate': 'Cryptex Mount Preferred'}
        replacement = {**image, 'identifier': 'replacement', 'runtimeBundlePath': preferred}
        for bundle, images, expected in [
            (fallback, [image], 'fallback'),
            (fallback, [{**image, 'kind': 'Disk Image'}], 'ready'),
            (fallback, [{**image, 'path': '/Library/Developer/CoreSimulator/Images/local.dmg'}], 'ready'),
            (None, [displaced], 'replacing'),
            (preferred, [replacement, displaced], 'ready'),
            (preferred, [{**replacement, 'build': 'wrong'}], 'unavailable'),
            (preferred, [replacement, {**replacement, 'identifier': 'ambiguous'}], 'unavailable'),
        ]:
            with self.subTest(bundle=bundle, expected=expected):
                runtime_list = {'runtimes': [self.runtime_fixture('26.2', '23C52')]}
                if bundle:
                    runtime_list['runtimes'].append({**runtime, 'bundlePath': bundle})
                image_list = {i['identifier']: i for i in images}
                with patch.object(runtime_mount, 'simctl', side_effect=[json.dumps(runtime_list), json.dumps(image_list)]):
                    self.assertEqual(runtime_mount.mount_state(), expected)

    def test_storekit_mount_rescans_once_only_for_observed_image_replacement(self):
        for states, times, expected_scans, fails in [
            (['ready'], [], 0, False),
            (['unavailable'], [], 0, True),
            (['fallback', 'replacing', 'ready'], [0, 0], 1, False),
            (['replacing', 'unavailable', 'ready'], [0, 0], 1, False),
            (['fallback', 'fallback', 'fallback', 'replacing', 'ready'], [0, 61, 590, 600], 1, False),
            (['fallback', 'fallback'], [0, 661], 1, True),
            (['replacing', 'replacing'], [0, 61], 1, True),
            (['fallback', 'replacing', 'unavailable'], [0, 100, 161], 1, True),
        ]:
            with self.subTest(states=states), patch.object(runtime_mount, 'mount_state', side_effect=states), \
                    patch.object(runtime_mount, 'simctl') as simctl, \
                    patch('time.monotonic', side_effect=times), patch('time.sleep'):
                if fails:
                    with self.assertRaises(RuntimeError):
                        runtime_mount.check_mount()
                else:
                    runtime_mount.check_mount()
                if expected_scans:
                    simctl.assert_called_once_with('runtime', 'scan-and-mount')
                else:
                    simctl.assert_not_called()

    def test_actual_runtime_policy_handles_pr_manual_and_pr_originated_reuse(self):
        cases = [('', 'pull_request', '26.2', '23C54'),
                 ('true', 'pull_request', '27.0', '24A434'),  # Explicit release input wins.
                 ('true', 'workflow_dispatch', '27.0', '24A434'),
                 ('false', 'workflow_dispatch', '26.2', '23C54'),
                 ('', 'workflow_dispatch', '27.0', '24A434')]
        for request, event, version, build in cases:
            with self.subTest(request=request, event=event):
                runtime = self.runtime_fixture(version, build)
                environment, native, download = self.prepare_runtime(request, event, [runtime])
                self.assertEqual(environment['STOREKIT_CREATED_SIMULATOR'], environment['SIMULATOR_ID'])
                native.assert_any_call(['xcrun', 'simctl', 'list', '-j'], text=True)
                self.assertEqual(sum(call.args[0][2:3] == ['create'] for call in native.call_args_list), 1)
                self.assertEqual(environment['CI_IPHONE_RUNTIME'], runtime['identifier'])
                self.assertEqual(environment['STOREKIT_OS_VERSION'], version)
                self.assertEqual(environment['STOREKIT_OS_BUILD'], build)
                download.assert_not_called()

    def test_github_compatibility_imports_once_before_creating_each_locale_device(self):
        runtime = self.runtime_fixture('26.2', '23C54')
        for locale in ('en', 'es'):
            with self.subTest(locale=locale):
                environment, native, preparation = self.prepare_runtime(
                    '', 'pull_request', [runtime], existing_device=False,
                    locale=locale, provider='github-hosted')
                preparation.assert_called_once_with(
                    ['python3', 'scripts/prepare_github_storekit_runtime.py'], check=True)
                self.assertEqual(environment['STOREKIT_IMPORTED_RUNTIME'], '23C54')
                self.assertEqual(sum(call.args[0][2:3] == ['create'] for call in native.call_args_list), 1)
                self.assertEqual(environment['STOREKIT_CREATED_SIMULATOR'], environment['SIMULATOR_ID'])
        for inventory in ([], [{**runtime, 'buildversion': 'wrong'}]):
            with self.subTest(inventory=inventory), self.assertRaises(AssertionError):
                self.prepare_runtime('', 'pull_request', inventory, provider='github-hosted')
        with self.assertRaises(subprocess.CalledProcessError):
            self.prepare_runtime('', 'pull_request', [runtime], provider='github-hosted',
                                 download_error=subprocess.CalledProcessError(1, 'import'))

    def test_github_current_policy_does_not_invoke_compatibility_import(self):
        runtime = self.runtime_fixture('27.0', '24A434')
        for request, event in [('true', 'pull_request'), ('true', 'workflow_dispatch'), ('', 'workflow_dispatch')]:
            with self.subTest(request=request, event=event):
                environment, _, preparation = self.prepare_runtime(request, event, [runtime], provider='github-hosted')
                preparation.assert_not_called()
                self.assertNotIn('STOREKIT_IMPORTED_RUNTIME', environment)

    def test_import_stability_runs_after_native_failure_and_is_required_only_when_imported(self):
        stability = self.step('storekit', identifier='storekit-import-stability')
        self.assertEqual(stability['if'], "${{ !cancelled() && env.STOREKIT_IMPORTED_RUNTIME == '23C54' }}")
        gate = self.python_block(self.step('storekit', identifier='storekit-locale-gate'))
        successful = {f'storekit-{phase}': {'outcome': 'success'} for phase in ('native', 'results', 'verify')}
        self.execute(gate, ROOT, STOREKIT_STEP_RESULTS=json.dumps(successful), STOREKIT_IMPORTED_RUNTIME='')
        for outcome in ('failure', 'skipped', 'cancelled', None):
            results = copy.deepcopy(successful)
            if outcome is not None:
                results['storekit-import-stability'] = {'outcome': outcome}
            with self.subTest(outcome=outcome), self.assertRaises(SystemExit):
                self.execute(gate, ROOT, STOREKIT_STEP_RESULTS=json.dumps(results), STOREKIT_IMPORTED_RUNTIME='23C54')
        successful['storekit-import-stability'] = {'outcome': 'success'}
        self.execute(gate, ROOT, STOREKIT_STEP_RESULTS=json.dumps(successful), STOREKIT_IMPORTED_RUNTIME='23C54')

    def test_import_stability_rejects_runtime_changes_pending_assets_and_recovery(self):
        code = self.step('storekit', identifier='storekit-import-stability')['run']
        for locale in ('en', 'es'):
            for change in ('none', 'uuid', 'mount', 'pending', 'recovery', 'restart',
                           'cryptex', 'parent-mount', 'parent-id', 'missing-image'):
                with self.subTest(locale=locale, change=change), tempfile.TemporaryDirectory() as directory:
                    root = Path(directory)
                    evidence = root / '.build/storekit-runtime-import'
                    evidence.mkdir(parents=True)
                    mount = root / 'imported-mount'
                    mount.mkdir()
                    bundle = mount / 'iOS 26.2.simruntime'
                    bundle.mkdir()
                    image = root / 'imported.dmg'
                    image.write_bytes(b'image')
                    target = {'identifier': 'imported-id', 'state': 'Ready', 'build': '23C54',
                              'kind': 'Disk Image',
                              'runtimeIdentifier': 'com.apple.CoreSimulator.SimRuntime.iOS-26-2',
                              'path': str(image),
                              'mountPath': str(mount), 'runtimeBundlePath': str(bundle)}
                    (evidence / 'target.json').write_text(json.dumps(target))
                    (evidence / 'original-asset-paths.json').write_text(json.dumps({'roots': ['/original/AssetData']}))
                    output = root / ('.build/storekit-' + locale)
                    output.mkdir()
                    (output / 'StoreKit.log').write_text('Restarting after unexpected exit' if change == 'restart' else 'Native log')
                    if change == 'recovery':
                        (output / 'launch-failure').mkdir()
                    after = dict(target)
                    if change == 'uuid':
                        after['identifier'] = 'changed-id'
                    if change == 'mount':
                        after['mountPath'] = '/changed-mount'
                    if change == 'cryptex':
                        after['kind'] = 'Patchable Cryptex Disk Image'
                    if change == 'parent-mount':
                        after['parentMountPath'] = '/temporary/exportedBundle'
                    if change == 'parent-id':
                        after['parentIdentifier'] = 'unexpected-parent'
                    if change == 'missing-image':
                        image.unlink()
                    snapshot = {after['identifier']: after}
                    if change == 'pending':
                        snapshot['pending'] = {'path': '/original/AssetData/Restore/runtime.dmg', 'state': 'Verifying'}
                    with patch('subprocess.check_output', return_value=json.dumps(snapshot)):
                        if change == 'none':
                            self.execute(code, root, STOREKIT_LOCALE=locale)
                            receipt = json.loads((evidence / 'stability-passed.json').read_text())
                            self.assertEqual(receipt['identifier'], target['identifier'])
                        else:
                            with self.assertRaises(AssertionError):
                                self.execute(code, root, STOREKIT_LOCALE=locale)
                    self.assertTrue((evidence / 'after-tests.json').is_file())

    def test_shared_identifier_creates_owned_device_from_the_exact_runtime_bundle(self):
        exact = {**self.runtime_fixture('26.2', '23C54'),
                 'bundlePath': '/Volumes/iOS_23C54/iOS 26.2.simruntime'}
        other = {**exact, 'buildversion': '23C52', 'bundlePath': '/Volumes/iOS_23C52/iOS 26.2.simruntime'}
        for locale, inventory in [('en', [other, exact]), ('es', [exact, other])]:
            with self.subTest(locale=locale):
                environment, native, download = self.prepare_runtime('', 'pull_request', inventory, locale=locale)
                native.assert_called_with(['xcrun', 'simctl', 'create', 'RITC-StoreKit-' + locale,
                                           'com.apple.CoreSimulator.SimDeviceType.iPhone-17',
                                           exact['bundlePath']], text=True)
                self.assertEqual(environment['SIMULATOR_ID'], environment['STOREKIT_CREATED_SIMULATOR'])
                self.assertEqual(environment['STOREKIT_OS_BUILD'], '23C54')
                download.assert_not_called()
        for inventory in ([other, exact, exact], [other, {**exact, 'isAvailable': False}],
                          [other, {**exact, 'bundlePath': 'relative.simruntime'}]):
            with self.subTest(inventory=inventory), self.assertRaises(AssertionError):
                self.prepare_runtime('', 'pull_request', inventory)

    def test_missing_compatibility_runtime_downloads_exact_build_and_creates_only_its_device(self):
        runtime = self.runtime_fixture('26.2', '23C54')
        environment, native, download = self.prepare_runtime('', 'pull_request', [],
                                                             after_download=[runtime], existing_device=False)
        download.assert_called_once_with(['xcodebuild', '-downloadPlatform', 'iOS', '-buildVersion', '23C54',
                                          '-architectureVariant', 'arm64'], check=True, timeout=600)
        self.assertEqual(sum(call.args[0][2:3] == ['create'] for call in native.call_args_list), 1)
        self.assertEqual(environment['SIMULATOR_ID'], '22222222-3333-4444-8555-666666666666')
        self.assertEqual(environment['STOREKIT_CREATED_SIMULATOR'], environment['SIMULATOR_ID'])

    def test_runtime_setup_rejects_wrong_build_version_unavailable_or_missing_current_without_fallback(self):
        good = self.runtime_fixture('26.2', '23C54')
        for bad in ({**good, 'buildversion': '23C52'}, {**good, 'version': '26.3'},
                    {**good, 'isAvailable': False}):
            with self.subTest(runtime=bad), self.assertRaises(AssertionError):
                self.prepare_runtime('', 'pull_request', [bad])
            with self.subTest(downloaded=bad), self.assertRaises(AssertionError):
                self.prepare_runtime('', 'pull_request', [], after_download=[bad])
        for request, runtimes in [('true', []), ('true', [self.runtime_fixture('26.2', '23C54')]),
                                  ('false', [good, good]), ('invalid', [good])]:
            with self.subTest(request=request, runtimes=runtimes), self.assertRaises(AssertionError):
                self.prepare_runtime(request, 'pull_request', runtimes)
        with self.assertRaises(AssertionError):
            self.prepare_runtime('true', 'pull_request', [self.runtime_fixture('27.0', '24A434')], existing_device=False)
        for error in (subprocess.TimeoutExpired('download', 600), subprocess.CalledProcessError(1, 'download')):
            with self.subTest(error=type(error).__name__), self.assertRaises(type(error)):
                self.prepare_runtime('', 'pull_request', [], after_download=[good], download_error=error)

    def test_result_checks_exact_runtime_build_device_and_locale_for_both_policies(self):
        code = self.python_block(self.step('storekit', identifier='storekit-verify'))
        for version, build in [('26.2', '23C54'), ('27.0', '24A434')]:
            for locale in EXPECTED:
                with tempfile.TemporaryDirectory() as directory:
                    root = Path(directory); output = root / '.build' / ('storekit-' + EXPECTED[locale][0]); output.mkdir(parents=True)
                    device = {'osVersion': version, 'osBuildNumber': build, 'architecture': 'arm64',
                              'modelName': 'iPhone 17', 'platform': 'iOS Simulator', 'deviceId': 'selected-device'}
                    configuration = {'testPlanConfiguration': {'configurationName': locale}, 'device': device}
                    summary = output / 'storekit-summary.json'
                    def validate(value):
                        summary.write_text(json.dumps({'devicesAndConfigurations': value}))
                        self.execute(code, root, STOREKIT_LOCALE=EXPECTED[locale][0], STOREKIT_CONFIGURATION=locale, STOREKIT_OS_VERSION=version,
                                     STOREKIT_OS_BUILD=build, SIMULATOR_ID='SELECTED-DEVICE')
                    validate([configuration])
                    for key in device:
                        wrong = copy.deepcopy(configuration); wrong['device'][key] = 'wrong'
                        with self.subTest(version=version, locale=locale, field=key), self.assertRaises(AssertionError):
                            validate([wrong])
                    wrong_locale = copy.deepcopy(configuration)
                    wrong_locale['testPlanConfiguration']['configurationName'] = 'wrong'
                    for values in ([], [configuration, configuration], [wrong_locale]):
                        with self.assertRaises(AssertionError): validate(values)

    def test_real_inventory_and_restore_code_accept_both_configs(self):
        inventory = self.python_block(self.step('storekit-build', identifier='storekit-inventory'))
        restore = self.python_block(self.step('storekit', identifier='storekit-restore'))
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            run, fixture, _ = self.compiled_fixture(root)
            run.write_bytes(plistlib.dumps(fixture))
            self.execute(inventory, root, GITHUB_SHA='checked-commit')
            self.execute(restore, root, GITHUB_SHA='checked-commit')
            with self.assertRaises(AssertionError):
                self.execute(restore, root, GITHUB_SHA='different-commit')
            path = root / '.build/storekit-product-inventory.json'
            original = json.loads(path.read_text())
            for configurations in ([], [next(iter(EXPECTED))], [*EXPECTED, 'unbuilt-locale'],
                                   [next(iter(EXPECTED)), next(iter(EXPECTED))]):
                value = {**original, 'configurations': configurations}
                path.write_text(json.dumps(value))
                with self.subTest(configurations=configurations), self.assertRaises(AssertionError):
                    self.execute(restore, root, GITHUB_SHA='checked-commit')

    def test_shared_products_reject_wrong_sdk_toolchain_or_deployment_target(self):
        inventory = self.python_block(self.step('storekit-build', identifier='storekit-inventory'))
        restore = self.python_block(self.step('storekit', identifier='storekit-restore'))
        for field, wrong in [('DTSDKName', 'iphonesimulator26.2'), ('DTXcodeBuild', 'other'), ('MinimumOSVersion', '27.0')]:
            with self.subTest(field=field), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                run, fixture, _ = self.compiled_fixture(root)
                run.write_bytes(plistlib.dumps(fixture))
                info_path = run.parent / 'Debug-iphonesimulator/RoomInTheCart.app/Info.plist'
                info = plistlib.loads(info_path.read_bytes()); info[field] = wrong
                info_path.write_bytes(plistlib.dumps(info))
                with self.assertRaises(AssertionError): self.execute(inventory, root, GITHUB_SHA='checked-commit')
        for field in ('buildSDK', 'xcodeBuild'):
            with self.subTest(field=field), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                run, fixture, _ = self.compiled_fixture(root)
                run.write_bytes(plistlib.dumps(fixture))
                self.execute(inventory, root, GITHUB_SHA='checked-commit')
                path = root / '.build/storekit-product-inventory.json'
                value = json.loads(path.read_text()); value[field] = 'wrong'; path.write_text(json.dumps(value))
                with self.assertRaises(AssertionError):
                    self.execute(restore, root, GITHUB_SHA='checked-commit', STOREKIT_CONFIGURATION=next(iter(EXPECTED)))

    def test_real_inventory_rejects_missing_disabled_or_narrowed_configuration(self):
        code = self.python_block(self.step('storekit-build', identifier='storekit-inventory'))
        def missing(value): value['TestConfigurations'].pop()
        def duplicate(value): value['TestConfigurations'][1]['Name'] = value['TestConfigurations'][0]['Name']
        def disabled(value): value['TestConfigurations'][1]['IsEnabled'] = False
        def wrong_language(value): value['TestConfigurations'][1]['TestTargets'][0]['TestLanguage'] = 'en-US'
        def wrong_offer(value): value['TestConfigurations'][1]['TestTargets'][0]['EnvironmentVariables']['RITC_STOREKIT_LOCALE'] = 'en_US'
        def narrowed(value): value['TestConfigurations'][0]['TestTargets'][0]['OnlyTestIdentifiers'] = ['StoreKitScenarioTests/testOne']
        def skipped(value): value['TestConfigurations'][0]['TestTargets'][0]['SkipTestIdentifiers'] = ['StoreKitScenarioTests/testOne']
        for mutate in [missing, duplicate, disabled, wrong_language, wrong_offer, narrowed, skipped]:
            with self.subTest(mutation=mutate.__name__), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                run, fixture, _ = self.compiled_fixture(root)
                mutate(fixture); run.write_bytes(plistlib.dumps(fixture))
                with self.assertRaises(AssertionError): self.execute(code, root, GITHUB_SHA='checked-commit')
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            run, fixture, resource = self.compiled_fixture(root)
            run.write_bytes(plistlib.dumps(fixture)); resource.unlink()
            with self.assertRaises(AssertionError): self.execute(code, root, GITHUB_SHA='checked-commit')

    def test_gate_rejects_failure_cancellation_skip_or_missing_dependency(self):
        gate = self.jobs['storekit-gate']
        self.assertEqual(gate['needs'], ['storekit-plan', 'storekit-build', 'storekit'])
        self.assertEqual(gate['if'], 'always()')
        self.assertEqual(gate['runs-on'], 'ubuntu-24.04')
        code = self.python_block(gate['steps'][0])
        successful = {name: {'result': 'success'} for name in gate['needs']}
        self.execute(code, ROOT, JOB_RESULTS=json.dumps(successful))
        for name in successful:
            for result in ['failure', 'cancelled', 'skipped']:
                values = copy.deepcopy(successful); values[name]['result'] = result
                with self.subTest(job=name, result=result), self.assertRaises(SystemExit):
                    self.execute(code, ROOT, JOB_RESULTS=json.dumps(values))
        missing = copy.deepcopy(successful); missing.pop('storekit-build')
        with self.assertRaises(AssertionError): self.execute(code, ROOT, JOB_RESULTS=json.dumps(missing))


if __name__ == '__main__':
    unittest.main()
