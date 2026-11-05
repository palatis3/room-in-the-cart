#!/usr/bin/env python3
"""Validate complete Release simulator measurements and independently read back the fictional pickup."""

import argparse
from contextlib import closing
import hashlib
import json
import math
from pathlib import Path
import sqlite3
from statistics import median
from urllib.parse import unquote, urlparse
from uuid import UUID


SUITE = "ReleasePerformanceUITests"
METHODS = {
    "launch": "testColdLaunchPerformance",
    "rendered": "testRenderedFiveHundredItemPickup",
    "scroll": "testScrollingPerformanceOnFiveHundredItemPickup",
}
LAUNCH_METRIC = "com.apple.dt.XCTMetric_ApplicationLaunch-ApplicationFirstFramePresentationResponsive.duration"
SCROLL_METRIC = "com.apple.dt.XCTMetric_OSSignpost-Scroll_DraggingAndDeceleration.duration"
MEMORY_METRIC = "com.apple.dt.XCTMetric_Memory-dev.roominthecart.app.physical"
LINE_COUNT = 500
CHECKOFF_COUNT = 20
XCTEST_ITERATIONS = 5


def require(condition, message):
    if not condition:
        raise ValueError(message)


def read_json(path):
    return json.loads(path.read_text(encoding="utf-8"))


def sample_series(values, count, name, *, minimum=None):
    require(isinstance(values, list) and len(values) == count, f"{name} requires exactly {count} samples")
    require(all(type(value) in (int, float) and math.isfinite(value) and
                (minimum is None or value >= minimum) for value in values), f"{name} contains invalid samples")
    return values


def only_case(entries, case):
    method = METHODS[case]
    expected = f"{SUITE}/{method}"
    require(isinstance(entries, list) and len(entries) == 1, f"Expected evidence from only {expected}")
    entry, = entries
    require(entry["testIdentifier"].removesuffix("()") == expected, f"Expected evidence from {expected}")
    if identifier_url := entry.get("testIdentifierURL"):
        parts = unquote(urlparse(identifier_url).path).strip("/").split("/")
        require(parts[-3:] == ["RoomInTheCartUITests", SUITE, method], "Unexpected XCTest target in evidence")
    return entry


def check_metrics(entries, case, device_id, configuration_id):
    runs = only_case(entries, case)["testRuns"]
    require(len(runs) == 1, "Expected one performance measurement run")
    run, = runs
    require(run["device"]["deviceId"] == device_id and
            run["testPlanConfiguration"]["configurationId"] == configuration_id,
            "Performance metrics came from a different simulator or test configuration")
    metrics = {row["identifier"]: row for row in run["metrics"] if row.get("identifier")}
    require(len(metrics) == sum(bool(row.get("identifier")) for row in run["metrics"]), "Duplicate performance metric identifier")
    required = {LAUNCH_METRIC: ("s", 0)} if case == "launch" else {
        SCROLL_METRIC: ("s", 0), MEMORY_METRIC: ("kB", None),
        f"{MEMORY_METRIC}_absolute": ("kB", 0), f"{MEMORY_METRIC}_peak": ("kB", 0),
    }
    report = {}
    for identifier, (unit, minimum) in required.items():
        require(identifier in metrics, f"Missing required performance metric: {identifier}")
        metric = metrics[identifier]
        require(metric["unitOfMeasurement"] == unit, f"Unexpected unit for {identifier}")
        samples = sample_series(metric["measurements"], XCTEST_ITERATIONS, identifier, minimum=minimum)
        if unit == "s":
            require(all(samples), f"{identifier} contains a zero duration")
        report[identifier] = {"unit": unit, "samples": samples, "median": median(samples)}

    result = {"metrics": report}
    if case == "scroll":
        hitch_metrics = {}
        for metric in run["metrics"]:
            name = metric.get("identifier") or metric["displayName"]
            if "hitch" not in (name + metric["displayName"]).lower():
                continue
            samples = sample_series(metric["measurements"], XCTEST_ITERATIONS, name, minimum=0)
            hitch_metrics[name] = {"unit": metric["unitOfMeasurement"], "samples": samples}
        result["simulatorHitches"] = ({"status": "measured", "metrics": hitch_metrics} if hitch_metrics else {
            "status": "unavailable",
            "detail": "XCTest emitted scroll duration and memory, but no animation hitch samples on this simulator. "
                      "This run cannot evaluate frame hitches.",
        })
    return result


def attachment(directory, manifest, name, extension, device_id):
    matches = [item for item in manifest if item["suggestedHumanReadableName"].startswith(name + "_") and
               Path(item["exportedFileName"]).suffix == extension and not item["isAssociatedWithFailure"]]
    require(len(matches) == 1, f"Missing or duplicated XCTest attachment: {name}")
    item, = matches
    filename = item["exportedFileName"]
    require(Path(filename).name == filename and item["deviceId"] == device_id, f"Invalid attachment origin: {name}")
    path = directory / filename
    require(path.is_file() and path.stat().st_size > 0, f"Empty XCTest attachment: {name}")
    return path


