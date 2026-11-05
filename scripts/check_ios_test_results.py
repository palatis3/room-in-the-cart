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
        # SQLite can report an unsafe live-file deletion outside XCTest's
        # runtime-warning export, even when every assertion passes.
        if "BUG IN CLIENT OF libsqlite3.dylib:" in line:
            failures.append(f"SQLite reported an API misuse diagnostic at log line {number}.")
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


# The standalone Menu control experiment reproduced this exact warning.
# Allow only the observed test, environment, Menu tap, activity and count.
OBSERVED_WARNING = (
    "Adding '_UIReparentingView' as a subview of UIHostingController.view is not supported and may result "
    "in a broken view hierarchy. Add your view above UIHostingController.view in a common superview or "
    "insert it into your SwiftUI content in a UIViewRepresentable instead."
)
PICKUP_MENU_TAP = 'Tap "ledgerShopPicker" Button'
LIST_OPTIONS_MENU_TAP = 'Tap "ledgerListOptions" Button[0.50, 0.50]'
FIXTURE_MENU_TAP = 'Tap "fixture.s27.controls" Button'
SYNTHESIZE_EVENT = "Synthesize event"
INTERNAL_ACTIVITY = "com.apple.dt.xctest.activity-type.internal"
ISSUE_ATTACHMENT_UUID = re.compile(r"[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}", re.IGNORECASE)
OBSERVED_MENU_WARNINGS = {
    "RoomInTheCartUITests/FreeJourneyUITests/testMealWeekKeepsOriginalPickupWhenShopSelectionChanges":
        (2, PICKUP_MENU_TAP, SYNTHESIZE_EVENT),
    "RoomInTheCartUITests/FreeJourneyUITests/testManualListOrderSurvivesRestartAndOpensLargePrint":
        (2, LIST_OPTIONS_MENU_TAP, SYNTHESIZE_EVENT),
    "RoomInTheCartUITests/FreeJourneyUITests/testMealWeekReservationDraftCannotFollowAnotherPickup":
        (2, PICKUP_MENU_TAP, SYNTHESIZE_EVENT),
    "RoomInTheCartUITests/SharedStoreQuoteUITests/testKnownTripUnknownBreakEvenPrivateProposalAndExplicitShopperAdoption":
        (2, FIXTURE_MENU_TAP, "Wait for dev.roominthecart.app.debug to idle"),
    "RoomInTheCartUITests/SharedStoreQuoteUITests/testLostReplyRelaunchRestoresExactRetryWithoutDuplicatingPrivateSave":
        (2, FIXTURE_MENU_TAP, SYNTHESIZE_EVENT),
    "RoomInTheCartUITests/SharedStoreQuoteUITests/testStaleReviewedSaveCannotBeRebasedAndLockedShopHasNoNewComparisonAction":
        (2, FIXTURE_MENU_TAP, SYNTHESIZE_EVENT),
}
# f20feb6's manual-order case recorded both issues while waiting for the
# same Menu tap to settle, matching the standalone Menu control experiment.
# Keep this additional exact phase local to that case, with the same total cap.
OBSERVED_MENU_WARNING_ALTERNATE_PHASES = {
    "RoomInTheCartUITests/FreeJourneyUITests/testManualListOrderSurvivesRestartAndOpensLargePrint":
        ("Wait for dev.roominthecart.app.debug to idle",),
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


def export_test_activities(bundle, identifier_url):
    result = subprocess.run(
        ["xcrun", "xcresulttool", "get", "test-results", "activities",
         "--path", str(bundle), "--test-id", identifier_url, "--compact"],
        check=True, capture_output=True, text=True,
    )
    return json.loads(result.stdout)


def activity_warning_paths(activities, messages, parents=()):
    if not isinstance(activities, list):
        raise ValueError("Invalid XCTest warning activity tree")
    for activity in activities:
        title = activity["title"]
        kind = activity.get("activityType")
        failed = activity["isAssociatedWithFailure"]
        attachments = activity.get("attachments", [])
        if (not isinstance(title, str) or (kind is not None and not isinstance(kind, str))
                or not isinstance(failed, bool) or not isinstance(attachments, list)
                or any(not isinstance(item, dict) for item in attachments)):
            raise ValueError("Invalid XCTest warning activity")
        issue_files = [item for item in attachments if item.get("name") == "Complete Issue Description.txt"]
        # XCTest exports runtime warnings as untyped, nonfailure issue records.
        # Assertion failures use the same attachment but are marked as failures.
        if title in messages or title == OBSERVED_WARNING or (kind is None and not failed and issue_files):
            if kind is not None or failed or len(issue_files) != 1 or not title.strip():
                raise ValueError("Malformed XCTest runtime warning activity")
            issue_id = issue_files[0].get("uuid")
            if not isinstance(issue_id, str) or not ISSUE_ATTACHMENT_UUID.fullmatch(issue_id):
                raise ValueError("Invalid XCTest runtime warning activity attachment UUID")
            yield title, parents, issue_id.lower()
        yield from activity_warning_paths(
            activity.get("childActivities", []), messages, (*parents[-1:], (kind, title)),
        )


def verify_warning_activities(activities, identifier_url, configurations, detail_configurations, names):
    if len(configurations) != 1 or activities["testIdentifierURL"] != identifier_url:
        raise ValueError("XCTest warning activities came from another test or configuration")
    configuration, = configurations
    if detail_configurations != [configuration["testPlanConfiguration"]]:
        raise ValueError("XCTest warning details came from another test configuration")
    runs = activities["testRuns"]
    if not isinstance(runs, list) or len(runs) != 1:
        raise ValueError("Expected one XCTest runtime warning activity run")
    run, = runs
    if (run["device"] != configuration["device"]
            or run["testPlanConfiguration"] != configuration["testPlanConfiguration"]):
        raise ValueError("XCTest warning activity run came from another device or configuration")
    records = list(activity_warning_paths(run["activities"], set(names)))
    # The attachment UUID identifies an occurrence within the activity export.
    # The detailed result export uses separate attachment identities.
    if len({issue_id for _, _, issue_id in records}) != len(records):
        raise ValueError("Duplicated XCTest runtime warning activity attachment UUID")
    occurrences = [(title, parents) for title, parents, _ in records]
    if Counter(title for title, _ in occurrences) != Counter(names):
        raise ValueError("XCTest warning activities and detailed results disagree")
    return occurrences


def verify_detail_run_identity(runs, identifier_url, configurations, detail_configurations, case_result, detail_result):
    # The CI shards execute one device/configuration. Failed cases still need
    # usable warning evidence, so validate identity without requiring Passed.
    if len(configurations) != 1 or len(runs) != 1:
        raise ValueError("Expected one XCTest detail device/configuration run")
    configuration, = configurations
    plan = configuration["testPlanConfiguration"]
    device_id = configuration["device"].get("deviceId")
    configuration_id = plan.get("configurationId")
    if (not isinstance(device_id, str) or not device_id
            or not isinstance(configuration_id, str) or not configuration_id):
        raise ValueError("Missing XCTest detail device/configuration identity")
    if detail_configurations != [plan]:
        raise ValueError("XCTest warning details came from another test configuration")
    device_run, = runs
    if device_run["nodeType"] != "Device" or device_run.get("nodeIdentifier") != device_id:
        raise ValueError("XCTest detail run came from another device")
    children = device_run.get("children", [])
    if len(children) != 1:
        raise ValueError("Expected one XCTest detail configuration run")
    plan_run, = children
    if (plan_run["nodeType"] != "Test Plan Configuration"
            or plan_run.get("nodeIdentifier") != configuration_id
            or ("nodeIdentifierURL" in plan_run and plan_run["nodeIdentifierURL"] != identifier_url)):
        raise ValueError("XCTest detail run came from another test or configuration")
    if (not isinstance(case_result, str) or not case_result.strip()
            or detail_result != case_result or device_run.get("result") != case_result
            or plan_run.get("result") != case_result):
        raise ValueError("XCTest selected case and detail run results disagree")
    if any(node["nodeType"] in ("Device", "Test Plan Configuration")
           for node in result_nodes(plan_run.get("children", []))):
        raise ValueError("Unexpected nested XCTest detail device/configuration run")


def inspect_runtime_warnings(summary, nodes, cases, read_details, read_activities):
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
    activity_exports = 0
    menu_matches = {}
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
        run_nodes = list(result_nodes(runs))
        verify_detail_run_identity(runs, url, configurations, details["testPlanConfigurations"],
                                   node.get("result"), details.get("testResult"))
        names = list(warning_names(run_nodes))
        if listed == [MULTIPLE_WARNINGS]:
            matches_tree = len(names) > 1
        else:
            matches_tree = Counter(names) == Counter(listed)
        if not matches_tree or MULTIPLE_WARNINGS in names:
            raise ValueError(f"Runtime warning details disagree with test tree: {selector}")
        counts.update((selector, message) for message in names)
        if names:
            occurrences = verify_warning_activities(
                read_activities(url), url, configurations, details["testPlanConfigurations"], names,
            )
            activity_exports += 1
            if observed_environment and selector in OBSERVED_MENU_WARNINGS:
                maximum, tap, phase = OBSERVED_MENU_WARNINGS[selector]
                paths = [path for title, path in occurrences if title == OBSERVED_WARNING]
                # Xcode 26.3 omits activityType on these parents; newer exports label them internal.
                for observed_phase in (phase, *OBSERVED_MENU_WARNING_ALTERNATE_PHASES.get(selector, ())):
                    if paths and all(tuple(title for _, title in path) == (tap, observed_phase)
                                     and all(kind in (None, INTERNAL_ACTIVITY) for kind, _ in path) for path in paths):
                        menu_matches[selector] = (maximum, tap, observed_phase)
                        break

    if Counter(markers) != Counter(warning_names(all_nodes)):
        raise ValueError("XCTest recorded a runtime warning without a selected test")
    details_names = Counter()
    warnings = []
    for (selector, message), count in sorted(counts.items()):
        details_names[message] += count
        allowance = menu_matches.get(selector) if message == OBSERVED_WARNING else None
        warning = {"selector": selector, "message": message, "count": count, "maximum": 0}
        if allowance is not None:
            maximum, tap, phase = allowance
            warning.update(maximum=maximum, menuActivity={"tap": tap, "phase": phase})
        warnings.append(warning)
    if summary_names is not None and summary_names != details_names:
        raise ValueError("XCTest summary and test details disagree on runtime warnings")
    return {
        "status": "unexpected-warnings" if any(row["count"] > row["maximum"] for row in warnings) else "passed",
        "summaryWarningCount": None if summary_names is None else sum(summary_names.values()),
        "runtimeWarningCount": sum(counts.values()),
        "examinedTestCount": len(cases),
        "detailExportCount": len(cases),
        "activityExportCount": activity_exports,
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
            summary, nodes, cases,
            lambda url: export_test_details(args.result_bundle, url),
            lambda url: export_test_activities(args.result_bundle, url),
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
