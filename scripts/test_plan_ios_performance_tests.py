from pathlib import Path
import io
import itertools
import os
import tempfile
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


class FreshPerformanceWorkflowTests(unittest.TestCase):
    def setUp(self):
        self.text = (Path(__file__).resolve().parents[1] / '.github/workflows/ios-performance.yml').read_text()
        self.plan = self.text[self.text.index('  performance-plan:'):self.text.index('  performance-build:')]
        self.build = self.text[self.text.index('  performance-build:'):self.text.index('  performance-tests:')]
        self.consumer = self.text[self.text.index('  performance-tests:'):]

    def test_fresh_pilot_admission_executes_actual_linux_guard(self):
        start = self.plan.index('          if [[ "${{ inputs.fresh_performance_simulator }}" == true ]]; then')
        guard = self.plan[start:self.plan.index('          fi', start) + len('          fi')]
        for event, case, enforce, capture, preflight in itertools.product(
                ('workflow_dispatch', 'pull_request', 'workflow_call'),
                ('scroll', 'all', 'launch', 'rendered'), ('false', 'true'),
                ('false', 'true'), ('false', 'true')):
            expected = event == 'workflow_dispatch' and case == 'scroll' and enforce == capture == preflight == 'false'
            replacements = {'inputs.fresh_performance_simulator': 'true', 'github.event_name': event,
                            'inputs.case': case, 'inputs.capture_scroll_signposts': capture,
                            'inputs.capture_preflight_only': preflight}
            code = guard
            for key, value in replacements.items(): code = code.replace('${{ ' + key + ' }}', value)
            with self.subTest(**replacements, enforce=enforce):
                result = subprocess.run(['bash', '-e', '-c', code],
                                        env=dict(os.environ, ENFORCE_BASELINES=enforce), timeout=10)
                self.assertEqual(result.returncode, 0 if expected else 1)
        # Absent/false opt-in does not alter ordinary PR or reusable-call admission.
        for disabled in ('', 'false'):
            code = guard.replace('${{ inputs.fresh_performance_simulator }}', disabled)
            code = code.replace('${{ github.event_name }}', 'workflow_call').replace('${{ inputs.case }}', 'all')
            code = code.replace('${{ inputs.capture_scroll_signposts }}', '').replace('${{ inputs.capture_preflight_only }}', '')
            self.assertEqual(subprocess.run(['bash', '-e', '-c', code],
                             env=dict(os.environ, ENFORCE_BASELINES='true'), timeout=10).returncode, 0)

    def test_fresh_selector_default_and_failure_have_no_fallback(self):
        block = self.consumer[self.consumer.index('      - name: Select an iPhone simulator'):
                              self.consumer.index('      - name: Reject runner environment drift')]
        self.assertIn('timeout-minutes: 8', block)
        shell = block.split('        run: |\n', 1)[1]
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            for name, source in {
                'xcrun': '#!/bin/sh\nprintf \'{"devices":{}}\\n\'\n',
                'python3': '#!/bin/sh\ncat >/dev/null\nprintf "%s\\n" "$@" >> "$CAPTURE"\nexit "${SELECTOR_EXIT:-0}"\n',
            }.items():
                executable = folder / name
                executable.write_text(source); executable.chmod(0o755)
            for enabled, status in itertools.product(('', 'false', 'true'), (0, 17)):
                capture = folder / 'args'; capture.write_text('')
                code = shell.replace('${{ inputs.fresh_performance_simulator }}', enabled)
                result = subprocess.run(['bash', '-eo', 'pipefail', '-c', code],
                    env=dict(os.environ, PATH=str(folder) + ':/usr/bin:/bin', CAPTURE=str(capture),
                             SELECTOR_EXIT=str(status)), capture_output=True, text=True, timeout=10)
                self.assertEqual(result.returncode, status, result.stderr)
                expected = ['scripts/select_ci_iphone.py']
                if enabled == 'true': expected += ['--create-owned', '.build/performance/test-simulator-ownership.json']
                self.assertEqual(capture.read_text().splitlines(), expected)

    def test_fresh_pilot_is_manual_disjoint_and_leaves_build_unchanged(self):
        dispatch = self.text[self.text.index('  workflow_dispatch:'):self.text.index('  workflow_call:')]
        self.assertIn('      fresh_performance_simulator:\n        description: One original scroll case on a new job-owned simulator (calibration only)\n        type: boolean\n        default: false', dispatch)
        reusable = self.text[self.text.index('  workflow_call:'):self.text.index('permissions:')]
        self.assertNotIn('fresh_performance_simulator', reusable)
        self.assertIn("${{ inputs.fresh_performance_simulator && ' · fresh simulator (diagnostic only)' || '' }}", self.text.splitlines()[1])
        self.assertIn("${{ inputs.fresh_performance_simulator && '-fresh-simulator' || '' }}", self.text)
        for forbidden in ('fresh_performance_simulator', '--create-owned', '--cleanup-owned', 'TEST_SHARD:'):
            self.assertNotIn(forbidden, self.build)
        self.assertIn('xcrun simctl list devices available -j | python3 scripts/select_ci_iphone.py\n', self.build)
        self.assertIn('python3 scripts/test_plan_ios_performance_tests.py', self.plan)
        self.assertIn('    timeout-minutes: 35\n', self.build)
        self.assertIn('    timeout-minutes: 40\n', self.consumer)
        self.assertIn('      TEST_SHARD: performance-${{ matrix.case }}', self.consumer)

    def test_owned_cleanup_follows_all_reads_is_fatal_and_receipt_is_uploaded(self):
        cleanup = self.consumer.index('      - name: Clean up the job-owned performance simulator')
        upload = self.consumer.index('      - name: Retain Release performance evidence')
        for command in ('xcresulttool export attachments', 'scripts/scroll_signpost_diagnostic.py',
                        'get_app_container', 'scripts/check_ios_performance.py'):
            self.assertLess(self.consumer.index(command), cleanup)
        block = self.consumer[cleanup:upload]
        self.assertIn('if: always() && inputs.fresh_performance_simulator', block)
        self.assertIn('timeout-minutes: 2', block)
        self.assertIn('python3 scripts/select_ci_iphone.py --cleanup-owned .build/performance/test-simulator-ownership.json', block)
        self.assertLess(block.index('require-preserved'), block.index('--cleanup-owned'))
        preserve = self.consumer.index('      - name: Preserve the attempted pilot ledger before cleanup')
        preservation = self.consumer[preserve:cleanup]
        self.assertIn('if: always() && inputs.fresh_performance_simulator', preservation)
        self.assertIn('timeout-minutes: 2', preservation)
        self.assertNotIn('continue-on-error', preservation)
        self.assertIn('scripts/preserve_performance_store.py preserve --evidence .build/performance', preservation)
        self.assertLess(self.consumer.index('scripts/check_ios_performance.py'), preserve)
        self.assertLess(self.consumer.index('mark-attempt'), self.consumer.index('\"${capture[@]}\" xcodebuild'))
        self.assertIn('python3 scripts/test_preserve_performance_store.py', self.plan)
        self.assertNotIn('continue-on-error', block)
        self.assertNotIn('||', block)
        retained = self.consumer[upload:]
        self.assertIn('if: always()', retained)
        self.assertIn('path: .build/performance/', retained)
        self.assertIn('include-hidden-files: true', retained)
        run = self.consumer[self.consumer.index('      - name: Run one Release performance case'):cleanup]
        self.assertIn('timeout-minutes: 30', run)
        self.assertIn('-default-test-execution-time-allowance 900 -maximum-test-execution-time-allowance 1200', run)


if __name__ == "__main__":
    unittest.main()
