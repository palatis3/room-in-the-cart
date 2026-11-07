"""Check Foundation 2.1's opaque color pairs for the iPhone and web themes."""
import json
from pathlib import Path
import unittest


THEME = Path(__file__).resolve().parents[1] / "shared/contracts/theme.json"


def luminance(hex_color):
    # https://www.w3.org/WAI/WCAG22/Understanding/relative-luminance.html
    rgb = bytes.fromhex(hex_color.removeprefix("#"))
    if len(rgb) != 3:
        raise ValueError(f"Expected opaque sRGB color, got {hex_color!r}")
    red, green, blue = (
        c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4
        for c in (channel / 255 for channel in rgb)
    )
    return 0.2126 * red + 0.7152 * green + 0.0722 * blue


class ThemeContrastTests(unittest.TestCase):
    def check_pair(self, mode, colors, foreground, background, minimum):
        with self.subTest(mode=mode, foreground=foreground, background=background):
            low, high = sorted(luminance(colors[key]) for key in (foreground, background))
            self.assertGreaterEqual((high + 0.05) / (low + 0.05), minimum)

    def test_opaque_text_and_interactive_boundaries(self):
        theme = json.loads(THEME.read_text())
        for mode in ("light", "dark"):
            colors = theme[mode]
            for background in ("canvas", "surface", "selection"):
                for text in ("ink", "secondary", "accent"):
                    self.check_pair(mode, colors, text, background, 4.5)
                for edge in ("focus", "control_edge"):
                    self.check_pair(mode, colors, edge, background, 3)
            for text, background in (("on_accent", "accent"), ("warning", "warning_surface"),
                                     ("error", "error_surface")):
                self.check_pair(mode, colors, text, background, 4.5)


if __name__ == "__main__":
    unittest.main()
