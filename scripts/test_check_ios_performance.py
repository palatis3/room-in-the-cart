import hashlib
import json
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from uuid import UUID

from check_ios_performance import (LAUNCH_METRIC, MEMORY_METRIC, METHODS, SCROLL_METRIC, SUITE, baseline_values, check_metrics,
                                   compare_baseline, ledger_readback, rendered_measurements)


DEVICE = "sample-simulator"
CONFIG = "1"
FIXTURE = Path(__file__).resolve().parents[1] / "ios/UITests/Fixtures/ReleaseLedger500.txt"


def case_entry(case, **fields):
    method = METHODS[case]
    return {"testIdentifier": f"{SUITE}/{method}()",
            "testIdentifierURL": f"test://com.apple.xcode/RoomInTheCart/RoomInTheCartUITests/{SUITE}/{method}",
            **fields}


def metric(identifier, unit, samples):
    return {"identifier": identifier, "displayName": identifier, "unitOfMeasurement": unit, "measurements": samples}


def measurements(case, *series):
    return [case_entry(case, testRuns=[{"device": {"deviceId": DEVICE},
                                       "testPlanConfiguration": {"configurationId": CONFIG}, "metrics": list(series)}])]


def write_json(path, value):
    path.write_text(json.dumps(value), encoding="utf-8")


def workspace(checked_count):
    shop = str(UUID(int=1))
    batch = str(UUID(int=2))
    lines = FIXTURE.read_text(encoding="utf-8").splitlines()
    rows = [{"id": str(UUID(int=1000 + index)), **({"checkedAt": 1} if index >= 500 - checked_count else {})}
            for index in range(len(lines))]
    contributions = [{"id": str(UUID(int=2000 + index)), "lineID": rows[index]["id"], "originalText": text}
                     for index, text in enumerate(lines)]
    preview = {"id": batch, "shopID": shop, "source": "paste", "originalText": FIXTURE.read_text(encoding="utf-8"),
               "lines": [{"id": row["id"], "proposedLineID": row["lineID"], "originalText": row["originalText"]}
                         for row in contributions]}
    saved = {"id": shop, "title": "Fictional weekly pickup", "lines": rows, "contributions": contributions,
             "importBatches": [{"id": batch, "preview": preview, "contributionIDs": [row["id"] for row in contributions]}]}
    return {"formatVersion": 1, "workspace": {"selectedShopID": shop, "shops": [saved]}}


def write_store(path, document, valid_digest=True):
    payload = json.dumps(document).encode()
    with sqlite3.connect(path) as database:
        database.executescript("""
            CREATE TABLE ledger_workspace (singleton, id, head_revision);
            CREATE TABLE ledger_revisions (workspace_id, revision, payload, payload_sha256);
            INSERT INTO ledger_workspace VALUES (1, 'sample', 2);
        """)
        digest = hashlib.sha256(payload).digest() if valid_digest else bytes(32)
        database.execute("INSERT INTO ledger_revisions VALUES ('sample', 2, ?, ?)", (payload, digest))


