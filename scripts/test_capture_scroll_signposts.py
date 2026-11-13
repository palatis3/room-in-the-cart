#!/usr/bin/env python3
"""Pure/synthetic collector tests: no Xcode, simctl, log or app invocation."""
import io
import copy
import json
import os
import plistlib
import re
import subprocess
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch
from types import SimpleNamespace

import capture_scroll_signposts as probe


def event(**kwargs):
    row = dict(timestamp='2026-11-09 13:01:02.123456+0000', processID=123,
               processImagePath='/private/simulator/App.app/RoomInTheCart',
               subsystem='com.apple.UIKit', category='ScrollView',
               signpostName='Scroll_DraggingAndDeceleration', eventType='signpostEvent',
               signpostType='begin', signpostID=42, eventMessage='PRIVATE GROCERY TEXT')
    row.update(kwargs)
    return json.dumps(row).encode()


class MetadataTests(unittest.TestCase):
    def make(self):
        return probe.Metadata('control.ns', b'fixed synthetic salt')

    def test_original_endpoint_metadata_without_message_or_path(self):
        meta = self.make()
        meta.line(event())
        self.assertFalse(meta.errors)
        self.assertTrue(meta.events[0]['originalScrollTaxonomy'])
        self.assertEqual(meta.events[0]['id'], '42')
        output = json.dumps(meta.events)
        for private in ('PRIVATE', 'simulator', 'com.apple.UIKit', 'ScrollView'):
            self.assertNotIn(private, output)

    def test_unknown_labels_are_same_run_tokens_only(self):
        live, stored = self.make(), self.make()
        raw = event(subsystem='private user label', category='secret', signpostName='receipt contents')
        live.line(raw)
        stored.line(raw)
        self.assertEqual(live.events, stored.events)
        self.assertFalse(live.events[0]['originalScrollTaxonomy'])
        self.assertNotIn('secret', json.dumps(live.events))

    def test_cross_run_tokens_differ(self):
        a, b = self.make(), probe.Metadata('control.ns', b'another salt')
        a.line(event())
        b.line(event())
        self.assertNotEqual(a.events[0]['taxonomyTokens'], b.events[0]['taxonomyTokens'])

    def test_control_is_separate_process_and_not_scroll_pair(self):
        meta = self.make()
        meta.line(event(subsystem='control.ns', category='pre', signpostName='',
                        signpostType='event', processImagePath='/usr/bin/log'))
        self.assertEqual(meta.controls, {'pre'})
        self.assertEqual(meta.events[0]['scope'], 'control-pre')
        self.assertFalse(meta.events[0]['originalScrollTaxonomy'])

    def test_missing_timezone_wrong_pid_wrong_schema_fail_closed(self):
        for delta in ({'timestamp': '2026-11-09T13:01:02'}, {'processID': True},
                      {'signpostType': 'START'}, {'signpostID': 'arbitrary'},
                      {'eventType': 'lossEvent'}, {'processImagePath': '/other/App'}):
            with self.subTest(delta=delta):
                meta = self.make()
                meta.line(event(**delta))
                self.assertTrue(meta.errors)
                self.assertFalse(meta.events)

    def test_counts_and_bytes_have_independent_caps(self):
        for cap in ('MAX_EVENTS', 'MAX_METADATA'):
            with self.subTest(cap=cap), patch.object(probe, cap, 0):
                meta = self.make()
                meta.line(event())
                self.assertIn('metadata_cap', meta.errors)
                self.assertFalse(meta.events)

    def test_loss_and_unknown_terminal_record_are_not_silent(self):
        meta = self.make()
        meta.line(b'{"finished":1,"dropped":2}')
        self.assertTrue(meta.finished)
        self.assertIn('unqualified_terminal_record', meta.errors)

    def test_zero_count_terminal_record_is_accepted(self):
        meta = self.make()
        meta.line(b'{"count":0,"finished":1}')
        self.assertTrue(meta.finished)
        self.assertFalse(meta.errors)

    def test_capture_filter_matches_observed_actual_predicate_banner(self):
        namespace = 'dev.roominthecart.scrollprobe.f564e682b42d4a46b9e2dd77070caead'
        predicate, banner = probe.capture_filter(namespace)
        self.assertEqual(predicate, 'eventType == "signpostEvent" AND (process == "RoomInTheCart" OR subsystem == "' + namespace + '")')
        self.assertEqual(banner, ('Filtering the log data using "type == 1536 AND (process == "RoomInTheCart" OR subsystem == "' + namespace + '")"').encode())
        for invalid in ('other', namespace + '"', namespace.upper(), namespace[:-1]):
            with self.subTest(namespace=invalid), self.assertRaisesRegex(ValueError, 'invalid_capture_namespace'):
                probe.capture_filter(invalid)

    def test_duplicate_json_members_are_rejected_even_when_equal(self):
        for raw in (b'{"count":999,"count":0,"finished":1}',
                    b'{"count":0,"finished":0,"finished":1}',
                    b'{"count":0,"count":0,"finished":1}',
                    event().replace(b'"processID": 123', b'"processID": 999,"processID": 123')):
            with self.subTest(raw=raw):
                meta = self.make()
                meta.line(raw)
                self.assertIn('unsupported_record_or_schema', meta.errors)
                self.assertFalse(meta.events)

    def test_exact_initial_banner_and_three_event_footer(self):
        banner = b'Filtering the log data using "exact synthetic predicate"'
        meta = probe.Metadata('control.ns', b'salt', banner)
        meta.line(banner)
        for pid in (101, 102, 103):
            meta.line(event(subsystem='control.ns', category='pre', signpostName='log-emit',
                            signpostType='event', processID=pid, signpostID=17216892719917625070,
                            processImagePath='/usr/bin/log'))
        meta.line(b'{"count":3,"finished":1}')
        self.assertEqual(len(meta.events), 3)
        self.assertEqual(meta.controls, {'pre'})
        self.assertTrue(meta.finished)
        self.assertFalse(meta.errors)

    def test_wrong_duplicate_and_late_banners_fail(self):
        banner = b'Filtering the log data using "exact synthetic predicate"'
        for lines in ([banner + b' extra'], [b'Filtering the log data using "other predicate"'],
                      [banner, banner], [event(), banner]):
            with self.subTest(lines=lines):
                meta = probe.Metadata('control.ns', b'salt', banner)
                for line in lines:
                    meta.line(line)
                self.assertTrue(meta.errors)

    def test_footer_requires_exact_schema_types_and_validated_event_count(self):
        for footer in ({'finished': 1}, {'count': 0}, {'count': -1, 'finished': 1},
                       {'count': True, 'finished': 1}, {'count': 1.0, 'finished': 1},
                       {'count': '1', 'finished': 1}, {'count': 1, 'finished': True},
                       {'count': 1, 'finished': 0}, {'count': 0, 'finished': 1},
                       {'count': 2, 'finished': 1}, {'count': 1, 'finished': 1, 'dropped': 0}):
            with self.subTest(footer=footer):
                meta = self.make()
                meta.line(event())
                meta.line(json.dumps(footer).encode())
                self.assertTrue(meta.errors)

    def test_footer_does_not_rescue_errors_and_no_records_may_follow_it(self):
        for trailing in (b'{"count":1,"finished":1}', event(), b'arbitrary text'):
            with self.subTest(trailing=trailing):
                meta = self.make()
                meta.line(event())
                meta.line(b'{"count":1,"finished":1}')
                meta.line(trailing)
                self.assertIn('record_after_terminal', meta.errors)
                self.assertEqual(len(meta.events), 1)
        with patch.object(probe, 'MAX_EVENTS', 0):
            meta = self.make()
            meta.line(event())
            meta.line(b'{"count":0,"finished":1}')
            self.assertIn('metadata_cap', meta.errors)

    def test_logging_environment_redacts_unknown_values_and_names(self):
        with patch.dict(os.environ, {'OS_LOG_PRIVATE_secret': 'secret value'}, clear=True):
            value = probe.environment_summary({'TestHostEnvironmentVariables':
                    {'OS_ACTIVITY_MODE': 'disable', 'TOKEN': 'private token'}})
        output = json.dumps(value)
        self.assertIn('disable', output)
        self.assertNotIn('secret', output)
        self.assertNotIn('TOKEN', output)
        self.assertNotIn('private token', output)