def rendered_measurements(directory, device_id):
    manifest = only_case(read_json(directory / "manifest.json"), "rendered")["attachments"]
    attachment(directory, manifest, "Recently checked row after Release relaunch", ".png", device_id)
    report = read_json(attachment(directory, manifest, "rendered-500-item-pickup", ".json", device_id))
    require(report["fixtureLineCount"] == LINE_COUNT and report["sampleCount"] == CHECKOFF_COUNT,
            "Unexpected fixture or timing sample count in rendered pickup evidence")
    for name, p95 in (("searchToAccessibleResultMilliseconds", "searchP95Milliseconds"),
                      ("checkToResultRemovalMilliseconds", "checkP95Milliseconds")):
        samples = sample_series(report[name], CHECKOFF_COUNT, name, minimum=0)
        rank = math.ceil(len(samples) * 0.95) - 1
        require(all(samples) and report[p95] == sorted(samples)[rank], f"Invalid rendered pickup timing or p95: {name}")
    checked = unique_ids(report["checkedRowIDs"], CHECKOFF_COUNT, "attachment checkoff")
    return report, checked


def unique_ids(values, count, name):
    require(isinstance(values, list) and all(isinstance(value, str) for value in values), f"Invalid {name} ID list")
    identifiers = {UUID(value) for value in values}
    require(len(values) == len(identifiers) == count, f"Expected {count} unique {name} IDs")
    return identifiers


def ledger_readback(store, fixture, expected_checked):
    fixture_text = fixture.read_bytes().decode("utf-8")
    fixture_lines = fixture_text.splitlines()
    require(len(fixture_lines) == len(set(fixture_lines)) == LINE_COUNT and all(fixture_lines),
            f"Expected a {LINE_COUNT}-line unique fictional fixture")
    with closing(sqlite3.connect(store.resolve().as_uri() + "?mode=ro", uri=True)) as database:
        require(database.execute("PRAGMA quick_check").fetchall() == [("ok",)], "Ledger SQLite integrity check failed")
        record = database.execute("""
            SELECT w.head_revision, r.payload, r.payload_sha256
            FROM ledger_workspace w
            JOIN ledger_revisions r ON r.workspace_id = w.id AND r.revision = w.head_revision
            WHERE w.singleton = 1
        """).fetchone()
    require(record is not None, "Ledger is missing its saved head revision")
    revision, payload, payload_hash = record
    require(hashlib.sha256(payload).digest() == payload_hash, "Ledger saved head digest does not match the payload")
    document = json.loads(payload)
    require(document["formatVersion"] == 1, "Unexpected ledger document format")
    workspace = document["workspace"]
    require(len(workspace["shops"]) == 1, "Expected one persisted pickup")
    shop, = workspace["shops"]
    require(shop["id"] == workspace["selectedShopID"] and shop["title"] == "Fictional weekly pickup",
            "The saved selection does not identify the fictional pickup")

    lines = shop["lines"]
    line_ids = unique_ids([row["id"] for row in lines], LINE_COUNT, "pickup row")
    contributions = shop["contributions"]
    contribution_ids = unique_ids([row["id"] for row in contributions], LINE_COUNT, "contribution")
    require(unique_ids([row["lineID"] for row in contributions], LINE_COUNT, "contribution row") == line_ids,
            "Each saved row must have exactly one import contribution")
    require(all(row.get("removedAt") is None for row in contributions) and
            all(row.get("trashedAt") is None and row.get("handledAt") is None for row in lines),
            "The pickup contains unexpected removals or handled items")

    batches = shop["importBatches"]
    require(len(batches) == 1, "Expected exactly one import batch")
    batch, = batches
    preview = batch["preview"]
    require(batch.get("undoneAt") is None and batch["id"] == preview["id"] and preview["shopID"] == shop["id"] and
            preview["source"] == "paste" and preview["originalText"] == fixture_text,
            "The import batch does not preserve the exact native paste fixture")
    require(unique_ids(batch["contributionIDs"], LINE_COUNT, "batch contribution") == contribution_ids,
            "Saved batch contribution IDs do not match the pickup")
    require([row["originalText"] for row in preview["lines"]] == fixture_lines and
            [row["originalText"] for row in contributions] == fixture_lines,
            "The saved import preview or contributions differ from the fixture lines")
    require([(row["id"], row["proposedLineID"]) for row in preview["lines"]] ==
            [(row["id"], row["lineID"]) for row in contributions], "Import preview IDs do not match committed contributions")

    checked = {UUID(row["id"]) for row in lines if row.get("checkedAt") is not None}
    require(checked == expected_checked, "Persisted checkoff IDs do not match XCTest evidence")
    if checked:
        require(checked == {UUID(row["lineID"]) for row in contributions[-CHECKOFF_COUNT:]},
                "The checked items are not the final twenty fixture rows")
    return {"sqliteQuickCheck": "ok", "revision": revision, "payloadSHA256": payload_hash.hex(),
            "lineCount": len(lines), "contributionCount": len(contributions), "importCount": len(batches),
            "source": preview["source"], "checkedCount": len(checked),
            "checkedRowIDs": sorted(str(identifier) for identifier in checked)}