class CheckIOSPerformanceTests(unittest.TestCase):
    def test_launch_rejects_four_samples_wrong_units_and_nonfinite_values(self):
        for unit, samples in (("s", [1.0] * 4), ("ms", [1.0] * 5), ("s", [float("nan")] * 5),
                              ("s", [float("inf")] * 5), ("s", [True] * 5), ("s", [0.0] * 5)):
            with self.subTest(unit=unit, samples=samples):
                with self.assertRaises(ValueError):
                    check_metrics(measurements("launch", metric(LAUNCH_METRIC, unit, samples)), "launch", DEVICE, CONFIG)

    def test_scroll_preserves_signed_memory_delta_and_reports_missing_hitches(self):
        required = [metric(SCROLL_METRIC, "s", [2.0] * 5), metric(MEMORY_METRIC, "kB", [-16, -1, 0, 1, 2]),
                    metric(f"{MEMORY_METRIC}_absolute", "kB", [100] * 5), metric(f"{MEMORY_METRIC}_peak", "kB", [110] * 5)]
        result = check_metrics(measurements("scroll", *required), "scroll", DEVICE, CONFIG)
        self.assertEqual(result["simulatorHitches"]["status"], "unavailable")
        self.assertEqual(result["metrics"][MEMORY_METRIC]["samples"], [-16, -1, 0, 1, 2])
        with self.assertRaisesRegex(ValueError, "Missing required performance metric"):
            check_metrics(measurements("scroll", *required[:-1]), "scroll", DEVICE, CONFIG)
        with self.assertRaisesRegex(ValueError, "exactly 5 samples"):
            check_metrics(measurements("scroll", *required, metric("hitch.duration", "s", [0] * 4)), "scroll", DEVICE, CONFIG)
        for suffix in ("_absolute", "_peak"):
            with self.subTest(suffix=suffix), self.assertRaisesRegex(ValueError, "zero measurement"):
                invalid = [metric(row["identifier"], row["unitOfMeasurement"],
                                  [0] + row["measurements"][1:] if row["identifier"] == MEMORY_METRIC + suffix
                                  else row["measurements"]) for row in required]
                check_metrics(measurements("scroll", *invalid), "scroll", DEVICE, CONFIG)

    def test_rendered_requires_exact_attachments_finite_timings_and_relaunch(self):
        with tempfile.TemporaryDirectory() as folder:
            directory = Path(folder)
            file = directory / "report.json"
            ids = [str(UUID(int=1000 + index)).upper() for index in range(480, 500)]
            report = {"fixtureLineCount": 500, "sampleCount": 20, "checkedRowIDs": ids,
                      "searchToAccessibleResultMilliseconds": list(range(1, 21)), "searchP95Milliseconds": 19,
                      "checkToResultRemovalMilliseconds": [5] * 20, "checkP95Milliseconds": 5}
            functional = {
                "fixtureLineCount": 500, "unmatchedQuery": "zz-no-such-fixture-item-987654321",
                "uncheckedRowID": str(UUID(int=1000)),
                "beforeRelaunch": {"unmatchedEmpty": True, "replacementFoundUncheckedRow": True, "clearedListRestored": True},
                "afterRelaunch": {"unmatchedEmpty": True, "sameUncheckedRowFound": True, "checkedRowAbsent": True},
            }
            attachments = [{"suggestedHumanReadableName": f"{name}_0_sample{Path(filename).suffix}", "exportedFileName": filename,
                            "deviceId": DEVICE, "isAssociatedWithFailure": False}
                           for name, filename in (("rendered-500-item-pickup", file.name),
                                                  ("functional-search-500-item-pickup", "functional.json"),
                                                  ("Recently checked row after Release relaunch", "relaunch.png"))]
            write_json(directory / "manifest.json", [case_entry("rendered", attachments=attachments)])
            write_json(file, report)
            write_json(directory / "functional.json", functional)
            (directory / "relaunch.png").write_bytes(b"example screenshot")
            measurements, checked = rendered_measurements(directory, DEVICE)
            self.assertEqual(checked, {UUID(value) for value in ids})
            self.assertEqual(measurements["searchP95Milliseconds"], 19)
            self.assertEqual(measurements["functionalSearch"], functional)
            for invalid in (False, 1, None):
                with self.subTest(invalid=invalid):
                    write_json(directory / "functional.json", {
                        **functional, "beforeRelaunch": {**functional["beforeRelaunch"], "clearedListRestored": invalid}})
                    with self.assertRaisesRegex(ValueError, "Incomplete functional search assertions"):
                        rendered_measurements(directory, DEVICE)
            write_json(directory / "functional.json", {**functional, "uncheckedRowID": ids[0]})
            with self.assertRaisesRegex(ValueError, "Functional search result was checked"):
                rendered_measurements(directory, DEVICE)
            (directory / "functional.json").unlink()
            with self.assertRaisesRegex(ValueError, "Empty XCTest attachment"):
                rendered_measurements(directory, DEVICE)
            write_json(directory / "functional.json", functional)
            write_json(file, {**report, "checkP95Milliseconds": 6})
            with self.assertRaisesRegex(ValueError, "Invalid rendered pickup timing or p95"):
                rendered_measurements(directory, DEVICE)
            (directory / "relaunch.png").unlink()
            with self.assertRaisesRegex(ValueError, "Empty XCTest attachment"):
                rendered_measurements(directory, DEVICE)

    def test_readback_binds_each_pasted_line_and_checkoff_to_the_saved_head(self):
        for checked_count in (0, 20):
            with self.subTest(checked_count=checked_count), tempfile.TemporaryDirectory() as folder:
                store = Path(folder) / "ledger.sqlite"
                write_store(store, workspace(checked_count))
                ids = {UUID(int=1000 + index) for index in range(500 - checked_count, 500)}
                readback = ledger_readback(store, FIXTURE, ids)
                self.assertEqual((readback["lineCount"], readback["contributionCount"], readback["importCount"]), (500, 500, 1))
                self.assertEqual(len(readback["checkedRowIDs"]), checked_count)
                self.assertEqual(ledger_readback(store, FIXTURE, ids, UUID(int=1000)), readback)
                with self.assertRaisesRegex(ValueError, "original unchecked first fixture row"):
                    ledger_readback(store, FIXTURE, ids, UUID(int=1001))
                with self.assertRaisesRegex(ValueError, "checkoff IDs do not match"):
                    ledger_readback(store, FIXTURE, ids ^ {UUID(int=1000)})

    def test_readback_rejects_wrong_original_text_duplicate_and_bad_digest(self):
        for problem in ("paste", "contribution", "digest"):
            with self.subTest(problem=problem), tempfile.TemporaryDirectory() as folder:
                document = workspace(0)
                shop = document["workspace"]["shops"][0]
                if problem == "paste":
                    shop["importBatches"][0]["preview"]["originalText"] += "\n"
                if problem == "contribution":
                    shop["contributions"][1]["lineID"] = shop["contributions"][0]["lineID"]
                store = Path(folder) / "ledger.sqlite"
                write_store(store, document, valid_digest=problem != "digest")
                with self.assertRaisesRegex(ValueError, {"paste": "exact native paste", "contribution": "unique contribution row",
                                                         "digest": "digest does not match"}[problem]):
                    ledger_readback(store, FIXTURE, set())

    def test_baseline_requires_exact_environment_and_all_approved_values(self):
        environment = {"xcode": "Xcode 26.3\nBuild version sample", "osVersion": "26.2", "osBuildNumber": "sample-build",
                       "modelName": "iPhone 17", "architecture": "x86_64", "buildConfiguration": "Release",
                       "testConfiguration": "Test Scheme Action"}
        name = "responsiveLaunchMedianSeconds"
        baseline = {"schemaVersion": 1, "profiles": [{"environment": environment, "limits": {"launch": {name: 1.2}}}]}
        self.assertTrue(compare_baseline(baseline, environment, "launch", {name: 1.2})[name]["passed"])
        self.assertFalse(compare_baseline(baseline, environment, "launch", {name: 1.21})[name]["passed"])
        for key in environment:
            with self.subTest(key=key), self.assertRaisesRegex(ValueError, "exactly one approved baseline"):
                compare_baseline(baseline, {**environment, key: "different"}, "launch", {name: 1.2})
        with self.assertRaisesRegex(ValueError, "Incomplete approved rendered baseline"):
            compare_baseline(baseline, environment, "rendered", {"searchP95Milliseconds": 5, "checkP95Milliseconds": 5})

    def test_scroll_budget_catches_a_single_peak_without_hiding_sustained_growth(self):
        limits = {"scrollMedianSeconds": 3.25, "absoluteMemoryMedianKilobytes": 150000,
                  "peakMemoryMedianKilobytes": 155000, "maximumPeakMemoryKilobytes": 160000}
        environment = {"xcode": "fictional-test-environment"}
        baseline = {"schemaVersion": 1, "profiles": [{"environment": environment, "limits": {"scroll": limits}}]}
        for peaks, rejected in (([119000] * 4 + [161000], {"maximumPeakMemoryKilobytes"}),
                                ([156000] * 5, {"peakMemoryMedianKilobytes"}),
                                ([119000] * 4 + [160000], set())):
            with self.subTest(peaks=peaks):
                measured = check_metrics(measurements("scroll",
                    metric(SCROLL_METRIC, "s", [2.5] * 5), metric(MEMORY_METRIC, "kB", [0] * 5),
                    metric(f"{MEMORY_METRIC}_absolute", "kB", [119000] * 5),
                    metric(f"{MEMORY_METRIC}_peak", "kB", peaks)), "scroll", DEVICE, CONFIG)
                values = baseline_values({"case": "scroll", **measured})
                comparisons = compare_baseline(baseline, environment, "scroll", values)
                self.assertEqual({name for name, result in comparisons.items() if not result["passed"]}, rejected)
        del limits["maximumPeakMemoryKilobytes"]
        with self.assertRaisesRegex(ValueError, "Incomplete approved scroll baseline"):
            compare_baseline(baseline, environment, "scroll", values)

    def test_cli_calibration_and_strict_baseline_outcomes(self):
        with tempfile.TemporaryDirectory() as folder:
            directory = Path(folder)
            device = {"platform": "iOS Simulator", "deviceId": DEVICE, "osVersion": "26.2", "osBuildNumber": "sample-build",
                      "modelName": "iPhone 17", "architecture": "x86_64"}
            write_json(directory / "test-summary.json", {"devicesAndConfigurations": [{"device": device,
                "testPlanConfiguration": {"configurationId": CONFIG, "configurationName": "Test Scheme Action"}}]})
            write_json(directory / "metrics.json", measurements("launch", metric(LAUNCH_METRIC, "s", [1.0] * 5)))
            (directory / "toolchain.txt").write_text("Xcode 26.3\nBuild version sample\n")
            command = [sys.executable, str(Path(__file__).with_name("check_ios_performance.py")), "launch", "--evidence", folder]
            self.assertEqual(subprocess.run(command, capture_output=True).returncode, 0)
            result = directory / "calibration.json"
            calibration = json.loads(result.read_text())
            self.assertEqual(calibration["status"], "calibration-only")
            baseline = directory / "baseline.json"
            command.extend(["--baseline", str(baseline)])
            strict = subprocess.run(command, capture_output=True)
            self.assertEqual(strict.returncode, 1)
            self.assertIn(b"Approved performance baseline does not exist", strict.stderr)
            self.assertEqual(json.loads(result.read_text())["status"], "baseline-unavailable")
            for maximum, exit_code, status in ((1.1, 0, "baseline-passed"), (0.9, 1, "regression")):
                with self.subTest(status=status):
                    write_json(baseline, {"schemaVersion": 1, "profiles": [{"environment": calibration["environment"],
                        "limits": {"launch": {"responsiveLaunchMedianSeconds": maximum}}}]})
                    self.assertEqual(subprocess.run(command, capture_output=True).returncode, exit_code)
                    self.assertEqual(json.loads(result.read_text())["status"], status)


if __name__ == "__main__":
    unittest.main()