class PumpTests(unittest.TestCase):
    def run_python(self, code, seconds=2, metadata=None):
        pump = probe.Pump([sys.executable, '-c', code], seconds, metadata).start()
        pump.thread.join(seconds + 4)
        pump.close()
        return pump

    def test_only_synthetic_child_stderr_is_counted_not_retained(self):
        pump = self.run_python('import sys; sys.stderr.write("private error")')
        self.assertIn('stderr_present', pump.errors)
        self.assertEqual(pump.stderr_bytes, 13)
        self.assertNotIn('private error', json.dumps(pump.receipt()))

    def test_chunk_split_framing_passes_but_uid_warning_still_fails(self):
        banner = b'Filtering the log data using "exact synthetic predicate"'
        payload = banner + b'\n' + event() + b'\n{"count":1,"finished":1}\n'
        code = ('import os; data=' + repr(payload) +
                '; [os.write(1, data[i:i+7]) for i in range(0, len(data), 7)]')
        for warning in (False, True):
            with self.subTest(warning=warning):
                meta = probe.Metadata('control.ns', b'salt', banner)
                child = code + ('; os.write(2, b"getpwuid_r did not find a match for uid 501\\n")' if warning else '')
                pump = self.run_python(child, metadata=meta)
                self.assertEqual(len(meta.events), 1)
                self.assertTrue(meta.finished)
                self.assertFalse(meta.errors)
                self.assertEqual(pump.errors, {'stderr_present'} if warning else set())
                self.assertEqual(pump.stderr_bytes, 44 if warning else 0)

    def test_help_may_use_either_channel_but_nonhelp_stderr_still_fails(self):
        argv = [sys.executable, '-c', 'import sys; print("usage"); sys.stderr.write("signpost-event")']
        receipt = {}
        self.assertIn(b'signpost-event', probe.command(argv, help_receipt=receipt))
        self.assertGreater(receipt['stderrBytes'], 0)
        self.assertNotIn('signpost-event', json.dumps(receipt))
        with self.assertRaises(ValueError):
            probe.command(argv)

    def test_deadline_reaps_owned_synthetic_child(self):
        pump = self.run_python('import time; time.sleep(20)', seconds=0.1)
        self.assertIn('deadline', pump.errors)
        self.assertIsNotNone(pump.process.poll())

    def test_partial_record_is_not_accepted(self):
        pump = self.run_python('import sys; sys.stdout.write("{")', metadata=probe.Metadata('x', b's'))
        self.assertIn('partial_record', pump.errors)

    def test_raw_byte_cap_stops_collector(self):
        with patch.object(probe, 'MAX_RAW', 100):
            pump = self.run_python('print("x" * 200)')
        self.assertIn('raw_cap', pump.errors)
        self.assertIsNotNone(pump.process.poll())

    def test_preflight_output_cap_is_bounded(self):
        with patch.object(probe, 'MAX_LINE', 100):
            pump = self.run_python('print("x" * 200)')
        self.assertIn('preflight_output_cap', pump.errors)
        self.assertLessEqual(len(pump.stdout), 100)


