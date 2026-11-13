import contextlib
import copy
import io
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from check_ci_workflows import parse_workflow
from check_ios_performance_environment import configured_environment, main, require_compatible_baseline, runner_environment, write_toolchain_identity

ROOT = Path(__file__).resolve().parents[1]
ENV = {'DEVELOPER_DIR': '/Applications/Xcode_27.1.app/Contents/Developer',
       'CI_IPHONE_RUNTIME': 'com.apple.CoreSimulator.SimRuntime.iOS-27-0',
       'CI_IPHONE_NAME': 'iPhone 17', 'SIMULATOR_ID': 'selected-device', 'ENFORCE_BASELINES': 'true'}
XCODE = 'Xcode 27.1\nBuild version 27A9275'
JOB = {'GITHUB_SHA': 'a' * 40, 'GITHUB_RUN_ID': '123', 'GITHUB_RUN_ATTEMPT': '1',
       'GITHUB_JOB': 'performance-tests', 'RUNNER_NAME': 'fixture-runner'}
# Fictional runtime build: tests must never invent an approved real calibration.
INVENTORY = {'devices': {ENV['CI_IPHONE_RUNTIME']: [{'udid': 'selected-device', 'isAvailable': True,
    'deviceTypeIdentifier': 'com.apple.CoreSimulator.SimDeviceType.iPhone-17'}]},
    'runtimes': [{'identifier': ENV['CI_IPHONE_RUNTIME'], 'isAvailable': True, 'version': '27.0', 'buildversion': 'fixture-build'}],
    'devicetypes': [{'identifier': 'com.apple.CoreSimulator.SimDeviceType.iPhone-17', 'name': 'iPhone 17'}]}


def approved_fixture():
    baseline = json.loads((ROOT / 'scripts/ios_performance_baselines.json').read_text())
    baseline['profiles'][0]['environment'].update(runner_environment(ENV, INVENTORY, XCODE, 'arm64'))
    return baseline


