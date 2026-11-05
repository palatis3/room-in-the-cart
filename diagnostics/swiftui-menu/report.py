#!/usr/bin/env python3
"""Check the diagnostic scenarios and retain exact warning occurrences."""

from collections import Counter
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts"))
from check_ios_test_results import (  # noqa: E402
    OBSERVED_DEVICE, OBSERVED_WARNING, export_test_details, inspect_runtime_warnings, result_nodes,
    test_cases, warning_names,
)


SUITE = "MenuRuntimeDiagnosticUITests"
SCENARIOS = {
    "testPickupControlWithoutOpeningMenu": ["Pickup control without opening a Menu"],
    "testFixtureControlWithoutOpeningMenu": ["Fixture control without opening a Menu"],
    "testOpenAndCancelSinglePickupMenu": ["Open pickup Menu", "Dismiss pickup Menu without selection"],
    "testOpenAndCancelFixtureControlsMenu": ["Open fixture Menu", "Dismiss fixture Menu without selection"],
}
MENU_TAPS = {
    "testOpenAndCancelSinglePickupMenu": 'Tap "probe.pickupMenu" Button[0.50, 0.50]',
    "testOpenAndCancelFixtureControlsMenu": 'Tap "probe.fixtureMenu" Button[0.50, 0.50]',
}


def activity_titles(activities):
    for activity in activities:
        yield activity["title"]
        yield from activity_titles(activity.get("childActivities", []))


def activity_nodes(activities, parents=(), path="$.testRuns[0].activities"):
    if not isinstance(activities, list):
        raise ValueError("Invalid diagnostic activity list")
    for index, activity in enumerate(activities):
        if not isinstance(activity, dict) or not isinstance(activity.get("title"), str):
            raise ValueError("Invalid diagnostic activity")
        location = f"{path}[{index}]"
        yield activity, parents, location
        yield from activity_nodes(
            activity.get("childActivities", []),
            parents + ((activity["title"], location),), location + ".childActivities",
        )


def correlate_warning_activities(method, activities, detail_counts):
    # This diagnostic certifies the retained four-scenario observation, not a
    # product warning allowance: two exact warnings per open, none per control.
    expected = Counter({OBSERVED_WARNING: 2}) if method in MENU_TAPS else Counter()
    if detail_counts != expected:
        raise ValueError("Diagnostic warning multiset differs from the observed open/control scenario")
    entries = list(activity_nodes(activities))
    titles = [activity["title"] for activity, _, _ in entries]
    other_markers = {title for markers in SCENARIOS.values() for title in markers} - set(SCENARIOS[method])
    if any(title in other_markers for title in titles):
        raise ValueError("Diagnostic activities contain another scenario")
    taps = [(activity, parents, path) for activity, parents, path in entries
            if activity["title"].startswith(('Tap "probe.pickupMenu"', 'Tap "probe.fixtureMenu"'))]
    tap_path = None
    if method in MENU_TAPS:
        if (len(taps) != 1 or taps[0][0]["title"] != MENU_TAPS[method] or
                not taps[0][1] or taps[0][1][-1][0] != SCENARIOS[method][0]):
            raise ValueError("Expected one exact Menu tap inside its matching open activity")
        tap_path = taps[0][2]
    elif taps:
        raise ValueError("A no-open control tapped a probe Menu")
    counts = Counter()
    matched = []
    issue_ids = set()
    for activity, parents, path in entries:
        attachments = activity.get("attachments", [])
        if not isinstance(attachments, list) or not all(isinstance(item, dict) for item in attachments):
            raise ValueError("Invalid diagnostic activity attachments")
        issue_attachments = [item for item in attachments if item.get("name") == "Complete Issue Description.txt"]
        issue_child = any(child["title"] == "Complete Issue Description"
                          for child in activity.get("childActivities", []))
        title = activity["title"]
        if title != OBSERVED_WARNING and not issue_attachments and not issue_child:
            continue
        if title != OBSERVED_WARNING:
            raise ValueError("An unknown diagnostic issue activity was recorded")
        if activity.get("isAssociatedWithFailure") is not False or activity.get("activityType") is not None:
            raise ValueError("Diagnostic warning activity is not the observed untyped nonfailure issue")
        if len(issue_attachments) != 1 or not issue_child:
            raise ValueError("Diagnostic warning activity is missing its issue evidence")
        issue_id = issue_attachments[0].get("uuid")
        if not isinstance(issue_id, str) or not issue_id or issue_id in issue_ids:
            raise ValueError("Missing or duplicated diagnostic warning activity identity")
        issue_ids.add(issue_id)
        # Match the nearest tap, not merely an earlier Menu marker elsewhere.
        parent_taps = [(name, location) for name, location in parents if name.startswith("Tap ")]
        if not tap_path or not parent_taps or parent_taps[-1] != (MENU_TAPS[method], tap_path):
            raise ValueError("Diagnostic warning activity is outside the exact observed Menu tap")
        counts[title] += 1
        matched.append({"message": title, "activityPath": path, "issueAttachmentId": issue_id,
                        "ancestors": [name for name, _ in parents]})
    if counts != detail_counts:
        raise ValueError("Diagnostic warning activities do not match the detailed warning multiset")
    return matched


def export_activities(bundle, url):
    return json.loads(subprocess.check_output(
        ["xcrun", "xcresulttool", "get", "test-results", "activities", "--path", str(bundle),
         "--test-id", url, "--compact"],
        timeout=15,
    ))