def baseline_values(report):
    if report["case"] == "rendered":
        metrics = report["renderedMeasurements"]
        return {name: metrics[name] for name in ("searchP95Milliseconds", "checkP95Milliseconds")}
    metrics = report["metrics"]
    if report["case"] == "launch":
        return {"responsiveLaunchMedianSeconds": metrics[LAUNCH_METRIC]["median"]}
    return {"scrollMedianSeconds": metrics[SCROLL_METRIC]["median"],
            "absoluteMemoryMedianKilobytes": metrics[f"{MEMORY_METRIC}_absolute"]["median"],
            "peakMemoryMedianKilobytes": metrics[f"{MEMORY_METRIC}_peak"]["median"],
            "maximumPeakMemoryKilobytes": max(metrics[f"{MEMORY_METRIC}_peak"]["samples"])}


def compare_baseline(baseline, environment, case, values):
    require(type(baseline["schemaVersion"]) is int and baseline["schemaVersion"] == 1, "Unsupported performance baseline schema")
    matches = [entry for entry in baseline["profiles"] if entry["environment"] == environment]
    require(len(matches) == 1, "Expected exactly one approved baseline for this Xcode and simulator environment")
    limits = matches[0]["limits"].get(case)
    require(isinstance(limits, dict) and limits.keys() == values.keys(), f"Incomplete approved {case} baseline limits")
    require(all(type(limit) in (int, float) and math.isfinite(limit) and limit > 0 for limit in limits.values()),
            f"Invalid approved {case} baseline limits")
    return {name: {"measured": measured, "maximum": limits[name], "passed": measured <= limits[name]}
            for name, measured in values.items()}


def write_report(directory, report):
    (directory / "calibration.json").write_text(json.dumps(report, indent=2, allow_nan=False) + "\n", encoding="utf-8")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("case", choices=METHODS)
    parser.add_argument("--evidence", type=Path, required=True)
    parser.add_argument("--fixture", type=Path)
    parser.add_argument("--store", type=Path)
    parser.add_argument("--baseline", type=Path, help="require an approved matching baseline and enforce its maximum values")
    args = parser.parse_args()
    if args.case != "launch" and not (args.fixture and args.store):
        parser.error("pickup cases require both --fixture and --store")
    try:
        directory = args.evidence
        summary = read_json(directory / "test-summary.json")
        configuration, = summary["devicesAndConfigurations"]
        device = configuration["device"]
        require(device["platform"] == "iOS Simulator", "Expected an iOS Simulator result")
        toolchain = (directory / "toolchain.txt").read_text(encoding="utf-8").strip()
        require(toolchain.startswith("Xcode ") and "\nBuild version " in toolchain, "Missing Xcode version or build number")
        environment = {key: device[key] for key in ("osVersion", "osBuildNumber", "modelName", "architecture")}
        environment.update(xcode=toolchain, buildConfiguration="Release",
                           testConfiguration=configuration["testPlanConfiguration"]["configurationName"])
        require(all(isinstance(value, str) and value for value in environment.values()), "Incomplete simulator environment")
        report = {"case": args.case, "status": "calibration-only", "device": device, "environment": environment}
        checked = set()
        if args.case == "rendered":
            report["renderedMeasurements"], checked = rendered_measurements(directory / "attachments", device["deviceId"])
        else:
            report.update(check_metrics(read_json(directory / "metrics.json"), args.case, device["deviceId"],
                                        configuration["testPlanConfiguration"]["configurationId"]))
        if args.case != "launch":
            report["persistedPickup"] = ledger_readback(args.store, args.fixture, checked)
        report["baselineValues"] = baseline_values(report)
        if report.get("simulatorHitches", {}).get("status") == "unavailable":
            print("::warning::" + report["simulatorHitches"]["detail"])
        if args.baseline is None:
            write_report(directory, report)
            print("Complete simulator calibration evidence. No timing regression baseline was applied.")
            return
        try:
            require(args.baseline.is_file(), f"Approved performance baseline does not exist: {args.baseline}")
            comparisons = compare_baseline(read_json(args.baseline), environment, args.case, report["baselineValues"])
        except (OSError, ValueError, KeyError, TypeError) as error:
            report.update(status="baseline-unavailable", baselineError=str(error))
            write_report(directory, report)
            raise
        passed = all(comparison["passed"] for comparison in comparisons.values())
        report.update(status="baseline-passed" if passed else "regression", comparisons=comparisons)
        write_report(directory, report)
        if not passed:
            exceeded = [name for name, result in comparisons.items() if not result["passed"]]
            parser.exit(1, f"Performance regression exceeded approved limits: {', '.join(exceeded)}\n")
        print("Complete measurements passed the approved baseline for this simulator environment.")
    except (OSError, ValueError, KeyError, TypeError, sqlite3.Error) as error:
        parser.exit(1, f"Incomplete iOS performance evidence: {error}\n")


if __name__ == "__main__":
    main()
