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
        self.assertEqual({row['provider'] for row in fixtures}, {'github', 'bitrise', 'bitrise-m4'})
        # Lock the provider and concurrency group for each planned fixture.
        self.assertEqual([(row['provider'], row['macos_slot']) for row in fixtures], [
            ('bitrise', 1), ('bitrise-m4', 2), ('github', 3), ('bitrise-m4', 0),
            ('bitrise-m4', 4), ('bitrise', 0), ('bitrise', 1), ('bitrise', 2),
            ('github', 0), ('bitrise-m4', 1), ('bitrise', 2), ('bitrise-m4', 3),
            ('bitrise-m4', 4), ('bitrise', 0), ('bitrise', 1), ('bitrise', 2),
            ('github', 0), ('github', 1), ('bitrise-m4', 2), ('github', 3),
            ('bitrise-m4', 4), ('bitrise', 0), ('bitrise', 1), ('bitrise', 2),
            ('bitrise-m4', 0), ('github', 1),
        ])
        self.assertEqual({row['shard']: (row['provider'], row['macos_slot'])
                          for row in fixtures if row['shard'] in {
                              'contributor-balanced-04', 'contributor-balanced-02', 'contributor-balanced-05',
                              'SharedFallbackUITests'}}, {
            'contributor-balanced-04': ('bitrise-m4', 0),
            'contributor-balanced-02': ('bitrise', 1),
            'contributor-balanced-05': ('bitrise-m4', 2),
            'SharedFallbackUITests': ('bitrise', 2),
        })
        for row in fixtures:
            self.assertIs(type(row['macos_slot']), int)
            self.assertIn(row['macos_slot'], range(3 if row['provider'] == 'bitrise' else 5))
            if row['provider'] == 'bitrise-m4':
                self.assertIs(type(row['m4_slot']), int)
                self.assertIn(row['m4_slot'], range(6))
            else:
                self.assertNotIn('m4_slot', row)
        self.assertEqual(len({(row['profile'], row['shard']) for row in fixtures}), 26)
        self.assertEqual(len(fixtures), 26)
        self.assertEqual([(r['shard'], r['macos_slot'], r['m4_slot']) for r in fixtures if 'm4_slot' in r], [
            ('contributor-balanced-05', 2, 5),
            ('contributor-balanced-04', 0, 1),
            ('contributor-balanced-03', 4, 2),
            ('SharedDeliveryUITests-recovery-cook-and-closeout', 1, 3),
            ('SharedFoodEditorUITests-testExpiredQuoteCancelApplyAndRelaunchRetryPreserveExactFoodAndMoney', 3, 4),
            ('SharedFoodEditorUITests-testSpanishExpiredQuoteCancelApplyAndRelaunchRetryPreserveExactFoodAndMoney', 4, 1),
            ('SharedOperationUndoUITests-testSpanishSkippedDinnerUndoCancelRelaunchRetryKeepsProtectedLunchAndLaterStaple', 2, 4),
            ('SharedStoreQuoteUITests-testFilledFinancialFieldsRetainVisibleMeaningAndGrantActionNamesAdult', 4, 4),
            ('SharedStoreQuoteUITests-testStaleReviewedSaveCannotBeRebasedAndLockedShopHasNoNewComparisonAction', 0, 5)])
        self.assertEqual([row['profile'] for row in fixtures if row['shard'] == 'SharedRecordsUITests'], ['contributor'])
        self.assertEqual([row['profile'] for row in fixtures if row['shard'] == 'SharedFallbackUITests'], ['contributor'])
        self.assertEqual(set(fixtures[0]), {'profile', 'shard', 'provider', 'macos_slot'})
        performance = performance_matrix('\n'.join(COMPILED))['include']
        validate_macos_slots(performance, ('case',))
        self.assertEqual([r['case'] for r in performance], ['launch', 'rendered', 'scroll'])
        self.assertEqual(len({r['selector'] for r in performance}), 3)


if __name__ == '__main__':
    unittest.main()
