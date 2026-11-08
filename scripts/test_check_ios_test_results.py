#!/usr/bin/env python3
import json
import copy
import hashlib
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

from check_ios_test_results import (
    INTERNAL_ACTIVITY, MULTIPLE_WARNINGS, OBSERVED_DEVICE, OBSERVED_MENU_WARNINGS, OBSERVED_WARNING,
    activity_warning_paths, animation_idle_report, append_runtime_warning_report,
    execution_log_failures, inspect_execution_log, markdown_cell,
    inspect_runtime_warnings, test_cases,
)

SCRIPT = Path(__file__).with_name('check_ios_test_results.py')


class ExecutionInventoryTests(unittest.TestCase):
    def check_case(self, identifiers, *, selected=None, skipped=0, result='Passed', expected_failures=0, case_result='Passed', log=None, output=False):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'selection.txt').write_text('\n'.join(selected or ['Target/Suite/testOne']) + '\n')
            (root / 'summary.json').write_text(json.dumps({
                'totalTestCount': len(identifiers), 'passedTests': len(identifiers) - skipped,
                'skippedTests': skipped, 'failedTests': 0, 'expectedFailures': expected_failures, 'result': result,
            }))
            (root / 'tests.json').write_text(json.dumps({'testNodes': [
                {'nodeType': 'Test Case', 'nodeIdentifierURL': 'test://com.apple.xcode/Project/' + identifier,
                 'result': case_result, 'durationInSeconds': 1} for identifier in identifiers
            ]}))
            env = dict(os.environ)
            env.pop('GITHUB_STEP_SUMMARY', None)
            args = [sys.executable, str(SCRIPT), '--selectors', str(root / 'selection.txt'),
                    '--expected-count', str(len(selected or ['Target/Suite/testOne'])),
                    '--summary', str(root / 'summary.json'), '--tests', str(root / 'tests.json')]
            if log is not None:
                path = root / 'XCTest.log'
                if log != 'missing':
                    path.write_text(log)
                args += ['--test-log', str(path)]
            result = subprocess.run(args, env=env, capture_output=True, text=True)
            return result if output else result.returncode

    def test_exact_execution_passes(self):
        self.assertEqual(self.check_case(['Target/Suite/testOne']), 0)

    def test_wrong_test_with_same_count_fails(self):
        self.assertNotEqual(self.check_case(['Target/Suite/testOther']), 0)

    def test_missing_or_duplicate_execution_fails(self):
        self.assertNotEqual(self.check_case([]), 0)
        self.assertNotEqual(self.check_case(['Target/Suite/testOne'] * 2), 0)

    def test_skip_or_failed_summary_fails(self):
        self.assertNotEqual(self.check_case(['Target/Suite/testOne'], skipped=1), 0)
        self.assertNotEqual(self.check_case(['Target/Suite/testOne'], result='Failed'), 0)

    def test_expected_failures_and_nonpassing_case_cannot_hide_in_passing_summary(self):
        self.assertNotEqual(self.check_case(['Target/Suite/testOne'], expected_failures=1), 0)
        for status in ('Failed', 'Skipped', 'Expected Failure', 'Unknown', None):
            with self.subTest(status=status):
                self.assertNotEqual(self.check_case(['Target/Suite/testOne'], case_result=status), 0)


    def test_passed_bundle_cannot_hide_missing_log_or_repeat_start(self):
        start = "Test Case '-[Target.Suite testOne]' started.\n"
        done = "Test Case '-[Target.Suite testOne]' passed (0.013 seconds).\n"
        banner = "** TEST EXECUTE SUCCEEDED **\n"
        self.assertEqual(self.check_case(['Target/Suite/testOne'], log=start + done + banner), 0)
        self.assertEqual(self.check_case(['Target/Suite/testOne'], log=start + done + start + done + banner), 1)
        self.assertEqual(self.check_case(['Target/Suite/testOne'], log='missing'), 1)

    def test_idle_diagnostics_do_not_change_acceptance_or_claim_missing_log_coverage(self):
        log = ("Test Case '-[Target.Suite testOne]' started.\n"
               "    t =    91.69s App animations complete notification not received, will attempt to continue.\n"
               "Test Case '-[Target.Suite testOne]' passed (92.000 seconds).\n"
               "** TEST EXECUTE SUCCEEDED **\n")
        result = self.check_case(['Target/Suite/testOne'], log=log, output=True)
        self.assertEqual(result.returncode, 0)
        self.assertIn('| Target/Suite/testOne (line 1) | 1 | 91.69 | 2 |', result.stdout)
        for value, code in [(None, 0), ('missing', 1)]:
            with self.subTest(log=value):
                result = self.check_case(['Target/Suite/testOne'], log=value, output=True)
                self.assertEqual(result.returncode, code)
                self.assertIn('coverage is unknown', result.stdout)
                self.assertNotIn('0 observed messages', result.stdout)


