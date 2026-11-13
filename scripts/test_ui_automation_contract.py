from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[1]


class UIAutomationContractTests(unittest.TestCase):
    def test_keyboard_input_uses_supported_xctest_api(self):
        sources = sorted((ROOT / "ios/UITests").rglob("*.swift"))
        self.assertTrue(sources, "The UI test sources must be present")
        for source in sources:
            with self.subTest(source=source.relative_to(ROOT)):
                self.assertIsNone(
                    re.search(r"\bhasKeyboardFocus\b", source.read_text()),
                    "Use targeted XCUIElement.typeText, keyboard visibility and exact "
                    "value assertions. The undocumented focus attribute failed on "
                    "ready inputs in hosted Xcode 26.3.",
                )


if __name__ == "__main__":
    unittest.main()