class PumpPhaseTests(unittest.TestCase):
    """Controlled clocks/real nonblocking pipes: no native child or wall-time sleeps."""
    def controlled_command(self, mode, worker_delay=0, seconds=10, output_at=3, expect_success=None):
        should_succeed = mode == 'delayed-output' if expect_success is None else expect_success
        clock = SimpleNamespace(now=0.0)
        reads = [os.pipe(), os.pipe()]
        process = SimpleNamespace(stdout=os.fdopen(reads[0][0], 'rb'),
                                  stderr=os.fdopen(reads[1][0], 'rb'), returncode=None)
        writes = [pair[1] for pair in reads]
        def finish(code):
            process.returncode = code
            while writes:
                os.close(writes.pop())
        process.poll = lambda: process.returncode
        process.wait = lambda timeout: process.returncode
        def spawn(*_args, **_kwargs):
            if mode == 'delayed-spawn':
                clock.now += 11
            return process
        class Thread:
            def __init__(self, target, daemon):
                self.target = target
            def start(self):
                clock.now += worker_delay
                self.target()
            def join(self, timeout):
                pass
            def is_alive(self):
                return False
        class Selector:
            def __init__(self):
                self.keys = {}
                self.emitted = False
            def register(self, pipe, _event, channel):
                self.keys[pipe.fileno()] = SimpleNamespace(fileobj=pipe, fd=pipe.fileno(), data=channel)
            def unregister(self, pipe):
                del self.keys[pipe.fileno()]
            def get_map(self):
                return self.keys
            def select(self, timeout):
                if mode == 'unread-buffer':
                    os.write(writes[0], b'PRIVATE_COMPLETE_OUTPUT')
                    os.write(writes[1], b'PRIVATE_ERROR')
                    finish(0)
                    clock.now += 11
                    return []  # Data exists, but no normal read occurs before expiry.
                clock.now += 0.25 if mode == 'delayed-output' else timeout
                if mode == 'delayed-output' and clock.now >= output_at:
                    if not self.emitted:
                        os.write(writes[0], b'ordinary-output')
                        finish(0)
                        self.emitted = True
                    return [(key, None) for key in self.keys.values()]
                return []
            def close(self):
                self.keys.clear()
        entry = {}
        try:
            with patch.object(probe.time, 'monotonic', side_effect=lambda: clock.now), \
                 patch.object(probe.threading, 'Thread', Thread), \
                 patch.object(probe.selectors, 'DefaultSelector', Selector), \
                 patch.object(probe.subprocess, 'Popen', side_effect=spawn), \
                 patch.object(probe, 'terminate_owned', side_effect=lambda child: finish(-15) if child.poll() is None else None):
                if should_succeed:
                    output = probe.command_result(['synthetic-child'], seconds, None, entry)
                else:
                    with self.assertRaisesRegex(ValueError, 'capability_command_failed'):
                        probe.command_result(['synthetic-child'], seconds, None, entry)
                    output = None
            return entry, output
        finally:
            for descriptor in writes:
                os.close(descriptor)
            process.stdout.close()
            process.stderr.close()

    def test_delayed_spawn_is_visible_and_budget_still_includes_creation(self):
        entry, output = self.controlled_command('delayed-spawn', worker_delay=0.5)
        phases = entry['pump']['phaseSeconds']
        self.assertEqual(phases['workerEntry'], 0.5)
        self.assertEqual(phases['spawnReturned'] - phases['spawnStart'], 11)
        self.assertEqual(phases['deadlineObserved'] - phases['budgetStart'], 11)
        self.assertIsNone(phases['firstRead'])
        self.assertEqual(entry['errors'], ['deadline'])
        self.assertEqual(entry['exitCode'], -15)
        self.assertIsNone(output)

    def test_inventory_policy_allows_later_output_but_other_commands_still_expire(self):
        self.assertEqual(probe.INVENTORY_COMMAND_SECONDS, 30)
        self.assertEqual(probe.COMMAND_SECONDS, 10)
        entry, output = self.controlled_command('delayed-output', seconds=probe.INVENTORY_COMMAND_SECONDS, output_at=15)
        self.assertEqual(output, b'ordinary-output')
        self.assertEqual(entry['timeoutSeconds'], 30)
        self.assertEqual(entry['pump']['phaseSeconds']['firstRead'], 15)
        entry, output = self.controlled_command('delayed-output', seconds=probe.COMMAND_SECONDS,
                                               output_at=15, expect_success=False)
        self.assertEqual(entry['timeoutSeconds'], 10)
        self.assertEqual(entry['errors'], ['deadline'])
        self.assertEqual(entry['exitCode'], -15)
        self.assertIsNone(output)

    def test_inventory_boundary_still_fails_closed_with_original_cleanup(self):
        entry, output = self.controlled_command('delayed-output', seconds=probe.INVENTORY_COMMAND_SECONDS,
                                               output_at=30, expect_success=False)
        self.assertEqual(entry['timeoutSeconds'], 30)
        self.assertEqual(entry['errors'], ['deadline'])
        self.assertEqual(entry['pump']['phaseSeconds']['deadlineObserved'], 30)
        self.assertIsNotNone(entry['pump']['phaseSeconds']['cleanupComplete'])
        self.assertIsNone(output)
        entry, _ = self.controlled_command('no-output', seconds=probe.INVENTORY_COMMAND_SECONDS)
        self.assertEqual(entry['errors'], ['deadline'])
        self.assertEqual(entry['exitCode'], -15)

    def test_delayed_output_is_separate_from_spawn_and_is_normally_accepted(self):
        entry, output = self.controlled_command('delayed-output')
        phases = entry['pump']['phaseSeconds']
        self.assertEqual(phases['spawnReturned'], phases['spawnStart'])
        self.assertEqual(phases['firstRead'], 3)
        self.assertIsNone(phases['deadlineObserved'])
        self.assertIsNone(entry['pump']['deadlineObservation'])
        self.assertEqual(output, b'ordinary-output')
        self.assertEqual(entry['errors'], [])
        self.assertEqual(set(phases), set(probe.PUMP_PHASES))
        self.assertEqual(len(phases), 10)
        self.assertIsNotNone(phases['cleanupComplete'])

    def test_unread_buffer_and_exit_zero_never_rescue_a_deadline(self):
        entry, output = self.controlled_command('unread-buffer')
        observation = entry['pump']['deadlineObservation']
        self.assertEqual(observation['processState'], 'exited')
        self.assertEqual(observation['exitCode'], 0)
        self.assertEqual(entry['exitCode'], 0)
        self.assertEqual(entry['errors'], ['deadline'])
        self.assertEqual(entry['stdoutBytes'], 0)
        self.assertEqual(entry['stderrBytes'], 0)
        self.assertEqual(entry['rawBytesConsumed'], 0)
        self.assertEqual(observation['pipes']['stdout']['bytes'], len(b'PRIVATE_COMPLETE_OUTPUT'))
        self.assertEqual(observation['pipes']['stderr']['bytes'], len(b'PRIVATE_ERROR'))
        self.assertIsNone(entry['pump']['phaseSeconds']['firstRead'])
        self.assertEqual(entry['pump']['maxLoopGapSeconds'], 11)
        self.assertNotIn('PRIVATE', json.dumps(entry))
        self.assertIsNone(output)

    def test_no_output_preserves_deadline_cleanup_and_records_empty_polls(self):
        entry, _ = self.controlled_command('no-output')
        observation = entry['pump']['deadlineObservation']
        self.assertEqual(observation['processState'], 'running')
        self.assertIsNone(observation['exitCode'])
        for row in observation['pipes'].values():
            self.assertEqual(row, {'attempts': 1, 'bytes': 0, 'status': 'would_block'})
        self.assertGreaterEqual(entry['pump']['selectorReturns'], 90)
        self.assertLessEqual(entry['pump']['selectorReturns'], 110)
        self.assertAlmostEqual(entry['pump']['maxLoopGapSeconds'], 0.1)
        self.assertEqual(entry['errors'], ['deadline'])
        self.assertEqual(entry['exitCode'], -15)

    def test_late_observation_is_one_read_per_pipe_with_a_fixed_byte_bound(self):
        pump = probe.Pump(['synthetic-child'], 10)
        pump.errors.add('deadline')
        pump.process = SimpleNamespace(poll=Mock(return_value=None),
                                       stdout=SimpleNamespace(fileno=lambda: 10),
                                       stderr=SimpleNamespace(fileno=lambda: 11))
        with patch.object(probe.os, 'read', side_effect=lambda _fd, count: b'x' * count) as read:
            pump.observe_deadline()
            pump.observe_deadline()
        self.assertEqual([call.args for call in read.call_args_list], [(10, 8192), (11, 8192)])
        pump.process.poll.assert_called_once()
        self.assertEqual(sum(row['bytes'] for row in pump.deadline_observation['pipes'].values()), 16384)
        self.assertEqual(pump.stdout, b'')
        self.assertEqual(pump.stderr_bytes, 0)
        self.assertEqual(pump.errors, {'deadline'})
        snapshot = pump.observation()
        pump.deadline_observation['pipes']['stdout']['bytes'] = 0
        self.assertEqual(snapshot['deadlineObservation']['pipes']['stdout']['bytes'], 8192)

    def test_late_bytes_share_the_existing_raw_budget_without_extending_it(self):
        for remaining in (3, 0):
            pump = probe.Pump(['synthetic-child'], 10)
            pump.errors.add('deadline')
            pump.raw_bytes = probe.MAX_RAW - remaining
            pump.process = SimpleNamespace(poll=lambda: None, stdout=SimpleNamespace(fileno=lambda: 10),
                                           stderr=SimpleNamespace(fileno=lambda: 11))
            with self.subTest(remaining=remaining), patch.object(probe.os, 'read', side_effect=lambda _fd, count: b'x' * count) as read:
                pump.observe_deadline()
            consumed = sum(row['bytes'] for row in pump.deadline_observation['pipes'].values())
            self.assertEqual(pump.raw_bytes + consumed, probe.MAX_RAW)
            self.assertEqual(read.call_count, 1 if remaining else 0)
            self.assertEqual(pump.deadline_observation['pipes']['stderr']['status'], 'raw_budget_exhausted')

    def test_observation_cannot_consume_before_deadline_or_grow_phase_keys(self):
        pump = probe.Pump(['synthetic-child'], 10)
        with patch.object(probe.os, 'read') as read:
            pump.observe_deadline()
        read.assert_not_called()
        self.assertIsNone(pump.deadline_observation)
        with self.assertRaisesRegex(ValueError, 'unknown_pump_phase'):
            pump.mark('arbitrary_label')
        self.assertEqual(set(pump.phase_seconds), set(probe.PUMP_PHASES))

    def test_selector_counter_saturates_without_changing_acceptance(self):
        with patch.object(probe, 'MAX_SELECTOR_RETURNS', 2):
            entry, output = self.controlled_command('delayed-output')
        self.assertEqual(entry['pump']['selectorReturns'], 2)
        self.assertTrue(entry['pump']['selectorReturnsCapped'])
        self.assertEqual(entry['errors'], [])
        self.assertEqual(output, b'ordinary-output')