def check_log(log, method):
    expected = f"-[{SUITE}.{SUITE} {method}]"
    if re.search(r"(?im)^\s*Restarting after\b|^Test Case .* exceeded execution time allowance\b", log):
        raise ValueError("XCTest reported an implicit restart or execution timeout")
    starts = re.findall(r"(?m)^Test Case '([^'\r\n]+)' started\.[ \t]*\r?$", log)
    terminals = re.findall(r"(?m)^Test Case '([^'\r\n]+)' (passed|failed|skipped) \(", log)
    if starts != [expected] or terminals != [(expected, "passed")]:
        raise ValueError("Expected exactly one log start and one passing terminal result for the selected scenario")


def main(evidence, method, simulator_id, commit):
    markers = SCENARIOS[method]
    provenance = json.loads((evidence / "input-provenance.json").read_text())
    if (not re.fullmatch(r"[a-f0-9]{40}", commit) or provenance["commit"] != commit or
            not re.fullmatch(r"[0-9]+", provenance["buildArtifactId"]) or
            any(not re.fullmatch(r"[a-f0-9]{64}", provenance[key])
                for key in ("buildArtifactZIPSHA256", "productsTarSHA256", "sourceTarSHA256"))):
        raise ValueError("Missing verified diagnostic build provenance")
    product_identities = (evidence / "product-sha256.txt").read_text().splitlines()
    if len(product_identities) != 5 or any(not re.fullmatch(r"[a-f0-9]{64}  .+", row) for row in product_identities):
        raise ValueError("Missing diagnostic binary identities")
    if (evidence / "toolchain.txt").read_text().strip() != "Xcode 26.3\nBuild version 17C529":
        raise ValueError("The result is outside the pinned Xcode 26.3 toolchain")
    summary = json.loads((evidence / "test-summary.json").read_text())
    nodes = json.loads((evidence / "test-tree.json").read_text())["testNodes"]
    bundle = evidence / "MenuDiagnostic.xcresult"
    (selector, node), = test_cases(nodes)
    if selector != f"{SUITE}/{SUITE}/{method}":
        raise ValueError("The result does not contain the exact selected diagnostic scenario")
    configuration, = summary["devicesAndConfigurations"]
    device = configuration["device"]
    if (configuration["testPlanConfiguration"]["configurationName"] != "Test Scheme Action" or
            device["deviceId"] != simulator_id or
            any(device.get(key) != value for key, value in OBSERVED_DEVICE.items())):
        raise ValueError("The result is outside the selected iPhone 17/iOS 26.2 (23C54) environment")
    url = node["nodeIdentifierURL"]
    details = export_test_details(bundle, url)
    activities = export_activities(bundle, url)
    (evidence / f"{method}-details.json").write_text(json.dumps(details, indent=2) + "\n")
    (evidence / f"{method}-activities.json").write_text(json.dumps(activities, indent=2) + "\n")
    detail_device, = details["testRuns"]
    detail_configuration, = detail_device["children"]
    if (details["testIdentifierURL"] != url or details["devices"] != [device] or
            details["testResult"] != "Passed" or
            details["testPlanConfigurations"] != [configuration["testPlanConfiguration"]] or
            detail_device["nodeType"] != "Device" or detail_device["nodeIdentifier"] != simulator_id or
            detail_device["result"] != "Passed" or
            detail_configuration["nodeType"] != "Test Plan Configuration" or
            detail_configuration["result"] != "Passed" or
            # Xcode 26.3 omits this optional URL on configuration nodes; the
            # outer test URL and exact device/configuration IDs remain required.
            ("nodeIdentifierURL" in detail_configuration and detail_configuration["nodeIdentifierURL"] != url) or
            detail_configuration["nodeIdentifier"] != configuration["testPlanConfiguration"]["configurationId"]):
        raise ValueError(f"Unexpected diagnostic test detail identity for {method}")
    run, = activities["testRuns"]
    if (activities["testIdentifierURL"] != url or run["device"] != device or
            run["testPlanConfiguration"] != configuration["testPlanConfiguration"]):
        raise ValueError(f"Unexpected diagnostic activity run identity for {method}")

    log = (evidence / "XCTest.log").read_bytes()
    check_log(log.decode(), method)
    if ((evidence / "xcodebuild-status.txt").read_text().strip() != "0" or node["result"] != "Passed" or
            summary["result"] != "Passed" or summary["totalTestCount"] != 1 or summary["passedTests"] != 1 or
            any(summary[field] for field in ("failedTests", "skippedTests", "expectedFailures"))):
        raise ValueError("The isolated diagnostic scenario must pass once")
    titles = list(activity_titles(run["activities"]))
    if any(titles.count(marker) != 1 for marker in markers) or sorted(markers, key=titles.index) != markers:
        raise ValueError(f"Unexpected diagnostic activity sequence for {method}")

    detail_counts = Counter(warning_names(result_nodes(details["testRuns"])))
    warning_report = inspect_runtime_warnings(summary, nodes, [(selector, node)], {url: details}.__getitem__)
    verified_counts = Counter({row["message"]: row["count"] for row in warning_report["warnings"]})
    if detail_counts != verified_counts:
        raise ValueError("Diagnostic warning details disagree with the summary and test tree")
    warning_activities = correlate_warning_activities(method, run["activities"], verified_counts)
    exact_warnings = verified_counts[OBSERVED_WARNING]
    result = {
        "selector": selector, "device": device, "activities": markers,
        "exactReparentingWarnings": exact_warnings, "warningEvidence": warning_report,
        "warningActivities": warning_activities,
        "inputProvenance": provenance, "productIdentities": product_identities,
        "xctestLogSHA256": hashlib.sha256(log).hexdigest(),
    }
    (evidence / "diagnostic.json").write_text(json.dumps(result, indent=2) + "\n")
    print(f"{method} recorded {exact_warnings} exact _UIReparentingView warnings.")


if __name__ == "__main__":
    main(Path(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4])
