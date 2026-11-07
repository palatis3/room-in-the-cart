import copy
import unittest
from ci_mac_slots import validate_macos_slots, with_macos_slots
from plan_ios_tests import make_plan
from test_plan_ios_tests import MODEL, DURATIONS, UI_TARGET, enumeration
from plan_ios_fixture_tests import matrix as fixture_matrix
from plan_ios_performance_tests import performance_matrix
from test_plan_ios_performance_tests import COMPILED


class MacSlotMetadataTests(unittest.TestCase):
    def test_original_row_identity_order_and_input_are_preserved(self):
        rows = [{'shard': f'case-{i}', 'expected_count': i + 1} for i in range(12)]
        saved = copy.deepcopy(rows)
        assigned = with_macos_slots(rows, ('shard',))
        self.assertEqual(rows, saved)
        self.assertEqual([{k: v for k, v in r.items() if k != 'macos_slot'} for r in assigned], rows)
        self.assertEqual([r['macos_slot'] for r in assigned], [0, 1, 2, 3, 4, 0, 1, 2, 3, 4, 0, 1])

    def test_bad_or_duplicate_matrix_inventory_is_rejected(self):
        for rows in ([], {}, ['bad'], [{}], [{'shard': ''}], [{'shard': 'x'}, {'shard': 'x'}],
                     [{'shard': 'x', 'macos_slot': 0}]):
            with self.subTest(rows=rows), self.assertRaises(ValueError):
                with_macos_slots(rows, ('shard',))

    def test_slots_require_exact_integer_range_and_row_assignment(self):
        original = with_macos_slots([{'shard': 'a'}, {'shard': 'b'}], ('shard',))
        for value in (-1, 5, True, 0.0, '0', None, 1):
            with self.subTest(value=value), self.assertRaises(ValueError):
                validate_macos_slots([{**original[0], 'macos_slot': value}, original[1]], ('shard',))
        for invalid in ([{'shard': 'a'}], list(reversed(original))):
            with self.assertRaises(ValueError):
                validate_macos_slots(invalid, ('shard',))

    def test_all_three_planners_keep_complete_cases_and_emit_valid_slots(self):
        methods = [f'{UI_TARGET}/JourneyTests/test{i:02d}()' for i in range(10)]
        plan = make_plan(enumeration([MODEL, *methods]), DURATIONS, 10)
        validate_macos_slots(plan['include'], ('shard',))
        self.assertEqual([r['shard'] for r in plan['include']], ['models', *[f'ui-{i:02d}' for i in range(1, 11)]])
        self.assertCountEqual([c for s in plan['shards'].values() for c in s['test_identifiers']], [MODEL, *methods])
        fixtures = fixture_matrix()['include']
        validate_macos_slots(fixtures, ('profile', 'shard'))
        self.assertEqual(len(fixtures), 15)
        self.assertEqual(set(fixtures[0]), {'profile', 'shard', 'macos_slot'})
        performance = performance_matrix('\n'.join(COMPILED))['include']
        validate_macos_slots(performance, ('case',))
        self.assertEqual([r['case'] for r in performance], ['launch', 'rendered', 'scroll'])
        self.assertEqual(len({r['selector'] for r in performance}), 3)


if __name__ == '__main__':
    unittest.main()
