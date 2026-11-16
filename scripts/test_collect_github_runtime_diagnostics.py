import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

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


if __name__ == "__main__":
    unittest.main()