class AdmissionTests(unittest.TestCase):
    def test_documented_log_dates_enclose_capture_without_iso_t(self):
        stamp = '2026-11-09T13:01:02.123456+00:00'
        self.assertEqual(probe.log_date(stamp), '2026-11-09 13:01:02+00:00')
        self.assertEqual(probe.log_date(stamp, end=True), '2026-11-09 13:01:03+00:00')

    def test_changed_selector_never_invokes_native_capability_command(self):
        with patch.object(probe, 'command') as command:
            with self.assertRaisesRegex(ValueError, 'not_the_original_scroll_command'):
                probe.preflight('test-simulator', Path('test.xctestrun'), ['xcodebuild', 'test'])
        command.assert_not_called()

    def test_exact_runtime_and_emit_capability_gate(self):
        inventory = {'devices': {probe.RUNTIME: [{'udid': 'test-simulator', 'state': 'Booted',
                     'isAvailable': True, 'deviceTypeIdentifier': 'com.apple.CoreSimulator.SimDeviceType.iPhone-17'}]},
                     'runtimes': [{'identifier': probe.RUNTIME, 'isAvailable': True,
                                   'version': '27.0', 'buildversion': '24A434'}]}
        with tempfile.TemporaryDirectory(dir=Path(__file__).resolve().parents[1]) as directory:
            test_run = Path(directory) / 'test.xctestrun'
            test_run.write_bytes(plistlib.dumps({}))
            argv = ['xcodebuild', '-xctestrun', str(test_run), '-destination', 'platform=iOS Simulator,id=test-simulator',
                    '-parallel-testing-enabled', 'NO', '-test-timeouts-enabled', 'YES',
                    '-default-test-execution-time-allowance', '900', '-maximum-test-execution-time-allowance', '1200',
                    '-resultBundlePath', '.build/performance/Performance.xcresult', '-collect-test-diagnostics', 'on-failure',
                    '-only-testing:' + probe.SELECTOR, 'test-without-building']
            responses = [b'Xcode 27.1\nBuild version 27A9275', json.dumps({'devices': inventory['devices']}).encode(),
                         json.dumps({'runtimes': inventory['runtimes']}).encode(),
                         b'--[no]-signpost ndjson --timeout --predicate --level',
                         b'--[no-]signpost ndjson --start --end --predicate --[no-]info --[no-]debug',
                         b'signpost-event --type --subsystem --category']
            for mode in ('valid', 'xcode_drift', 'runtime_drift', 'missing_emit', 'enforced', 'unspecified_enforcement'):
                data = list(responses)
                if mode == 'xcode_drift':
                    data[0] = b'Xcode 27.1\nBuild version other'
                elif mode == 'runtime_drift':
                    data[2] = data[2].replace(b'24A434', b'24A999')
                elif mode == 'missing_emit':
                    data[-1] = b'--subsystem --category'
                enforcement = 'true' if mode == 'enforced' else '' if mode == 'unspecified_enforcement' else 'false'
                with self.subTest(mode=mode), patch.dict(os.environ, {'PERFORMANCE_CASE': 'scroll', 'ENFORCE_BASELINES': enforcement}), \
                     patch.object(probe, 'SOURCE_PINS', {}), patch.object(probe.platform, 'machine', return_value='arm64'), \
                     patch.object(probe, 'command', side_effect=data) as command:
                    if mode == 'valid':
                        self.assertEqual(probe.preflight('test-simulator', test_run, argv)['exactRuntime']['iOSBuild'], '24A434')
                    else:
                        with self.assertRaises(ValueError):
                            probe.preflight('test-simulator', test_run, argv)
                        if mode in ('enforced', 'unspecified_enforcement'):
                            command.assert_not_called()

    def test_missing_precontrol_never_launches_native(self):
        pump = Mock()
        pump.start.return_value = pump
        pump.metadata.controls = set()
        pump.metadata.errors = set()
        pump.errors = set()
        pump.receipt.return_value = {'controls': []}
        with tempfile.TemporaryDirectory(dir=Path(__file__).resolve().parents[1]) as directory:
            output = Path(directory) / 'receipt.json'
            argv = ['probe', '--simulator', 'test-simulator', '--xctestrun', 'test.xctestrun',
                    '--output', str(output), '--', 'xcodebuild']
            with patch.object(sys, 'argv', argv), patch.object(probe, 'preflight', return_value={}), \
                 patch.object(probe, 'Pump', return_value=pump), patch.object(probe, 'handshake', return_value=False), \
                 patch.object(probe.subprocess, 'Popen') as native:
                self.assertEqual(probe.main(), 78)
            native.assert_not_called()
            receipt = json.loads(output.read_text())
            self.assertFalse(receipt['nativeAttempted'])
            self.assertEqual(receipt['reason'], 'pre_control_unqualified_no_native_run')

    def test_capture_failure_after_test_preserves_native_exit_status(self):
        for native_code in (0, 65, -15):
            with self.subTest(native_code=native_code):
                pump = Mock()
                pump.start.return_value = pump
                pump.metadata.controls = {'pre'}
                pump.metadata.errors = set()
                pump.errors = {'deadline'}
                pump.receipt.return_value = {'controls': ['pre'], 'errors': ['deadline']}
                process = Mock()
                process.wait.return_value = native_code
                process.poll.return_value = native_code
                with tempfile.TemporaryDirectory(dir=Path(__file__).resolve().parents[1]) as directory:
                    output = Path(directory) / 'receipt.json'
                    argv = ['probe', '--simulator', 'test-simulator', '--xctestrun', 'test.xctestrun',
                            '--output', str(output), '--', 'xcodebuild', 'unchanged']
                    def observe_spawn(*_args, **_kwargs):
                        boundary = json.loads(output.read_text())
                        self.assertTrue(boundary['nativeAttempted'])
                        self.assertIn('nativeStartUTC', boundary)
                        self.assertNotIn('nativeExitCode', boundary)
                        return process
                    control_calls = []
                    def observe_control(*_args, **_kwargs):
                        control_calls.append(True)
                        if len(control_calls) == 1:
                            return True
                        boundary = json.loads(output.read_text())
                        self.assertEqual(boundary['nativeExitCode'], native_code)
                        self.assertIn('nativeEndUTC', boundary)
                        raise ValueError('emit_failed')
                    with patch.object(sys, 'argv', argv), patch.object(probe, 'preflight', return_value={}), \
                         patch.object(probe, 'Pump', return_value=pump), \
                         patch.object(probe, 'handshake', side_effect=observe_control), \
                         patch.object(probe.subprocess, 'Popen', side_effect=observe_spawn) as native:
                        self.assertEqual(probe.main(), native_code if native_code >= 0 else 128 - native_code)
                    native.assert_called_once_with(['xcodebuild', 'unchanged'], start_new_session=True)
                    receipt = json.loads(output.read_text())
                    self.assertEqual(receipt['nativeExitCode'], native_code)
                    self.assertFalse(receipt['liveTransportQualified'])


