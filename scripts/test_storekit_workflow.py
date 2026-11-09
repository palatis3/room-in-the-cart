"""Offline checks for one shared StoreKit build and both required locale runs."""
import copy
import json
import os
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest.mock import patch

from check_ci_workflows import parse_workflow

ROOT = Path(__file__).resolve().parents[1]
EXPECTED = {
    'US English — local StoreKit': ('en', 'en-US', 'en_US', 2),
    'US Spanish app · Spanish (Mexico) offer · USA storefront': ('es', 'es-US', 'es_MX', 3),
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
        return step['run'].split("python3 - <<'PYCODE'\n", 1)[1].split('\nPYCODE', 1)[0]

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

    def test_source_plan_and_matrix_keep_both_locales_and_all_scenarios(self):
        configurations = self.plan['configurations']
        self.assertEqual(len(configurations), 2)
        self.assertEqual({row['name'] for row in configurations}, set(EXPECTED))
        for entry in configurations:
            _, language, offer_locale, _ = EXPECTED[entry['name']]
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
        rows = self.jobs['storekit']['strategy']['matrix']['include']
        self.assertEqual(rows, [{'locale': locale, 'macos_slot': slot, 'configuration': name}
                                for name, (locale, _, _, slot) in EXPECTED.items()])

    def test_one_build_exact_artifact_and_test_without_building(self):
        build = self.jobs['storekit-build']
        tests = self.jobs['storekit']
        self.assertEqual(build['needs'], 'storekit-plan')
        self.assertEqual(tests['needs'], 'storekit-build')
        self.assertEqual(build['concurrency'], {'group': 'ritc-macos-slot-2', 'queue': 'max', 'cancel-in-progress': False})
        self.assertEqual(tests['concurrency'], {'group': 'ritc-macos-slot-${{ matrix.macos_slot }}', 'queue': 'max', 'cancel-in-progress': False})
        commands = '\n'.join(step.get('run', '') for step in build['steps'])
        self.assertEqual(commands.count('build-for-testing'), 1)
        self.assertIn('-scheme RoomInTheCart-LocalStoreKit', commands)
        self.assertNotIn('-only-test-configuration', commands)
        self.assertEqual(build['outputs']['artifact'], "${{ steps.upload.outputs['artifact-id'] }}")
        download = next(step for step in tests['steps'] if step.get('uses', '').startswith('actions/download-artifact@'))
        self.assertEqual(download['with']['artifact-ids'], '${{ needs.storekit-build.outputs.artifact }}')
        self.assertNotIn('run-id', download['with'])
        command = self.step('storekit', name='Run purchase, restore, renewal and revocation scenarios')['run']
        self.assertIn('-xctestrun "${test_runs[0]}"', command)
        self.assertIn('test-without-building', command)
        self.assertNotIn('-project', command)
        self.assertNotIn('build-for-testing', command)
        self.assertIn('-only-test-configuration "$STOREKIT_CONFIGURATION"', command)
        self.assertIn('-default-test-execution-time-allowance 120', command)
        self.assertIn('-maximum-test-execution-time-allowance 120', command)
        self.assertEqual(tests['timeout-minutes'], 45)
        self.assertEqual(self.step('storekit', name='Run purchase, restore, renewal and revocation scenarios')['timeout-minutes'], 35)
        verifier = self.step('storekit', name='Verify exact StoreKit configuration and all scenario results')
        self.assertIn('--expected-count 15', verifier['run'])
        self.assertIn('testPlanConfiguration', verifier['run'])
        self.assertEqual(verifier['if'], "always() && steps.storekit-results.outcome == 'success'")
        self.assertFalse(tests['strategy']['fail-fast'])
        self.assertFalse(any(step.get('continue-on-error') for step in tests['steps']))

    def test_linux_preflight_installs_hash_pinned_yaml_before_test(self):
        job = self.jobs['storekit-plan']
        self.assertEqual(job['runs-on'], 'ubuntu-24.04')
        command = '\n'.join(step.get('run', '') for step in job['steps'])
        self.assertIn('--require-hashes --only-binary=:all: -r scripts/ci_yaml_requirements.txt', command)
        self.assertIn('.build/storekit-workflow-venv/bin/python scripts/test_storekit_workflow.py', command)

    def test_real_inventory_and_restore_code_accept_both_configs(self):
        inventory = self.python_block(self.step('storekit-build', identifier='storekit-inventory'))
        restore = self.python_block(self.step('storekit', identifier='storekit-restore'))
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            run, fixture, _ = self.compiled_fixture(root)
            run.write_bytes(plistlib.dumps(fixture))
            self.execute(inventory, root, GITHUB_SHA='checked-commit')
            for configuration in EXPECTED:
                self.execute(restore, root, GITHUB_SHA='checked-commit', STOREKIT_CONFIGURATION=configuration)
            with self.assertRaises(AssertionError):
                self.execute(restore, root, GITHUB_SHA='different-commit', STOREKIT_CONFIGURATION=next(iter(EXPECTED)))
            with self.assertRaises(AssertionError):
                self.execute(restore, root, GITHUB_SHA='checked-commit', STOREKIT_CONFIGURATION='unbuilt-locale')

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
