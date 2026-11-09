import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

from report_ios_test_timing import summarize

ROOT = Path(__file__).resolve().parents[1]
LOG = """Test Suite 'Selected tests' started at 2026-11-09 13:14:03.078.
Test Suite 'Inner' started at 2026-11-09 13:14:03.079.
Test Suite 'Inner' failed at 2026-11-09 13:19:48.061.
Test Suite 'Selected tests' failed at 2026-11-09 13:19:48.063.
\t Executed 8 tests, with 2 failures (0 unexpected) in 344.971 (344.985) seconds
2026-11-09 13:29:48.384 xcodebuild[65529:29493094]  IDETestOperationsObserverDebug: Failure collecting diagnostics from simulator: Timed out after 600.0 seconds while waiting for a response from the invoked process
2026-11-09 13:29:48.398 xcodebuild[65529:29490295] [MT] IDETestOperationsObserverDebug: 952.116 elapsed -- Testing started completed.
"""


class NativeTimingTests(unittest.TestCase):
    def test_completed_failure_separates_tests_from_post_suite_work(self):
        result = summarize(LOG)
        self.assertEqual(result["rootSuite"]["outcome"], "failed")
        self.assertEqual(result["suiteWallSeconds"], 344.985)
        self.assertEqual(result["reportedCaseSeconds"], 344.971)
        self.assertEqual(result["reportedCaseCount"], 8)
        self.assertEqual(result["postSuiteObserverSeconds"], 600.335)
        self.assertEqual(result["observerElapsedSeconds"], 952.116)
        self.assertEqual(result["diagnosticTimeoutSeconds"], [600.0])
        self.assertTrue(result["observationOnly"])

    def test_all_tests_and_success_are_observed_without_reclassifying(self):
        result = summarize(LOG.replace("Selected tests", "All tests").replace("failed at", "passed at"))
        self.assertEqual(result["rootSuite"]["outcome"], "passed")
        self.assertEqual(result["postSuiteObserverSeconds"], 600.335)
        self.assertNotIn("accepted", result)

    def test_crash_restart_or_missing_root_remains_unknown(self):
        for log in ("", LOG.split("Test Suite 'Selected tests' failed")[0], LOG + LOG,
                    LOG.replace("Selected tests' failed", "All tests' failed")):
            with self.subTest(log=log[:80]):
                result = summarize(log)
                self.assertIsNone(result["suiteWallSeconds"])
                self.assertIsNone(result["postSuiteObserverSeconds"])

    def test_missing_or_duplicate_observer_does_not_guess_tail(self):
        for log in ("\n".join(LOG.splitlines()[:-1]), LOG + LOG.splitlines()[-1] + "\n"):
            result = summarize(log)
            self.assertEqual(result["suiteWallSeconds"], 344.985)
            self.assertIsNone(result["postSuiteObserverSeconds"])

    def test_clock_inconsistency_is_unknown(self):
        for log in (LOG.replace("13:14:03.078", "13:24:03.078"),
                    LOG.replace("13:29:48.398", "13:19:47.398"),
                    LOG.replace("952.116 elapsed", "12.000 elapsed")):
            self.assertIsNone(summarize(log)["postSuiteObserverSeconds"])

    def test_receipt_binds_bytes_and_does_not_replace_first_evidence(self):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            log, output = base / "native.log", base / "timing.json"
            log.write_text(LOG)
            command = [sys.executable, str(ROOT / "scripts/report_ios_test_timing.py"),
                       "--test-log", str(log), "--output", str(output)]
            first = subprocess.run(command, capture_output=True, text=True)
            self.assertEqual(first.returncode, 0, first.stderr)
            saved = output.read_bytes()
            self.assertEqual(json.loads(saved)["testLogSHA256"], hashlib.sha256(log.read_bytes()).hexdigest())
            self.assertNotEqual(subprocess.run(command, capture_output=True).returncode, 0)
            self.assertEqual(output.read_bytes(), saved)


if __name__ == "__main__":
    unittest.main()
