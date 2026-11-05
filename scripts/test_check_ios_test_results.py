#!/usr/bin/env python3
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

from check_ios_test_results import (
    MULTIPLE_WARNINGS, OBSERVED_DEVICE, OBSERVED_LIMITS, OBSERVED_WARNING, inspect_runtime_warnings, test_cases,
)

SCRIPT = Path(__file__).with_name('check_ios_test_results.py')


class ExecutionInventoryTests(unittest.TestCase):
    def check_case(self, identifiers, *, selected=None, skipped=0, result='Passed', expected_failures=0, case_result='Passed'):
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
            return subprocess.run([sys.executable, str(SCRIPT), '--selectors', str(root / 'selection.txt'),
                '--expected-count', str(len(selected or ['Target/Suite/testOne'])), '--summary', str(root / 'summary.json'), '--tests', str(root / 'tests.json')],
                env=env, capture_output=True, text=True).returncode

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


class RuntimeWarningTests(unittest.TestCase):
    def warning_summary(self, device, configuration="Test Scheme Action"):
        return {"devicesAndConfigurations": [{"device": device,
                "testPlanConfiguration": {"configurationName": configuration}}]}

    def inspect(self, markers, messages, *, selector=None, device=None, summary_warnings=None,
                configuration="Test Scheme Action", extra_nodes=(), detail_changes=None):
        selector = selector or next(iter(OBSERVED_LIMITS))
        url = "test://com.apple.xcode/RoomInTheCart/" + selector
        device = device or OBSERVED_DEVICE
        summary = self.warning_summary(device, configuration)
        if summary_warnings is not None:
            summary["runtimeWarnings"] = summary_warnings
        case = {"nodeType": "Test Case", "nodeIdentifierURL": url,
                "children": [{"nodeType": "Runtime Warning", "name": name} for name in markers]}
        nodes = [case, *extra_nodes]
        details = {
            "testIdentifierURL": url, "devices": [device],
            "testRuns": [{"nodeType": "Device", "children": [
                {"nodeType": "Runtime Warning", "name": name} for name in messages
            ]}],
            **(detail_changes or {}),
        }

        def read_detail(requested):
            self.assertEqual(requested, url)
            return details

        return inspect_runtime_warnings(summary, nodes, list(test_cases(nodes)), read_detail)

    def test_omitted_summary_still_requires_a_clean_detail_export(self):
        evidence = self.inspect([], [])
        self.assertIsNone(evidence["summaryWarningCount"])
        self.assertEqual(evidence["runtimeWarningCount"], 0)
        self.assertEqual(evidence["examinedTestCount"], 1)
        self.assertEqual(evidence["detailExportCount"], 1)

    def test_detail_only_warning_is_rejected_when_summary_and_tree_omit_it(self):
        with self.assertRaisesRegex(ValueError, "disagree with test tree"):
            self.inspect([], [OBSERVED_WARNING])

    def test_duplicate_occurrences_are_counted_and_capped_for_each_case(self):
        for selector, maximum in OBSERVED_LIMITS.items():
            for count in (maximum, maximum + 1):
                with self.subTest(selector=selector, count=count):
                    marker = [MULTIPLE_WARNINGS] if count > 1 else [OBSERVED_WARNING]
                    evidence = self.inspect(marker, [OBSERVED_WARNING] * count, selector=selector)
                    self.assertEqual(evidence["runtimeWarningCount"], count)
                    self.assertEqual(evidence["warnings"][0]["maximum"], maximum)
                    self.assertEqual(evidence["status"], "passed" if count == maximum else "unexpected-warnings")

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
                case = {"nodeType": "Test Case", "nodeIdentifierURL": "test://suite/case"}
                inspect_runtime_warnings(
                    self.warning_summary(OBSERVED_DEVICE),
                    [case, node], [("Suite/Class/testCase", case)],
                    lambda url: {"testIdentifierURL": url, "devices": [OBSERVED_DEVICE],
                                 "testRuns": [{"nodeType": "Device"}]},
                )
        omitted = {"nodeType": "Test Case", "nodeIdentifierURL": "test://suite/omitted"}
        with self.assertRaisesRegex(ValueError, "did not examine every test case"):
            inspect_runtime_warnings({"devicesAndConfigurations": []}, [omitted], [], lambda _: {})


if __name__ == '__main__':
    unittest.main()
