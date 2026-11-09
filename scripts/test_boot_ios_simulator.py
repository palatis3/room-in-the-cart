import contextlib
import io
import os
from pathlib import Path
import selectors
import signal
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

from boot_ios_simulator import boot_simulator


SIMULATOR = "8C9F4118-331E-4250-B1FC-194972BA6726"
# Verbatim terminal excerpts from KeyboardDiagnostic20261106/{ios-27-1,
# ios-27-0}-target/boot.log; simctl returned 0 for the migration failure.
FAILED = """[2026-11-06 08:44:20 +0000] Status=3, isTerminal=YES, Elapsed=00:44.
\tData Migration Failed

"""
FINISHED = """[2026-11-06 08:39:32 +0000] Status=4294967295, isTerminal=YES, Elapsed=00:47.
\tFinished

"""
# Observed in KeyboardDiagnostic20261106/local-build-driver.log:4568.
# `simctl help bootstatus` documents -b as booting only if not already booted.
ALREADY_BOOTED = "Device already booted, nothing to do.\n"


class BootSimulatorTests(unittest.TestCase):
    def replay(self, output, status=0):
        with patch("boot_ios_simulator.subprocess.Popen") as popen:
            process = popen.return_value.__enter__.return_value
            process.stdout = io.StringIO(output)
            process.wait.return_value = status
            stdout, stderr = io.StringIO(), io.StringIO()
            with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
                result = boot_simulator(SIMULATOR)
            popen.assert_called_once_with(
                ["xcrun", "simctl", "bootstatus", SIMULATOR, "-b"],
                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
            )
        self.assertEqual(stdout.getvalue(), output)
        return result, stderr.getvalue()

    def test_zero_exit_migration_failure_is_fatal(self):
        status, error = self.replay(FAILED)
        self.assertEqual(status, 1)
        self.assertIn("despite exit 0", error)

    def test_either_observed_failure_marker_is_sufficient(self):
        for output in (FAILED.splitlines(keepends=True)[0], "\tData Migration Failed\n"):
            with self.subTest(output=output):
                self.assertEqual(self.replay(output)[0], 1)

    def test_finished_and_already_booted_succeed(self):
        for output in (FINISHED, ALREADY_BOOTED):
            with self.subTest(output=output):
                self.assertEqual(self.replay(output), (0, ""))

    def test_nonzero_and_timeout_exits_take_precedence_over_output(self):
        for status in (1, 70, 124, 137, 143):
            for output in (FAILED, FINISHED, ALREADY_BOOTED, ""):
                with self.subTest(status=status, output=output):
                    self.assertEqual(self.replay(output, status), (status, ""))

    def test_child_signal_cannot_be_reported_as_success(self):
        self.assertEqual(self.replay(FINISHED, -signal.SIGTERM), (143, ""))

    def test_failure_cannot_be_overwritten_by_later_success_text(self):
        self.assertEqual(self.replay(FAILED + FINISHED)[0], 1)

    def test_no_new_success_format_requirement_or_broad_failure_matching(self):
        self.assertEqual(self.replay(""), (0, ""))
        self.assertEqual(self.replay("\tReason: plugin text mentions Data Migration Failed\n"), (0, ""))

    def test_invalid_simulator_is_rejected_before_launch(self):
        with patch("boot_ios_simulator.subprocess.Popen") as popen:
            with self.assertRaises(ValueError):
                boot_simulator("booted")
            popen.assert_not_called()


class BootSimulatorCommandTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        executable = self.root / "xcrun"
        executable.write_text("""#!/usr/bin/env python3
import os, signal, sys, time
assert sys.argv[1:] == ['simctl', 'bootstatus', os.environ['FAKE_SIMULATOR'], '-b']
print(os.environ['FAKE_OUTPUT'], end='', flush=True)
print(os.environ.get('FAKE_STDERR', ''), end='', file=sys.stderr, flush=True)
if os.environ.get('FAKE_HANG'):
    time.sleep(60)
status = int(os.environ['FAKE_STATUS'])
if status < 0:
    os.kill(os.getpid(), -status)
sys.exit(status)
""")
        executable.chmod(0o755)
        self.environment = dict(os.environ, PATH=str(self.root) + os.pathsep + os.environ['PATH'],
                                FAKE_SIMULATOR=SIMULATOR, FAKE_OUTPUT=FINISHED, FAKE_STATUS="0")
        self.command = [sys.executable, str(Path(__file__).with_name("boot_ios_simulator.py")), SIMULATOR]

    def test_real_wrapper_with_fake_simctl_preserves_output_and_status(self):
        for output, status, expected in ((FAILED, 0, 1), (FINISHED, 0, 0),
                                         (ALREADY_BOOTED, 0, 0), (FINISHED, 124, 124),
                                         (FAILED, 70, 70), (FINISHED, -signal.SIGTERM, 143)):
            with self.subTest(status=status, output=output):
                environment = dict(self.environment, FAKE_OUTPUT=output, FAKE_STATUS=str(status))
                result = subprocess.run(self.command, env=environment, capture_output=True, text=True, timeout=10)
                self.assertEqual(result.returncode, expected)
                self.assertEqual(result.stdout, output)

    def test_stderr_failure_is_also_detected(self):
        environment = dict(self.environment, FAKE_OUTPUT="", FAKE_STDERR=FAILED)
        result = subprocess.run(self.command, env=environment, capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout, FAILED)

    def test_discovery_stops_before_enumeration_on_zero_exit_migration_failure(self):
        from discover_ios_tests import discover

        products = self.root / "products"
        products.mkdir()
        (products / "RoomInTheCart_iphonesimulator1-arm64.xctestrun").touch()
        diagnostics, plan = self.root / "diagnostics", self.root / "plan"
        environment = dict(self.environment, FAKE_OUTPUT=FAILED)
        original_run = subprocess.run

        def invoke(command, *, check):
            self.assertEqual(Path(command[1]).name, "boot_ios_simulator.py")
            return original_run(command, check=check, env=environment,
                                capture_output=True, text=True, timeout=10)

        with patch("discover_ios_tests.subprocess.run", side_effect=invoke) as run:
            with self.assertRaises(subprocess.CalledProcessError) as raised:
                discover(SIMULATOR, products, diagnostics, plan)
        self.assertEqual(raised.exception.returncode, 1)
        self.assertIn(FAILED, raised.exception.output)
        self.assertEqual(run.call_count, 1)
        self.assertIn("bootstatus: exit 1", (diagnostics / "stages.txt").read_text())
        self.assertFalse(plan.exists())
        self.assertFalse((diagnostics / "attempt-1.json").exists())

    def test_outer_deadline_can_still_stop_hung_fake_boot(self):
        environment = dict(self.environment, FAKE_OUTPUT="waiting\n", FAKE_HANG="1")
        process = subprocess.Popen(self.command, env=environment, stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, start_new_session=True)
        try:
            # Start the outer deadline once the wrapper forwards the fake boot's ready marker.
            marker = b"waiting\n"
            with selectors.DefaultSelector() as ready:
                ready.register(process.stdout, selectors.EVENT_READ)
                self.assertTrue(ready.select(timeout=10), "fake boot did not report readiness")
            # Read only available bytes so a partial line cannot block the startup check.
            self.assertEqual(os.read(process.stdout.fileno(), len(marker)), marker)
            with self.assertRaises(subprocess.TimeoutExpired):
                process.communicate(timeout=1)
        finally:
            # This process group contains only the fake CLI and its wrapper.
            with contextlib.suppress(ProcessLookupError):
                os.killpg(process.pid, signal.SIGTERM)
            process.communicate(timeout=5)
        self.assertEqual(process.returncode, -signal.SIGTERM)


if __name__ == "__main__":
    unittest.main()
