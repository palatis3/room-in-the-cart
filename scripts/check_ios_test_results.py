#!/usr/bin/env python3
"""Require complete XCTest execution and verify recorded runtime warnings."""
import argparse
from collections import Counter, defaultdict
import json
import os
from pathlib import Path
import re
import subprocess
from urllib.parse import unquote, urlparse


XCTEST_CASE_ID = r"(?P<target>[^.\s]+)\.(?P<suite>[^\s\]]+) (?P<method>[^\s\]]+)"
XCTEST_CASE_LINE = re.compile(rf"Test Case '-\[{XCTEST_CASE_ID}\]' (?P<event>.+)")
XCTEST_CASE_ERROR = re.compile(rf".+:\d+(?::\d+)?: error: -\[{XCTEST_CASE_ID}\] : ")
XCTEST_CASE_PASSED = re.compile(r"passed \([0-9]+(?:\.[0-9]+)? seconds\)\.")
XCTEST_RESULT_BANNER = re.compile(r"\*\* TEST (?:EXECUTE )?(SUCCEEDED|FAILED) \*\*")
XCTEST_RESTART = "Restarting after unexpected exit, crash, or test timeout;"


def execution_log_failures(lines, expected):
    """Verify the serial XCTest lifecycle, which the result bundle may collapse."""
    events = defaultdict(list)
    failures = []
    banners = []
    for number, raw_line in enumerate(lines, 1):
        line = raw_line.rstrip("\r\n")
        if line.startswith(XCTEST_RESTART):
            failures.append(f"XCTest restarted its runner at log line {number}.")
        banner = XCTEST_RESULT_BANNER.fullmatch(line)
        if banner:
            banners.append(banner[1])
        error = XCTEST_CASE_ERROR.match(line)
        if error:
            selector = "/".join(error.group("target", "suite", "method"))
            failures.append(f"XCTest logged a failure for {selector} at log line {number}.")
        if not line.startswith("Test Case "):
            continue
        case = XCTEST_CASE_LINE.fullmatch(line)
        if case is None or banners:
            failures.append(f"Unrecognized or out-of-order XCTest case record at log line {number}.")
            continue
        selector = "/".join(case.group("target", "suite", "method"))
        event = case["event"]
        if event == "started.":
            events[selector].append("start")
        elif XCTEST_CASE_PASSED.fullmatch(event):
            events[selector].append("pass")
        elif event.startswith("exceeded execution time allowance "):
            events[selector].append("timeout")
        else:
            events[selector].append("non-passing or unrecognized completion")

    missing = set(expected) - events.keys()
    unexpected = events.keys() - set(expected)
    if missing or unexpected:
        failures.append(f"XCTest log inventory mismatch. Missing {sorted(missing)}; extra {sorted(unexpected)}.")
    for selector, lifecycle in sorted(events.items()):
        if lifecycle != ["start", "pass"]:
            failures.append(f"XCTest log requires one start then one pass for {selector}; found {lifecycle}.")
    if banners != ["SUCCEEDED"]:
        failures.append(f"XCTest log requires one successful result banner; found {banners}.")
    return failures


def test_cases(nodes):
    for node in nodes:
        if node.get("nodeType") == "Test Case":
            parts = unquote(urlparse(node["nodeIdentifierURL"]).path).strip("/").split("/")
            yield "/".join(parts[-3:]), node
        else:
            yield from test_cases(node.get("children", []))


# The retained Xcode 26.3 simulator runs recorded this message. Its origin is
# unknown. Keep the allowance tied to the exact test, environment and count.
OBSERVED_WARNING = (
    "Adding '_UIReparentingView' as a subview of UIHostingController.view is not supported and may result "
    "in a broken view hierarchy. Add your view above UIHostingController.view in a common superview or "
    "insert it into your SwiftUI content in a UIViewRepresentable instead."
)
OBSERVED_LIMITS = {
    "RoomInTheCartUITests/FreeJourneyUITests/testMealWeekKeepsOriginalPickupWhenShopSelectionChanges": 2,
    "RoomInTheCartUITests/FreeJourneyUITests/testManualListOrderSurvivesRestartAndOpensLargePrint": 1,
}
OBSERVED_DEVICE = {
    "modelName": "iPhone 17", "osVersion": "26.2", "osBuildNumber": "23C54",
    "architecture": "arm64", "platform": "iOS Simulator",
}
MULTIPLE_WARNINGS = "Multiple Runtime Warnings"