class ExecutionLogTests(unittest.TestCase):
    selector = "RoomInTheCartUITests/FreeJourneyUITests/testOne"
    case = "Test Case '-[RoomInTheCartUITests.FreeJourneyUITests testOne]' "
    start = case + "started."
    done = case + "passed (71.217 seconds)."
    success = "** TEST EXECUTE SUCCEEDED **"
    split_prefix = "2026-11-08 00:36:46.274412+0000 RoomInThe"
    split_suffix = 'Cart[26733:75724] [Default] Error in products service call: Error Domain=ASDErrorDomain Code=511 "(null)"'

    def test_hosted_f90_storekit_complete_record_inside_split_process_header(self):
        # Exact failing hosted artifact, StoreKit.log lines 4422–4426. The
        # console mux split RoomInTheCart's header around a complete pass record.
        log = [
            "Test Case '-[RoomInTheCartTests.StoreKitScenarioTests testUnavailableProductKeepsFreeRoute]' started.",
            "2026-11-08 00:36:46.274412+0000 RoomInTheTest Case '-[RoomInTheCartTests.StoreKitScenarioTests testUnavailableProductKeepsFreeRoute]' passed (0.101 seconds).",
            'Cart[26733:75724] [Default] Error in products service call: Error Domain=ASDErrorDomain Code=511 "(null)"',
            "Test Case '-[RoomInTheCartTests.StoreKitScenarioTests testUnverifiedLocalTransactionGrantsNothing]' started.",
            "Test Case '-[RoomInTheCartTests.StoreKitScenarioTests testUnverifiedLocalTransactionGrantsNothing]' passed (0.245 seconds).",
            self.success,
        ]
        expected = [
            "RoomInTheCartTests/StoreKitScenarioTests/testUnavailableProductKeepsFreeRoute",
            "RoomInTheCartTests/StoreKitScenarioTests/testUnverifiedLocalTransactionGrantsNothing",
        ]
        self.assertEqual(execution_log_failures(iter(line + "\r\n" for line in log), expected), [])

    def test_split_process_recovery_preserves_lifecycle_gates(self):
        def split(record):
            return [self.split_prefix + record, self.split_suffix]

        self.assertEqual(execution_log_failures(
            [*split(self.start), *split(self.done), self.success], [self.selector]), [])
        for log, reason in (
            ([self.start, *split(self.start), self.done, self.success], "one start then one pass"),
            ([self.start, self.done, *split(self.done), self.success], "one start then one pass"),
            ([*split(self.done), self.start, self.success], "one start then one pass"),
            ([self.start, self.success, *split(self.done)], "out-of-order"),
            ([self.start, *split(self.case + "failed (0.101 seconds)."), self.done, self.success], "non-passing"),
            ([self.start, *split(self.case + "exceeded execution time allowance of 1 minute."), self.done, self.success], "timeout"),
            ([self.start, *split(self.done), "Restarting after unexpected exit, crash, or test timeout; retry", self.success], "restarted"),
            ([self.start, self.split_prefix + self.done,
              "Cart[26733:75724] [logging] BUG IN CLIENT OF libsqlite3.dylib: API misuse", self.success], "SQLite"),
        ):
            with self.subTest(log=log):
                self.assertTrue(any(reason in error for error in execution_log_failures(log, [self.selector])))

    def test_embedded_or_unproven_records_cannot_supply_missing_completion(self):
        for fragment in (
            ["some output: " + self.done],
            [self.split_prefix + "Cart[26733:75724] [Default] " + self.done],
            [self.split_prefix + "Cart[26733:75724] [Default] quoted: \"" + self.done + '"'],
            ["arbitrary prefix " + self.done, self.split_suffix],
            [self.split_prefix + self.done],  # No following process fragment.
            [self.split_prefix + self.done, "unrelated line", self.split_suffix],
            [self.split_prefix + self.done, self.split_suffix.replace("Cart[", "Other[")],
            [self.split_prefix + self.done, self.split_suffix.replace("26733:75724", "not-a-pid")],
            [self.split_prefix.replace("2026-11-08", "not-a-date") + self.done, self.split_suffix],
            [self.split_prefix + self.done[:-1], self.split_suffix],
            [self.split_prefix + self.done + " trailing quoted text", self.split_suffix],
            [self.split_prefix + self.done.split(" passed")[0], self.split_suffix],
        ):
            with self.subTest(fragment=fragment):
                self.assertTrue(execution_log_failures(
                    [self.start, *fragment, self.success], [self.selector]))

    def test_quoted_record_in_regular_message_is_not_an_extra_completion(self):
        message = self.split_prefix + 'Cart[26733:75724] [Default] quoted: "' + self.done + '"'
        self.assertEqual(execution_log_failures(
            [self.start, self.done, message, self.success], [self.selector]), [])

    def test_passing_cases_cannot_hide_sqlite_api_misuse(self):
        warning = (
            "2026-11-05 05:17:24.258991+0000 RoomInTheCart[6045:24194] [logging] "
            "BUG IN CLIENT OF libsqlite3.dylib: database integrity compromised by API violation: "
            "vnode unlinked while in use: /fictional-test/ledger.sqlite"
        )
        failures = execution_log_failures([self.start, warning, self.done, self.success], [self.selector])
        self.assertEqual(failures, ["SQLite reported an API misuse diagnostic at log line 2."])
        # Routine SQLite output is not blanket-classified as an execution failure.
        self.assertEqual(execution_log_failures(
            [self.start, "SQLite fixture saved and closed", self.done, self.success], [self.selector]), [])

    def test_exact_pass_and_case_inventory(self):
        other = "RoomInTheCartTests/ModelTests/testOther"
        other_case = "Test Case '-[RoomInTheCartTests.ModelTests testOther]' "
        log = [other_case + "started.", other_case + "passed (0.002 seconds).",
               self.start, "    t =     5.00s Relaunch the app within the test", self.done, self.success]
        self.assertEqual(execution_log_failures(log, [self.selector, other]), [])
        self.assertIn("inventory mismatch", execution_log_failures(log, [self.selector])[0])
        self.assertIn("inventory mismatch", execution_log_failures(log[-4:], [self.selector, other])[0])

    def test_hidden_retry_timeout_failure_and_repeated_completion(self):
        for log, reason in (
            ([self.start, self.done, self.start, self.done, self.success], "one start then one pass"),
            ([self.start, self.done, self.done, self.success], "one start then one pass"),
            ([self.start, self.case + "exceeded execution time allowance of 1 minute.", self.done, self.success], "timeout"),
            ([self.start, self.case + "failed (61.030 seconds).", self.done, self.success], "non-passing"),
            ([self.start, self.case + "skipped (0.000 seconds).", self.success], "non-passing"),
            ([self.start, self.done, self.success, "Restarting after unexpected exit, crash, or test timeout; summary will include totals from previous launches."], "restarted"),
            ([self.start, "<unknown>:0: error: -[RoomInTheCartUITests.FreeJourneyUITests testOne] : App terminated", self.done, self.success], "logged a failure"),
        ):
            with self.subTest(log=log):
                self.assertTrue(any(reason in error for error in execution_log_failures(log, [self.selector])))

    def test_unrecognized_incomplete_or_unsuccessful_log(self):
        for log, reason in (
            ([self.start, self.done], "successful result banner"),
            ([self.start, self.done, "** TEST EXECUTE FAILED **"], "successful result banner"),
            ([self.start, self.done, self.success, self.success], "successful result banner"),
            ([self.done, self.start, self.success], "one start then one pass"),
            ([self.success, self.start, self.done], "out-of-order"),
            ([self.start, "Test Case malformed record", self.done, self.success], "Unrecognized"),
        ):
            with self.subTest(log=log):
                self.assertTrue(any(reason in error for error in execution_log_failures(log, [self.selector])))


