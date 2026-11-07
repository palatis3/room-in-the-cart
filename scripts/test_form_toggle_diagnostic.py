import copy
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("toggle_captures", Path(__file__).resolve().parents[1] /
                                             "diagnostics/swiftui-toggle/verify-captures.py")
captures = importlib.util.module_from_spec(spec)
spec.loader.exec_module(captures)


class FormToggleCaptureTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        attachments = []
        for phase, value, timestamp in [("before", "0", 100), ("after", "1", 101)]:
            for kind in ["state", "AX", "screen"]:
                name = f"{phase}-{kind}"
                data = {"state": f'Timestamp: {timestamp}\nExists: true\nFrame: (1,2,3,4)\nRequested point: (3,4)\nEnabled: true\nHittable: true\nValue: Optional({value})\nKeyboard: false\nContent area: (1,2,3,4)',
                        "AX": "Retailer total already includes all charges"}.get(kind)
                (self.root / name).write_bytes(data.encode() if data else b"\x89PNG\r\n\x1a\nfixture")
                attachments.append({"suggestedHumanReadableName": f"Toggle-{phase}-{kind}_0",
                                    "exportedFileName": name, "isAssociatedWithFailure": False})
        (self.root / "movement").write_text("Before midpoint Y: 700\nAfter midpoint Y: 220")
        attachments.append({"suggestedHumanReadableName": "Toggle-scroll-movement_0",
                            "exportedFileName": "movement", "isAssociatedWithFailure": False})
        self.manifest = [{"testIdentifier": "FormToggleDiagnosticUITests/testOneTapAfterInputDoneAndScroll()",
                          "attachments": attachments}]

    def run_check(self):
        (self.root / "manifest.json").write_text(json.dumps(self.manifest))
        return captures.verify(self.root)

    def test_requires_both_complete_capture_sets(self):
        self.assertEqual(len(self.run_check()["captures"]), 6)
        self.manifest[0]["attachments"].pop()
        with self.assertRaises(ValueError):
            self.run_check()

    def test_rejects_wrong_case_or_duplicate_capture(self):
        original = copy.deepcopy(self.manifest)
        self.manifest[0]["testIdentifier"] = "AnotherTest/testOneTapAfterInputDoneAndScroll()"
        with self.assertRaises(ValueError):
            self.run_check()
        self.manifest = original
        self.manifest[0]["attachments"].append(copy.deepcopy(self.manifest[0]["attachments"][0]))
        with self.assertRaises(ValueError):
            self.run_check()

    def test_rejects_unchanged_switch_and_ambiguous_state(self):
        path = self.root / "after-state"
        original = path.read_text()
        path.write_text(original.replace('Optional(1)', 'Optional(0)'))
        with self.assertRaises(ValueError):
            self.run_check()
        path.write_text(original + '\nValue: Optional(0)')
        with self.assertRaises(ValueError):
            self.run_check()

    def test_rejects_empty_ax_screenshot_and_reversed_time(self):
        for name, data in [("after-AX", b""), ("after-screen", b"invalid"),
                           ("after-state", (self.root / "after-state").read_bytes().replace(b"101", b"99"))]:
            with self.subTest(name=name):
                path = self.root / name
                original = path.read_bytes()
                path.write_bytes(data)
                with self.assertRaises(ValueError):
                    self.run_check()
                path.write_bytes(original)

    def test_rejects_path_escape(self):
        self.manifest[0]["attachments"][0]["exportedFileName"] = "../outside"
        with self.assertRaises(ValueError):
            self.run_check()

    def test_requested_drag_alone_cannot_certify_scroll_movement(self):
        (self.root / "movement").write_text("Before midpoint Y: 700\nAfter midpoint Y: 700")
        with self.assertRaises(ValueError):
            self.run_check()


if __name__ == "__main__":
    unittest.main()
