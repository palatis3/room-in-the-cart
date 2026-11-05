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


def activity_titles(activities):
    for activity in activities:
        yield activity["title"]
        yield from activity_titles(activity.get("childActivities", []))


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
            detail_configuration["nodeType"] != "Test Plan Configuration" or
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
    exact_warnings = verified_counts[OBSERVED_WARNING]
    result = {
        "selector": selector, "device": device, "activities": markers,
        "exactReparentingWarnings": exact_warnings, "warningEvidence": warning_report,
        "inputProvenance": provenance, "productIdentities": product_identities,
        "xctestLogSHA256": hashlib.sha256(log).hexdigest(),
    }
    (evidence / "diagnostic.json").write_text(json.dumps(result, indent=2) + "\n")
    print(f"{method} recorded {exact_warnings} exact _UIReparentingView warnings.")


if __name__ == "__main__":
    main(Path(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4])