class AnimationIdleTests(unittest.TestCase):
    marker = 'App animations complete notification not received, will attempt to continue.'
    case = "Test Case '-[RoomInTheCartUITests.RoomInTheCartUITests testSpanishEntryPreservesOriginalFoodNameAndSavedAnswer]' "
    selector = 'RoomInTheCartUITests/RoomInTheCartUITests/testSpanishEntryPreservesOriginalFoodNameAndSavedAnswer'

    def test_original_ui07_lines_and_crlf_preserve_first_timestamp_not_duration(self):
        # Original UI07 Tests.log 4144–4153: two completed ~60s idle waits.
        lines = [self.case + 'started.',
                 '    t =    31.66s     Wait for dev.roominthecart.app.debug to idle',
                 '    t =    91.69s ' + self.marker,
                 '    t =    94.91s     Wait for dev.roominthecart.app.debug to idle',
                 '    t =   154.93s ' + self.marker,
                 self.case + 'exceeded execution time allowance of 12.0 minutes.',
                 '** TEST EXECUTE FAILED **']
        failures, idle = inspect_execution_log(iter(x + '\r\n' for x in lines), [self.selector])
        self.assertTrue(failures)
        self.assertEqual(idle['groups'], [{'runnerSegment': 1, 'selector': self.selector,
            'caseStartLine': 1, 'count': 2, 'firstLine': 3, 'firstElapsedSeconds': '91.69'}])

    def test_restart_and_completion_clear_attribution_and_repeated_case_stays_separate(self):
        start = self.case + 'started.'
        lines = [self.marker, start, 't = 60.00s ' + self.marker,
                 'Restarting after unexpected exit, crash, or test timeout; retry',
                 't = 62.00s ' + self.marker, start, 't = 61.00s ' + self.marker,
                 self.case + 'passed (62.000 seconds).', self.marker]
        failures, idle = inspect_execution_log(lines, [self.selector])
        self.assertTrue(any('restarted' in x for x in failures))
        self.assertEqual(idle['restartLines'], [4])
        self.assertEqual([(g['runnerSegment'], g['caseStartLine'], g['count'], g['firstElapsedSeconds'])
                         for g in idle['groups']], [(1, None, 1, None), (1, 2, 1, '60.00'),
                                                   (2, None, 2, '62.00'), (2, 6, 1, '61.00')])

    def test_exact_records_only_and_existing_mux_recovery_clears_attribution(self):
        lines = [self.case + 'started.', 'quoted: "t = 60.00s ' + self.marker + '"',
                 '2026-11-08 00:36:46.274412+0000 RoomInThe' + self.case + 'passed (1.000 seconds).',
                 'Cart[26733:75724] [Default] fixture log', self.marker,
                 'Test Case malformed record', 't = 4.00s ' + self.marker]
        _, idle = inspect_execution_log(lines, [self.selector])
        self.assertEqual(len(idle['groups']), 1)
        self.assertIsNone(idle['groups'][0]['selector'])
        self.assertEqual(idle['groups'][0]['count'], 2)
        self.assertIsNone(idle['groups'][0]['firstElapsedSeconds'])
        self.assertIn('| unknown |', '\n'.join(animation_idle_report(idle)))

    def test_empty_log_does_not_claim_coverage_and_identifiers_cannot_break_markdown(self):
        _, empty = inspect_execution_log([], [])
        self.assertIn('does not establish complete log coverage', '\n'.join(animation_idle_report(empty)))
        _, idle = inspect_execution_log(["Test Case '-[Target.Suite|<x> test`One]' started.",
                                        't = 1.00s ' + self.marker], [])
        report = '\n'.join(animation_idle_report(idle))
        self.assertIn('Target/Suite&#124;&lt;x&gt;/test&#96;One', report)
        self.assertEqual(markdown_cell('one\r\ntwo'), 'one&#13;&#10;two')


