import copy
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

from check_ci_workflows import parse_workflow
from plan_ios_tests import ACCESSIBILITY_AUDIT, DURATIONS_PATH, make_plan, selector, write_plan
from select_ios_core_work import DINNER, select_work

ROOT = Path(__file__).resolve().parents[1]
MODELS = ['RoomInTheCartTests/ModelTests/testOne()', 'RoomInTheCartTests/ModelTests/testTwo()']
OTHER_UI = [f'RoomInTheCartUITests/OtherTests/test{i}()' for i in range(10)]
INVENTORY = {'errors': [], 'values': [{'testPlan': 'RoomInTheCart',
    'enabledTests': [{'identifier': identifier} for identifier in [*MODELS, *OTHER_UI, ACCESSIBILITY_AUDIT, *DINNER]],
    'disabledTests': [{'identifier': 'RoomInTheCartTests/StoreKitScenarioTests/testOffer()'}]}]}
DURATIONS = json.loads(DURATIONS_PATH.read_text())


class SelectCoreWorkTests(unittest.TestCase):
    def test_only_manual_dinner_selects_exact_two_cases_and_every_model(self):
        original = copy.deepcopy(INVENTORY)
        full, selected = select_work(INVENTORY, DURATIONS, 'workflow_dispatch', 'dinner')
        self.assertEqual(INVENTORY, original)
        self.assertEqual(full, make_plan(INVENTORY, DURATIONS, 10))
        self.assertEqual(selected['shards']['models'], full['shards']['models'])
        self.assertEqual(selected['shards']['ui-01']['test_identifiers'], sorted(DINNER))
        self.assertEqual(selected['include'], [
            {'shard': 'models', 'expected_count': 2, 'macos_slot': 0},
            {'shard': 'ui-01', 'expected_count': 2, 'macos_slot': 1}])
        for event in ('push', 'pull_request', 'workflow_call', 'schedule', 'workflow_dispatch'):
            with self.subTest(event=event):
                self.assertEqual(select_work(INVENTORY, DURATIONS, event, 'full'), (full, full))
                if event != 'workflow_dispatch':
                    with self.assertRaisesRegex(ValueError, 'Only an explicit manual'):
                        select_work(INVENTORY, DURATIONS, event, 'dinner')
        with self.assertRaises(ValueError):
            select_work(INVENTORY, DURATIONS, 'workflow_dispatch', 'typo')

    def test_focus_cannot_conceal_bad_inventory_or_missing_original_case(self):
        bad = []
        error = copy.deepcopy(INVENTORY); error['errors'] = ['enumeration failed']; bad.append(error)
        disabled = copy.deepcopy(INVENTORY)
        disabled['values'][0]['disabledTests'].append({'identifier': OTHER_UI[0]})
        bad.append(disabled)
        duplicate = copy.deepcopy(INVENTORY)
        duplicate['values'][0]['enabledTests'].append({'identifier': MODELS[0]})
        bad.append(duplicate)
        missing = copy.deepcopy(INVENTORY)
        missing['values'][0]['enabledTests'].pop(); bad.append(missing)
        for scope in ('full', 'dinner'):
            missing_audit = copy.deepcopy(INVENTORY)
            missing_audit['values'][0]['enabledTests'].remove({'identifier': ACCESSIBILITY_AUDIT})
            with self.subTest(scope=scope), self.assertRaisesRegex(ValueError, 'accessibility audit'):
                select_work(missing_audit, DURATIONS, 'workflow_dispatch', scope)
        for inventory in bad:
            with self.subTest(inventory=inventory), self.assertRaises(ValueError):
                select_work(inventory, DURATIONS, 'workflow_dispatch', 'dinner')

    def test_actual_cli_preserves_full_evidence_and_writes_exact_selection_once(self):
        with tempfile.TemporaryDirectory() as folder:
            plan_dir, output = Path(folder) / 'plan', Path(folder) / 'output'
            full = make_plan(INVENTORY, DURATIONS, 10)
            write_plan(full, plan_dir)
            (plan_dir / 'test-enumeration.json').write_text(json.dumps(INVENTORY))
            command = [sys.executable, str(ROOT / 'scripts/select_ios_core_work.py'),
                       '--plan-dir', str(plan_dir), '--github-output', str(output)]
            env = {**os.environ, 'GITHUB_EVENT_NAME': 'workflow_dispatch', 'REQUESTED_IOS_SCOPE': 'dinner'}
            result = subprocess.run(command, env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(json.loads((plan_dir / 'full-plan/manifest.json').read_text()), full)
            for shard in full['shards'].values():
                self.assertEqual((plan_dir / 'full-plan' / shard['selector_file']).read_text().splitlines(),
                                 [selector(i) for i in shard['test_identifiers']])
            self.assertEqual(sorted(p.name for p in plan_dir.glob('*.txt')), ['models.txt', 'ui-01.txt'])
            self.assertEqual((plan_dir / 'ui-01.txt').read_text().splitlines(), sorted(DINNER))
            self.assertEqual((plan_dir / 'models.txt').read_text().splitlines(), [selector(i) for i in MODELS])
            outputs = dict(line.split('=', 1) for line in output.read_text().splitlines())
            self.assertEqual(outputs['model_count'], '2')
            self.assertEqual(json.loads(outputs['matrix'])['include'], [
                {'shard': 'ui-01', 'expected_count': 2, 'macos_slot': 1, 'provider': 'bitrise-A2', 'pool_slot': 0}])
            again = subprocess.run(command, env=env, capture_output=True, text=True)
            self.assertNotEqual(again.returncode, 0)
            self.assertIn('full plan changed', again.stderr)

    def test_workflow_defaults_release_to_full_and_separates_focused_identity(self):
        workflow = parse_workflow(ROOT / '.github/workflows/ci.yml')[0]
        manual = workflow['on']['workflow_dispatch']['inputs']['ios_scope']
        self.assertEqual(manual['default'], 'full')
        self.assertEqual(manual['options'], ['full', 'dinner'])
        self.assertNotIn('ios_scope', workflow['on']['workflow_call']['inputs'])
        step = next(s for s in workflow['jobs']['ios-build']['steps'] if s.get('id') == 'plan')
        self.assertEqual(step['env']['RITC_BITRISE_A3_ENABLED'], '${{ vars.RITC_BITRISE_A3_ENABLED }}')
        self.assertEqual(step['env']['REQUESTED_IOS_SCOPE'],
                         "${{ github.event_name == 'workflow_dispatch' && inputs.ios_scope || 'full' }}")
        self.assertLess(step['run'].index('scripts/discover_ios_tests.py'), step['run'].index('scripts/select_ios_core_work.py'))
        for expression in (workflow['run-name'], workflow['concurrency']['group'], workflow['jobs']['ci-gate']['name']):
            self.assertIn("github.event_name == 'workflow_dispatch' && inputs.ios_scope == 'dinner'", expression)
        self.assertIn("'dinner-diagnostic'", workflow['concurrency']['group'])
        self.assertIn("'Dinner diagnostic gate'", workflow['jobs']['ci-gate']['name'])
        self.assertTrue(workflow['jobs']['ci-gate']['name'].endswith("|| 'CI gate' }}"))

    def test_full_cli_keeps_compiled_plan_and_only_reassigns_reviewed_consumers(self):
        with tempfile.TemporaryDirectory() as folder:
            plan_dir, output = Path(folder) / 'plan', Path(folder) / 'output'
            full = make_plan(INVENTORY, DURATIONS, 10)
            write_plan(full, plan_dir)
            (plan_dir / 'test-enumeration.json').write_text(json.dumps(INVENTORY))
            original = {p.name: p.read_bytes() for p in plan_dir.iterdir()}
            result = subprocess.run([sys.executable, str(ROOT / 'scripts/select_ios_core_work.py'),
                                     '--plan-dir', str(plan_dir), '--github-output', str(output)],
                                    env={**os.environ, 'GITHUB_EVENT_NAME': 'pull_request',
                                         'REQUESTED_IOS_SCOPE': 'full', 'RITC_BITRISE_A3_ENABLED': ''}, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            outputs = dict(line.split('=', 1) for line in output.read_text().splitlines())
            self.assertEqual(outputs['model_count'], str(len(MODELS)))
            consumers = json.loads(outputs['matrix'])['include']
            self.assertEqual(full['shards']['ui-11']['test_identifiers'], [ACCESSIBILITY_AUDIT])
            self.assertEqual([r['expected_count'] for r in consumers if r['shard'] == 'ui-11'], [1])
            original_ui = [row for row in full['include'] if row['shard'] != 'models']
            def test_selection(row):
                return {k: v for k, v in row.items() if k not in ('provider', 'macos_slot', 'pool_slot')}
            self.assertEqual([test_selection(row) for row in consumers],
                             [test_selection(row) for row in original_ui])
            self.assertEqual({r['provider'] for r in consumers}, {'bitrise-A1', 'bitrise-A2'})
            self.assertEqual(len({(r['provider'], r['pool_slot']) for r in consumers}), 11)
            self.assertTrue(all(type(r['pool_slot']) is int and 0 <= r['pool_slot'] < 6 for r in consumers))
            self.assertTrue(all('m4_slot' not in r for r in consumers))
            self.assertEqual({p.name: p.read_bytes() for p in plan_dir.iterdir()}, original)
            result = subprocess.run([sys.executable, str(ROOT / 'scripts/select_ios_core_work.py'),
                                     '--plan-dir', str(plan_dir), '--github-output', str(output)],
                                    env={**os.environ, 'GITHUB_EVENT_NAME': 'pull_request',
                                         'REQUESTED_IOS_SCOPE': 'full', 'IOS_PROVIDER': 'circleci',
                                         'RITC_BITRISE_A3_ENABLED': ''},
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            outputs = dict(line.split('=', 1) for line in output.read_text().splitlines())
            self.assertEqual(json.loads(outputs['matrix'])['include'],
                             [row for row in consumers if row['shard'] not in ('ui-01', 'ui-02', 'ui-03')])
            self.assertEqual(outputs['model_count'], str(len(MODELS)))
            enabled = subprocess.run([sys.executable, str(ROOT / 'scripts/select_ios_core_work.py'),
                                      '--plan-dir', str(plan_dir), '--github-output', str(output)],
                                     env={**os.environ, 'GITHUB_EVENT_NAME': 'pull_request', 'REQUESTED_IOS_SCOPE': 'full',
                                          'RITC_BITRISE_A3_ENABLED': 'true'}, capture_output=True, text=True)
            self.assertEqual(enabled.returncode, 0, enabled.stderr)
            outputs = dict(line.split('=', 1) for line in output.read_text().splitlines())
            a3_consumers = json.loads(outputs['matrix'])['include']
            self.assertEqual([test_selection(row) for row in a3_consumers], [test_selection(row) for row in consumers])
            self.assertEqual(sum(row['provider'] == 'bitrise-A3' for row in a3_consumers), 5)
            self.assertEqual({p.name: p.read_bytes() for p in plan_dir.iterdir()}, original)

    def test_circleci_consumer_checks_full_shard_membership_before_running_its_selection(self):
        shell = (ROOT / 'scripts/circle_ios_test.sh').read_text()
        start = shell.index('EXPECTED_TEST_COUNT=$(jq')
        command = shell[start:shell.index('export EXPECTED_TEST_COUNT', start)] + 'echo "$EXPECTED_TEST_COUNT"'
        full, _ = select_work(INVENTORY, DURATIONS, 'pull_request', 'full')
        malformed = []
        for field, value in (('shard', 'ui-07'), ('shard', 'unexpected'), ('expected_count', 2)):
            changed = copy.deepcopy(full)
            changed['include'][-1][field] = value
            malformed.append(changed)
        malformed.append({**full, 'include': full['include'][:-1]})
        with tempfile.TemporaryDirectory() as folder:
            manifest = Path(folder) / '.build/test-plan/manifest.json'
            manifest.parent.mkdir(parents=True)
            for plan in (full, *malformed):
                manifest.write_text(json.dumps(plan))
                for shard in ('ui-01', 'ui-02', 'ui-03'):
                    with self.subTest(shard=shard, audit=plan['include'][-1]):
                        result = subprocess.run(['bash', '-ec', command], cwd=folder, capture_output=True,
                                                text=True, env={**os.environ, 'TEST_SHARD': shard})
                        self.assertEqual(result.returncode == 0, plan is full)
                        if plan is full:
                            self.assertEqual(int(result.stdout), len(plan['shards'][shard]['test_identifiers']))

    def test_producer_model_failure_cannot_pass_the_required_gate(self):
        jobs = parse_workflow(ROOT / '.github/workflows/ci.yml')[0]['jobs']
        producer = jobs['ios-build']
        model = next(s for s in producer['steps'] if s.get('id') == 'models')
        self.assertIs(model['continue-on-error'], True)
        self.assertEqual(model['timeout-minutes'], 40)
        self.assertEqual(model['run'], 'bash scripts/run_ios_test_shard.sh')
        self.assertEqual(model['env'], {'TEST_SHARD': 'models',
                         'EXPECTED_TEST_COUNT': '${{ steps.plan.outputs.model_count }}'})
        self.assertEqual(producer['outputs']['model_result'], '${{ steps.models.outcome }}')
        self.assertEqual(jobs['ios-tests']['needs'], 'ios-build')
        report = jobs['ios-model-results']
        self.assertEqual(report['needs'], 'ios-build')
        self.assertEqual(report['runs-on'], 'ubuntu-24.04')
        step, = report['steps']
        self.assertEqual(step['env']['MODEL_OUTCOME'], '${{ needs.ios-build.outputs.model_result }}')
        for outcome in ('success', 'failure', 'skipped', 'cancelled', ''):
            with self.subTest(reported_model_outcome=outcome):
                checked = subprocess.run(['bash', '-c', step['run']], env={**os.environ, 'MODEL_OUTCOME': outcome},
                                         capture_output=True, text=True)
                self.assertEqual(checked.returncode == 0, outcome == 'success')
        gate = jobs['ci-gate']
        code = gate['steps'][0]['run'].split("<<'PY'\n", 1)[1].rsplit('\nPY', 1)[0]
        results = {name: {'result': 'success'} for name in gate['needs']}
        results['source-checks']['outputs'] = {'ios_provider': 'github'}
        results['ios-build']['outputs'] = {'model_result': 'success'}
        def execute(value):
            return subprocess.run([sys.executable, '-c', code], capture_output=True, text=True,
                                  env={**os.environ, 'JOB_RESULTS': json.dumps(value)})
        self.assertEqual(execute(results).returncode, 0)
        for outcome in ('failure', 'cancelled', 'skipped', '', None):
            with self.subTest(outcome=outcome):
                changed = copy.deepcopy(results)
                changed['ios-build']['outputs']['model_result'] = outcome
                result = execute(changed)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('ios-models', result.stderr)
        for missing in ('outputs', 'ios-build'):
            changed = copy.deepcopy(results)
            if missing == 'outputs': del changed['ios-build']['outputs']
            else: del changed['ios-build']
            self.assertNotEqual(execute(changed).returncode, 0)
        changed = copy.deepcopy(results)
        changed['ios-tests']['result'] = 'failure'
        self.assertNotEqual(execute(changed).returncode, 0)


if __name__ == '__main__':
    unittest.main()
