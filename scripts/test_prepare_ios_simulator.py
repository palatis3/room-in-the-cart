"""Exercise the cross-step boot handoff without launching an actual simulator."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

from check_ci_workflows import parse_workflow

ROOT = Path(__file__).resolve().parents[1]
SIMULATOR = "8C9F4118-331E-4250-B1FC-194972BA6726"


class SimulatorPreparationTests(unittest.TestCase):
    def test_download_can_run_during_boot_and_wait_preserves_success_or_failure(self):
        for status, migration, expected in ((0, False, 0), (70, False, 70), (0, True, 1)):
            with self.subTest(status=status, migration=migration), tempfile.TemporaryDirectory() as folder:
                root = Path(folder)
                (root / "scripts").symlink_to(ROOT / "scripts", target_is_directory=True)
                (root / "python3").symlink_to(sys.executable)
                fake = root / "xcrun"
                fake.write_text('''#!/bin/bash
test "$*" = "simctl bootstatus $SIMULATOR_ID -b" || exit 2
for (( attempt = 0; attempt < 100; attempt++ )); do
    if [ -f download-finished ]; then
        if [ "$FAKE_MIGRATION" = 1 ]; then echo 'Data Migration Failed'; fi
        echo 'Boot check completed'
        exit "$FAKE_STATUS"
    fi
    sleep 0.05
done
exit 72
''')
                fake.chmod(0o755)
                env = dict(os.environ, PATH=str(root) + os.pathsep + os.environ["PATH"],
                           SIMULATOR_ID=SIMULATOR, FAKE_STATUS=str(status),
                           FAKE_MIGRATION=str(int(migration)))
                command = ["/bin/bash", str(ROOT / "scripts/prepare_ios_simulator.sh")]
                started = subprocess.run([*command, "start"], cwd=root, env=env,
                                         capture_output=True, text=True, timeout=3)
                self.assertEqual(started.returncode, 0, started.stderr)
                self.assertFalse((root / ".build/test-simulator-boot.status").exists())
                # This represents the independent artifact step. A serialized
                # boot would time out before it could ever reach this point.
                (root / "download-finished").touch()
                waited = subprocess.run([*command, "wait"], cwd=root, env=env,
                                        capture_output=True, text=True, timeout=8)
                self.assertEqual(waited.returncode, expected, waited.stderr)
                self.assertIn("Boot check completed", waited.stdout)
                self.assertEqual((root / ".build/test-simulator-boot.status").read_text(), f"{expected}\n")
                again = subprocess.run([*command, "start"], cwd=root, env=env,
                                       capture_output=True, text=True, timeout=3)
                self.assertNotEqual(again.returncode, 0, "Must not reuse a prior boot result")

    def test_missing_or_invalid_receipt_cannot_report_ready(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            command = ["/bin/bash", str(ROOT / "scripts/prepare_ios_simulator.sh"), "wait"]
            self.assertNotEqual(subprocess.run(command, cwd=root, capture_output=True).returncode, 0)
            (root / ".build").mkdir()
            (root / ".build/test-simulator-boot.log").write_text("retained failure\n")
            for status in ("", "ready", "256"):
                (root / ".build/test-simulator-boot.status").write_text(status)
                result = subprocess.run(command, cwd=root, capture_output=True, text=True, timeout=3)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("retained failure", result.stdout)

    def test_every_consumer_waits_for_boot_after_download_and_before_tests_or_cleanup(self):
        for workflow, job in (("ci.yml", "ios-tests"), ("ios-fixtures.yml", "contributor-tests"),
                              ("ios-fixtures.yml", "dinner-tests")):
            with self.subTest(workflow=workflow, job=job):
                steps = parse_workflow(ROOT / ".github/workflows" / workflow)[0]["jobs"][job]["steps"]
                index = lambda predicate: next(i for i, step in enumerate(steps) if predicate(step))
                select = index(lambda s: "Select isolated iPhone" in s.get("name", ""))
                start = index(lambda s: s.get("run") == "bash scripts/prepare_ios_simulator.sh start")
                download = index(lambda s: s.get("uses", "").startswith("actions/download-artifact@"))
                restore = index(lambda s: "compression_tool -decode" in s.get("run", ""))
                wait = index(lambda s: s.get("run") == "bash scripts/prepare_ios_simulator.sh wait")
                test = index(lambda s: "bash scripts/run_ios_test_shard.sh" in s.get("run", ""))
                cleanup = index(lambda s: "--cleanup-owned" in s.get("run", ""))
                self.assertEqual(sorted((select, start, download, restore, wait, test, cleanup)),
                                 [select, start, download, restore, wait, test, cleanup])
                self.assertEqual(steps[wait]["timeout-minutes"], 8)
                starters = [i for i, s in enumerate(steps) if s.get("run") == steps[start]["run"]]
                if workflow == "ios-fixtures.yml":
                    early, late = starters
                    self.assertLess(restore, late)
                    self.assertLess(late, wait)
                    self.assertEqual(steps[early]["if"], "runner.environment == 'self-hosted'")
                    self.assertEqual(steps[late]["if"], "runner.environment != 'self-hosted'")
                    for i in starters:
                        self.assertFalse(steps[i].get("continue-on-error", False))
                    self.assertEqual(steps[wait]["if"], "${{ !cancelled() && (steps." + steps[early]["id"] +
                                     ".outcome == 'success' || steps." + steps[late]["id"] + ".outcome == 'success') }}")
                else:
                    self.assertEqual(starters, [start])
                    self.assertEqual(steps[wait]["if"], "${{ !cancelled() }}")
                for step in (steps[start], steps[wait], steps[test]):
                    self.assertFalse(step.get("continue-on-error", False))


if __name__ == "__main__":
    unittest.main()
