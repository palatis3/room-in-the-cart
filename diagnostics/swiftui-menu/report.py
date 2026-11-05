#!/usr/bin/env python3
"""Check the diagnostic scenarios and retain exact warning occurrences."""

from collections import Counter
import json
from pathlib import Path
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


def main(evidence):
    summary = json.loads((evidence / "test-summary.json").read_text())
    nodes = json.loads((evidence / "test-tree.json").read_text())["testNodes"]
    bundle = evidence / "MenuDiagnostic.xcresult"
    cases = list(test_cases(nodes))
    expected = {f"{SUITE}/{SUITE}/{method}" for method in SCENARIOS}
    count = len(expected)
    if (len(cases) != count or {selector for selector, _ in cases} != expected or
            any(node["result"] != "Passed" for _, node in cases) or
            summary["result"] != "Passed" or summary["totalTestCount"] != count or summary["passedTests"] != count or
            any(summary[field] for field in ("failedTests", "skippedTests", "expectedFailures"))):
        raise ValueError("The exact diagnostic scenarios must pass")
    configuration, = summary["devicesAndConfigurations"]
    if any(configuration["device"].get(key) != value for key, value in OBSERVED_DEVICE.items()):
        raise ValueError("The result is outside the pinned iPhone 17/iOS 26.2 (23C54) environment")

    details_by_url = {}
    detail_counts = Counter()
    scenarios = {}
    for selector, node in cases:
        method = selector.rsplit("/", 1)[-1]
        url = node["nodeIdentifierURL"]
        details_by_url[url] = details = export_test_details(bundle, url)
        activities = export_activities(bundle, url)
        (evidence / f"{method}-details.json").write_text(json.dumps(details, indent=2) + "\n")
        (evidence / f"{method}-activities.json").write_text(json.dumps(activities, indent=2) + "\n")
        if details["testIdentifierURL"] != url or details["devices"] != [configuration["device"]]:
            raise ValueError(f"Unexpected diagnostic test detail identity for {method}")
        if len(details["testRuns"]) != 1:
            raise ValueError(f"Unexpected diagnostic test detail run count for {method}")
        detail_counts.update((selector, message) for message in warning_names(result_nodes(details["testRuns"])))
        run, = activities["testRuns"]
        if (activities["testIdentifierURL"] != url or run["device"] != configuration["device"] or
                run["testPlanConfiguration"] != configuration["testPlanConfiguration"]):
            raise ValueError(f"Unexpected diagnostic activity run identity for {method}")
        titles = list(activity_titles(run["activities"]))
        markers = SCENARIOS[method]
        if any(titles.count(marker) != 1 for marker in markers) or list(sorted(markers, key=titles.index)) != markers:
            raise ValueError(f"Unexpected diagnostic activity sequence for {method}")
        scenarios[method] = {"activities": markers, "exactReparentingWarnings": 0}

    warning_report = inspect_runtime_warnings(summary, nodes, cases, details_by_url.__getitem__)
    verified_counts = Counter({
        (row["selector"], row["message"]): row["count"] for row in warning_report["warnings"]
    })
    if detail_counts != verified_counts:
        raise ValueError("Diagnostic warning details disagree with the summary and test tree")
    for warning in warning_report["warnings"]:
        if warning["message"] == OBSERVED_WARNING:
            method = warning["selector"].rsplit("/", 1)[-1]
            scenarios[method]["exactReparentingWarnings"] += warning["count"]
    result = {"device": configuration["device"], "scenarios": scenarios, "warningEvidence": warning_report}
    (evidence / "diagnostic.json").write_text(json.dumps(result, indent=2) + "\n")
    for method, scenario in scenarios.items():
        print(f"{method} recorded {scenario['exactReparentingWarnings']} exact _UIReparentingView warnings.")


if __name__ == "__main__":
    main(Path(sys.argv[1]))