class WorkflowTests(unittest.TestCase):
    def test_capability_step_reserves_inventory_help_and_existing_join_cleanup_bounds(self):
        text = (Path(__file__).resolve().parents[1] / '.github/workflows/ios-performance.yml').read_text()
        block = text[text.index('      - name: Check capture capabilities before compilation'):
                     text.index('      - name: Retain capture capability stages')]
        outer_seconds = int(re.search(r'timeout-minutes: (\d+)', block)[1]) * 60
        self.assertIn('--toolchain-identity', block)  # No sixth/direct version command on this route.
        command_count = 2 + len(probe.HELP_TOKENS)
        # Existing command_result join permits budget+4, then close joins for4.
        # Reserve both tolerances; this is an outer infrastructure envelope,
        # not a measurement or a guarantee against arbitrary host starvation.
        required_seconds = 2 * probe.INVENTORY_COMMAND_SECONDS + len(probe.HELP_TOKENS) * probe.COMMAND_SECONDS + command_count * 8
        self.assertGreaterEqual(outer_seconds, required_seconds)

    def test_each_capture_consumer_writes_and_uses_its_own_identity(self):
        text = (Path(__file__).resolve().parents[1] / '.github/workflows/ios-performance.yml').read_text()
        build = text[text.index('  performance-build:'):text.index('  performance-tests:')]
        tests = text[text.index('  performance-tests:'):]
        for block, path in ((build, '.build/capture-preflight/runner-identity.json'),
                            (tests, '.build/performance/runner-identity.json')):
            self.assertIn('identity=(--identity-output ' + path + ')', block)
            self.assertIn('--toolchain-identity ' + path, block)
            self.assertLess(block.index('--identity-output'), block.index('--toolchain-identity'))
            self.assertIn('identity=()', block)
        self.assertNotIn('--toolchain-identity .build/capture-preflight/', tests)
        self.assertIn('-C .build/DerivedData/Build Products', build)

    def test_capabilities_only_has_no_build_products_or_xctest_path(self):
        text = (Path(__file__).resolve().parents[1] / '.github/workflows/ios-performance.yml').read_text()
        build = text[text.index('  performance-build:'):text.index('  performance-tests:')]
        self.assertIn("inputs.capture_preflight_only && 'Check scroll capture capabilities (no build)'", build)
        for name in ('Build the Release app and dedicated performance tests',
                     'Check the compiled XCTest inventory and plan performance jobs',
                     'Verify and package Release test products'):
            self.assertIn('      - name: ' + name + '\n        if: ${{ !inputs.capture_preflight_only }}', build)
        self.assertIn('id: upload\n        if: ${{ !inputs.capture_preflight_only }}', build)
        consumer = text[text.index('  performance-tests:'):text.index('  simulator-signpost-control:')]
        self.assertIn('  performance-tests:\n    if: ${{ !inputs.capture_preflight_only && !inputs.simulator_signpost_control }}',
                      consumer)
        gate = build[build.index('      - name: Boot diagnostic simulator'):build.index('      - name: Build the Release')]
        self.assertIn('--capabilities-only', gate)
        self.assertIn('if: inputs.capture_scroll_signposts', gate)
        self.assertIn('if: always() && inputs.capture_scroll_signposts', gate)
        for forbidden in ('pbcopy', 'prepare_ios_performance_simulator', 'build-for-testing', 'test-without-building', '--xctestrun'):
            self.assertNotIn(forbidden, gate)
        self.assertIn("${{ inputs.capture_preflight_only && '-capabilities-only' || '' }}", text)

    def test_capabilities_only_requires_capture_input_before_macos(self):
        text = (Path(__file__).resolve().parents[1] / '.github/workflows/ios-performance.yml').read_text()
        start = text.index('          if [[ "${{ inputs.capture_preflight_only }}" == true ]]; then')
        guard = text[start:text.index('          fi', start) + len('          fi')]
        for only, capture, expected in (('true', 'false', 1), ('true', 'true', 0), ('false', 'false', 0)):
            code = guard.replace('${{ inputs.capture_preflight_only }}', only).replace('${{ inputs.capture_scroll_signposts }}', capture)
            self.assertEqual(subprocess.run(['bash', '-e', '-c', code]).returncode, expected)

    def test_manual_scroll_calibration_only_guard_before_macos(self):
        text = (Path(__file__).resolve().parents[1] / '.github/workflows/ios-performance.yml').read_text()
        start = text.index('          if [[ "${{ inputs.capture_scroll_signposts }}" == true ]]; then')
        guard = text[start:text.index('          fi', start) + len('          fi')]
        for capture, event_name, case, enforcement, expected in (
                ('true', 'workflow_dispatch', 'scroll', 'false', 0),
                ('true', 'workflow_dispatch', 'scroll', 'true', 1),
                ('true', 'workflow_dispatch', 'all', 'false', 1),
                ('true', 'pull_request', 'scroll', 'false', 1),
                ('false', 'pull_request', 'all', 'true', 0)):
            script = guard.replace('${{ inputs.capture_scroll_signposts }}', capture)
            script = script.replace('${{ github.event_name }}', event_name).replace('${{ inputs.case }}', case)
            result = subprocess.run(['bash', '-e', '-c', script], env=dict(os.environ, ENFORCE_BASELINES=enforcement))
            self.assertEqual(result.returncode, expected)

    def test_diagnostic_has_distinct_name_and_cancellation_domain(self):
        text = (Path(__file__).resolve().parents[1] / '.github/workflows/ios-performance.yml').read_text()
        suffix = "${{ inputs.capture_scroll_signposts && '-scroll-capture' || '' }}"
        concurrency = re.search(r'^concurrency:\n  group: ([^\n]+)$', text, re.M)
        self.assertIsNotNone(concurrency)
        group = concurrency.group(1)
        self.assertTrue(group.startswith('ios-performance-${{ github.workflow }}-${{ github.ref }}'))
        self.assertEqual(group.count(suffix), 1)
        self.assertIn("${{ inputs.simulator_signpost_control && '-simulator-helper' || '' }}", group)
        self.assertIn("${{ inputs.capture_scroll_signposts && ' · signpost capture (diagnostic only)' || '' }}", text)
        plan = text[text.index('  performance-plan:'):text.index('  performance-build:')]
        self.assertIn('python3 scripts/test_capture_scroll_signposts.py', plan)