class ActivityRetentionTests(unittest.TestCase):
    def run_report(self, root, raw_exports, inspector, *, cap=None):
        bundle = root / 'Tests.xcresult'
        bundle.mkdir(exist_ok=True)
        (bundle / 'Info.plist').touch()
        args = SimpleNamespace(result_bundle=bundle, tests=root / 'test-details.json')
        report, failures = [], []
        replies = [subprocess.CompletedProcess([], 0, stdout=raw, stderr=b'') for raw in raw_exports]
        with patch('check_ios_test_results.subprocess.run', side_effect=replies) as exporter, \
             patch('check_ios_test_results.inspect_runtime_warnings', side_effect=inspector), \
             patch('check_ios_test_results.MAX_ACTIVITY_DIAGNOSTIC_BYTES', cap or 8 * 1024 * 1024):
            append_runtime_warning_report(args, {}, [], [], report, failures)
        return report, failures, exporter

    def test_missing_attachment_retains_exact_per_case_stdout_without_logging_payload(self):
        raw = (b'{\r\n "activities": [{"title": "Fixture private text", "isAssociatedWithFailure": false},'
               b'{"title":"QoS warning", "isAssociatedWithFailure":false}]\r\n}\r\n')
        first = b'{"activities": []}\n'

        def inspect(summary, nodes, cases, details, activities):
            activities('test://Target/Suite/first')
            value = activities('test://Target/Suite/second')
            list(activity_warning_paths(value['activities'], {'QoS warning'}))

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            report, failures, exporter = self.run_report(root, [first, raw], inspect)
            diagnostic = json.loads((root / 'test-runtime-warning-activities.json').read_text())
            evidence = json.loads((root / 'test-runtime-warnings.json').read_text())
            self.assertEqual(evidence['status'], 'unavailable')
            self.assertNotIn('runtimeWarningCount', evidence)
            self.assertIn('found 0', failures[0])
            self.assertEqual(exporter.call_count, 2)
            self.assertEqual([x['testIdentifierURL'] for x in diagnostic['exports']],
                             ['test://Target/Suite/first', 'test://Target/Suite/second'])
            self.assertEqual([x['rawJSON'].encode('utf-8') for x in diagnostic['exports']], [first, raw])
            self.assertEqual([x['sha256'] for x in diagnostic['exports']],
                             [hashlib.sha256(value).hexdigest() for value in [first, raw]])
            self.assertEqual(diagnostic['retainedBytes'], len(first) + len(raw))
            self.assertNotIn('Fixture private text', '\n'.join(report + failures))

    def test_retention_limit_is_explicit_and_does_not_discard_later_small_export_or_change_gate(self):
        large, small = b'{"padding":"' + b'x' * 100 + b'"}', b'{}'

        def inspect(summary, nodes, cases, details, activities):
            activities('test://large'); activities('test://small')
            return {'status': 'unexpected-warnings', 'runtimeWarningCount': 1,
                    'examinedTestCount': 2, 'summaryWarningCount': 1,
                    'warnings': [{'selector': 'Target/Suite/testOne', 'count': 1, 'maximum': 0, 'message': 'QoS'}]}

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            _, failures, _ = self.run_report(root, [large, small], inspect, cap=64)
            diagnostic = json.loads((root / 'test-runtime-warning-activities.json').read_text())
            self.assertIn('Unexpected runtime warning count', failures[0])
            self.assertEqual(diagnostic['exports'][0]['bytes'], len(large))
            self.assertIn('unavailable', diagnostic['exports'][0])
            self.assertNotIn('rawJSON', diagnostic['exports'][0])
            self.assertEqual(diagnostic['exports'][1]['rawJSON'], '{}')
            self.assertEqual(diagnostic['retainedBytes'], len(small))

    def test_malformed_export_retained_before_parse_but_success_has_no_diagnostic_payload(self):
        def malformed(summary, nodes, cases, details, activities):
            return activities('test://Target/Suite/testOne')

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            _, failures, _ = self.run_report(root, [b'{ malformed JSON\n'], malformed)
            diagnostic = json.loads((root / 'test-runtime-warning-activities.json').read_text())
            self.assertTrue(failures)
            self.assertEqual(diagnostic['exports'][0]['rawJSON'], '{ malformed JSON\n')
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            clean = {'status': 'passed', 'runtimeWarningCount': 0, 'examinedTestCount': 1,
                     'summaryWarningCount': None, 'warnings': []}
            _, failures, exporter = self.run_report(root, [], lambda *args: clean)
            self.assertEqual(failures, [])
            self.assertFalse((root / 'test-runtime-warning-activities.json').exists())
            exporter.assert_not_called()

    def test_failure_then_success_removes_only_prior_generated_activity_diagnostic(self):
        clean = {'status': 'passed', 'runtimeWarningCount': 0, 'examinedTestCount': 1,
                 'summaryWarningCount': None, 'warnings': []}
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            unrelated = root / 'retained-original.json'
            unrelated.write_text('original evidence')
            _, failures, _ = self.run_report(root, [b'{ malformed JSON\n'],
                lambda summary, nodes, cases, details, activities: activities('test://Target/Suite/testOne'))
            diagnostic = root / 'test-runtime-warning-activities.json'
            self.assertTrue(failures)
            self.assertTrue(diagnostic.is_file())
            _, failures, _ = self.run_report(root, [], lambda *args: clean)
            self.assertEqual(failures, [])
            self.assertFalse(diagnostic.exists())
            self.assertEqual(unrelated.read_text(), 'original evidence')
            self.assertEqual(json.loads((root / 'test-runtime-warnings.json').read_text())['status'], 'passed')

    def test_stale_diagnostic_cleanup_failure_is_reported_without_changing_warning_acceptance(self):
        clean = {'status': 'passed', 'runtimeWarningCount': 0, 'examinedTestCount': 1,
                 'summaryWarningCount': None, 'warnings': []}
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.run_report(root, [b'{ malformed JSON\n'],
                lambda summary, nodes, cases, details, activities: activities('test://Target/Suite/testOne'))
            diagnostic = root / 'test-runtime-warning-activities.json'
            original = diagnostic.read_bytes()
            with patch.object(Path, 'unlink', side_effect=PermissionError('fixture denial')) as unlink:
                report, failures, _ = self.run_report(root, [], lambda *args: clean)
            unlink.assert_called_once_with()
            self.assertEqual(failures, [])
            self.assertEqual(diagnostic.read_bytes(), original)
            self.assertIn('stale/unavailable', '\n'.join(report))
            self.assertIn('Do not interpret it as current-run evidence', '\n'.join(report))
            self.assertEqual(json.loads((root / 'test-runtime-warnings.json').read_text())['status'], 'passed')


