"""Exercise the actual shard entry point with fake native executables."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
BOOTSTRAP_STALL = (
    '\tRoomInTheCartUITests-Runner (6919) encountered an error (Early unexpected exit, '
    'operation never finished bootstrapping - no restart will be attempted. '
    '(Underlying Error: The test runner crashed while preparing to run tests: '
    'RoomInTheCartUITests-Runner at -[XCTWaiter(StallHandling) handleStalledWait:]))'
)


class LocalDiagnosticsTests(unittest.TestCase):
    def run_shard(self, **overrides):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            plan = root / '.build/test-plan'
            plan.mkdir(parents=True)
            (plan / 'sample.txt').write_text('Suite/Case/testOriginal\n')
            products = root / '.build/DerivedData/Build/Products'
            products.mkdir(parents=True)
            (products / 'RoomInTheCart_iphonesimulator.xctestrun').touch()
            binaries = root / 'bin'
            binaries.mkdir()
            for name, body in {
                'xcodebuild': 'printf "%s\\n" "$@" >> "$TRACE"\n'
                              'if [[ " $* " = *" .build/Tests-retry.xcresult "* ]]; then\n'
                              '    printf "%s\\n" "${RETRY_MESSAGE:-}"\n'
                              '    exit "${RETRY_EXIT:-${NATIVE_EXIT:-0}}"\n'
                              'fi\n'
                              'printf "%s\\n" "${NATIVE_MESSAGE:-}"\nexit "${NATIVE_EXIT:-0}"',
                'xcrun': 'printf "%s\\n" "$@" >> "$TRACE"\necho "{}"',
                'python3': 'printf "%s\\n" "$@" >> "$TRACE"\n'
                           'if [[ "$1" = scripts/report_ios_test_timing.py ]]; then exit "${TIMING_EXIT:-0}"; fi\n'
                           'if [[ "$1" = scripts/check_ios_test_results.py ]]; then exit "${STRICT_EXIT:-0}"; fi',
            }.items():
                path = binaries / name
                path.write_text('#!/bin/bash\n' + body + '\n')
                path.chmod(0o755)
            env = {key: value for key, value in os.environ.items()
                   if key not in ('CI', 'GITHUB_ACTIONS', 'LOCAL_TEST_DIAGNOSTICS')}
            env.update(PATH=str(binaries) + os.pathsep + env['PATH'], TRACE=str(root / 'trace'),
                       SIMULATOR_ID='owned-test-device', TEST_SHARD='sample', EXPECTED_TEST_COUNT='1')
            env.update(overrides)
            result = subprocess.run(['bash', str(ROOT / 'scripts/run_ios_test_shard.sh')],
                                    cwd=root, env=env, capture_output=True, text=True)
            trace = root / 'trace'
            return result.returncode, trace.read_text().splitlines() if trace.exists() else []

    def test_default_and_local_mode_preserve_selection_timeouts_and_strict_check(self):
        for mode in ('on-failure', 'never'):
            with self.subTest(mode=mode):
                status, args = self.run_shard(LOCAL_TEST_DIAGNOSTICS=mode)
                self.assertEqual(status, 0)
                self.assertEqual(args[args.index('-collect-test-diagnostics') + 1], mode)
                self.assertIn('-only-testing:Suite/Case/testOriginal', args)
                self.assertEqual(args[args.index('-default-test-execution-time-allowance') + 1], '720')
                self.assertEqual(args[args.index('-maximum-test-execution-time-allowance') + 1], '900')
                self.assertIn('scripts/check_ios_test_results.py', args)
                self.assertIn('--result-bundle', args)
                self.assertIn('--test-log', args)
                self.assertIn('scripts/report_ios_test_timing.py', args)
                self.assertIn('.build/test-run-timing.json', args)
        status, args = self.run_shard(CI='true', GITHUB_ACTIONS='true')
        self.assertEqual(status, 0)
        self.assertEqual(args[args.index('-collect-test-diagnostics') + 1], 'on-failure')

    def test_ci_cannot_disable_diagnostics_and_invalid_values_fail_before_native_work(self):
        for values in ({'CI': 'true'}, {'GITHUB_ACTIONS': 'true'}, {'CI': 'false'}):
            with self.subTest(values=values):
                self.assertEqual(self.run_shard(LOCAL_TEST_DIAGNOSTICS='never', **values), (2, []))
        self.assertEqual(self.run_shard(LOCAL_TEST_DIAGNOSTICS='bad'), (2, []))

    def test_native_and_strict_failures_stay_failed_without_retrying_product_failures(self):
        for values in ({'NATIVE_EXIT': '65'}, {'STRICT_EXIT': '1'}):
            with self.subTest(values=values):
                status, args = self.run_shard(LOCAL_TEST_DIAGNOSTICS='never', **values)
                self.assertNotEqual(status, 0)
                self.assertEqual(args.count('test-without-building'), 1)
                self.assertIn('scripts/check_ios_test_results.py', args)
                self.assertIn('scripts/report_ios_test_timing.py', args)

    def test_timing_failure_does_not_replace_native_or_strict_status(self):
        for native, strict, expected in (('0', '0', 0), ('65', '0', 1), ('0', '1', 1)):
            status, args = self.run_shard(NATIVE_EXIT=native, STRICT_EXIT=strict, TIMING_EXIT='1')
            self.assertEqual(status, expected)
            self.assertIn('scripts/check_ios_test_results.py', args)
            self.assertEqual(args.count('test-without-building'), 1)

    def test_infrastructure_retry_retains_distinct_timing_for_both_attempts(self):
        status, args = self.run_shard(
            NATIVE_EXIT='65', NATIVE_MESSAGE='Test crashed with signal kill before establishing connection.')
        self.assertNotEqual(status, 0)
        self.assertEqual(args.count('test-without-building'), 2)
        self.assertEqual(args.count('.build/test-run-timing.json'), 1)
        self.assertEqual(args.count('.build/test-run-timing-retry.json'), 1)

    def test_preparation_stall_reboots_once_and_checks_the_unchanged_selector(self):
        for retry, strict, expected in (('0', '0', 0), ('65', '0', 65), ('0', '7', 7)):
            with self.subTest(retry=retry, strict=strict):
                status, args = self.run_shard(
                    NATIVE_EXIT='65', NATIVE_MESSAGE=BOOTSTRAP_STALL, RETRY_EXIT=retry,
                    RETRY_MESSAGE=BOOTSTRAP_STALL if retry == '65' else '', STRICT_EXIT=strict)
                self.assertEqual(status, expected)
                self.assertEqual(args.count('test-without-building'), 2)
                self.assertEqual(args.count('-only-testing:Suite/Case/testOriginal'), 2)
                self.assertEqual(args.count('scripts/boot_ios_simulator.py'), 1)
                self.assertEqual(args.count('.build/test-run-timing.json'), 1)
                self.assertEqual(args.count('.build/test-run-timing-retry.json'), 1)
                self.assertEqual(args[args.index('--result-bundle') + 1], '.build/Tests-retry.xcresult')
                self.assertEqual(args[-2:], ['--test-log', '.build/Tests-retry.log'])

    def test_started_suites_assertions_restarts_and_other_crash_sites_are_not_retryable(self):
        for message in (
            "Test Suite 'Selected tests' started\n" + BOOTSTRAP_STALL,
            "interleaved: Test Case '-[Suite testOriginal]' started.\n" + BOOTSTRAP_STALL,
            'Suite.swift:25: error: -[Suite testOriginal] : failed\n' + BOOTSTRAP_STALL,
            'Restarting after unexpected exit, crash, or test timeout;\n' + BOOTSTRAP_STALL,
            BOOTSTRAP_STALL.replace('handleStalledWait:', 'waitForExpectations:'),
            BOOTSTRAP_STALL.replace('RoomInTheCartUITests-Runner', 'RoomInTheCart'),
        ):
            with self.subTest(message=message):
                status, args = self.run_shard(NATIVE_EXIT='65', NATIVE_MESSAGE=message)
                self.assertNotEqual(status, 0)
                self.assertEqual(args.count('test-without-building'), 1)
                self.assertIn('scripts/check_ios_test_results.py', args)


if __name__ == '__main__':
    unittest.main()