class PerformanceEnvironmentTests(unittest.TestCase):
    def test_identity_written_after_success_with_whitelisted_bindings_and_write_timing(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'identity.json'
            env = {**ENV, **JOB, 'ENFORCE_BASELINES': 'false', 'SECRET': 'do-not-retain'}
            with patch.dict(os.environ, env, clear=True), \
                 patch('sys.argv', ['guard', 'runner', '--identity-output', str(path)]), \
                 patch('check_ios_performance_environment.platform.machine', return_value='arm64'), \
                 patch('check_ios_performance_environment.subprocess.check_output', side_effect=[json.dumps(INVENTORY), XCODE]) as native, \
                 contextlib.redirect_stdout(io.StringIO()) as output:
                main()
            receipt = json.loads(path.read_text())
            self.assertEqual(receipt['context'], {key: env[key] for key in receipt['context']})
            self.assertEqual(receipt['toolchain'], XCODE)
            self.assertEqual(receipt['architecture'], 'arm64')
            self.assertTrue(receipt['passed'])
            self.assertFalse(receipt['releaseAcceptance'])
            self.assertNotIn('do-not-retain', path.read_text())
            self.assertGreaterEqual(json.loads(output.getvalue())['identityReceiptWriteSeconds'], 0)
            self.assertEqual(native.call_count, 2)

    def test_no_identity_on_baseline_or_environment_failure(self):
        with tempfile.TemporaryDirectory() as folder:
            for mode in ('baseline', 'environment'):
                path = Path(folder) / (mode + '.json')
                env = {**ENV, **JOB, 'ENFORCE_BASELINES': 'true' if mode == 'baseline' else 'false'}
                version = XCODE if mode == 'baseline' else XCODE.replace('27.1', '27.2')
                with self.subTest(mode=mode), patch.dict(os.environ, env, clear=True), \
                     patch('sys.argv', ['guard', 'runner', '--identity-output', str(path)]), \
                     patch('check_ios_performance_environment.platform.machine', return_value='arm64'), \
                     patch('check_ios_performance_environment.subprocess.check_output', side_effect=[json.dumps(INVENTORY), version]), \
                     contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                    main()
                self.assertFalse(path.exists())

    def test_identity_supported_after_approved_fixture_baseline_success(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'identity.json'; baseline = Path(folder) / 'baseline.json'
            baseline.write_text(json.dumps(approved_fixture()))
            with patch.dict(os.environ, {**ENV, **JOB}, clear=True), \
                 patch('sys.argv', ['guard', 'runner', '--baseline', str(baseline), '--identity-output', str(path)]), \
                 patch('check_ios_performance_environment.platform.machine', return_value='arm64'), \
                 patch('check_ios_performance_environment.subprocess.check_output', side_effect=[json.dumps(INVENTORY), XCODE]), \
                 contextlib.redirect_stdout(io.StringIO()) as output:
                main()
            self.assertEqual(json.loads(output.getvalue())['compatibleProfiles'], 1)
            self.assertEqual(json.loads(path.read_text())['context']['ENFORCE_BASELINES'], 'true')

    def test_identity_rejects_configured_stage_without_queries(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'identity.json'
            with patch.dict(os.environ, {**ENV, **JOB}, clear=True), \
                 patch('sys.argv', ['guard', 'configured', '--architecture', 'arm64', '--identity-output', str(path)]), \
                 patch('check_ios_performance_environment.subprocess.check_output') as native, \
                 contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                main()
            native.assert_not_called()
            self.assertFalse(path.exists())

    def test_identity_requires_complete_context_and_never_overwrites(self):
        observed = runner_environment(ENV, INVENTORY, XCODE, 'arm64')
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'identity.json'
            with self.assertRaises(KeyError):
                write_toolchain_identity(path, ENV, observed)
            self.assertFalse(path.exists())
            with self.assertRaises(ValueError):
                write_toolchain_identity(path, {**ENV, **JOB, 'GITHUB_SHA': 'short'}, observed)
            write_toolchain_identity(path, {**ENV, **JOB}, observed)
            before = path.read_bytes()
            with self.assertRaises(FileExistsError):
                write_toolchain_identity(path, {**ENV, **JOB}, observed)
            self.assertEqual(path.read_bytes(), before)

    def test_real_old_baseline_rejected_in_both_stages_and_new_fixture_allowed(self):
        old = json.loads((ROOT / 'scripts/ios_performance_baselines.json').read_text())
        for environment in (configured_environment(ENV, 'arm64'), runner_environment(ENV, INVENTORY, XCODE, 'arm64')):
            with self.assertRaisesRegex(ValueError, 'No approved baseline'):
                require_compatible_baseline(old, environment)
            self.assertEqual(require_compatible_baseline(approved_fixture(), environment), 1)

    def test_every_known_configured_dimension_rejects_incompatibility(self):
        configured = configured_environment(ENV, 'arm64')
        for key, wrong in [('xcodeVersion', '26.3'), ('osVersion', '26.2'), ('modelName', 'iPhone Duo'), ('architecture', 'x86_64')]:
            with self.subTest(key=key), self.assertRaisesRegex(ValueError, 'No approved baseline'):
                require_compatible_baseline(approved_fixture(), {**configured, key: wrong})
        # Linux cannot know the runtime/toolchain build; the runner must reject drift.
        drift = approved_fixture()
        drift['profiles'][0]['environment']['osBuildNumber'] = 'different-build'
        self.assertEqual(require_compatible_baseline(drift, configured), 1)
        observed = runner_environment(ENV, INVENTORY, XCODE, 'arm64')
        for change in ({'osBuildNumber': 'different-build'}, {'xcode': XCODE.replace('27A9275', 'different-build')}, {'architecture': 'x86_64'}):
            with self.subTest(change=change), self.assertRaisesRegex(ValueError, 'No approved baseline'):
                require_compatible_baseline(approved_fixture(), {**observed, **change})

    def test_unavailable_ambiguous_missing_and_wrong_actual_identity_fail(self):
        variants = []
        wrong = copy.deepcopy(INVENTORY); wrong['devices'][ENV['CI_IPHONE_RUNTIME']][0]['udid'] = 'other'; variants.append(wrong)
        wrong = copy.deepcopy(INVENTORY); wrong['runtimes'][0]['isAvailable'] = False; variants.append(wrong)
        wrong = copy.deepcopy(INVENTORY); wrong['runtimes'] *= 2; variants.append(wrong)
        wrong = copy.deepcopy(INVENTORY); wrong['runtimes'][0]['buildversion'] = ''; variants.append(wrong)
        wrong = copy.deepcopy(INVENTORY); wrong['devicetypes'][0]['name'] = 'iPhone Duo'; variants.append(wrong)
        for inventory in variants:
            with self.subTest(inventory=inventory), self.assertRaises(ValueError):
                runner_environment(ENV, inventory, XCODE, 'arm64')
        with self.assertRaisesRegex(ValueError, 'differs from workflow'):
            runner_environment(ENV, INVENTORY, XCODE.replace('27.1', '27.2'), 'arm64')

    def test_calibration_checks_configured_identity_without_requiring_baseline(self):
        with patch.dict(os.environ, {**ENV, 'ENFORCE_BASELINES': 'false'}, clear=True), \
                patch('sys.argv', ['guard', 'configured', '--architecture', 'arm64', '--baseline', '/missing']), \
                contextlib.redirect_stdout(io.StringIO()) as output:
            main()
        self.assertEqual(json.loads(output.getvalue())['environment'], configured_environment(ENV, 'arm64'))
        with patch.dict(os.environ, {**ENV, 'ENFORCE_BASELINES': 'false', 'DEVELOPER_DIR': '/unknown'}, clear=True), \
                patch('sys.argv', ['guard', 'configured', '--architecture', 'arm64', '--baseline', '/missing']), \
                contextlib.redirect_stderr(io.StringIO()) as error, self.assertRaises(SystemExit) as failure:
            main()
        self.assertEqual(failure.exception.code, 1)
        self.assertIn('Cannot establish', error.getvalue())
        with patch.dict(os.environ, {'ENFORCE_BASELINES': ''}, clear=True), \
                patch('sys.argv', ['guard', 'configured', '--architecture', 'arm64']), \
                contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as failure:
            main()
        self.assertEqual(failure.exception.code, 1)

    def test_calibration_checks_actual_runner_identity_and_rejects_drift_without_baseline(self):
        for toolchain, should_pass in [(XCODE, True), (XCODE.replace('27.1', '27.2'), False)]:
            with self.subTest(toolchain=toolchain), \
                    patch.dict(os.environ, {**ENV, 'ENFORCE_BASELINES': 'false'}, clear=True), \
                    patch('sys.argv', ['guard', 'runner', '--baseline', '/missing']), \
                    patch('check_ios_performance_environment.platform.machine', return_value='arm64'), \
                    patch('check_ios_performance_environment.subprocess.check_output', side_effect=[json.dumps(INVENTORY), toolchain]) as native, \
                    contextlib.redirect_stdout(io.StringIO()) as output, contextlib.redirect_stderr(io.StringIO()) as error:
                if should_pass:
                    main()
                    self.assertEqual(json.loads(output.getvalue())['environment'], runner_environment(ENV, INVENTORY, XCODE, 'arm64'))
                    self.assertFalse(json.loads(output.getvalue())['releaseAcceptance'])
                else:
                    with self.assertRaises(SystemExit) as failure:
                        main()
                    self.assertEqual(failure.exception.code, 1)
                    self.assertIn('differs from workflow', error.getvalue())
                self.assertEqual([call.args[0] for call in native.call_args_list],
                                 [['xcrun', 'simctl', 'list', '-j'], ['xcodebuild', '-version']])

    def test_runner_cli_reads_only_inventory_and_xcode_never_boots_or_builds(self):
        with tempfile.TemporaryDirectory() as folder:
            baseline = Path(folder) / 'baseline.json'; baseline.write_text(json.dumps(approved_fixture()))
            with patch.dict(os.environ, ENV, clear=True), \
                    patch('sys.argv', ['guard', 'runner', '--baseline', str(baseline)]), \
                    patch('check_ios_performance_environment.platform.machine', return_value='arm64'), \
                    patch('check_ios_performance_environment.subprocess.check_output', side_effect=[json.dumps(INVENTORY), XCODE]) as native, \
                    contextlib.redirect_stdout(io.StringIO()) as output:
                main()
            self.assertEqual([call.args[0] for call in native.call_args_list],
                             [['xcrun', 'simctl', 'list', '-j'], ['xcodebuild', '-version']])
            self.assertFalse(json.loads(output.getvalue())['releaseAcceptance'])

    def test_linux_cli_rejects_current_baseline_without_native_queries(self):
        with patch.dict(os.environ, ENV, clear=True), \
                patch('sys.argv', ['guard', 'configured', '--architecture', 'arm64']), \
                patch('check_ios_performance_environment.subprocess.check_output') as native, \
                contextlib.redirect_stderr(io.StringIO()) as error, self.assertRaises(SystemExit) as failure:
            main()
        self.assertEqual(failure.exception.code, 1)
        self.assertIn('No approved baseline', error.getvalue())
        native.assert_not_called()

    def test_workflow_orders_guards_before_expensive_work_and_keeps_late_validation(self):
        workflow = parse_workflow(ROOT / '.github/workflows/ios-performance.yml')[0]
        self.assertEqual(workflow['env']['ENFORCE_BASELINES'],
                         "${{ inputs.enforce_baselines }}")
        self.assertNotIn('pull_request', workflow['on'])
        self.assertIn('workflow_dispatch', workflow['on'])
        self.assertTrue(workflow['on']['workflow_call']['inputs']['enforce_baselines']['default'])
        release = parse_workflow(ROOT / '.github/workflows/release-checks.yml')[0]
        self.assertEqual(release['jobs']['performance']['uses'], './.github/workflows/ios-performance.yml')
        self.assertTrue(release['jobs']['performance']['with']['enforce_baselines'])
        self.assertEqual(release['jobs']['diagnostics']['uses'], './.github/workflows/ios-deep.yml')
        for job in workflow['jobs'].values():
            self.assertNotIn('ENFORCE_BASELINES', job.get('env', {}))
        plan = workflow['jobs']['performance-plan']
        self.assertEqual(plan['runs-on'], 'ubuntu-24.04')
        self.assertEqual(plan['steps'][-1]['run'], 'python3 scripts/check_ios_performance_environment.py configured --architecture arm64')
        self.assertEqual(workflow['jobs']['performance-build']['needs'], 'performance-plan')
        for job_name, expensive in [('performance-build', 'build-for-testing'), ('performance-tests', 'scripts/prepare_ios_performance_simulator.py')]:
            steps = workflow['jobs'][job_name]['steps']
            guard = next(i for i, step in enumerate(steps) if 'python3 scripts/check_ios_performance_environment.py runner' in step.get('run', ''))
            self.assertIn('if [[ "${{ inputs.capture_scroll_signposts }}" == true ]]', steps[guard]['run'])
            self.assertIn('identity=()', steps[guard]['run'])
            self.assertIn('"${identity[@]}"', steps[guard]['run'])
            selection = next(i for i, step in enumerate(steps) if 'scripts/select_ci_iphone.py' in step.get('run', ''))
            work = next(i for i, step in enumerate(steps) if expensive in step.get('run', ''))
            self.assertLess(selection, guard); self.assertLess(guard, work)
        late = '\n'.join(s.get('run', '') for s in workflow['jobs']['performance-tests']['steps'])
        self.assertIn('scripts/check_ios_performance.py', late)
        self.assertIn('--baseline scripts/ios_performance_baselines.json', late)


if __name__ == '__main__':
    unittest.main()
