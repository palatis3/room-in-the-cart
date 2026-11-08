import copy
import hashlib
import json
from pathlib import Path
import tempfile
import unittest

from check_ci_workflows import parse_workflow
from plan_ios_tests import make_plan, write_plan
from select_core_ui_diagnostic import CASES, SHARD, require_identity, selected_case, write_selection
from test_plan_ios_tests import MODEL, DURATIONS, enumeration

ROOT = Path(__file__).resolve().parents[1]
ENABLED = [MODEL, *[value + '()' for value in CASES.values()],
           *[f'RoomInTheCartUITests/OtherTests/test{i}()' for i in range(8)]]
SHA = 'a' * 40


class CoreUIDiagnosticTests(unittest.TestCase):
    def setUp(self):
        self.enumeration = enumeration(ENABLED)
        self.plan = make_plan(self.enumeration, DURATIONS, 10)

    def test_each_explicit_language_selects_only_its_existing_case(self):
        saved = copy.deepcopy((self.enumeration, self.plan))
        for language, expected in CASES.items():
            self.assertEqual(selected_case(language, self.enumeration, self.plan, DURATIONS),
                             (expected, len(ENABLED)))
        self.assertEqual((self.enumeration, self.plan), saved)

    def test_no_default_all_wildcard_or_arbitrary_selector(self):
        for choice in (None, '', 'choose', 'all', '*', 'EN', 'en,es', CASES['en'], '../ui-01', ['en']):
            with self.subTest(choice=choice), self.assertRaises(ValueError):
                selected_case(choice, self.enumeration, self.plan, DURATIONS)

    def test_full_inventory_checks_remain_active_even_for_one_requested_case(self):
        bad_inputs = []
        bad = copy.deepcopy(self.enumeration); bad['errors'] = ['discovery failed']; bad_inputs.append(bad)
        bad = enumeration([*ENABLED, ENABLED[-1]]); bad_inputs.append(bad)
        bad = enumeration(ENABLED, ['RoomInTheCartUITests/OtherTests/testHidden()']); bad_inputs.append(bad)
        bad = enumeration([x for x in ENABLED if not x.startswith('RoomInTheCartTests/')]); bad_inputs.append(bad)
        for data in bad_inputs:
            with self.subTest(data=data), self.assertRaises(ValueError):
                selected_case('en', data, self.plan, DURATIONS)

    def test_missing_unselected_spanish_case_and_tampered_full_plan_fail(self):
        source = enumeration([x for x in ENABLED if x != CASES['es'] + '()'] +
                             ['RoomInTheCartUITests/OtherTests/testExtra()'])
        with self.assertRaisesRegex(ValueError, 'Both existing'):
            selected_case('en', source, make_plan(source, DURATIONS, 10), DURATIONS)
        changed = copy.deepcopy(self.plan); changed['include'][0]['expected_count'] += 1
        with self.assertRaisesRegex(ValueError, 'Retained full plan'):
            selected_case('en', self.enumeration, changed, DURATIONS)

    def test_exact_manual_event_workflow_ref_and_checkout_binding(self):
        require_identity('workflow_dispatch', SHA, SHA, SHA)
        for args in [('pull_request', SHA, SHA, SHA), ('workflow_call', SHA, SHA, SHA),
                     ('workflow_dispatch', SHA[:7], SHA, SHA), ('workflow_dispatch', SHA.upper(), SHA, SHA),
                     ('workflow_dispatch', SHA, 'b' * 40, SHA), ('workflow_dispatch', SHA, SHA, 'b' * 40)]:
            with self.subTest(args=args), self.assertRaises(ValueError):
                require_identity(*args)

    def test_write_preserves_complete_plan_and_refuses_stale_selection(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder); plan_dir = root / 'test-plan'; write_plan(self.plan, plan_dir)
            (plan_dir / 'test-enumeration.json').write_text(json.dumps(self.enumeration))
            before = {p.name: p.read_bytes() for p in plan_dir.iterdir()}
            receipt = root / 'receipt.json'
            result = write_selection(plan_dir, receipt, 'es', SHA, DURATIONS)
            self.assertEqual((plan_dir / (SHARD + '.txt')).read_text(), CASES['es'] + '\n')
            self.assertEqual(result['expectedCount'], 1)
            self.assertEqual(result['fullEnabledCount'], len(ENABLED))
            self.assertEqual(result['fullPlanSHA256'], hashlib.sha256(before['manifest.json']).hexdigest())
            for name, data in before.items(): self.assertEqual((plan_dir / name).read_bytes(), data)
            with self.assertRaises(ValueError): write_selection(plan_dir, receipt, 'en', SHA, DURATIONS)

    def test_workflow_is_manual_only_with_distinct_check_and_existing_runner(self):
        data, _, _ = parse_workflow(ROOT / '.github/workflows/ios-toggle-diagnostic.yml')
        self.assertEqual(set(data['on']), {'workflow_dispatch'})
        self.assertEqual(data['on']['workflow_dispatch']['inputs']['dinner_case']['default'], 'choose')
        self.assertEqual(data['on']['workflow_dispatch']['inputs']['dinner_case']['options'], ['choose', 'en', 'es'])
        self.assertEqual(set(data['jobs']), {'core-dinner-diagnostic'})
        job = data['jobs']['core-dinner-diagnostic']
        self.assertNotEqual(job['name'], 'CI gate')
        self.assertNotIn('needs', job)
        self.assertNotIn('strategy', job)
        self.assertEqual(job['env']['TEST_SHARD'], SHARD)
        self.assertEqual(job['env']['EXPECTED_TEST_COUNT'], '1')
        runs = [step.get('run', '') for step in job['steps']]
        self.assertEqual(sum('build-for-testing' in run for run in runs), 1)
        self.assertEqual(sum(run == 'bash scripts/run_ios_test_shard.sh' for run in runs), 1)
        self.assertFalse(any('SWIFT_ACTIVE_COMPILATION_CONDITIONS' in run for run in runs))
        self.assertTrue(any('scripts/discover_ios_tests.py' in run for run in runs))
        self.assertTrue(any('--create-owned .build/test-simulator-ownership.json' in run for run in runs))
        self.assertTrue(any('--cleanup-owned .build/test-simulator-ownership.json' in run for run in runs))
        self.assertFalse(any('download-artifact' in step.get('uses', '') for step in job['steps']))
        upload, = [step for step in job['steps'] if 'upload-artifact' in step.get('uses', '')]
        for path in upload['with']['path'].splitlines():
            self.assertTrue(path.startswith('.build/'))
            self.assertNotIn('DerivedData', path)
            self.assertNotIn('Records', path)
            self.assertNotIn('Containers', path)
            self.assertNotIn('**', path)
            self.assertNotIn(path, ('.build/', '.build/*'))
        self.assertEqual(data['permissions'], {'contents': 'read'})


if __name__ == '__main__':
    unittest.main()
