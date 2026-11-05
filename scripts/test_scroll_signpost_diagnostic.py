import copy
import json
import unittest
from datetime import datetime, timezone

from scroll_signpost_diagnostic import SELECTOR, URL_SUFFIX, summarize


class ScrollSignpostDiagnosticTests(unittest.TestCase):
    def setUp(self):
        activities = [{"title": "Swipe down CollectionView", "startTime": 100}]
        self.lines = []
        for index in range(6):
            start = 110 + index * 10
            activities += [
                {"title": "Swipe up CollectionView", "childActivities": [
                    {"title": "Synthesize event", "startTime": start}]},
                {"title": "Checking existence", "startTime": start + 5},
            ]
            for instant, kind in [(start + 1, "begin"), (start + 3, "end")]:
                stamp = datetime.fromtimestamp(instant, timezone.utc).strftime("%Y-%m-%d %H:%M:%S.000")
                self.lines.append(
                    f"{stamp} Sp RoomInTheCart[123:abc] [com.apple.UIKit:ScrollView] "
                    f"[spid 0xab, process, {kind}] Scroll_DraggingAndDeceleration: private sample text")
        self.activity = {
            "testIdentifier": SELECTOR,
            "testIdentifierURL": "test://com.apple.xcode/RoomInTheCart" + URL_SUFFIX,
            "testRuns": [{"activities": activities}],
        }

    def report(self, lines=None, activity=None):
        return summarize("\n".join(self.lines if lines is None else lines),
                         json.dumps(self.activity if activity is None else activity), "ok", "ok")

    def test_six_complete_windows_are_diagnostic_only_and_redacted(self):
        report = self.report()
        self.assertEqual(report["status"], "captured")
        self.assertTrue(report["diagnosticOnly"])
        self.assertEqual([window["pairs"] for window in report["windows"]],
                         [[{"durationSeconds": 2.0}]] * 6)
        self.assertNotIn("private sample text", json.dumps(report))
        self.assertNotIn("0xab", json.dumps(report))
        self.assertNotIn("123", json.dumps(report))

    def test_empty_unparsed_and_mixed_malformed_capture_remain_incomplete(self):
        self.assertEqual(self.report([])["status"], "zero_events")
        malformed = "bad Scroll_DraggingAndDeceleration record"
        self.assertEqual(self.report([malformed])["status"], "unparsed_events")
        self.assertEqual(self.report(self.lines + [malformed])["status"], "unparsed_events")

    def test_extra_unmatched_duplicate_or_mixed_process_events_are_not_complete(self):
        for lines in [self.lines[:-1], [self.lines[0]] + self.lines,
                      self.lines[:2] + [self.lines[0]] + self.lines[2:],
                      [line.replace("[123:", "[456:") for line in self.lines[:2]] + self.lines[2:]]:
            with self.subTest(lines=lines):
                self.assertEqual(self.report(lines)["status"], "incomplete_windows")
        mismatched = self.lines.copy()
        mismatched[1] = mismatched[1].replace("0xab", "0xcd")
        self.assertEqual(self.report(mismatched)["status"], "incomplete_windows")

    def test_wrong_identity_or_multiple_runs_are_rejected(self):
        for update in [{"testIdentifier": "Other/testCase()"},
                       {"testIdentifierURL": "test://other/Target/testCase"},
                       {"testRuns": self.activity["testRuns"] * 2}]:
            with self.subTest(update=update):
                self.assertEqual(self.report(activity={**self.activity, **update})["status"], "parse_error")

    def test_nonfinite_reversed_and_overlapping_windows_are_rejected(self):
        for value in [float("nan"), float("inf"), True, 120, "110"]:
            activity = copy.deepcopy(self.activity)
            activity["testRuns"][0]["activities"][1]["childActivities"][0]["startTime"] = value
            with self.subTest(value=value):
                self.assertEqual(self.report(activity=activity)["status"], "parse_error")
        activity = copy.deepcopy(self.activity)
        activity["testRuns"][0]["activities"][3]["childActivities"][0]["startTime"] = 114
        self.assertEqual(self.report(activity=activity)["status"], "parse_error")

    def test_missing_or_duplicate_synthesis_and_window_count(self):
        for count in [0, 2]:
            activity = copy.deepcopy(self.activity)
            activity["testRuns"][0]["activities"][1]["childActivities"] *= count
            self.assertEqual(self.report(activity=activity)["status"], "parse_error")
        activity = copy.deepcopy(self.activity)
        activity["testRuns"][0]["activities"] = activity["testRuns"][0]["activities"][:-2]
        self.assertEqual(self.report(activity=activity)["status"], "incomplete_windows")

    def test_capture_and_activity_errors_never_become_success(self):
        for capture, activity in [("error", "ok"), ("unavailable", "ok"),
                                  ("ok", "error"), ("ok", "unavailable")]:
            report = summarize("", "", capture, activity)
            self.assertIn(report["status"], ["capture_unavailable", "activities_unavailable"])
            self.assertEqual(report["captureStatus"], capture)
            self.assertEqual(report["activityStatus"], activity)
        self.assertEqual(summarize("", "not JSON", "ok", "ok")["status"], "parse_error")


if __name__ == "__main__":
    unittest.main()
