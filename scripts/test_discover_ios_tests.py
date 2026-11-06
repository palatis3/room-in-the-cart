import json
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from discover_ios_tests import discover


SIMULATOR = "8C9F4118-331E-4250-B1FC-194972BA6726"
BUNDLE = "dev.roominthecart.app.debug"
# Transcribed from the hosted planner's printed errors array, independent of the classifier.
ERROR = (
    'RoomInTheCart encountered an error. (Underlying Error: Failed to install or launch the test runner. '
    '(Underlying Error: Simulator device failed to launch dev.roominthecart.app.debug. The request was '
    'denied by service delegate (SBMainWorkspace) for reason: NotFound ("Application "dev.roominthecart.app.debug" '
    'is unknown to FrontBoard"). (Underlying Error: The request to open "dev.roominthecart.app.debug" failed. '
    'The request was denied by service delegate (SBMainWorkspace) for reason: NotFound ("Application '
    '"dev.roominthecart.app.debug" is unknown to FrontBoard"). (Underlying Error: The operation couldn’t be '
    'completed. Application "dev.roominthecart.app.debug" is unknown to FrontBoard.))))'
)


def encoded(errors=(), model=True, disabled=()):
    enabled = [f"RoomInTheCartUITests/Journey/testCase{i}()" for i in range(10)]
    if model:
        enabled.append("RoomInTheCartTests/Models/testCase()")
    return json.dumps({"errors": list(errors), "values": [{
        "testPlan": "RoomInTheCart",
        "enabledTests": [{"identifier": name} for name in enabled],
        "disabledTests": [{"identifier": name} for name in disabled],
    }]}, indent=2).encode()


class DiscoverTests(unittest.TestCase):
    def prepare(self, attempts, *, failure=None, bundle=BUNDLE):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        root = Path(temp.name)
        self.products, self.diagnostics, self.plan = root / "products", root / "diagnostics", root / "plan"
        self.app = self.products / "Debug-iphonesimulator/RoomInTheCart.app"
        self.app.mkdir(parents=True)
        (self.app / "Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": bundle, "CFBundleSupportedPlatforms": ["iPhoneSimulator"]
        }))
        self.runfile = self.products / "RoomInTheCart_iphonesimulator1-arm64.xctestrun"
        self.runfile.touch()
        self.commands = []
        inventories = iter(attempts)

        def invoke(command, *, check):
            self.commands.append(command)
            if command[0] == "xcodebuild":
                self.assertEqual(command[:5], ["xcodebuild", "-xctestrun", str(self.runfile),
                                              "-destination", f"platform=iOS Simulator,id={SIMULATOR}"])
                self.assertIn("-enumerate-tests", command)
                self.assertEqual(command[-1], "test-without-building")
                path = Path(command[command.index("-test-enumeration-output-path") + 1])
                path.write_bytes(next(inventories))
            return subprocess.CompletedProcess(command, 1 if failure in command else 0)

        with_mock = patch("discover_ios_tests.subprocess.run", side_effect=invoke)
        with_mock.start()
        self.addCleanup(with_mock.stop)

    def discover(self):
        discover(SIMULATOR, self.products, self.diagnostics, self.plan)

    def test_clean_first_attempt_uses_strict_plan_without_install(self):
        self.prepare([encoded()])
        self.discover()
        self.assertEqual(len(self.commands), 2)
        self.assertEqual((self.plan / "test-enumeration.json").read_bytes(), encoded())
        self.assertFalse((self.diagnostics / "attempt-2.json").exists())

    def test_exact_error_recovers_once_on_same_device_and_preserves_both_outputs(self):
        failed = encoded([ERROR], model=False)
        self.prepare([failed, encoded()])
        self.discover()
        self.assertEqual(self.commands[2:4], [
            ["xcrun", "simctl", "install", SIMULATOR, str(self.app)],
            ["xcrun", "simctl", "get_app_container", SIMULATOR, BUNDLE, "app"],
        ])
        self.assertEqual(len(self.commands), 5)
        self.assertEqual((self.diagnostics / "attempt-1.json").read_bytes(), failed)
        self.assertEqual((self.diagnostics / "attempt-2.json").read_bytes(), encoded())
        self.assertEqual((self.plan / "test-enumeration.json").read_bytes(), encoded())
        self.assertEqual(len(json.loads((self.plan / "manifest.json").read_bytes())["include"]), 11)

    def test_other_errors_and_bad_inventories_never_trigger_recovery(self):
        for inventory in (
            encoded([ERROR, "Timed out"]), encoded([ERROR + " Timed out"]),
            encoded([ERROR.replace(BUNDLE, "dev.roominthecart.app.staging")]),
            encoded([ERROR.replace("NotFound", "Busy")]), encoded(model=False),
            encoded(disabled=["RoomInTheCartTests/Models/testHidden()"]), b"invalid JSON",
        ):
            with self.subTest(inventory=inventory[:150]):
                self.prepare([inventory])
                with self.assertRaises(ValueError):
                    self.discover()
                self.assertEqual(len(self.commands), 2)
                self.assertFalse(self.plan.exists())

    def test_second_failure_never_retries_or_publishes_a_plan(self):
        for inventory in (encoded([ERROR]), encoded(model=False), encoded(disabled=["RoomInTheCartUITests/A/testB()"])):
            with self.subTest(inventory=inventory[:150]):
                first = encoded([ERROR])
                self.prepare([first, inventory])
                with self.assertRaises(ValueError):
                    self.discover()
                self.assertEqual(len(self.commands), 5)
                self.assertEqual((self.diagnostics / "attempt-1.json").read_bytes(), first)
                self.assertEqual((self.diagnostics / "attempt-2.json").read_bytes(), inventory)
                self.assertFalse(self.plan.exists())

    def test_nonzero_exit_is_fatal_at_each_stage(self):
        for stage, count in (("bootstatus", 1), ("xcodebuild", 2), ("install", 3), ("get_app_container", 4)):
            with self.subTest(stage=stage):
                self.prepare([encoded([ERROR])], failure=stage)
                with self.assertRaises(subprocess.CalledProcessError):
                    self.discover()
                self.assertEqual(len(self.commands), count)
                self.assertIn("exit 1", (self.diagnostics / "stages.txt").read_text())
                self.assertFalse(self.plan.exists())

    def test_missing_xctestrun_fails_before_boot_and_leaves_diagnostics(self):
        self.prepare([])
        self.runfile.unlink()
        with self.assertRaisesRegex(ValueError, "Expected one compiled test run"):
            self.discover()
        self.assertEqual(self.commands, [])
        self.assertTrue((self.diagnostics / "stages.txt").is_file())
        self.assertFalse(self.plan.exists())

    def test_wrong_compiled_app_is_never_installed(self):
        self.prepare([encoded([ERROR])], bundle="dev.roominthecart.app")
        with self.assertRaisesRegex(ValueError, "compiled Debug simulator app"):
            self.discover()
        self.assertEqual(len(self.commands), 2)
