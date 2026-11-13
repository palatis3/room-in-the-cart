import json
import os
from pathlib import Path
import subprocess
import sys
from tempfile import TemporaryDirectory
import unittest
from unittest.mock import patch

from report_records_media_test import METHOD, SELECTOR, SOURCE, SUITE, SHARED_METHODS, SHARED_SUITE, assertion_line, modern_location, legacy_location, combined_location, read_legacy_location


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

    def execute(self, runner_status, *options, build_workspace=""):
        result = subprocess.run(
            [sys.executable, str(SCRIPT), str(self.evidence), str(runner_status), *options],
            env={**os.environ, "RECORDS_BUILD_WORKSPACE": build_workspace},
            capture_output=True, text=True,
        )
        self.assertNotIn(PRIVATE, result.stdout + result.stderr)
        self.assertEqual(result.stderr, "")
        return result

    def write_shared(self, results=("Passed", "Passed"), *, source_path=None):
        selectors = [f"RoomInTheCartUITests/{SHARED_SUITE}/{method}" for method in SHARED_METHODS]
        plan = self.evidence / "test-plan" / f"{SHARED_SUITE}.txt"
        plan.write_text("\n".join(selectors) + "\n")
        self.write_json("test-summary.json", {
            "result": "Passed" if results.count("Passed") == 2 else "Failed",
            "totalTestCount": 2, "passedTests": results.count("Passed"), "failedTests": results.count("Failed"),
            "skippedTests": results.count("Skipped"), "expectedFailures": results.count("Expected Failure"),
            "testFailures": [{"failureText": PRIVATE}],
        })
        nodes = []
        for i, (selector, result) in enumerate(zip(selectors, results)):
            nodes.append({
                "nodeType": "Test Case", "nodeIdentifierURL": "test://com.apple.xcode/RoomInTheCart/" + selector,
                "result": result, "name": PRIVATE, "children": [{
                    "nodeType": "Failure Message", "name": PRIVATE,
                    "sourceLocation": {"filePath": source_path, "lineNumber": 31 + i},
                }],
            })
        self.write_json("test-details.json", {"testNodes": list(reversed(nodes))})
        self.write_json("test-runtime-warnings.json", {
            "status": "passed", "examinedTestCount": 2, "runtimeWarningCount": 0, "warnings": [PRIVATE],
        })
        return selectors

    def test_shared_records_both_methods_and_compiler_source_path(self):
        relative = Path("ios/UITests/SharedRecordsUITests.swift")
        build_root = self.evidence / PRIVATE
        for results, runner_status, expected_status in [
            (("Passed", "Passed"), 0, 0), (("Passed", "Passed"), 7, 1),
            (("Passed", "Failed"), 0, 1), (("Failed", "Failed"), 1, 1),
            (("Skipped", "Expected Failure"), 0, 1),
        ]:
            with self.subTest(results=results, runner_status=runner_status):
                selectors = self.write_shared(results, source_path=str(build_root / relative))
                result = self.execute(runner_status, SHARED_SUITE, build_workspace=str(build_root))
                self.assertEqual(result.returncode, expected_status)
                for i, (selector, outcome) in enumerate(zip(selectors, results)):
                    self.assertIn(f"| `{selector}` | {outcome} |", result.stdout)
                    location = f"Failure location for `{SHARED_METHODS[i]}` `{relative}:{31 + i}`"
                    self.assertEqual(location in result.stdout, outcome == "Failed")

    def test_foreign_build_root_cannot_supply_shared_source_line(self):
        selector = self.write_shared(("Failed", "Passed"), source_path=f"/{PRIVATE}/ios/UITests/{SHARED_SUITE}.swift")[0]
        result = self.execute(1, SHARED_SUITE, build_workspace=str(self.evidence))
        self.assertEqual(result.returncode, 1)
        self.assertIn(f"| `{selector}` | Failed |", result.stdout)
        self.assertNotIn("Failure location", result.stdout)

    def test_shared_legacy_locations_are_scoped_to_each_method(self):
        source = SCRIPT.resolve().parents[1] / "ios" / "UITests" / f"{SHARED_SUITE}.swift"
        issues = []
        for index, method in enumerate(SHARED_METHODS):
            number = str(30 + index)
            issues.append({
                "testCaseName": {"_value": f"{SHARED_SUITE}.{method}()"},
                "documentLocationInCreatingWorkspace": {"url": {"_value":
                    f"{source.as_uri()}#StartingLineNumber={number}&EndingLineNumber={number}"}},
                "message": PRIVATE,
            })
        legacy = {"issues": {"testFailureSummaries": {"_values": issues}}}
        for index, method in enumerate(SHARED_METHODS):
            self.assertEqual(legacy_location(legacy, source, 100, f"{SHARED_SUITE}.{method}()"), ("valid", 31 + index))

    def test_shared_warning_failures_preserve_results_and_fail_verification(self):
        selectors = self.write_shared()
        for warnings, text in [
            ({"status": PRIVATE, "error": PRIVATE}, "Runtime warning verification unavailable."),
            ({"status": "unexpected-warnings", "runtimeWarningCount": 3, "examinedTestCount": 2, "warnings": [PRIVATE]},
             "Runtime warnings across both tests: 3."),
        ]:
            self.write_json("test-runtime-warnings.json", warnings)
            result = self.execute(0, SHARED_SUITE)
            self.assertEqual(result.returncode, 1)
            self.assertIn(text, result.stdout)
            for selector in selectors:
                self.assertIn(f"| `{selector}` | Passed |", result.stdout)

    def test_shared_inconsistent_evidence_fails_closed(self):
        for problem in ("missing", "duplicate", "unknown", "counts", "plan"):
            with self.subTest(problem=problem):
                self.write_shared()
                details = self.evidence / "test-details.json"
                nodes = json.loads(details.read_text())["testNodes"]
                if problem == "missing":
                    nodes.pop()
                elif problem == "duplicate":
                    nodes[1] = nodes[0]
                elif problem == "unknown":
                    nodes[0]["nodeIdentifierURL"] = PRIVATE
                elif problem == "counts":
                    summary = self.evidence / "test-summary.json"
                    self.write_json(summary.name, {**json.loads(summary.read_text()), "failedTests": 1})
                elif problem == "plan":
                    (self.evidence / "test-plan" / f"{SHARED_SUITE}.txt").write_text(PRIVATE)
                self.write_json(details.name, {"testNodes": nodes})
                result = self.execute(0, SHARED_SUITE)
                self.assertEqual(result.returncode, 1)
                self.assertEqual(result.stdout, "Shared Records verification failed. Structured evidence was unavailable or invalid.\n")
        self.assertEqual(self.execute(0, PRIVATE).returncode, 1)

    def test_modern_location_strict_and_private(self):
        source = (SCRIPT.resolve().parents[1] / SOURCE).resolve()
        def case(locations):
            return {"children": [{"nodeType": "Failure Message", "sourceLocation": x, "name": PRIVATE} for x in locations], "private": PRIVATE}
        valid = {"filePath": str(source), "lineNumber": 21, "message": PRIVATE}
        self.assertEqual(modern_location(case([valid, valid]), source, 100), ("valid", 21))
        self.assertEqual(modern_location(case([]), source, 100), ("missing", None))
        for bad in [
            {"filePath": str(source.parent / ".." / source.parent.name / source.name), "lineNumber": 21},
            {"filePath": str(source) + PRIVATE, "lineNumber": 21},
            {"filePath": str(source), "lineNumber": True},
            {"filePath": str(source), "lineNumber": 0},
            {"filePath": str(source), "lineNumber": 101},
            {"filePath": str(source), "lineNumber": "21"},
            None,
        ]:
            with self.subTest(bad=bad):
                self.assertEqual(modern_location(case([valid, bad]), source, 100), ("invalid", None))
        self.assertEqual(modern_location(case([valid, {**valid, "lineNumber": 22}]), source, 100), ("invalid", None))
        self.assertEqual(modern_location({"children": PRIVATE}, source, 100), ("invalid", None))
        # Do not descend into untrusted nested content or arbitrary node types.
        self.assertEqual(modern_location({"children": [{"nodeType": "other", "children": case([valid])["children"]}]}, source, 100), ("missing", None))

    def test_combination_never_falls_back_from_invalid_or_conflict(self):
        V, M, I = ("valid", 21), ("missing", None), ("invalid", None)
        self.assertEqual(combined_location(V, M), 21)
        self.assertEqual(combined_location(V, V), 21)
        for pair in [(V, I), (I, V), (V, ("valid", 22)), (M, M), (I, M)]:
            self.assertIsNone(combined_location(*pair))

    def test_legacy_invalid_missing_and_ambiguous(self):
        source = (SCRIPT.resolve().parents[1] / SOURCE).resolve()
        def issue(url, name=f"{SUITE}.{METHOD}()"):
            return {"testCaseName": {"_value": name}, "documentLocationInCreatingWorkspace": {"url": {"_value": url}}, "message": PRIVATE}
        def bundle(items): return {"issues": {"testFailureSummaries": {"_values": items}}}
        base = source.as_uri() + "#StartingLineNumber=20&EndingLineNumber=20"
        self.assertEqual(legacy_location(bundle([]), source, 100), ("missing", None))
        self.assertEqual(legacy_location(bundle([issue(base), issue(base)]), source, 100), ("valid", 21))
        for items in [[issue(base), issue(base.replace("20", "21"))], [issue(base + "&private=" + PRIVATE)],
                      [issue(base.replace("/ios/", "/%69os/" ).replace("%69os", "%2Fios"))],
                      [issue(base.replace("EndingLineNumber=20", "EndingLineNumber=21"))],
                      [issue(base.replace("20", "1000"))]]:
            self.assertEqual(legacy_location(bundle(items), source, 100), ("invalid", None))
        self.assertEqual(legacy_location(bundle([issue(base, PRIVATE)]), source, 100), ("missing", None))
        self.assertEqual(legacy_location({"issues": PRIVATE}, source, 100), ("invalid", None))

    def test_legacy_timeout_prevents_modern_fallback(self):
        source = (SCRIPT.resolve().parents[1] / SOURCE).resolve()
        (self.evidence / "Tests.xcresult").mkdir()
        with patch("report_records_media_test.subprocess.check_output", side_effect=subprocess.TimeoutExpired("xcrun", 5)):
            legacy = read_legacy_location(self.evidence, source, 100)
        self.assertEqual(legacy, ("invalid", None))
        self.assertIsNone(combined_location(("valid", 21), legacy))

    def test_expanded_modern_and_legacy_negative_paths(self):
        source = (SCRIPT.resolve().parents[1] / SOURCE).resolve()
        alias = self.evidence / "alias.swift"
        alias.symlink_to(source)
        def case(path, line=21):
            return {"children": [{"nodeType": "Failure Message", "sourceLocation": {"filePath": path, "lineNumber": line}, "secret": PRIVATE}]}
        for path in (str(alias), str(source).replace("/ios/", "/%69os/"), "/foreign/ios/UITests/RecordsMediaUITests.swift"):
            self.assertEqual(modern_location(case(path), source, 100), ("invalid", None))
        for line in (-1, 2.0, float("inf")):
            self.assertEqual(modern_location(case(str(source), line), source, 100), ("invalid", None))
        for children in ([PRIVATE], [None], {"unexpected": PRIVATE}):
            self.assertEqual(modern_location({"children": children}, source, 100), ("invalid", None))
        def wrap(url):
            return {"issues": {"testFailureSummaries": {"_values": [{"testCaseName": {"_value": f"{SUITE}.{METHOD}()"},
                "documentLocationInCreatingWorkspace": {"url": {"_value": url}}, "message": PRIVATE}]}}}
        base = source.as_uri() + "#StartingLineNumber=20&EndingLineNumber=20"
        self.assertEqual(legacy_location(wrap(base + "&StartingLineNumber=20"), source, 100), ("invalid", None))
        self.assertEqual(legacy_location({"issues": {"testFailureSummaries": {"_values": [None]}}}, source, 100), ("invalid", None))

    def test_wrong_selector_with_valid_location_cannot_publish_or_pass(self):
        self.write_evidence(result="Failed", identifier=PRIVATE)
        source = (SCRIPT.resolve().parents[1] / SOURCE).resolve()
        self.write_json("test-details.json", {"testNodes": [{"nodeType": "Test Case",
            "nodeIdentifierURL": "test://com.apple.xcode/RoomInTheCart/" + PRIVATE,
            "result": "Failed", "children": [{"nodeType": "Failure Message", "name": PRIVATE,
                "sourceLocation": {"filePath": str(source), "lineNumber": 21}}]}]})
        result = self.execute(0)
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout, "Records Media verification failed. Structured evidence was unavailable or invalid.\n")
        self.assertNotIn(str(source), result.stdout + result.stderr)
        self.assertNotIn("Failure location", result.stdout)

    def test_end_to_end_failure_location_does_not_leak_dynamic_fields(self):
        self.write_evidence(result="Failed")
        source = (SCRIPT.resolve().parents[1] / SOURCE).resolve()
        self.write_json("test-details.json", {"testNodes": [{"nodeType": "Test Case",
            "nodeIdentifierURL": "test://com.apple.xcode/RoomInTheCart/" + SELECTOR,
            "result": "Failed", "children": [{"nodeType": "Failure Message", "name": PRIVATE,
                "sourceLocation": {"filePath": str(source), "lineNumber": 21, "message": PRIVATE}}]}], "private": PRIVATE})
        result = self.execute(1)
        self.assertEqual(result.returncode, 1)
        self.assertIn(f"Failure location `{SOURCE}:21`", result.stdout)
        self.assertNotIn(str(source), result.stdout)

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
