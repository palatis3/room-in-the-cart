from pathlib import Path
import io
import subprocess
import unittest
from unittest.mock import patch

from plan_ios_performance_tests import (CLASS_PREFIX, METHODS, SUITE, UI_TARGET, performance_matrix,
                                        plan_from_binary, select_matrix, validate_request, main)


def symbol(method, effects=""):
    return f"{CLASS_PREFIX}{method}(){effects} -> ()"


COMPILED = [symbol(METHODS["launch"]), symbol(METHODS["rendered"], " throws"), symbol(METHODS["scroll"], " throws")]


class PlanIOSPerformanceTests(unittest.TestCase):
    def test_normal_and_release_selection_keeps_all_cases(self):
        full = performance_matrix("\n".join(COMPILED))
        for event in ("pull_request", "workflow_call", "workflow_dispatch", "push", ""):
            with self.subTest(event=event):
                self.assertEqual(select_matrix(full, event, ""), full)

    def test_manual_selection_preserves_selector_and_slot(self):
        full = performance_matrix("\n".join(COMPILED))
        for row in full["include"]:
            with self.subTest(case=row["case"]):
                self.assertEqual(select_matrix(full, "workflow_dispatch", row["case"]), {"include": [row]})
        self.assertEqual(len(full["include"]), 3)

    def test_selection_rejects_nonmanual_unknown_and_incomplete_inventory(self):
        for event in ("pull_request", "workflow_call", "push", "schedule", ""):
            with self.subTest(event=event), self.assertRaises(ValueError):
                validate_request(event, "scroll")
        for requested in (None, "*", "scroll\nmatrix={}", "missing"):
            with self.subTest(requested=requested), self.assertRaises(ValueError):
                validate_request("workflow_dispatch", requested)
        full = performance_matrix("\n".join(COMPILED))
        for rows in ([], full["include"][:-1], [full["include"][0]] * 3):
            with self.assertRaises(ValueError):
                select_matrix({"include": rows}, "workflow_dispatch", "launch")

    def test_linux_preflight_does_not_call_native_tools(self):
        with patch("sys.argv", ["planner", "--validate-request"]), \
                patch.dict("os.environ", {"GITHUB_EVENT_NAME": "workflow_dispatch", "REQUESTED_PERFORMANCE_CASE": "scroll"}), \
                patch("plan_ios_performance_tests.subprocess.check_output") as native, \
                patch("sys.stdout", new_callable=io.StringIO) as output:
            main()
            native.assert_not_called()
            self.assertIn('"cases": ["scroll"]', output.getvalue())

    def test_focused_cli_still_rejects_missing_unselected_compiled_case(self):
        symbols = "\n".join(COMPILED[:-1]).encode()
        with patch("sys.argv", ["planner", "fixture.xctest"]), \
                patch.dict("os.environ", {"GITHUB_EVENT_NAME": "workflow_dispatch", "REQUESTED_PERFORMANCE_CASE": "launch"}), \
                patch("plan_ios_performance_tests.subprocess.check_output", side_effect=[b"symbols", symbols]), \
                patch("sys.stderr", new_callable=io.StringIO) as error, \
                self.assertRaises(SystemExit) as result:
            main()
        self.assertEqual(result.exception.code, 1)
        self.assertIn("Missing", error.getvalue())

    def test_matrix_uses_exact_objc_tests_and_ignores_unrelated_symbols(self):
        unrelated = [COMPILED[0].removeprefix("@objc "),
                     "partial apply forwarder for closure #1 in " + COMPILED[1],
                     "@objc RoomInTheCartUITests.OtherTests.testExample() -> ()",
                     f"{CLASS_PREFIX}setUpWithError() throws -> ()"]
        plan = performance_matrix("\n".join([*reversed(COMPILED), *unrelated]))
        self.assertEqual(plan["include"], [{"case": case, "selector": f"{UI_TARGET}/{SUITE}/{method}", "macos_slot": index}
                                           for index, (case, method) in enumerate(METHODS.items())])

    def test_rejects_empty_missing_or_extra_compiled_tests(self):
        for symbols, error in (([], "Missing .*testColdLaunchPerformance"),
                               (COMPILED[:-1], "Missing .*testScrollingPerformanceOnFiveHundredItemPickup"),
                               ([*COMPILED, symbol("testFuturePerformance", " async throws")],
                                "extra .*testFuturePerformance")):
            with self.subTest(error=error), self.assertRaisesRegex(ValueError, error):
                performance_matrix("\n".join(symbols))

    def test_rejects_duplicate_or_malformed_test_thunks(self):
        for extra, error in ((COMPILED[1], "Duplicate compiled performance XCTest method"),
                             (f"{CLASS_PREFIX}testMalformed() invalid signature", "Malformed compiled performance XCTest symbol")):
            with self.subTest(error=error), self.assertRaisesRegex(ValueError, error):
                performance_matrix("\n".join([*COMPILED, extra]))

    def test_rejects_duplicate_method_declarations(self):
        with patch("plan_ios_performance_tests.METHODS", {**METHODS, "repeated": METHODS["launch"]}):
            with self.assertRaisesRegex(ValueError, "duplicate methods"):
                performance_matrix("\n".join(COMPILED))

    def test_tools_must_both_succeed(self):
        binary = Path("fixture.xctest/fixture")
        nm = ["xcrun", "nm", "-Uj", str(binary)]
        demangle = ["xcrun", "swift-demangle", "--compact"]
        with patch("plan_ios_performance_tests.subprocess.check_output", side_effect=[b"symbols", "\n".join(COMPILED).encode()]) as run:
            self.assertEqual(len(plan_from_binary(binary)["include"]), 3)
            self.assertEqual(run.call_args_list[0].args, (nm,))
            self.assertEqual(run.call_args_list[1].args, (demangle,))
            self.assertEqual(run.call_args_list[1].kwargs, {"input": b"symbols"})
        for outputs in ([subprocess.CalledProcessError(1, nm)], [b"symbols", subprocess.CalledProcessError(1, demangle)]):
            with patch("plan_ios_performance_tests.subprocess.check_output", side_effect=outputs):
                with self.assertRaises(subprocess.CalledProcessError):
                    plan_from_binary(binary)


if __name__ == "__main__":
    unittest.main()
