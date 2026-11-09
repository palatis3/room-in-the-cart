from pathlib import Path
import io
import itertools
import json
import os
import shlex
import sys
import tempfile
import textwrap
import subprocess
import unittest
from unittest.mock import patch

from plan_ios_performance_tests import (CLASS_PREFIX, METHODS, SUITE, UI_TARGET, performance_matrix,
                                        plan_from_binary, select_matrix, validate_request, validate_diagnostics_request, main)


def symbol(method, effects=""):
    return f"{CLASS_PREFIX}{method}(){effects} -> ()"


COMPILED = [symbol(METHODS["launch"]), symbol(METHODS["rendered"], " throws"), symbol(METHODS["scroll"], " throws")]


class PlanIOSPerformanceTests(unittest.TestCase):
    def test_diagnostics_admission_is_manual_single_case_and_never_acceptance(self):
        for event, case, enforce, capture, preflight in itertools.product(
                ('workflow_dispatch', 'pull_request', 'workflow_call'),
                ('', 'launch', 'scroll', 'rendered'), ('false', 'true'),
                ('false', 'true'), ('false', 'true')):
            allowed = event == 'workflow_dispatch' and case in ('launch', 'scroll') and enforce == capture == preflight == 'false'
            args = (event, case, 'true', enforce, capture, preflight)
            with self.subTest(args=args):
                if allowed: validate_diagnostics_request(*args)
                else:
                    with self.assertRaises(ValueError): validate_diagnostics_request(*args)
        for enabled in ('', 'false'):
            validate_diagnostics_request('workflow_call', '', enabled, 'true', '', '')
        for enabled in ('YES', '1', None):
            with self.assertRaises(ValueError):
                validate_diagnostics_request('workflow_dispatch', 'scroll', enabled, 'false', 'false', 'false')

    def test_invalid_diagnostics_cli_rejects_before_native_inventory(self):
        with patch('sys.argv', ['planner', 'fixture.xctest']), \
                patch.dict(os.environ, {'GITHUB_EVENT_NAME': 'workflow_dispatch',
                    'REQUESTED_PERFORMANCE_CASE': 'scroll', 'ENABLE_PERFORMANCE_DIAGNOSTICS': 'true',
                    'ENFORCE_BASELINES': 'true'}, clear=True), \
                patch('plan_ios_performance_tests.subprocess.check_output') as native, \
                patch('sys.stderr', new_callable=io.StringIO), self.assertRaises(SystemExit) as result:
            main()
        self.assertEqual(result.exception.code, 1)
        native.assert_not_called()

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

    def test_diagnostics_default_is_off_and_not_a_reusable_release_input(self):
        dispatch, reusable = self.text.split('  workflow_call:', 1)
        self.assertIn('      enable_performance_diagnostics:\n        description: Collect a trace for one launch or scroll case (diagnostic only, no baseline approval)\n        type: boolean\n        default: false', dispatch)
        self.assertNotIn('enable_performance_diagnostics', reusable.split('permissions:', 1)[0])
        self.assertIn('ENABLE_PERFORMANCE_DIAGNOSTICS: ${{ inputs.enable_performance_diagnostics || false }}', self.text)
        self.assertIn('CAPTURE_SCROLL_SIGNPOSTS: ${{ inputs.capture_scroll_signposts || false }}', self.text)
        self.assertIn('CAPTURE_PREFLIGHT_ONLY: ${{ inputs.capture_preflight_only || false }}', self.text)

    def test_actual_consumer_shell_keeps_default_argv_and_diagnostic_failures(self):
        block = self.consumer.split('      - name: Run one Release performance case\n', 1)[1].split('      - name:', 1)[0]
        script = textwrap.dedent(block.split('        run: |\n', 1)[1])
        for option in ('capture_scroll_signposts', 'fresh_performance_simulator'):
            script = script.replace('${{ inputs.' + option + ' }}', 'false')
        planner = Path(__file__).resolve().with_name('plan_ios_performance_tests.py')
        selector = f'{UI_TARGET}/{SUITE}/{METHODS["scroll"]}'
        plan = '.build/DerivedData/Build/Products/RoomInTheCart-Performance_iphonesimulator27.1-arm64.xctestrun'
        expected = ['-xctestrun', plan, '-destination', 'platform=iOS Simulator,id=fixture-device',
                    '-parallel-testing-enabled', 'NO', '-test-timeouts-enabled', 'YES',
                    '-default-test-execution-time-allowance', '900', '-maximum-test-execution-time-allowance', '1200',
                    '-resultBundlePath', '.build/performance/Performance.xcresult', '-collect-test-diagnostics', 'on-failure',
                    '-only-testing:' + selector]
        for enabled, enforce, native_exit in (('false', 'true', 0), ('false', 'true', 17),
                                               ('true', 'false', 0), ('true', 'false', 17), ('true', 'true', 0)):
            with self.subTest(enabled=enabled, enforce=enforce, native_exit=native_exit), tempfile.TemporaryDirectory() as temp:
                root = Path(temp)
                (root / plan).parent.mkdir(parents=True); (root / plan).write_text('immutable-plan')
                evidence = root / '.build/performance'; evidence.mkdir(); (evidence / 'selector.txt').write_text(selector + '\n')
                for name, source in {
                    'xcodebuild': '#!/bin/sh\nprintf "%s\\0" "$@" > "$ARGUMENTS"\nprintf "native diagnostic\\n" >&2\nexit "$NATIVE_EXIT"\n',
                    'python3': '#!/bin/sh\nshift\nexec ' + shlex.quote(sys.executable) + ' ' + shlex.quote(str(planner)) + ' "$@"\n',
                }.items():
                    f = root / name; f.write_text(source); f.chmod(0o755)
                args = root / 'arguments'
                env = dict(os.environ, PATH=str(root) + os.pathsep + os.defpath, ARGUMENTS=str(args),
                           NATIVE_EXIT=str(native_exit), SIMULATOR_ID='fixture-device', ENABLE_PERFORMANCE_DIAGNOSTICS=enabled,
                           GITHUB_EVENT_NAME='workflow_dispatch', REQUESTED_PERFORMANCE_CASE='scroll', ENFORCE_BASELINES=enforce,
                           CAPTURE_SCROLL_SIGNPOSTS='false', CAPTURE_PREFLIGHT_ONLY='false')
                r = subprocess.run(['bash', '--noprofile', '--norc', '-e', '-o', 'pipefail', '-c', script],
                                   cwd=root, env=env, capture_output=True, text=True, timeout=10)
                if enabled == enforce == 'true':
                    self.assertEqual(r.returncode, 1); self.assertFalse(args.exists())
                else:
                    self.assertEqual(r.returncode, native_exit, r.stderr)
                    self.assertEqual(args.read_bytes().decode().split('\0')[:-1], expected +
                        (['-enablePerformanceTestsDiagnostics', 'YES'] if enabled == 'true' else []) + ['test-without-building'])
                    self.assertEqual((evidence / 'Performance.log').read_text(), 'native diagnostic\n')
                self.assertEqual((root / plan).read_text(), 'immutable-plan')

    def test_diagnostics_export_retains_status_and_propagates_failure(self):
        block = self.consumer.split('      - name: Export requested performance diagnostics\n', 1)[1].split('      - name:', 1)[0]
        self.assertIn('if: always() && inputs.enable_performance_diagnostics', block)
        self.assertIn('timeout-minutes: 2', block)
        self.assertNotIn('continue-on-error', block)
        script = textwrap.dedent(block.split('        run: |\n', 1)[1])
        for present, status, expected in ((True, 0, 'exported'), (True, 19, 'export_failed'), (False, 0, 'missing_result')):
            with self.subTest(present=present, status=status), tempfile.TemporaryDirectory() as temp:
                root = Path(temp); evidence = root / '.build/performance'; evidence.mkdir(parents=True)
                if present: (evidence / 'Performance.xcresult').mkdir()
                stub = root / 'xcrun'; stub.write_text('#!/bin/sh\nprintf "%s\\n" "$@" > "$ARGUMENTS"\nprintf "export diagnostic\\n" >&2\nexit "$EXPORT_EXIT"\n'); stub.chmod(0o755)
                args = root / 'arguments'
                r = subprocess.run(['bash', '-e', '-o', 'pipefail', '-c', script], cwd=root,
                    env=dict(os.environ, PATH=str(root) + os.pathsep + os.defpath, ARGUMENTS=str(args), EXPORT_EXIT=str(status)),
                    capture_output=True, text=True, timeout=10)
                self.assertEqual(r.returncode, status if present else 1)
                receipt = json.loads((evidence / 'performance-diagnostics.json').read_text())
                self.assertEqual(receipt['status'], expected); self.assertIs(receipt['diagnosticOnly'], True)
                self.assertIs(receipt['releaseAcceptance'], False)
                if present:
                    self.assertEqual(receipt['exitCode'], status)
                    self.assertEqual(args.read_text().splitlines(), ['xcresulttool', 'export', 'diagnostics', '--path',
                        '.build/performance/Performance.xcresult', '--output-path', '.build/performance/performance-diagnostics'])
                    self.assertEqual((evidence / 'performance-diagnostics-export.log').read_text(), 'export diagnostic\n')
                else: self.assertFalse(args.exists())

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
