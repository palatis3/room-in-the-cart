#!/usr/bin/env python3
import json
import copy
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

from check_ios_test_results import (
    INTERNAL_ACTIVITY, MULTIPLE_WARNINGS, OBSERVED_DEVICE, OBSERVED_MENU_WARNINGS, OBSERVED_WARNING,
    execution_log_failures,
    inspect_runtime_warnings, test_cases,
)

SCRIPT = Path(__file__).with_name('check_ios_test_results.py')


class ExecutionInventoryTests(unittest.TestCase):
    def check_case(self, identifiers, *, selected=None, skipped=0, result='Passed', expected_failures=0, case_result='Passed', log=None):
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
            return subprocess.run(args, env=env, capture_output=True, text=True).returncode

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


class ExecutionLogTests(unittest.TestCase):
    selector = "RoomInTheCartUITests/FreeJourneyUITests/testOne"
    case = "Test Case '-[RoomInTheCartUITests.FreeJourneyUITests testOne]' "
    start = case + "started."
    done = case + "passed (71.217 seconds)."
    success = "** TEST EXECUTE SUCCEEDED **"

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


class RuntimeWarningTests(unittest.TestCase):
    def warning_summary(self, device, configuration="Test Scheme Action"):
        return {"devicesAndConfigurations": [{"device": device,
                "testPlanConfiguration": {"configurationId": "1", "configurationName": configuration}}]}

    def inspect(self, markers, messages, *, selector=None, device=None, summary_warnings=None,
                configuration="Test Scheme Action", extra_nodes=(), detail_changes=None,
                activity_messages=None, activity_tap=None, activity_phase=None, activity_changes=None, run_changes=None,
                activity_type=INTERNAL_ACTIVITY, activity_issue_ids=None, mutate_details=None, case_result="Passed"):
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

    def test_manual_order_menu_idle_phase_keeps_exact_case_device_tap_and_total_cap(self):
        selector = "RoomInTheCartUITests/FreeJourneyUITests/testManualListOrderSurvivesRestartAndOpensLargePrint"
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
            {"selector": "RoomInTheCartUITests/FreeJourneyUITests/testMealWeekKeepsOriginalPickupWhenShopSelectionChanges"},
            {"device": {**OBSERVED_DEVICE, "osBuildNumber": "23C52"}},
            {"activity_type": "com.apple.dt.xctest.activity-type.user-created"},
        ):
            with self.subTest(changes=changes):
                self.assertEqual(self.inspect([MULTIPLE_WARNINGS], messages,
                    **{**options, **changes})["status"], "unexpected-warnings")
        self.assertEqual(self.inspect([MULTIPLE_WARNINGS], ["different warning"] * 2,
            **options)["status"], "unexpected-warnings")

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