class JournalTests(unittest.TestCase):
    def test_failed_capabilities_only_keeps_last_stage_and_skips_native(self):
        with tempfile.TemporaryDirectory(dir=Path(__file__).resolve().parents[1]) as directory:
            path = Path(directory) / 'receipt.json'
            argv = ['probe', '--capabilities-only', '--simulator', 'test-simulator', '--output', str(path)]
            def failure(_simulator, journal, identity_path=None):
                self.assertIsNone(identity_path)
                journal.run('toolchain', lambda _: None)
                def fail(entry):
                    entry.update(commandObserved=True, exitCode=17, errors=['stderr_present'])
                    raise ValueError('capability_command_failed')
                journal.run('devices', fail)
            with patch.object(sys, 'argv', argv), patch.object(probe, 'source_contract', return_value={}), \
                 patch.object(probe, 'runtime_preflight', side_effect=failure), patch.object(probe, 'Pump') as pump, \
                 patch.object(probe.subprocess, 'Popen') as native:
                self.assertEqual(probe.main(), 78)
            pump.assert_not_called()
            native.assert_not_called()
            receipt = json.loads(path.read_text())
            self.assertEqual([row['stage'] for row in receipt['stages']], ['source-contract', 'toolchain', 'devices'])
            self.assertEqual(receipt['stages'][-1]['exitCode'], 17)
            self.assertEqual(receipt['stages'][-1]['status'], 'failed')
            self.assertFalse(receipt['nativeAttempted'])

    def test_failed_command_is_persisted_without_stderr_text(self):
        with tempfile.TemporaryDirectory(dir=Path(__file__).resolve().parents[1]) as directory:
            path = Path(directory) / 'receipt.json'
            journal = probe.Journal({'nativeAttempted': False}, path)
            argv = [sys.executable, '-c', 'import sys; sys.stderr.write("permission denied SECRET_TOKEN /private/path"); sys.exit(17)']
            with self.assertRaisesRegex(ValueError, 'capability_command_failed'):
                probe.command(argv, journal=journal, stage_name='help-emit')
            row = json.loads(path.read_text())['stages'][0]
            self.assertEqual(row['stage'], 'help-emit')
            self.assertEqual(row['status'], 'failed')
            self.assertEqual(row['exitCode'], 17)
            self.assertIn('permission_denied', row['stderrMarkers'])
            self.assertGreater(row['stderrBytes'], 0)
            self.assertIn('elapsedSeconds', row)
            self.assertIn('startedUTC', row)
            for private in ('SECRET_TOKEN', '/private/path', 'permission denied'):
                self.assertNotIn(private, path.read_text())

    def test_running_and_interrupted_stage_are_both_saved(self):
        with tempfile.TemporaryDirectory(dir=Path(__file__).resolve().parents[1]) as directory:
            path = Path(directory) / 'receipt.json'
            journal = probe.Journal({}, path)
            def interrupted(_):
                self.assertEqual(json.loads(path.read_text())['stages'][0]['status'], 'running')
                raise KeyboardInterrupt()
            with self.assertRaises(KeyboardInterrupt):
                journal.run('toolchain', interrupted)
            self.assertEqual(json.loads(path.read_text())['stages'][0]['status'], 'interrupted')

    def test_timeout_has_owned_child_exit_and_reason(self):
        with tempfile.TemporaryDirectory(dir=Path(__file__).resolve().parents[1]) as directory:
            path = Path(directory) / 'receipt.json'
            journal = probe.Journal({}, path)
            with self.assertRaises(ValueError):
                probe.command([sys.executable, '-c', 'import time; time.sleep(10)'], seconds=0.1,
                              journal=journal, stage_name='devices')
            row = json.loads(path.read_text())['stages'][0]
            self.assertIn('deadline', row['errors'])
            self.assertIsNotNone(row['exitCode'])

    def test_capabilities_only_never_starts_transport_or_native_or_reads_products(self):
        with tempfile.TemporaryDirectory(dir=Path(__file__).resolve().parents[1]) as directory:
            path = Path(directory) / 'receipt.json'
            argv = ['probe', '--capabilities-only', '--simulator', 'test-simulator', '--output', str(path)]
            with patch.object(sys, 'argv', argv), patch.object(probe, 'source_contract', return_value={}), \
                 patch.object(probe, 'runtime_preflight', return_value={}) as runtime, \
                 patch.object(probe, 'preflight') as products, patch.object(probe, 'Pump') as pump, \
                 patch.object(probe.subprocess, 'Popen') as native:
                self.assertEqual(probe.main(), 0)
            runtime.assert_called_once()
            products.assert_not_called()
            pump.assert_not_called()
            native.assert_not_called()
            receipt = json.loads(path.read_text())
            self.assertFalse(receipt['nativeAttempted'])
            self.assertFalse(receipt['liveTransportQualified'])
            self.assertEqual(receipt['status'], 'capabilities_checked_not_transport')

    def test_capabilities_only_rejects_native_arguments(self):
        argv = ['probe', '--capabilities-only', '--simulator', 'test-simulator', '--output', 'unused', '--', 'xcodebuild']
        with patch.object(sys, 'argv', argv), patch('sys.stderr', new=io.StringIO()), \
             patch.object(probe, 'runtime_preflight') as runtime:
            with self.assertRaises(SystemExit) as error:
                probe.main()
        self.assertEqual(error.exception.code, 2)
        runtime.assert_not_called()

    def test_journal_rejects_unbounded_or_unknown_stage_labels(self):
        with tempfile.TemporaryDirectory(dir=Path(__file__).resolve().parents[1]) as directory:
            journal = probe.Journal({}, Path(directory) / 'receipt.json')
            with self.assertRaises(ValueError):
                journal.run('private arbitrary content', lambda _: None)
            for _ in range(32):
                journal.run('devices', lambda _: None)
            with self.assertRaises(ValueError):
                journal.run('devices', lambda _: None)