# xcresulttool's TestNodeType schema. An unrecognized node may carry evidence
# that this verifier does not know how to read.
TEST_NODE_TYPES = {
    "Test Plan", "Unit test bundle", "UI test bundle", "Test Suite", "Test Case", "Device",
    "Test Plan Configuration", "Arguments", "Repetition", "Test Case Run", "Failure Message",
    "Source Code Reference", "Attachment", "Expression", "Test Value", "Runtime Warning",
    "Skip Message", "Expected Failure",
}


def result_nodes(nodes):
    if not isinstance(nodes, list):
        raise ValueError("Invalid XCTest warning tree")
    for node in nodes:
        if not isinstance(node, dict):
            raise ValueError("Invalid XCTest result node")
        kind = node["nodeType"]
        if not isinstance(kind, str) or kind not in TEST_NODE_TYPES:
            raise ValueError(f"Unknown XCTest result node type: {kind}")
        yield node
        yield from result_nodes(node.get("children", []))


def warning_names(nodes):
    for node in nodes:
        if node["nodeType"] != "Runtime Warning":
            continue
        name = node["name"]
        if not isinstance(name, str) or not name.strip():
            raise ValueError("XCTest runtime warning has no message")
        yield name


def export_test_details(bundle, identifier_url):
    result = subprocess.run(
        ["xcrun", "xcresulttool", "get", "test-results", "test-details",
         "--path", str(bundle), "--test-id", identifier_url, "--compact"],
        check=True, capture_output=True, text=True,
    )
    return json.loads(result.stdout)


def inspect_runtime_warnings(summary, nodes, cases, read_details):
    summary_names = None
    if "runtimeWarnings" in summary:
        issues = summary["runtimeWarnings"]
        if not isinstance(issues, list) or not all(
            isinstance(issue, dict) and issue.get("issueType") == "Runtime Warning"
            and isinstance(issue.get("message"), str) and issue["message"].strip() for issue in issues
        ):
            raise ValueError("Invalid XCTest summary runtimeWarnings")
        summary_names = Counter(issue["message"] for issue in issues)

    all_nodes = list(result_nodes(nodes))
    all_case_urls = Counter(node["nodeIdentifierURL"] for node in all_nodes if node["nodeType"] == "Test Case")
    if all_case_urls != Counter(node["nodeIdentifierURL"] for _, node in cases):
        raise ValueError("XCTest runtime warning scan did not examine every test case")

    configurations = summary["devicesAndConfigurations"]
    if not isinstance(configurations, list) or not configurations or not all(
        isinstance(item, dict) and isinstance(item.get("device"), dict)
        and isinstance(item.get("testPlanConfiguration"), dict) for item in configurations
    ):
        raise ValueError("Invalid XCTest warning device or test configuration")
    devices = [item["device"] for item in configurations]
    observed_environment = (
        len(devices) == 1 and configurations[0]["testPlanConfiguration"].get("configurationName") == "Test Scheme Action"
        and all(devices[0].get(key) == value for key, value in OBSERVED_DEVICE.items())
    )
    counts = Counter()
    markers = []
    for selector, node in cases:
        listed = list(warning_names(result_nodes([node])))
        markers.extend(listed)
        # A missing summary field or tree marker cannot establish zero warnings.
        url = node["nodeIdentifierURL"]
        details = read_details(url)
        if details["testIdentifierURL"] != url or details["devices"] != devices:
            raise ValueError(f"Runtime warning details came from another test or device: {selector}")
        runs = details["testRuns"]
        if not isinstance(runs, list) or not runs:
            raise ValueError(f"Missing test runs for runtime warning details: {selector}")
        names = list(warning_names(result_nodes(runs)))
        if listed == [MULTIPLE_WARNINGS]:
            matches_tree = len(names) > 1
        else:
            matches_tree = Counter(names) == Counter(listed)
        if not matches_tree or MULTIPLE_WARNINGS in names:
            raise ValueError(f"Runtime warning details disagree with test tree: {selector}")
        counts.update((selector, message) for message in names)

    if Counter(markers) != Counter(warning_names(all_nodes)):
        raise ValueError("XCTest recorded a runtime warning without a selected test")
    details_names = Counter()
    warnings = []
    for (selector, message), count in sorted(counts.items()):
        details_names[message] += count
        maximum = OBSERVED_LIMITS.get(selector, 0) if observed_environment and message == OBSERVED_WARNING else 0
        warnings.append({"selector": selector, "message": message, "count": count, "maximum": maximum})
    if summary_names is not None and summary_names != details_names:
        raise ValueError("XCTest summary and test details disagree on runtime warnings")
    return {
        "status": "unexpected-warnings" if any(row["count"] > row["maximum"] for row in warnings) else "passed",
        "summaryWarningCount": None if summary_names is None else sum(summary_names.values()),
        "runtimeWarningCount": sum(counts.values()),
        "examinedTestCount": len(cases),
        "detailExportCount": len(cases),
        "warnings": warnings,
    }


