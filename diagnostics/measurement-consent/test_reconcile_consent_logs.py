import contextlib
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from reconcile_consent_logs import APPLICABLE, FLAGS, SCOPE, main, parse, reconcile


def event(sequence=1, name='fixture.ready', pid=101, uptime=None, **values):
    flags = {key: (1 if key in APPLICABLE[name] else -1) for key in FLAGS}
    if name == 'consent.set.rejectedMissingWorkspace': flags['workspacePresent'] = 0
    flags.update(values)
    message = f'sequence={sequence} uptime={uptime or str(sequence)+".000000"} event={name}'
    message += ''.join(f' {key}={flags[key]}' for key in FLAGS)
    return f'2026-11-06 19:00:00.123 I  RoomInTheCart[{pid}:abc] {SCOPE} {message}'


def flow(pid=101):
    return '\n'.join(event(i, name, pid) for i, name in enumerate(
        ('fixture.ready', 'binding.enter', 'consent.set.enter', 'consent.set.exit', 'binding.exit'), 1))


class ReconcileTests(unittest.TestCase):
    def assert_no_negative_inference(self, result):
        self.assertEqual(result['status'], 'inconclusive')
        self.assertTrue(result['diagnosticOnly'])
        self.assertFalse(result['exhaustiveDeliveryEstablished'])
        self.assertFalse(result['noSetterInferencePermitted'])
        self.assertEqual(result['absenceMeaning'], 'not_observed')

    def test_complete_agreeing_flow_is_positive_observation_not_exhaustiveness(self):
        result = reconcile(flow(), flow(), live_status='ok', export_status='ok')
        self.assertEqual(result['comparison']['sharedUniqueEvents'], 5)
        self.assertTrue(result['processes'][0]['bindingEnterObserved'])
        self.assertEqual(result['processes'][0]['internalGapRanges'], [])
        self.assert_no_negative_inference(result)

    def test_matching_activation_only_cannot_exclude_missing_tail_setter(self):
        result = reconcile(event(), event(), live_status='ok', export_status='ok')
        self.assertTrue(result['processes'][0]['activationObserved'])
        self.assertFalse(result['processes'][0]['bindingEnterObserved'])
        self.assertTrue(result['comparison']['observedEventSetsEqual'])
        self.assert_no_negative_inference(result)

    def test_persisted_export_can_omit_whole_launch(self):
        live = flow(101)+'\n'+flow(102)
        result = reconcile(live, flow(102), expected_pids=[101, 102], live_status='ok', export_status='ok')
        self.assertEqual(result['comparison']['liveOnlyUniqueEvents'], 5)
        self.assertEqual(result['comparison']['exportOnlyUniqueEvents'], 0)
        self.assertEqual(set(result['sources']['live']['processes']), {'101', '102'})
        self.assertEqual(set(result['sources']['export']['processes']), {'102'})
        self.assert_no_negative_inference(result)

    def test_expected_launch_absent_from_both_remains_explicit(self):
        result = reconcile(flow(), flow(), expected_pids=[101, 202])
        missing = result['processes'][1]
        self.assertEqual(missing['pid'], 202)
        self.assertFalse(missing['observed'])
        self.assertFalse(missing['activationObserved'])
        self.assert_no_negative_inference(result)

    def test_prefix_and_large_internal_gaps_are_ranges_not_allocated_lists(self):
        text = event(3, 'binding.enter')+'\n'+event(2**63, 'binding.exit')
        result = reconcile(text, '')
        process = result['processes'][0]
        self.assertEqual(process['missingPrefixRange'], [1, 2])
        self.assertEqual(process['internalGapRanges'], [[4, 2**63-1]])
        self.assertFalse(process['activationObserved'])
        self.assert_no_negative_inference(result)

    def test_duplicates_are_counted_without_becoming_conflicts(self):
        text = event()+'\n'+event()
        result = reconcile(text, event())
        self.assertEqual(result['sources']['live']['eventCount'], 2)
        self.assertEqual(result['sources']['live']['exactDuplicateOccurrences'], 1)
        self.assertEqual(result['comparison']['sharedUniqueEvents'], 1)
        self.assertEqual(result['processes'][0]['conflictingSequences'], [])

    def test_cross_source_same_sequence_value_conflict_preserves_both(self):
        live = event(2, 'binding.enter', requested=1)
        exported = event(2, 'binding.enter', requested=0)
        result = reconcile(live, exported)
        process = result['processes'][0]
        self.assertEqual(process['conflictingSequences'], [2])
        self.assertEqual(len(process['records'][0]['observations']), 2)
        self.assertEqual(result['comparison']['liveOnlyUniqueEvents'], 1)
        self.assertEqual(result['comparison']['exportOnlyUniqueEvents'], 1)
        self.assert_no_negative_inference(result)

    def test_reused_pid_reset_or_corruption_is_not_merged_as_one_clean_launch(self):
        result = reconcile(event(uptime='1.0')+'\n'+event(uptime='999.0'), '')
        self.assertTrue(result['processes'][0]['pidReuseOrCorruptionPossible'])
        self.assertEqual(result['processes'][0]['conflictingSequences'], [1])

    def test_original_sequence_order_survives_sorted_union_report(self):
        text = '\n'.join((event(), event(3, 'consent.set.enter'), event(2, 'binding.enter')))
        result = reconcile(text, '')
        source = result['sources']['live']['processes']['101']
        self.assertEqual(source['sequenceInInputOrder'], [1, 3, 2])
        self.assertEqual(source['sequenceRegressions'], 1)
        self.assertEqual([record['sequence'] for record in result['processes'][0]['records']], [1, 2, 3])

    def test_empty_failed_or_unknown_capture_never_claims_no_setter(self):
        for status in ('ok', 'failed', 'unknown'):
            with self.subTest(status=status):
                result = reconcile('', '', live_status=status, export_status=status)
                self.assertEqual(result['processes'], [])
                self.assert_no_negative_inference(result)

    def test_extra_export_event_is_retained_not_discarded_in_favor_of_live(self):
        result = reconcile(event(), flow())
        self.assertEqual(result['comparison']['exportOnlyUniqueEvents'], 4)
        self.assertTrue(result['processes'][0]['bindingEnterObserved'])
        self.assert_no_negative_inference(result)

    def test_malformed_and_unrelated_content_never_echoes_private_strings(self):
        secret = 'sensitive@example.invalid'
        text = 'unrelated '+secret+'\n'+event()+' '+secret+'\n'+event(2, 'binding.enter')
        result = reconcile(text, '')
        self.assertEqual(result['sources']['live']['ignoredNonCandidateLines'], 1)
        self.assertEqual(result['sources']['live']['malformedLineNumbers'], [2])
        self.assertNotIn(secret, json.dumps(result))
        self.assertEqual(result['sources']['live']['eventCount'], 1)
        self.assert_no_negative_inference(result)

    def test_fixed_schema_rejects_truncation_wrong_flags_unknown_events_and_invalid_numbers(self):
        good = event()
        bad = [good[:-3], good.replace('event=fixture.ready', 'event=secret.unknown'),
               good.replace('requested=-1', 'requested=1'), good.replace('ready=1', 'ready=2'),
               good.replace('sequence=1 ', 'sequence=0 '), good.replace('sequence=1 ', 'sequence=18446744073709551616 '),
               good.replace('uptime=1.000000', 'uptime=NaN'), good.replace('uptime=1.000000', 'uptime=-1'),
               good.replace('2026-11-06', '2026-13-06'), good.replace('[101:', '[0:')]
        for value in bad:
            with self.subTest(value=value):
                parsed = parse(value)
                self.assertEqual(parsed['events'], [])
                self.assertEqual(parsed['malformedLineNumbers'], [1])

    def test_decimal_format_differences_do_not_manufacture_conflicting_events(self):
        result = reconcile(event(uptime='1.000000'), event(uptime='1.0'))
        self.assertEqual(result['comparison']['sharedUniqueEvents'], 1)
        self.assertEqual(result['processes'][0]['conflictingSequences'], [])

    def test_high_precision_uptime_differences_remain_conflicts(self):
        first = event(uptime='12345678901234567890.123456789001')
        second = event(uptime='12345678901234567890.123456789002')
        result = reconcile(first, second)
        self.assertEqual(result['processes'][0]['conflictingSequences'], [1])

    def test_rejection_and_reset_events_use_only_expected_structural_fields(self):
        text = '\n'.join((event(), event(2, 'consent.set.rejectedMissingWorkspace'), event(3, 'consent.reset')))
        self.assertEqual(len(parse(text)['events']), 3)
        self.assertEqual(parse(event(3, 'consent.reset', enabledValue=0))['events'], [])

    def test_cli_missing_files_writes_unavailable_inconclusive_report_without_path_echo(self):
        with tempfile.TemporaryDirectory() as folder:
            output = Path(folder)/'report.json'
            args = ['reconcile', '--live', str(Path(folder)/'missing-live'), '--export', str(Path(folder)/'missing-export'),
                    '--expected-pid', '101', '--output', str(output)]
            with patch('sys.argv', args), contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(main(), 0)
            result = json.loads(output.read_text())
            self.assertEqual(result['sources']['live']['readStatus'], 'unavailable')
            self.assertEqual(result['inputSHA256'], {'live': None, 'export': None})
            self.assertNotIn(folder, output.read_text())
            self.assert_no_negative_inference(result)

    def test_cli_records_hashes_and_does_not_spawn_capture_processes(self):
        with tempfile.TemporaryDirectory() as folder:
            live, exported, output = (Path(folder)/name for name in ('live', 'export', 'result'))
            live.write_text(flow()); exported.write_text(event())
            args = ['reconcile', '--live', str(live), '--export', str(exported), '--output', str(output)]
            with patch('sys.argv', args), patch('subprocess.run') as run, patch('subprocess.Popen') as popen:
                self.assertEqual(main(), 0)
            run.assert_not_called(); popen.assert_not_called()
            result = json.loads(output.read_text())
            self.assertEqual(len(result['inputSHA256']['live']), 64)
            self.assertEqual(result['comparison']['liveOnlyUniqueEvents'], 4)
            self.assert_no_negative_inference(result)

    def test_invalid_capture_status_and_expected_pid_rejected(self):
        with self.assertRaises(ValueError): reconcile('', '', live_status='complete')
        for pid in (0, -1, True, 'credential'):
            with self.assertRaises(ValueError): reconcile('', '', expected_pids=[pid])


if __name__ == '__main__':
    unittest.main()
