"""Exercise the actual shard entry point with fake native executables."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


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
                'xcodebuild': 'printf "%s\\n" "$@" >> "$TRACE"\nexit "${NATIVE_EXIT:-0}"',
                'xcrun': 'printf "%s\\n" "$@" >> "$TRACE"\necho "{}"',
                'python3': 'printf "%s\\n" "$@" >> "$TRACE"\nexit "${STRICT_EXIT:-0}"',
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


if __name__ == '__main__':
    unittest.main()
