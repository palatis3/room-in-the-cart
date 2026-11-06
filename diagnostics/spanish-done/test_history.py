import io
import json
from pathlib import Path
import signal
import subprocess
import tempfile
import unittest
from unittest.mock import Mock, patch
import history
import history_archive
import history_protocol as hp
from test_diagnostic import journal


def boundary(index, outcome=None):
    cls, method = hp.CASES[index]
    tail = 'started.' if outcome is None else f'{outcome} (10.000 seconds).'
    return f"Test Case '-[RoomInTheCartUITests.{cls} {method}]' {tail}\n"


DELETION = 'SDD_RUNNER|before|31|10\nSDD_RUNNER|after|31|11\n'
SPANISH = 'SDD_RUNNER|before|31|30\nSDD_RUNNER|after|31|31\n'


def log():
    return ''.join(boundary(i) + (DELETION if i == 2 else SPANISH if i == 3 else '')
                   + ('    t = 100.0s Terminate dev.roominthecart.app.debug:43\n' if i == 3 else '')
                   + boundary(i, 'failed' if i == 1 else 'passed') for i in range(4))


def events():
    first = journal(events=[(1, 'observer.installed'), (9, 'comparison.focus.bQuantity'), (12, 'textField.endEditing')])
    second = journal(pid=43, events=[(20, 'observer.installed'), (29, 'comparison.focus.bQuantity'), (32, 'textField.endEditing')])
    return {'process-42.events': first, 'process-43.events': second}


def compare(text=None, journals=None, exported=None):
    journals = journals or events()
    all_events = ''.join(journals.values())
    return hp.compare_history(journals, all_events, all_events if exported is None else exported, text or log())


class HistoryProtocolTests(unittest.TestCase):
    def test_target_scoped_after_completed_deletion_and_prefix_failure_retained(self):
        result = compare()
        self.assertEqual(result['targetProcessID'], 43)
        self.assertEqual(result['sequence']['cases'][1]['outcome'], 'failed')
        self.assertFalse(result['absenceInferenceAllowed'])
        self.assertEqual(result['processIDs'], [42, 43])

    def test_wrong_order_duplicate_missing_case_and_interleaved_starts_fail(self):
        bad = [log().replace(boundary(0), boundary(1), 1), log() + boundary(3),
               log().replace(boundary(2), '', 1), log().replace(boundary(0, 'passed'), '', 1)]
        for text in bad:
            with self.subTest(text=text[:80]), self.assertRaises(ValueError):
                compare(text)

    def test_restart_missing_end_and_timeout_missing_after_fail(self):
        for text in (log() + 'Restarting after unexpected exit, crash, or test timeout\n',
                     log().replace(boundary(3, 'passed'), ''), log().replace(SPANISH.splitlines(True)[1], '')):
            with self.subTest(text=text[-100:]), self.assertRaises(ValueError):
                compare(text)

    def test_cross_case_extra_and_outside_markers_fail(self):
        for text in (DELETION + log(), log().replace(boundary(0), boundary(0) + SPANISH),
                     log().replace(SPANISH, SPANISH + SPANISH), log().replace(SPANISH, DELETION)):
            with self.subTest(text=text[:70]), self.assertRaises(ValueError):
                compare(text)

    def test_runner_pid_change_is_not_silently_treated_as_same_history(self):
        with self.assertRaises(ValueError):
            compare(log().replace(SPANISH, SPANISH.replace('|31|', '|99|')))

    def test_ambiguous_pid_and_old_process_focus_are_rejected(self):
        for pid, activation in ((44, 21), (44, 1)):
            data = events()
            data[f'process-{pid}.events'] = journal(pid=pid, events=[(activation, 'observer.installed'),
                (28, 'comparison.focus.bQuantity'), (33, 'textField.endEditing')])
            with self.subTest(activation=activation), self.assertRaises(ValueError):
                compare(journals=data)

    def test_later_process_cannot_supply_target_coverage(self):
        data = events()
        data['process-43.events'] = journal(pid=43, events=[(20, 'observer.installed'), (29, 'comparison.focus.bQuantity')])
        data['process-44.events'] = journal(pid=44, events=[(32, 'observer.installed')])
        with self.assertRaisesRegex(ValueError, 'post-return'):
            compare(journals=data)

    def test_prefix_sink_loss_is_failure_even_when_target_capture_agrees(self):
        with self.assertRaisesRegex(ValueError, 'All-process'):
            compare(exported=events()['process-43.events'])

    def test_marker_screenshots_arm_only_at_exact_target_case(self):
        ledger = hp.CaseLog()
        targets = [line for line in log().splitlines(True) if ledger.feed(line)]
        self.assertEqual(targets, [boundary(3)])


    def test_first_target_termination_must_corroborate_candidate(self):
        for text in (log().replace('app.debug:43', 'app.debug:99'),
                     log().replace('    t = 100.0s Terminate dev.roominthecart.app.debug:43\n', '')):
            with self.subTest(text=text[-150:]), self.assertRaisesRegex(ValueError, 'termination'):
                compare(text)

    def test_stall_keeps_candidate_reasoning_without_after_end_or_termination(self):
        text = log().split(SPANISH.splitlines(True)[1])[0]
        result = hp.candidate_evidence(events(), text)
        self.assertEqual(result['candidatePIDs'], [43])
        self.assertFalse(result['sequence']['complete'])
        self.assertFalse(result['attributionComplete'])
        self.assertFalse(result['absenceInferenceAllowed'])


class HistoryRunnerTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory(); self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)

    def test_still_request_and_completion_are_distinct_from_unknown_exposure(self):
        stop, results = Mock(), []
        stop.wait.return_value = False
        with patch('history.subprocess.run', return_value=subprocess.CompletedProcess([], 0)) as invoke:
            history.capture_stills('owned', self.root, stop, 0, results)
        self.assertEqual(invoke.call_count, 2)
        for item in results:
            self.assertGreaterEqual(item['completedUTC'], item['requestUTC'])
            self.assertGreaterEqual(item['completionDelaySeconds'], item['requestDelaySeconds'])
            self.assertFalse(item['exposureTimeKnown'])

    def test_history_one_invocation_retains_prefix_failure_and_only_target_media(self):
        products = self.root / 'products'; products.mkdir()
        (products / 'RoomInTheCart_iphonesimulator26.2.xctestrun').touch()
        (self.root / 'selectors.txt').write_text('\n'.join(hp.SELECTORS) + '\n')
        container = self.root / 'container'; container.mkdir()
        live, video = Mock(pid=10, returncode=-15), Mock(pid=11, returncode=0)
        live.poll.return_value = video.poll.return_value = None
        test = Mock(pid=12, returncode=65, stdout=io.StringIO(log().replace(boundary(3),
            boundary(3) + '    t = 1.00s     Launch dev.roominthecart.app.debug\n')))
        test.poll.return_value = test.wait.return_value = 65
        with patch('history.frozen'), patch('history.verify_runtime', return_value=('owned', {})), \
             patch('history.command', return_value=str(container)), patch('history.time.sleep'), \
             patch('history.signal.alarm') as alarm, patch('history.threading.Thread') as watcher, \
             patch('history.subprocess.Popen', side_effect=[live, test, video]) as start:
            self.assertEqual(history.execute(self.root, products), 1)
        self.assertEqual(start.call_count, 3)
        self.assertEqual(watcher.call_count, 1)
        alarm.assert_any_call(3900)
        args = json.loads((self.root / 'test-command.json').read_text())
        self.assertEqual([x for x in args if x.startswith('-only-testing:')], ['-only-testing:' + s for s in hp.SELECTORS])
        self.assertEqual(args[args.index('-default-test-execution-time-allowance') + 1], '720')
        self.assertEqual(args[args.index('-maximum-test-execution-time-allowance') + 1], '900')
        self.assertEqual(json.loads((self.root / 'test-status.json').read_text())['exit'], 65)
        self.assertEqual(json.loads((self.root / 'case-sequence.json').read_text())['cases'][1]['outcome'], 'failed')
        with self.assertRaisesRegex(ValueError, 'no reuse/retry'):
            history.execute(self.root, products)

    def test_cancellation_exit_race_still_writes_raw_status_and_stops_capture(self):
        products = self.root / 'products'; products.mkdir()
        (products / 'RoomInTheCart_iphonesimulator26.2.xctestrun').touch()
        (self.root / 'selectors.txt').write_text('\n'.join(hp.SELECTORS) + '\n')
        container = self.root / 'container'; container.mkdir()
        def interrupted_output():
            yield boundary(0)
            raise KeyboardInterrupt
        live = Mock(pid=10, returncode=-15); live.poll.return_value = None
        test = Mock(pid=12, returncode=0, stdout=interrupted_output())
        test.poll.return_value = None
        test.wait.return_value = 0
        with patch('history.frozen'), patch('history.verify_runtime', return_value=('owned', {})), \
             patch('history.command', return_value=str(container)), patch('history.time.sleep'), \
             patch('history.signal.alarm'), patch('history.os.killpg', side_effect=ProcessLookupError), \
             patch('history.subprocess.Popen', side_effect=[live, test]):
            self.assertEqual(history.execute(self.root, products), 1)
        status = json.loads((self.root / 'test-status.json').read_text())
        self.assertEqual(status['exit'], 0)
        self.assertTrue(status['interrupted'])
        self.assertIn('live', json.loads((self.root / 'capture-stop.json').read_text()))

    def test_wrong_pinned_zip_refuses_before_any_git_or_native_command(self):
        path = self.root / 'fake.zip'; path.write_bytes(b'not the pinned archive')
        with patch('history_archive.command') as command, self.assertRaises(ValueError):
            history_archive.restore(path, self.root / 'proof')
        command.assert_not_called()

    def test_collection_preserves_full_journals_when_protocol_is_incomplete(self):
        # Collector remains the proven full-journal collector; validator failure
        # is a separate verdict and never removes or slices source journal data.
        history.run.write(self.root / 'capture-start.json', {'startedUTC': history.time.time()})
        history.run.write(self.root / 'target-video-start.json', {'aliveAtReadiness': True, 'aliveBeforeTargetMarker': True})
        (self.root / 'Tests.log').write_text(log())
        def collector(out, **kwargs):
            self.assertEqual(kwargs['expected_count'], 4)
            self.assertEqual(kwargs['export_window'], '90m')
            with self.assertRaises(ValueError):
                kwargs['event_validator'](events(), ''.join(events().values()), '', log())
            return 1
        with patch('history.run.collect', side_effect=collector):
            self.assertEqual(history.collect(self.root), 1)
        self.assertEqual(json.loads((self.root / 'spanish-assessment.json').read_text())['cases'][0]['outcome'], 'passed')
