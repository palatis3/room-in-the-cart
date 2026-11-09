import copy
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

from check_ci_workflows import parse_workflow
from plan_ios_tests import DURATIONS_PATH, make_plan, selector, write_plan
from select_ios_core_work import DINNER, select_work

ROOT = Path(__file__).resolve().parents[1]
MODELS = ['RoomInTheCartTests/ModelTests/testOne()', 'RoomInTheCartTests/ModelTests/testTwo()']
OTHER_UI = [f'RoomInTheCartUITests/OtherTests/test{i}()' for i in range(10)]
INVENTORY = {'errors': [], 'values': [{'testPlan': 'RoomInTheCart',
    'enabledTests': [{'identifier': identifier} for identifier in [*MODELS, *OTHER_UI, *DINNER]],
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
            self.assertEqual(json.loads(output.read_text().removeprefix('matrix='))['include'][1]['expected_count'], 2)
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
        self.assertEqual(step['env']['REQUESTED_IOS_SCOPE'],
                         "${{ github.event_name == 'workflow_dispatch' && inputs.ios_scope || 'full' }}")
        self.assertLess(step['run'].index('scripts/discover_ios_tests.py'), step['run'].index('scripts/select_ios_core_work.py'))
        for expression in (workflow['run-name'], workflow['concurrency']['group'], workflow['jobs']['ci-gate']['name']):
            self.assertIn("github.event_name == 'workflow_dispatch' && inputs.ios_scope == 'dinner'", expression)
        self.assertIn("'dinner-diagnostic' || 'full'", workflow['concurrency']['group'])
        self.assertIn("'Dinner diagnostic gate' || 'CI gate'", workflow['jobs']['ci-gate']['name'])


if __name__ == '__main__':
    unittest.main()
