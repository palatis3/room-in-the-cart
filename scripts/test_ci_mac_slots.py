import copy
import unittest
from ci_mac_slots import (validate_macos_slots, with_macos_slots, with_bitrise_slots,
                          BITRISE_POOLS, BITRISE_SLOTS_PER_POOL)
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

    def test_outage_spreads_fixture_work_across_the_five_github_slots(self):
        normal = fixture_matrix()['include']
        outage = fixture_matrix(github_mac_only=True)['include']
        self.assertEqual([(r['profile'], r['shard']) for r in normal],
                         [(r['profile'], r['shard']) for r in outage])
        self.assertEqual({r['provider'] for r in outage}, {'github'})
        self.assertEqual({r['macos_slot'] for r in outage}, set(range(5)))
        self.assertTrue(all('pool_slot' not in row for row in outage))
        self.assertEqual([{k: v for k, v in row.items() if k not in ('provider', 'pool_slot')} for row in normal],
                         [{k: v for k, v in row.items() if k != 'provider'} for row in outage])

    def test_twelve_pool_lanes_balance_long_jobs_without_changing_rows(self):
        rows = [{'shard': f'job-{i:02d}', 'macos_slot': i % 5} for i in range(26)]
        weights = list(range(26, 0, -1))
        saved = copy.deepcopy(rows)
        routed = with_bitrise_slots(rows, ('shard',), weights)
        self.assertEqual(rows, saved)
        self.assertEqual([{k: v for k, v in r.items() if k not in ('provider', 'pool_slot')} for r in routed], rows)
        self.assertEqual({(r['provider'], r['pool_slot']) for r in routed},
                         {(f'bitrise-{p}', n) for p in BITRISE_POOLS for n in range(6)})
        self.assertEqual(len({(r['provider'], r['pool_slot']) for r in routed[:12]}), 12)
        self.assertEqual(routed[0]['provider'], 'bitrise-A1')
        self.assertEqual(with_bitrise_slots(rows, ('shard',), weights, first_pool='A2')[0]['provider'], 'bitrise-A2')
        self.assertEqual(routed, with_bitrise_slots(rows, ('shard',), weights))
        totals = {}
        for row, seconds in zip(routed, weights):
            key = row['provider'], row['pool_slot']
            totals[key] = totals.get(key, 0) + seconds
        self.assertLessEqual(max(totals.values()) - min(totals.values()), max(weights))
        self.assertEqual(BITRISE_SLOTS_PER_POOL, 6)
        for bad in ([1], [True]*26, [0]*26, [1.5]*26):
            with self.assertRaises(ValueError): with_bitrise_slots(rows, ('shard',), bad)
        for bad in ([], [rows[0], rows[0]], [{'shard': 'a', 'provider': 'bitrise'}],
                    [{'shard': 'a', 'pool_slot': 6}], [{'shard': 'a', 'm4_slot': 0}]):
            with self.assertRaises(ValueError): with_bitrise_slots(bad, ('shard',), [1]*len(bad))
        with self.assertRaises(ValueError): with_bitrise_slots(rows, ('shard',), weights, first_pool='retired')

    def test_optional_a3_uses_six_m2_and_six_shared_m4_lanes_without_changing_inventory(self):
        enabled = fixture_matrix(a3_enabled=True)['include']
        default = fixture_matrix()['include']
        fields = ('profile', 'shard', 'macos_slot')
        self.assertEqual([[row[k] for k in fields] for row in enabled],
                         [[row[k] for k in fields] for row in default])
        self.assertEqual({(r['provider'], r['pool_slot']) for r in enabled},
                         {(f'bitrise-{p}', n) for p in ('A1', 'A2', 'A3')
                          for n in range(6 if p == 'A3' else 3)})
        self.assertEqual(fixture_matrix(github_mac_only=True, a3_enabled=True),
                         fixture_matrix(github_mac_only=True))
        # Longest first: each M4 assignment is followed by an M2 assignment
        # until all twelve lanes have work, regardless of which M4 pool starts.
        rows = [{'shard': str(index)} for index in range(12)]
        for first in ('A1', 'A2'):
            routed = with_bitrise_slots(rows, ('shard',), list(range(12, 0, -1)),
                                        first_pool=first, a3_enabled=True)
            self.assertEqual(routed[0]['provider'], 'bitrise-' + first)
            self.assertEqual([(r['provider'], r['pool_slot']) for r in routed[1::2]],
                             [('bitrise-A3', slot) for slot in range(6)])

    def test_all_three_planners_keep_complete_cases_and_emit_valid_slots(self):
        methods = [f'{UI_TARGET}/JourneyTests/test{i:02d}()' for i in range(10)]
        plan = make_plan(enumeration([MODEL, *methods]), DURATIONS, 10)
        validate_macos_slots(plan['include'], ('shard',))
        self.assertEqual([r['shard'] for r in plan['include']], ['models', *[f'ui-{i:02d}' for i in range(1, 11)]])
        self.assertCountEqual([c for s in plan['shards'].values() for c in s['test_identifiers']], [MODEL, *methods])
        fixtures = fixture_matrix()['include']
        self.assertEqual({row['provider'] for row in fixtures}, {'bitrise-A1', 'bitrise-A2'})
        self.assertEqual({(row['provider'], row['pool_slot']) for row in fixtures},
                         {(f'bitrise-{pool}', slot) for pool in BITRISE_POOLS for slot in range(6)})
        for row in fixtures:
            self.assertIs(type(row['pool_slot']), int)
            self.assertIn(row['pool_slot'], range(6))
            self.assertIn(row['macos_slot'], range(5))
            self.assertNotIn('m4_slot', row)
        self.assertEqual(len({(row['profile'], row['shard']) for row in fixtures}), 26)
        self.assertEqual(len(fixtures), 26)
        for suite in ('SharedRecordsUITests', 'SharedFallbackUITests'):
            self.assertEqual([row['profile'] for row in fixtures if row['shard'] == suite], ['contributor'])
        self.assertEqual(set(fixtures[0]), {'profile', 'shard', 'provider', 'macos_slot', 'pool_slot'})
        performance = performance_matrix('\n'.join(COMPILED))['include']
        validate_macos_slots(performance, ('case',))
        self.assertEqual([r['case'] for r in performance], ['launch', 'rendered', 'scroll'])
        self.assertEqual(len({r['selector'] for r in performance}), 3)


if __name__ == '__main__':
    unittest.main()