class IdentityReuseTests(unittest.TestCase):
    def environment(self):
        return {'GITHUB_SHA': 'a' * 40, 'GITHUB_RUN_ID': '123', 'GITHUB_RUN_ATTEMPT': '1',
                'GITHUB_JOB': 'performance-tests', 'RUNNER_NAME': 'fixture-runner',
                'SIMULATOR_ID': 'test-simulator', 'ENFORCE_BASELINES': 'false',
                'DEVELOPER_DIR': '/Applications/Xcode_27.1.app/Contents/Developer'}

    def test_valid_identity_skips_only_version_query_and_keeps_live_runtime_and_help(self):
        env = self.environment()
        devices = {'devices': {probe.RUNTIME: [{'udid': 'test-simulator', 'state': 'Booted',
                   'isAvailable': True, 'deviceTypeIdentifier': 'com.apple.CoreSimulator.SimDeviceType.iPhone-17'}]}}
        runtimes = {'runtimes': [{'identifier': probe.RUNTIME, 'isAvailable': True,
                                 'version': '27.0', 'buildversion': '24A434'}]}
        responses = [json.dumps(devices).encode(), json.dumps(runtimes).encode(),
                     b'--signpost ndjson --timeout --predicate --level',
                     b'--signpost ndjson --start --end --predicate --info --debug',
                     b'signpost-event --type --subsystem --category']
        with tempfile.TemporaryDirectory(dir=Path(__file__).resolve().parents[1]) as folder:
            path = Path(folder) / 'identity.json'
            path.write_text(json.dumps(probe.toolchain_identity(env, 'Xcode 27.1\nBuild version 27A9275', 'arm64')))
            with patch.dict(os.environ, env, clear=True), patch.object(probe.platform, 'machine', return_value='arm64'), \
                 patch.object(probe, 'command', side_effect=responses) as commands:
                result = probe.runtime_preflight('test-simulator', identity_path=path)
            self.assertEqual(result['toolchainIdentitySource'], 'same-job-receipt')
            self.assertEqual(result['toolchainIdentitySHA256'], probe.digest(path.read_bytes()))
            observed = [call.args[0] for call in commands.call_args_list]
            self.assertEqual(observed[:2], [['xcrun', 'simctl', 'list', 'devices', 'test-simulator', '-j'],
                                             ['xcrun', 'simctl', 'list', 'runtimes', probe.RUNTIME, '-j']])
            self.assertEqual([argv[-2:] for argv in observed[2:]], [['help', 'stream'], ['help', 'show'], ['help', 'emit']])
            self.assertEqual([(call.kwargs['stage_name'], call.kwargs.get('seconds', probe.COMMAND_SECONDS))
                              for call in commands.call_args_list],
                             [('devices', 30), ('runtimes', 30), ('help-stream', 10), ('help-show', 10), ('help-emit', 10)])
            self.assertFalse(any('xcodebuild' in argv for argv in observed))
            # A valid toolchain receipt is never a substitute for live runtime identity.
            drifted = list(responses); drifted[1] = drifted[1].replace(b'24A434', b'24A999')
            with patch.dict(os.environ, env, clear=True), patch.object(probe.platform, 'machine', return_value='arm64'), \
                 patch.object(probe, 'command', side_effect=drifted), self.assertRaisesRegex(ValueError, 'runtime_drift'):
                probe.runtime_preflight('test-simulator', identity_path=path)

    def test_device_search_cannot_replace_exact_identity_availability_or_state(self):
        device = {'udid': 'selected-uuid', 'state': 'Booted', 'isAvailable': True,
                  'deviceTypeIdentifier': 'com.apple.CoreSimulator.SimDeviceType.iPhone-17'}
        runtime = {'identifier': probe.RUNTIME, 'isAvailable': True, 'version': '27.0', 'buildversion': '24A434'}
        cases = {
            'missing': {probe.RUNTIME: []},
            'description-only-match': {probe.RUNTIME: [dict(device, udid='other-uuid', name='selected-uuid')]},
            'duplicate': {probe.RUNTIME: [device, device]},
            'unavailable': {probe.RUNTIME: [dict(device, isAvailable=False)]},
            'shutdown': {probe.RUNTIME: [dict(device, state='Shutdown')]},
            'wrong-device-type': {probe.RUNTIME: [dict(device, deviceTypeIdentifier='other')]},
            'wrong-runtime': {'other-runtime': [device]},
        }
        for name, devices in cases.items():
            responses = [b'Xcode 27.1\nBuild version 27A9275',
                         json.dumps({'devices': devices}).encode(),
                         json.dumps({'runtimes': [runtime]}).encode()]
            with self.subTest(name=name), patch.object(probe.platform, 'machine', return_value='arm64'), \
                 patch.object(probe, 'command', side_effect=responses) as commands:
                with self.assertRaisesRegex(ValueError, 'runtime_drift'):
                    probe.runtime_preflight('selected-uuid')
            self.assertEqual(commands.call_count, 3)
            self.assertEqual(commands.call_args_list[1].args[0],
                             ['xcrun', 'simctl', 'list', 'devices', 'selected-uuid', '-j'])
            self.assertEqual(commands.call_args_list[2].args[0], ['xcrun', 'simctl', 'list', 'runtimes', probe.RUNTIME, '-j'])

    def test_device_search_ignores_other_rows_without_relaxing_runtime_checks(self):
        selected = {'udid': 'selected-uuid', 'state': 'Booted', 'isAvailable': True,
                    'deviceTypeIdentifier': 'com.apple.CoreSimulator.SimDeviceType.iPhone-17'}
        devices = {'devices': {probe.RUNTIME: [dict(selected, udid='other-uuid'), selected]}}
        runtime = {'identifier': probe.RUNTIME, 'isAvailable': True, 'version': '27.0', 'buildversion': '24A434'}
        for valid in (True, False):
            responses = [b'Xcode 27.1\nBuild version 27A9275', json.dumps(devices).encode(),
                         json.dumps({'runtimes': [dict(runtime, isAvailable=valid)]}).encode(),
                         b'--signpost ndjson --timeout --predicate --level',
                         b'--signpost ndjson --start --end --predicate --info --debug',
                         b'signpost-event --type --subsystem --category']
            with self.subTest(runtimeAvailable=valid), patch.object(probe.platform, 'machine', return_value='arm64'), \
                 patch.object(probe, 'command', side_effect=responses):
                if valid:
                    self.assertEqual(probe.runtime_preflight('selected-uuid')['exactRuntime']['iOSBuild'], '24A434')
                else:
                    with self.assertRaisesRegex(ValueError, 'runtime_drift'):
                        probe.runtime_preflight('selected-uuid')

    def test_runtime_search_cannot_replace_exact_identity_or_build_checks(self):
        device = {'udid': 'selected-uuid', 'state': 'Booted', 'isAvailable': True,
                  'deviceTypeIdentifier': 'com.apple.CoreSimulator.SimDeviceType.iPhone-17'}
        runtime = {'identifier': probe.RUNTIME, 'isAvailable': True, 'version': '27.0', 'buildversion': '24A434'}
        cases = {
            'missing': [],
            'description-only-match': [dict(runtime, identifier='other-runtime', name=probe.RUNTIME)],
            'duplicate': [runtime, runtime],
            'unavailable': [dict(runtime, isAvailable=False)],
            'wrong-version': [dict(runtime, version='27.1')],
            'wrong-build': [dict(runtime, buildversion='24A999')],
        }
        for name, runtimes in cases.items():
            responses = [b'Xcode 27.1\nBuild version 27A9275',
                         json.dumps({'devices': {probe.RUNTIME: [device]}}).encode(),
                         json.dumps({'runtimes': runtimes}).encode()]
            with self.subTest(name=name), patch.object(probe.platform, 'machine', return_value='arm64'), \
                 patch.object(probe, 'command', side_effect=responses) as commands:
                with self.assertRaisesRegex(ValueError, 'runtime_drift'):
                    probe.runtime_preflight('selected-uuid')
            self.assertEqual(len(commands.call_args_list), 3)
            self.assertEqual(commands.call_args_list[2].args[0],
                             ['xcrun', 'simctl', 'list', 'runtimes', probe.RUNTIME, '-j'])

    def test_every_bound_context_field_and_version_architecture_rejects_drift(self):
        env = self.environment()
        original = probe.toolchain_identity(env, 'Xcode 27.1\nBuild version 27A9275', 'arm64')
        self.assertEqual(set(original['context']), set(env))
        variants = []
        for key in env:
            wrong = copy.deepcopy(original); wrong['context'][key] += '-different'; variants.append(wrong)
        for key, value in (('toolchain', 'Xcode 27.1\nBuild version different'), ('architecture', 'x86_64'),
                           ('passed', False), ('releaseAcceptance', True), ('schemaVersion', True), ('extra', 'unexpected')):
            wrong = copy.deepcopy(original); wrong[key] = value; variants.append(wrong)
        with tempfile.TemporaryDirectory(dir=Path(__file__).resolve().parents[1]) as folder:
            path = Path(folder) / 'identity.json'
            for wrong in variants:
                path.write_text(json.dumps(wrong))
                with self.subTest(wrong=wrong), patch.dict(os.environ, env, clear=True), \
                     patch.object(probe.platform, 'machine', return_value='arm64'), patch.object(probe, 'command') as commands, \
                     self.assertRaises(ValueError):
                    probe.runtime_preflight('test-simulator', identity_path=path)
                commands.assert_not_called()

    def test_bad_supplied_receipt_never_falls_back(self):
        env = self.environment()
        with tempfile.TemporaryDirectory(dir=Path(__file__).resolve().parents[1]) as folder:
            path = Path(folder) / 'identity.json'
            for raw in (None, '{invalid', 'x' * 8193, '[]'):
                if raw is not None:
                    path.write_text(raw)
                with self.subTest(raw=None if raw is None else len(raw)), patch.dict(os.environ, env, clear=True), \
                     patch.object(probe.platform, 'machine', return_value='arm64'), patch.object(probe, 'command') as commands, \
                     self.assertRaises(ValueError):
                    probe.runtime_preflight('test-simulator', identity_path=path)
                commands.assert_not_called()

    def test_source_pin_matches_reviewed_environment_helper(self):
        root = Path(__file__).resolve().parents[1]
        self.assertEqual(probe.SOURCE_PINS['scripts/check_ios_performance_environment.py'],
                         probe.digest((root / 'scripts/check_ios_performance_environment.py').read_bytes()))