def append_runtime_warning_report(args, summary, nodes, cases, report, failures):
    report.append("")
    if args.result_bundle is None:
        report.append("XCTest runtime warnings were not verified. Supply --result-bundle to check them.")
        return
    try:
        if not (args.result_bundle / "Info.plist").is_file():
            raise ValueError("Missing XCTest result bundle")
        evidence = inspect_runtime_warnings(
            summary, nodes, cases, lambda url: export_test_details(args.result_bundle, url),
        )
    except (KeyError, TypeError, ValueError, OSError, subprocess.CalledProcessError) as error:
        evidence = {"status": "unavailable", "error": str(error)}
        failures.append(f"XCTest runtime warning evidence is unavailable. {error}")
    args.tests.with_name("test-runtime-warnings.json").write_text(json.dumps(evidence, indent=2) + "\n", encoding="utf-8")
    if evidence["status"] == "unavailable":
        return
    report.append(f"The XCTest test export recorded {evidence['runtimeWarningCount']} runtime warning occurrences "
                  f"across {evidence['examinedTestCount']} examined tests.")
    if evidence["summaryWarningCount"] is None:
        report.append("The XCTest summary does not expose a runtime warnings field.")
    for row in evidence["warnings"]:
        count, maximum = row["count"], row["maximum"]
        message = " ".join(row["message"].splitlines())
        report.append(f"- `{row['selector']}` recorded {count} warning(s), with {maximum} allowed. {message}")
        if count > maximum:
            failures.append(f"Unexpected runtime warning count for {row['selector']}. Observed {count}, allowed {maximum}.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--selectors", type=Path, required=True)
    parser.add_argument("--summary", type=Path, required=True)
    parser.add_argument("--tests", type=Path, required=True)
    parser.add_argument("--result-bundle", type=Path, help="verify runtime warnings in this XCTest result bundle")
    parser.add_argument("--test-log", type=Path, help="verify the selected XCTest attempt's serial execution log")
    parser.add_argument("--expected-count", type=int, required=True)
    args = parser.parse_args()
    expected = args.selectors.read_text().splitlines()
    summary = json.loads(args.summary.read_text())
    nodes = json.loads(args.tests.read_text())["testNodes"]
    cases = list(test_cases(nodes))
    actual = [identifier for identifier, _ in cases]
    failures = []
    if not expected or len(expected) != len(set(expected)) or len(expected) != args.expected_count:
        failures.append("Expected selection is empty, duplicated or does not match the build count")
    if len(actual) != len(set(actual)) or set(actual) != set(expected):
        failures.append(f"Unexpected execution inventory. Missing {sorted(set(expected) - set(actual))}; extra {sorted(set(actual) - set(expected))}")
    if summary.get("totalTestCount") != len(expected) or summary.get("passedTests") != len(expected):
        failures.append("Executed and passing counts do not match the selected tests")
    if summary.get("failedTests") or summary.get("skippedTests") or summary.get("expectedFailures") or summary.get("result") != "Passed":
        failures.append("The shard contains failures, expected failures or skipped tests")
    if any(node.get("result") != "Passed" for _, node in cases):
        failures.append("Every selected test must individually report Passed")
    report = [f"Executed {len(actual)} of {len(expected)} selected tests.", "", "| Test | Result | Seconds |", "|---|---|---|"]
    for identifier, node in sorted(cases, key=lambda item: item[1].get("durationInSeconds", 0), reverse=True):
        report.append(f"| {identifier} | {node.get('result', 'Unknown')} | {node.get('durationInSeconds', 0):.2f} |")
    if args.test_log is not None:
        try:
            with args.test_log.open(encoding="utf-8") as log:
                log_failures = execution_log_failures(log, expected)
        except (OSError, UnicodeError) as error:
            log_failures = [f"XCTest execution log is unavailable. {error}"]
        if log_failures:
            failures.extend(log_failures)
        else:
            report.append("The XCTest log confirms one start and one passing completion per selected test.")
    append_runtime_warning_report(args, summary, nodes, cases, report, failures)
    report.extend(failures)
    output = "\n".join(report) + "\n"
    print(output)
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as handle:
            handle.write(output)
    if failures:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
