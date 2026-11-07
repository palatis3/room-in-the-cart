import contextlib
import io
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from prepare_ios_performance_simulator import APP_ID, prepare


SIMULATOR = "8C9F4118-331E-4250-B1FC-194972BA6726"


class PerformanceSetupTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.fixture = self.root / "fixture.txt"
        self.fixture.write_text("500 fictional fixture lines\n")
        self.output = self.root / "setup.json"
        self.calls = []
        self.inventory = {"com.apple.Preferences": {"CFBundleIdentifier": "com.apple.Preferences"}}
        self.failing = None
        self.raw_json = None

    def run_command(self, command, **kwargs):
        if command[0] == "plutil":
            name = "convert"
            self.assertEqual(kwargs["input"], b"raw plist inventory")
            value = self.raw_json if self.raw_json is not None else json.dumps(self.inventory).encode()
        elif command[1:3] == ["simctl", "listapps"]:
            name, value = "list", b"raw plist inventory"
            self.assertEqual(command[-1], SIMULATOR)
        elif command[1:3] == ["simctl", "pbcopy"]:
            name, value = "paste", None
            self.assertEqual(command[-1], SIMULATOR)
            self.assertEqual(kwargs["stdin"].read(), self.fixture.read_bytes())
        else:
            name, value = "boot", None
            self.assertEqual(Path(command[1]).name, "boot_ios_simulator.py")
            self.assertEqual(command[-1], SIMULATOR)
        self.calls.append(name)
        self.assertTrue(kwargs["check"])
        # The active stage must already be durable if the command hangs or is killed.
        receipt = json.loads(self.output.read_text())
        self.assertEqual(receipt["status"], "running")
        self.assertEqual(receipt["stages"][-1]["status"], "running")
        if name == self.failing:
            raise subprocess.CalledProcessError(60, command)
        return subprocess.CompletedProcess(command, 0, stdout=value)

    def run_setup(self, case="scroll"):
        with patch("prepare_ios_performance_simulator.subprocess.run", side_effect=self.run_command):
            with contextlib.redirect_stdout(io.StringIO()):
                prepare(SIMULATOR, case, self.fixture, self.output)
        return json.loads(self.output.read_text())

    def test_launch_checks_inventory_without_using_pasteboard(self):
        self.fixture.unlink()
        receipt = self.run_setup("launch")
        self.assertEqual(self.calls, ["boot", "list", "convert"])
        self.assertEqual(receipt["status"], "passed")
        self.assertNotIn("com.apple.Preferences", self.output.read_text())

    def test_rendered_and_scroll_seed_once_after_verified_absence(self):
        for case in ("rendered", "scroll"):
            with self.subTest(case=case):
                self.calls.clear()
                receipt = self.run_setup(case)
                self.assertEqual(self.calls, ["boot", "list", "convert", "paste"])
                self.assertEqual(receipt["status"], "passed")
                self.assertEqual(receipt["stages"][-1]["stage"], "seed-pasteboard")

    def test_each_command_failure_is_fatal_and_stops_later_commands(self):
        for name, stage, calls in (
            ("boot", "boot", ["boot"]),
            ("list", "list-installed-apps", ["boot", "list"]),
            ("convert", "verify-app-absent", ["boot", "list", "convert"]),
            ("paste", "seed-pasteboard", ["boot", "list", "convert", "paste"]),
        ):
            with self.subTest(command=name):
                self.failing = name
                self.calls.clear()
                with self.assertRaises(subprocess.CalledProcessError) as error:
                    self.run_setup()
                self.assertEqual(error.exception.returncode, 60)
                self.assertEqual(self.calls, calls)
                receipt = json.loads(self.output.read_text())
                self.assertEqual(receipt["status"], "failed")
                self.assertEqual(receipt["stages"][-1]["stage"], stage)
                self.assertEqual(receipt["stages"][-1]["exitCode"], 60)

    def test_existing_app_rejected_by_key_or_bundle_identifier(self):
        for inventory in ({APP_ID: {}}, {"unexpected-key": {"CFBundleIdentifier": APP_ID}}):
            self.calls.clear()
            self.inventory = inventory
            with self.assertRaisesRegex(ValueError, "fresh simulator"):
                self.run_setup()
            self.assertEqual(self.calls, ["boot", "list", "convert"])
            self.assertEqual(json.loads(self.output.read_text())["status"], "failed")

    def test_bad_inventory_never_counts_as_absence(self):
        for value in (b"", b"not-json", b"[]", b"null", b'{"app":"not a dictionary"}'):
            with self.subTest(value=value):
                self.calls.clear()
                self.raw_json = value
                with self.assertRaises(ValueError):
                    self.run_setup()
                self.assertEqual(self.calls, ["boot", "list", "convert"])
                self.assertEqual(json.loads(self.output.read_text())["status"], "failed")

    def test_missing_fixture_is_attributed_to_seed_without_invoking_pbcopy(self):
        self.fixture.unlink()
        with self.assertRaises(FileNotFoundError):
            self.run_setup()
        receipt = json.loads(self.output.read_text())
        self.assertEqual(receipt["stages"][-1]["stage"], "seed-pasteboard")
        self.assertEqual(receipt["status"], "failed")
        self.assertNotIn("paste", self.calls)

    def test_ambiguous_device_alias_never_invokes_simctl(self):
        with patch("prepare_ios_performance_simulator.subprocess.run") as command:
            with self.assertRaises(ValueError):
                prepare("booted", "scroll", self.fixture, self.output)
        command.assert_not_called()

    def test_previous_success_is_replaced_before_failing_command(self):
        self.run_setup()
        self.failing = "list"
        with self.assertRaises(subprocess.CalledProcessError):
            self.run_setup()
        receipt = json.loads(self.output.read_text())
        self.assertEqual(receipt["status"], "failed")
        self.assertEqual(len(receipt["stages"]), 2)


if __name__ == "__main__":
    unittest.main()