class HelpExitTests(unittest.TestCase):
    def argv(self, mode='stream'):
        return ['xcrun', 'simctl', 'spawn', 'test-simulator', 'log', 'help', mode]

    def usage(self, mode='stream'):
        return ('\nusage: log ' + mode + ' [options]\n' + ' '.join(probe.HELP_TOKENS[mode])).encode()

    def invoke(self, argv, output, code=64, errors=(), help_enabled=True):
        pump = Mock()
        pump.start.return_value = pump
        pump.stdout = bytearray()
        pump.help_stderr = bytearray(output)
        pump.stderr_bytes = len(output)
        pump.raw_bytes = len(output)
        pump.stderr_markers = set()
        pump.errors = set(errors)
        pump.exit_code = code
        pump.terminated_on_request = False
        pump.observation.return_value = {}
        self.entry, self.help = {}, {} if help_enabled else None
        with patch.object(probe, 'Pump', return_value=pump):
            return probe.command_result(argv, 10, self.help, self.entry)

    def test_known_help_usage_exit64_requires_all_capabilities(self):
        for mode in probe.HELP_TOKENS:
            with self.subTest(mode=mode):
                raw = self.usage(mode)
                self.assertIn(raw, self.invoke(self.argv(mode), raw))
                self.assertTrue(self.help['recognizedUsage'])
                self.assertTrue(self.help['requiredTokensPresent'])
                self.assertTrue(self.help['acceptedUsageExit64'])
                self.assertEqual(self.entry['exitCode'], 64)
                self.assertEqual(self.entry['help']['stderrSHA256'], probe.digest(raw))

    def test_wrong_usage_prefix_and_mode_are_rejected(self):
        for prefix in ('usage: log show ', 'usage: log streamish ', 'error: usage: log stream '):
            raw = (prefix + '[options]\n' + ' '.join(probe.HELP_TOKENS['stream'])).encode()
            with self.subTest(prefix=prefix), self.assertRaises(ValueError):
                self.invoke(self.argv(), raw)
            self.assertFalse(self.help['recognizedUsage'])
            self.assertFalse(self.help['acceptedUsageExit64'])

    def test_exit64_missing_each_required_token_is_rejected(self):
        for mode, tokens in probe.HELP_TOKENS.items():
            for missing in tokens:
                raw = ('usage: log ' + mode + ' [options]\n' + ' '.join(token for token in tokens if token != missing)).encode()
                with self.subTest(mode=mode, missing=missing), self.assertRaises(ValueError):
                    self.invoke(self.argv(mode), raw)
                self.assertFalse(self.help['requiredTokensPresent'])

    def test_usage64_never_overrides_pump_errors_or_caps(self):
        for error in ('deadline', 'raw_cap', 'preflight_output_cap', 'process_io_error'):
            with self.subTest(error=error), self.assertRaises(ValueError):
                self.invoke(self.argv(), self.usage(), errors=[error])
            self.assertFalse(self.help['acceptedUsageExit64'])
            self.assertEqual(self.entry['errors'], [error])

    def test_exit64_not_allowed_for_nonhelp_or_different_invocation(self):
        for argv in (['xcodebuild', '-version'], ['/usr/bin/log', 'help', 'stream'],
                     ['xcrun', 'simctl', 'spawn', 'test-simulator', 'log', 'emit', 'event'],
                     self.argv() + ['--extra']):
            with self.subTest(argv=argv), self.assertRaises(ValueError):
                self.invoke(argv, self.usage())
            self.assertFalse(self.help['fixedHelpCommand'])
        with self.assertRaises(ValueError):
            self.invoke(self.argv(), self.usage(), help_enabled=False)

    def test_exit_zero_keeps_prior_command_semantics(self):
        raw = ('old zero-exit help header\n' + ' '.join(probe.HELP_TOKENS['stream'])).encode()
        self.assertIn(raw, self.invoke(self.argv(), raw, code=0))
        self.assertFalse(self.help['recognizedUsage'])
        self.assertFalse(self.help['acceptedUsageExit64'])
        self.assertTrue(self.help['requiredTokensPresent'])

    def test_failed_help_keeps_hashes_and_labels_but_no_raw_text(self):
        raw = b'PRIVATE_ERROR_CONTENT'
        with self.assertRaises(ValueError):
            self.invoke(self.argv(), raw, code=64)
        self.assertEqual(self.entry['help']['stderrSHA256'], probe.digest(raw))
        self.assertEqual(self.entry['help']['stderrBytes'], len(raw))
        self.assertEqual(self.entry['help']['exitCode'], 64)
        self.assertNotIn(raw.decode(), json.dumps(self.entry))


if __name__ == '__main__':
    unittest.main()
