import contextlib
import io
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

import export_ios_test_results as exporter
from check_ios_test_results import export_test_activities, export_test_details


class ExportTests(unittest.TestCase):
    def test_exact_export_command_has_deadline_without_retry(self):
        for kind in ("summary", "tests"):
            with self.subTest(kind=kind), patch.object(exporter.subprocess, "run") as run:
                exporter.export("Original.xcresult", kind)
                run.assert_called_once_with(
                    ["xcrun", "xcresulttool", "get", "test-results", kind,
                     "--path", "Original.xcresult", "--compact"],
                    check=True, timeout=300)

    def test_cli_preserves_tool_failure_and_reports_timeout(self):
        for error, expected in ((subprocess.CalledProcessError(65, "xcrun"), 65),
                                (subprocess.TimeoutExpired("xcrun", 300), 124)):
            with self.subTest(expected=expected), \
                 patch.object(sys, "argv", ["export", "summary", "--path", "Original.xcresult"]), \
                 patch.object(exporter, "export", side_effect=error) as run, \
                 contextlib.redirect_stderr(io.StringIO()) as stderr:
                self.assertEqual(exporter.main(), expected)
                run.assert_called_once()
                if expected == 124:
                    self.assertIn("No retry attempted", stderr.getvalue())

    def test_stalled_export_is_killed_without_touching_original_bundle(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            bundle = root / "Original.xcresult"
            bundle.mkdir()
            original = bundle / "Info.plist"
            original.write_bytes(b"retained original evidence")
            executable = root / "xcrun"
            executable.write_text(f"#!{sys.executable}\nimport os, time\n"
                                  f"open({str(root / 'pid')!r}, 'w').write(str(os.getpid()))\n"
                                  "time.sleep(60)\n")
            executable.chmod(0o755)
            with patch.dict(os.environ, PATH=str(root) + os.pathsep + os.environ['PATH']), \
                 patch.object(exporter, "EXPORT_TIMEOUT_SECONDS", 1):
                with self.assertRaises(subprocess.TimeoutExpired):
                    exporter.export(bundle, "summary")
            with self.assertRaises(ProcessLookupError):
                os.kill(int((root / "pid").read_text()), 0)
            self.assertEqual(original.read_bytes(), b"retained original evidence")

    def test_per_case_exports_are_bounded_and_timeout_is_not_success(self):
        for operation in (export_test_details, export_test_activities):
            with self.subTest(operation=operation.__name__), \
                 patch("check_ios_test_results.subprocess.run",
                       side_effect=subprocess.TimeoutExpired("xcrun", 300)) as run:
                with self.assertRaises(subprocess.TimeoutExpired):
                    operation(Path("Original.xcresult"), "test://Target/Suite/testOne")
                self.assertEqual(run.call_count, 1)
                self.assertEqual(run.call_args.kwargs["timeout"], 300)


if __name__ == "__main__":
    unittest.main()
