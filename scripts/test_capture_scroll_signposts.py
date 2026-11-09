#!/usr/bin/env python3
"""Pure/synthetic collector tests: no Xcode, simctl, log or app invocation."""
import io
import json
import os
import plistlib
import subprocess
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch

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

    def test_plain_terminal_record_is_accepted(self):
        meta = self.make()
        meta.line(b'{"finished":1}')
        self.assertTrue(meta.finished)
        self.assertFalse(meta.errors)

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
                    with patch.object(sys, 'argv', argv), patch.object(probe, 'preflight', return_value={}), \
                         patch.object(probe, 'Pump', return_value=pump), \
                         patch.object(probe, 'handshake', side_effect=[True, ValueError('emit_failed')]), \
                         patch.object(probe.subprocess, 'Popen', return_value=process) as native:
                        self.assertEqual(probe.main(), native_code if native_code >= 0 else 128 - native_code)
                    native.assert_called_once_with(['xcodebuild', 'unchanged'], start_new_session=True)
                    receipt = json.loads(output.read_text())
                    self.assertEqual(receipt['nativeExitCode'], native_code)
                    self.assertFalse(receipt['liveTransportQualified'])


class WorkflowTests(unittest.TestCase):
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
        self.assertIn('group: ios-performance-${{ github.workflow }}-${{ github.ref }}' + suffix, text)
        self.assertIn("${{ inputs.capture_scroll_signposts && ' · signpost capture (diagnostic only)' || '' }}", text)
        plan = text[text.index('  performance-plan:'):text.index('  performance-build:')]
        self.assertIn('python3 scripts/test_capture_scroll_signposts.py', plan)


if __name__ == '__main__':
    unittest.main()
