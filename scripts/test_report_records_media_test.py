import json
from pathlib import Path
import subprocess
import sys
from tempfile import TemporaryDirectory
import unittest

from report_records_media_test import METHOD, SELECTOR, SOURCE, SUITE, assertion_line


SCRIPT = Path(__file__).with_name("report_records_media_test.py")
PRIVATE = "private synthetic phrase that must never be published"


class RecordsMediaReportTests(unittest.TestCase):
    def setUp(self):
        directory = TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.evidence = Path(directory.name)
        (self.evidence / "test-plan").mkdir()
        (self.evidence / "test-plan" / f"{SUITE}.txt").write_text(SELECTOR + "\n")

    def write_evidence(self, *, result="Passed", warning_status="passed", warning_count=0, identifier=SELECTOR):
        summary = {
            "result": result,
            "totalTestCount": 1,
            "passedTests": int(result == "Passed"),
            "failedTests": int(result == "Failed"),
            "skippedTests": 0,
            "expectedFailures": 0,
            "testFailures": [{"failureText": PRIVATE}],
        }
        self.write_json("test-summary.json", summary)
        self.write_json("test-details.json", {"testNodes": [{
            "nodeType": "Test Case",
            "nodeIdentifierURL": "test://com.apple.xcode/RoomInTheCart/" + identifier,
            "result": result,
            "children": [{"name": PRIVATE}],
        }]})
        self.write_json("test-runtime-warnings.json", {
            "status": warning_status,
            "runtimeWarningCount": warning_count,
            "examinedTestCount": 1,
            "warnings": [{"selector": PRIVATE, "message": PRIVATE}],
            "error": PRIVATE,
        })

    def write_json(self, filename, data):
        (self.evidence / filename).write_text(json.dumps(data))

    def execute(self, runner_status):
        result = subprocess.run(
            [sys.executable, str(SCRIPT), str(self.evidence), str(runner_status)],
            capture_output=True, text=True,
        )
        self.assertNotIn(PRIVATE, result.stdout + result.stderr)
        self.assertEqual(result.stderr, "")
        return result

    def test_passing_report_contains_only_known_fields(self):
        self.write_evidence()
        result = self.execute(0)
        self.assertEqual(result.returncode, 0)
        self.assertIn("verification **passed**", result.stdout)
        self.assertIn(f"`{SELECTOR}` | Passed | 1 | 1 | 0 | 0 | 0 | 0 |", result.stdout)

    def test_warning_and_failure_messages_stay_private_and_fail(self):
        self.write_evidence(result="Failed", warning_status="unexpected-warnings", warning_count=3)
        result = self.execute(1)
        self.assertEqual(result.returncode, 1)
        self.assertIn("verification **failed**", result.stdout)
        self.assertIn(f"`{SELECTOR}` | Failed | 1 | 0 | 1 | 0 | 0 | 3 |", result.stdout)

    def test_runner_failure_cannot_turn_green_with_passing_exports(self):
        self.write_evidence()
        result = self.execute(7)
        self.assertEqual(result.returncode, 1)
        self.assertIn("verification **failed**", result.stdout)

    def test_inconsistent_warning_count_cannot_turn_green(self):
        self.write_evidence(warning_count=1)
        result = self.execute(0)
        self.assertEqual(result.returncode, 1)
        self.assertIn("Structured evidence was unavailable or invalid.", result.stdout)

    def test_missing_malformed_and_unknown_evidence_fail_with_fixed_output(self):
        for kind in ("missing", "invalid-json", "unknown-warning-status", "unknown-selector", "unknown-result"):
            with self.subTest(kind=kind):
                self.write_evidence(
                    result=PRIVATE if kind == "unknown-result" else "Passed",
                    warning_status=PRIVATE if kind == "unknown-warning-status" else "passed",
                    identifier=PRIVATE if kind == "unknown-selector" else SELECTOR,
                )
                if kind == "missing":
                    (self.evidence / "test-runtime-warnings.json").unlink()
                if kind == "invalid-json":
                    (self.evidence / "test-summary.json").write_text(PRIVATE)
                result = self.execute(0)
                self.assertEqual(result.returncode, 1)
                self.assertEqual(result.stdout, "Records Media verification failed. Structured evidence was unavailable or invalid.\n")

    def test_source_location_uses_only_the_matching_exact_file_and_valid_line(self):
        source = (SCRIPT.resolve().parents[1] / SOURCE).resolve()
        def record(url, test_name=f"{SUITE}.{METHOD}()"):
            return {"issues": {"testFailureSummaries": {"_values": [{
                "testCaseName": {"_value": test_name},
                "documentLocationInCreatingWorkspace": {"url": {"_value": url}},
                "message": {"_value": PRIVATE},
            }]}}}

        valid = source.as_uri() + "#StartingLineNumber=20&EndingLineNumber=20"
        self.assertEqual(assertion_line(record(valid), source, 100), 21)
        for invalid in (
            record(valid, PRIVATE),
            record(valid.replace(source.as_uri(), (source.parent.parent / source.name).as_uri())),
            record(valid.replace("20", "999")),
            record(valid.replace("EndingLineNumber=20", "EndingLineNumber=21")),
            record(valid + "&StartingLineNumber=21"),
            record(valid.replace("#", "?" + PRIVATE + "#")),
        ):
            with self.subTest(invalid=invalid):
                self.assertIsNone(assertion_line(invalid, source, 100))


if __name__ == "__main__":
    unittest.main()
