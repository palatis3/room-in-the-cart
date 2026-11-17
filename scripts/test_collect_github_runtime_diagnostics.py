import json
from pathlib import Path
import sys
import subprocess
import tempfile
import unittest
from unittest.mock import Mock, call, patch

import collect_github_runtime_diagnostics as diagnostics


class RuntimeDiagnosticCaptureTests(unittest.TestCase):
    def test_hung_inventory_is_killed_and_system_log_still_runs(self):
        captures = (
            ("final.json", [sys.executable, "-c", "import time; print('partial', flush=True); time.sleep(30)"], 0.3),
            ("runtime-events.log", [sys.executable, "-c", "print('independent daemon evidence')"], 5),
        )
        with tempfile.TemporaryDirectory() as directory, patch.object(diagnostics, "CAPTURES", captures):
            results = diagnostics.collect(directory)
            self.assertEqual(results[0]["status"], "timed-out")
            self.assertEqual(results[0]["termination"], "reaped")
            self.assertLess(results[0]["elapsedSeconds"], 5)
            self.assertEqual(results[1]["exitCode"], 0)
            self.assertEqual((Path(directory) / "runtime-events.log").read_text(), "independent daemon evidence\n")
            self.assertEqual(json.loads((Path(directory) / "diagnostic-capture.json").read_text()), results)

    def test_missing_command_and_nonzero_exit_keep_evidence(self):
        captures = (
            ("final.json", ["/nonexistent/ritc-diagnostic-command"], 1),
            ("runtime-events.log", [sys.executable, "-c", "import sys; print('failure detail', file=sys.stderr); sys.exit(7)"], 5),
        )
        with tempfile.TemporaryDirectory() as directory, patch.object(diagnostics, "CAPTURES", captures):
            results = diagnostics.collect(directory)
            self.assertEqual(results[0]["status"], "unavailable")
            self.assertEqual(results[1]["exitCode"], 7)
            self.assertIn("failure detail", (Path(directory) / "runtime-events.log.stderr").read_text())

    def test_unreapable_child_does_not_block_independent_capture(self):
        stuck = Mock()
        stuck.wait.side_effect = subprocess.TimeoutExpired("inventory", 45)
        logs = Mock()
        logs.wait.return_value = 0
        with tempfile.TemporaryDirectory() as directory, patch.object(
                diagnostics.subprocess, "Popen", side_effect=[stuck, logs]):
            results = diagnostics.collect(directory)
        self.assertEqual(results[0]["termination"], "unreaped")
        self.assertEqual(stuck.wait.call_args_list, [call(timeout=45), call(timeout=5)])
        stuck.kill.assert_called_once_with()
        self.assertEqual(results[1]["exitCode"], 0)

    def test_kill_failure_is_recorded_without_blocking_next_capture(self):
        stuck = Mock()
        stuck.wait.side_effect = subprocess.TimeoutExpired("inventory", 45)
        stuck.kill.side_effect = OSError("termination unavailable")
        logs = Mock()
        logs.wait.return_value = 0
        with tempfile.TemporaryDirectory() as directory, patch.object(
                diagnostics.subprocess, "Popen", side_effect=[stuck, logs]):
            results = diagnostics.collect(directory)
        self.assertEqual(results[0]["termination"], "kill-failed")
        self.assertEqual(stuck.wait.call_args_list, [call(timeout=45)])
        self.assertEqual(results[1]["exitCode"], 0)


if __name__ == "__main__":
    unittest.main()