class RuntimeWarningTests(unittest.TestCase):
    def warning_summary(self, device, configuration="Test Scheme Action"):
        return {"devicesAndConfigurations": [{"device": device,
                "testPlanConfiguration": {"configurationId": "1", "configurationName": configuration}}]}

    def inspect(self, markers, messages, *, selector=None, device=None, summary_warnings=None,
                configuration="Test Scheme Action", extra_nodes=(), detail_changes=None,
                activity_messages=None, activity_tap=None, activity_phase=None, activity_changes=None, run_changes=None,
                activity_type=INTERNAL_ACTIVITY, activity_issue_ids=None, mutate_details=None,
                mutate_activity=None, case_result="Passed"):
        selector = selector or next(iter(OBSERVED_MENU_WARNINGS))
        url = "test://com.apple.xcode/RoomInTheCart/" + selector
        device = {"deviceId": "12345678-1234-4abc-8def-000000000001", **(device or OBSERVED_DEVICE)}
        summary = self.warning_summary(device, configuration)
        if summary_warnings is not None:
            summary["runtimeWarnings"] = summary_warnings
        case = {"nodeType": "Test Case", "nodeIdentifierURL": url, "result": case_result,
                "children": [{"nodeType": "Runtime Warning", "name": name} for name in markers]}
        nodes = [case, *extra_nodes]
        test_configuration = summary["devicesAndConfigurations"][0]["testPlanConfiguration"]
        details = {
            "testIdentifierURL": url, "devices": [device], "testPlanConfigurations": [test_configuration],
            "testResult": "Passed",
            "testRuns": [{"nodeType": "Device", "nodeIdentifier": device["deviceId"],
                          "result": "Passed", "children": [{
                "nodeType": "Test Plan Configuration", "nodeIdentifier": test_configuration["configurationId"],
                "nodeIdentifierURL": url, "result": "Passed",
                "children": [{"nodeType": "Runtime Warning", "name": name} for name in messages],
            }]}],
            **(detail_changes or {}),
        }
        if mutate_details is not None:
            mutate_details(details)

        def read_detail(requested):
            self.assertEqual(requested, url)
            return details

        _, tap, phase = OBSERVED_MENU_WARNINGS.get(selector, next(iter(OBSERVED_MENU_WARNINGS.values())))
        activity_messages = messages if activity_messages is None else activity_messages
        if activity_issue_ids is None:
            activity_issue_ids = [f"12345678-1234-4abc-8def-{index:012x}" for index in range(len(activity_messages))]
        self.assertEqual(len(activity_issue_ids), len(activity_messages))
        issues = [
            {"title": name, "isAssociatedWithFailure": False,
             "attachments": [{"name": "Complete Issue Description.txt", **({"uuid": issue_id} if issue_id is not None else {})}]}
            for name, issue_id in zip(activity_messages, activity_issue_ids)
        ]
        run = {"device": device, "testPlanConfiguration": test_configuration, "activities": [{
            "title": activity_tap or tap, "isAssociatedWithFailure": False, **({"activityType": activity_type} if activity_type else {}),
            "childActivities": [{
                "title": activity_phase or phase, "isAssociatedWithFailure": False, **({"activityType": activity_type} if activity_type else {}),
                "childActivities": issues,
            }],
        }], **(run_changes or {})}
        if mutate_activity is not None:
            mutate_activity(run)

        def read_activity(requested):
            self.assertEqual(requested, url)
            self.assertTrue(messages, "Clean cases should not need an activity export")
            return {"testIdentifierURL": url, "testRuns": [run], **(activity_changes or {})}

        return inspect_runtime_warnings(summary, nodes, list(test_cases(nodes)), read_detail, read_activity)

    def test_omitted_summary_still_requires_a_clean_detail_export(self):
        evidence = self.inspect([], [])
        self.assertIsNone(evidence["summaryWarningCount"])
        self.assertEqual(evidence["runtimeWarningCount"], 0)
        self.assertEqual(evidence["examinedTestCount"], 1)
        self.assertEqual(evidence["detailExportCount"], 1)
        self.assertEqual(evidence["activityExportCount"], 0)

    def test_nested_detail_identity_is_required_for_clean_and_warned_cases(self):
        mutations = (
            lambda d: d["testRuns"][0].update(nodeIdentifier="wrong-device"),
            lambda d: d["testRuns"][0]["children"][0].update(nodeIdentifier="wrong-configuration"),
            lambda d: d["testRuns"][0]["children"][0].update(nodeIdentifierURL="test://wrong"),
            lambda d: d["testRuns"].append(copy.deepcopy(d["testRuns"][0])),
            lambda d: d["testRuns"][0]["children"].append(copy.deepcopy(d["testRuns"][0]["children"][0])),
            lambda d: d["testRuns"][0]["children"][0]["children"].append(
                {"nodeType": "Device", "nodeIdentifier": "mixed-device"}),
            lambda d: d.update(testPlanConfigurations=[]),
            lambda d: d["testRuns"][0].update(nodeType="Test Case Run"),
            lambda d: d["testRuns"][0]["children"][0].update(nodeType="Test Case Run"),
            lambda d: d["testRuns"][0].pop("nodeIdentifier"),
            lambda d: d["testRuns"][0]["children"][0].pop("nodeIdentifier"),
        )
        for messages in ([], [OBSERVED_WARNING]):
            for mutation in mutations:
                with self.subTest(warnings=len(messages), mutation=mutation), self.assertRaises(ValueError):
                    self.inspect(messages, messages, mutate_details=mutation)

    def test_optional_nested_url_can_be_absent_but_not_wrong(self):
        for messages in ([], [OBSERVED_WARNING]):
            with self.subTest(warnings=len(messages)):
                evidence = self.inspect(messages, messages, mutate_details=lambda d:
                                        d["testRuns"][0]["children"][0].pop("nodeIdentifierURL"))
                self.assertEqual(evidence["runtimeWarningCount"], len(messages))

    def test_failed_detail_state_still_retains_warning_evidence(self):
        def fail(details):
            details["testResult"] = "Failed"
            details["testRuns"][0]["result"] = "Failed"
            details["testRuns"][0]["children"][0]["result"] = "Failed"
            details["testRuns"][0]["children"][0]["children"].append(
                {"nodeType": "Test Case Run", "result": "Failed", "name": "Original assertion failure"})
        evidence = self.inspect([OBSERVED_WARNING], [OBSERVED_WARNING], mutate_details=fail, case_result="Failed")
        self.assertEqual(evidence["runtimeWarningCount"], 1)
        self.assertEqual(evidence["status"], "passed")  # Warning policy only; the execution gate rejects failure.

    def test_result_contradictions_fail_for_clean_and_warned_cases(self):
        for messages in ([], [OBSERVED_WARNING]):
            for case_result in ("Passed", "Failed"):
                for field in ("outer", "device", "configuration", "all-details"):
                    def contradict(details):
                        details["testResult"] = case_result
                        device = details["testRuns"][0]
                        plan = device["children"][0]
                        device["result"] = plan["result"] = case_result
                        other = "Failed" if case_result == "Passed" else "Passed"
                        if field in ("outer", "all-details"):
                            details["testResult"] = other
                        if field in ("device", "all-details"):
                            device["result"] = other
                        if field in ("configuration", "all-details"):
                            plan["result"] = other
                    with self.subTest(warnings=len(messages), case=case_result, field=field):
                        with self.assertRaisesRegex(ValueError, "results disagree"):
                            self.inspect(messages, messages, case_result=case_result, mutate_details=contradict)

    def test_missing_or_invalid_result_cannot_certify_warning_evidence(self):
        mutations = (
            lambda d: d.pop("testResult"),
            lambda d: d["testRuns"][0].pop("result"),
            lambda d: d["testRuns"][0]["children"][0].pop("result"),
        )
        for mutation in mutations:
            with self.subTest(mutation=mutation), self.assertRaisesRegex(ValueError, "results disagree"):
                self.inspect([], [], mutate_details=mutation)
        for result in (None, "", " ", 1):
            with self.subTest(result=result), self.assertRaisesRegex(ValueError, "results disagree"):
                self.inspect([], [], case_result=result)

    def test_detail_only_warning_is_rejected_when_summary_and_tree_omit_it(self):
        with self.assertRaisesRegex(ValueError, "disagree with test tree"):
            self.inspect([], [OBSERVED_WARNING])

    def test_duplicate_occurrences_are_counted_and_capped_for_each_case(self):
        for selector, (maximum, tap, phase) in OBSERVED_MENU_WARNINGS.items():
            for count in (maximum, maximum + 1):
                with self.subTest(selector=selector, count=count):
                    marker = [MULTIPLE_WARNINGS] if count > 1 else [OBSERVED_WARNING]
                    evidence = self.inspect(marker, [OBSERVED_WARNING] * count, selector=selector)
                    self.assertEqual(evidence["runtimeWarningCount"], count)
                    self.assertEqual(evidence["activityExportCount"], 1)
                    self.assertEqual(evidence["warnings"][0]["maximum"], maximum)
                    self.assertEqual(evidence["warnings"][0]["menuActivity"], {"tap": tap, "phase": phase})
                    self.assertEqual(evidence["status"], "passed" if count == maximum else "unexpected-warnings")

    def test_manual_order_menu_allowance_stays_scoped_to_two_observed_issues(self):
        selector = "RoomInTheCartUITests/FreeJourneyUITests/testManualListOrderSurvivesRestartAndOpensLargePrint"
        messages = [OBSERVED_WARNING] * 2
        self.assertEqual(self.inspect([MULTIPLE_WARNINGS], messages, selector=selector)["status"], "passed")
        self.assertEqual(self.inspect([MULTIPLE_WARNINGS], messages + [OBSERVED_WARNING], selector=selector)["status"], "unexpected-warnings")
        for changes in (
            {"activity_tap": 'Tap "Other control" Button'},
            {"activity_phase": "Find the button"},
            {"selector": "RoomInTheCartUITests/FreeJourneyUITests/testUnreviewedMenu"},
            {"device": {**OBSERVED_DEVICE, "osBuildNumber": "23C52"}},
        ):
            with self.subTest(changes=changes):
                self.assertEqual(self.inspect([MULTIPLE_WARNINGS], messages,
                    **{"selector": selector, **changes})["status"], "unexpected-warnings")
        self.assertEqual(self.inspect([MULTIPLE_WARNINGS], ["different warning"] * 2,
            selector=selector)["status"], "unexpected-warnings")

    def test_reviewed_menu_idle_phases_keep_exact_case_device_tap_and_total_cap(self):
        for selector in (
            "RoomInTheCartUITests/FreeJourneyUITests/testManualListOrderSurvivesRestartAndOpensLargePrint",
            "RoomInTheCartUITests/FreeJourneyUITests/testMealWeekReservationDraftCannotFollowAnotherPickup",
            "RoomInTheCartUITests/SharedStoreQuoteUITests/testLostReplyRelaunchRestoresExactRetryWithoutDuplicatingPrivateSave",
        ):
            phase = "Wait for dev.roominthecart.app.debug to idle"
            messages = [OBSERVED_WARNING] * 2
            options = {"selector": selector, "activity_phase": phase}
            evidence = self.inspect([MULTIPLE_WARNINGS], messages, **options)
            self.assertEqual(evidence["status"], "passed")
            self.assertEqual(evidence["warnings"][0]["maximum"], 2)
            self.assertEqual(evidence["warnings"][0]["menuActivity"]["phase"], phase)
            self.assertEqual(self.inspect([MULTIPLE_WARNINGS], messages + [OBSERVED_WARNING], **options)["status"], "unexpected-warnings")
            for changes in (
                {"activity_tap": 'Tap "Other control" Button'},
                {"activity_phase": "Find the button"},
                {"activity_phase": "Wait for another.app to idle"},
                {"selector": "RoomInTheCartUITests/FreeJourneyUITests/testUnreviewedPickupMenu"},
                {"device": {**OBSERVED_DEVICE, "osBuildNumber": "23C52"}},
                {"activity_type": "com.apple.dt.xctest.activity-type.user-created"},
            ):
                with self.subTest(changes=changes):
                    self.assertEqual(self.inspect([MULTIPLE_WARNINGS], messages,
                        **{**options, **changes})["status"], "unexpected-warnings")
            self.assertEqual(self.inspect([MULTIPLE_WARNINGS], ["different warning"] * 2,
                **options)["status"], "unexpected-warnings")

    def test_meal_week_pickup_observed_idle_phase_keeps_identity_and_combined_cap(self):
        selector = "RoomInTheCartUITests/FreeJourneyUITests/testMealWeekKeepsOriginalPickupWhenShopSelectionChanges"
        phases = ("Synthesize event", "Wait for dev.roominthecart.app.debug to idle")
        for phase in phases:
            options = {"selector": selector, "activity_phase": phase}
            for count in (1, 2, 3):
                with self.subTest(phase=phase, count=count):
                    markers = [OBSERVED_WARNING] if count == 1 else [MULTIPLE_WARNINGS]
                    result = self.inspect(markers, [OBSERVED_WARNING] * count, **options)
                    self.assertEqual(result["warnings"][0]["maximum"], 2)
                    self.assertEqual(result["status"], "passed" if count <= 2 else "unexpected-warnings")
            for changes in (
                {"activity_tap": 'Tap "Other control" Button'},
                {"activity_phase": "Find the button"},
                {"device": {**OBSERVED_DEVICE, "osBuildNumber": "23C52"}},
                {"configuration": "Other configuration"},
                {"selector": "RoomInTheCartUITests/SharedStoreQuoteUITests/testUnreviewed"},
                {"activity_type": "com.apple.dt.xctest.activity-type.user-created"},
            ):
                with self.subTest(phase=phase, changes=changes):
                    self.assertEqual(self.inspect([MULTIPLE_WARNINGS], [OBSERVED_WARNING] * 2,
                        **{**options, **changes})["status"], "unexpected-warnings")
            self.assertEqual(self.inspect([MULTIPLE_WARNINGS], ["different warning"] * 2,
                **options)["status"], "unexpected-warnings")

        def mixed_paths(run):
            phases = run["activities"][0]["childActivities"]
            other = copy.deepcopy(phases[0])
            other["title"] = "Wait for dev.roominthecart.app.debug to idle"
            other["childActivities"] = phases[0]["childActivities"][1:]
            phases[0]["childActivities"] = phases[0]["childActivities"][:1]
            phases.append(other)

        def deeper_path(run):
            tap = run["activities"][0]
            tap["childActivities"] = [{"title": "Unreviewed ancestor", "isAssociatedWithFailure": False,
                                       "activityType": INTERNAL_ACTIVITY, "childActivities": tap["childActivities"]}]

        def missing_phase(run):
            tap = run["activities"][0]
            tap["childActivities"] = tap["childActivities"][0]["childActivities"]

        # Mixed phases remain unreviewed; they never get a separate allowance per phase.
        for mutate in (mixed_paths, deeper_path, missing_phase):
            for count in (2, 3):
                with self.subTest(mutation=mutate.__name__, count=count):
                    self.assertEqual(self.inspect([MULTIPLE_WARNINGS], [OBSERVED_WARNING] * count,
                        selector=selector, mutate_activity=mutate)["status"], "unexpected-warnings")
        with self.assertRaisesRegex(ValueError, "Duplicated .* attachment UUID"):
            self.inspect([MULTIPLE_WARNINGS], [OBSERVED_WARNING] * 2, selector=selector,
                         activity_issue_ids=["12345678-1234-4abc-8def-000000000001"] * 2)
        with self.assertRaises(ValueError):
            self.inspect([MULTIPLE_WARNINGS], [OBSERVED_WARNING] * 2, selector=selector,
                         activity_messages=[OBSERVED_WARNING])
        with self.assertRaises(ValueError):
            self.inspect([MULTIPLE_WARNINGS], [OBSERVED_WARNING] * 2, selector=selector,
                         detail_changes={"testIdentifierURL": "test://wrong-case"})

    def test_known_trip_observed_phases_keep_one_cap_and_reject_mixed_paths(self):
        selector = "RoomInTheCartUITests/SharedStoreQuoteUITests/testKnownTripUnknownBreakEvenPrivateProposalAndExplicitShopperAdoption"
        phases = ("Synthesize event", "Wait for dev.roominthecart.app.debug to idle")
        for phase in phases:
            options = {"selector": selector, "activity_phase": phase}
            for count in (1, 2, 3):
                with self.subTest(phase=phase, count=count):
                    markers = [OBSERVED_WARNING] if count == 1 else [MULTIPLE_WARNINGS]
                    result = self.inspect(markers, [OBSERVED_WARNING] * count, **options)
                    self.assertEqual(result["warnings"][0]["maximum"], 2)
                    self.assertEqual(result["status"], "passed" if count <= 2 else "unexpected-warnings")
            for changes in (
                {"activity_tap": 'Tap "Other control" Button'},
                {"activity_phase": "Find the button"},
                {"device": {**OBSERVED_DEVICE, "osBuildNumber": "23C52"}},
                {"configuration": "Other configuration"},
                {"selector": "RoomInTheCartUITests/SharedStoreQuoteUITests/testUnreviewed"},
                {"activity_type": "com.apple.dt.xctest.activity-type.user-created"},
            ):
                with self.subTest(phase=phase, changes=changes):
                    self.assertEqual(self.inspect([MULTIPLE_WARNINGS], [OBSERVED_WARNING] * 2,
                        **{**options, **changes})["status"], "unexpected-warnings")
            self.assertEqual(self.inspect([MULTIPLE_WARNINGS], ["different warning"] * 2,
                **options)["status"], "unexpected-warnings")

        def mixed_paths(run):
            phases = run["activities"][0]["childActivities"]
            other = copy.deepcopy(phases[0])
            other["title"] = "Synthesize event"
            other["childActivities"] = phases[0]["childActivities"][1:]
            phases[0]["childActivities"] = phases[0]["childActivities"][:1]
            phases.append(other)

        def deeper_path(run):
            tap = run["activities"][0]
            tap["childActivities"] = [{"title": "Unreviewed ancestor", "isAssociatedWithFailure": False,
                                       "activityType": INTERNAL_ACTIVITY, "childActivities": tap["childActivities"]}]

        def missing_phase(run):
            tap = run["activities"][0]
            tap["childActivities"] = tap["childActivities"][0]["childActivities"]

        # Mixed phases remain unreviewed; they never get a separate allowance per phase.
        for mutate in (mixed_paths, deeper_path, missing_phase):
            for count in (2, 3):
                with self.subTest(mutation=mutate.__name__, count=count):
                    self.assertEqual(self.inspect([MULTIPLE_WARNINGS], [OBSERVED_WARNING] * count,
                        selector=selector, mutate_activity=mutate)["status"], "unexpected-warnings")
        with self.assertRaisesRegex(ValueError, "Duplicated .* attachment UUID"):
            self.inspect([MULTIPLE_WARNINGS], [OBSERVED_WARNING] * 2, selector=selector,
                         activity_issue_ids=["12345678-1234-4abc-8def-000000000001"] * 2)
        with self.assertRaises(ValueError):
            self.inspect([MULTIPLE_WARNINGS], [OBSERVED_WARNING] * 2, selector=selector,
                         activity_messages=[OBSERVED_WARNING])
        with self.assertRaises(ValueError):
            self.inspect([MULTIPLE_WARNINGS], [OBSERVED_WARNING] * 2, selector=selector,
                         detail_changes={"testIdentifierURL": "test://wrong-case"})

    def test_same_count_warning_substitution_rejects_duplicate_issue_uuid(self):
        first = "098DC6EC-90D4-40A9-8363-2BF5B66767FE"
        second = "C2356A60-61FD-4962-920B-05FC780F3A40"
        messages = [OBSERVED_WARNING] * 2
        self.assertEqual(self.inspect([MULTIPLE_WARNINGS], messages, activity_issue_ids=[first, second])["status"], "passed")
        for duplicate in (first, first.lower()):
            with self.subTest(duplicate=duplicate), self.assertRaisesRegex(ValueError, "Duplicated .* attachment UUID"):
                self.inspect([MULTIPLE_WARNINGS], messages, activity_issue_ids=[first, duplicate])

    def test_warning_issue_uuid_must_be_present_and_valid(self):
        for issue_id in (None, "", 123, "not-a-uuid"):
            with self.subTest(issue_id=issue_id), self.assertRaisesRegex(ValueError, "Invalid .* attachment UUID"):
                self.inspect([OBSERVED_WARNING], [OBSERVED_WARNING], activity_issue_ids=[issue_id])

    def test_hosted_parent_activity_type_can_be_absent(self):
        evidence = self.inspect([OBSERVED_WARNING], [OBSERVED_WARNING], activity_type=None)
        self.assertEqual(evidence["status"], "passed")
        self.assertGreater(evidence["warnings"][0]["maximum"], 0)

    def test_correct_message_does_not_inherit_allowance_under_another_tap_or_phase(self):
        for changes in (
            {"activity_tap": 'Tap "Other control" Button'},
            {"activity_phase": "Find the button"},
            {"activity_type": "com.apple.dt.xctest.activity-type.user-created"},
            {"run_changes": {"activities": [
                {"title": OBSERVED_WARNING, "isAssociatedWithFailure": False,
                 "attachments": [{"name": "Complete Issue Description.txt", "uuid": "12345678-1234-4abc-8def-000000000001"}]},
            ]}},
        ):
            with self.subTest(changes=changes):
                evidence = self.inspect([OBSERVED_WARNING], [OBSERVED_WARNING], **changes)
                self.assertEqual(evidence["status"], "unexpected-warnings")
                self.assertEqual(evidence["warnings"][0]["maximum"], 0)

    def test_activity_warnings_must_match_messages_and_multiplicity(self):
        for activity_messages in ([], ["different issue"], [OBSERVED_WARNING] * 2,
                                  [OBSERVED_WARNING, "unassigned warning"]):
            with self.subTest(activity_messages=activity_messages), self.assertRaisesRegex(ValueError, "activities and detailed results disagree"):
                self.inspect([OBSERVED_WARNING], [OBSERVED_WARNING], activity_messages=activity_messages)

    def test_missing_malformed_or_misattributed_activity_fails_closed(self):
        for changes, error in (
            ({"activity_changes": {"testIdentifierURL": "other"}}, "another test or configuration"),
            ({"activity_changes": {"testRuns": []}}, "one XCTest runtime warning activity run"),
            ({"run_changes": {"device": {}}}, "another device or configuration"),
            ({"run_changes": {"testPlanConfiguration": {}}}, "another device or configuration"),
            ({"run_changes": {"activities": {}}}, "Invalid XCTest warning activity tree"),
            ({"run_changes": {"activities": [{"title": OBSERVED_WARNING, "isAssociatedWithFailure": False}]}}, "Malformed XCTest runtime warning activity"),
            ({"detail_changes": {"testPlanConfigurations": []}}, "another test configuration"),
        ):
            with self.subTest(changes=changes), self.assertRaisesRegex(ValueError, error):
                self.inspect([OBSERVED_WARNING], [OBSERVED_WARNING], **changes)

    def test_warning_without_an_issue_attachment_reports_the_original_message(self):
        message = "Modifying state during view update, this will cause undefined behavior."
        activity = {"title": message, "isAssociatedWithFailure": False}
        with self.assertRaises(ValueError) as failure:
            self.inspect([message], [message], run_changes={"activities": [activity]})
        self.assertIn(message, str(failure.exception))
        self.assertIn("Expected one Complete Issue Description.txt attachment, found 0", str(failure.exception))

    def test_new_message_selector_or_environment_does_not_inherit_an_allowance(self):
        for message, kwargs in (
            ("Unexpected layout warning", {}),
            (OBSERVED_WARNING, {"selector": "RoomInTheCartUITests/OtherTests/testOne"}),
            (OBSERVED_WARNING, {"device": {**OBSERVED_DEVICE, "osBuildNumber": "different"}}),
            (OBSERVED_WARNING, {"configuration": "other"}),
        ):
            with self.subTest(message=message, kwargs=kwargs):
                evidence = self.inspect([message], [message], **kwargs)
                self.assertEqual(evidence["status"], "unexpected-warnings")
                self.assertEqual(evidence["warnings"][0]["maximum"], 0)

    def test_present_summary_must_match_message_and_multiplicity(self):
        issues = [{"issueType": "Runtime Warning", "message": OBSERVED_WARNING}] * 2
        self.assertEqual(self.inspect([MULTIPLE_WARNINGS], [OBSERVED_WARNING] * 2,
                                     summary_warnings=issues)["summaryWarningCount"], 2)
        with self.assertRaisesRegex(ValueError, "summary and test details disagree"):
            self.inspect([MULTIPLE_WARNINGS], [OBSERVED_WARNING] * 2, summary_warnings=issues[:1])
        with self.assertRaisesRegex(ValueError, "Invalid XCTest summary runtimeWarnings"):
            self.inspect([], [], summary_warnings={"issueType": "Runtime Warning"})

    def test_ambiguous_missing_or_wrong_detail_export_fails_closed(self):
        for markers, messages, changes, error in (
            ([MULTIPLE_WARNINGS], [OBSERVED_WARNING], {}, "disagree with test tree"),
            ([OBSERVED_WARNING], ["different"], {}, "disagree with test tree"),
            ([], [], {"testRuns": []}, "Missing test runs"),
            ([], [], {"testRuns": {}}, "Missing test runs"),
            ([], [], {"testRuns": [{"nodeType": "Future runtime diagnosis"}]}, "Unknown XCTest result node type"),
            ([], [], {"testIdentifierURL": "other"}, "another test or device"),
            ([], [], {"devices": []}, "another test or device"),
        ):
            with self.subTest(error=error), self.assertRaisesRegex(ValueError, error):
                self.inspect(markers, messages, detail_changes=changes)

    def test_unrecognized_unassigned_or_unexamined_nodes_fail_closed(self):
        for node, error in (
            ({"nodeType": "Future runtime diagnosis"}, "Unknown XCTest result node type"),
            ({"nodeType": "Runtime Warning", "name": OBSERVED_WARNING}, "without a selected test"),
            ({"nodeType": "Test Suite", "children": {}}, "Invalid XCTest warning tree"),
        ):
            with self.subTest(error=error), self.assertRaisesRegex(ValueError, error):
                # Construct the known selected case independently so malformed
                # sibling structures reach the runtime warning schema check.
                case = {"nodeType": "Test Case", "nodeIdentifierURL": "test://suite/case", "result": "Passed"}
                device = {**OBSERVED_DEVICE, "deviceId": "12345678-1234-4abc-8def-000000000001"}
                summary = self.warning_summary(device)
                plan = summary["devicesAndConfigurations"][0]["testPlanConfiguration"]
                inspect_runtime_warnings(
                    summary,
                    [case, node], [("Suite/Class/testCase", case)],
                    lambda url: {"testIdentifierURL": url, "devices": [device], "testPlanConfigurations": [plan],
                                 "testResult": "Passed",
                                 "testRuns": [{"nodeType": "Device", "nodeIdentifier": device["deviceId"], "result": "Passed",
                                               "children": [{"nodeType": "Test Plan Configuration",
                                                             "nodeIdentifier": plan["configurationId"], "result": "Passed"}]}]},
                    lambda _: {},
                )
        omitted = {"nodeType": "Test Case", "nodeIdentifierURL": "test://suite/omitted"}
        with self.assertRaisesRegex(ValueError, "did not examine every test case"):
            inspect_runtime_warnings({"devicesAndConfigurations": []}, [omitted], [], lambda _: {}, lambda _: {})


if __name__ == '__main__':
    unittest.main()
