"""Require the three instrumented files to reduce exactly to reviewed b359 sources."""
import hashlib
from pathlib import Path

BASE = "b359d0743c2db77bb81a00a1c7e69036aa12ab77"
ORIGINAL = {
    "ios/App/Theme.swift": "2d77ecf6ce6bed132275b3a9a33853cf4af311b81e2b7f9892bffe939defaa01",
    "ios/Features/Shop/ComparisonView.swift": "cb1e419eccc3af825d6eeaad331d628dd0230d6377244c93c8c6b8d866b1d8a4",
    "ios/UITests/RoomInTheCartUITests.swift": "7d9e7240a8c7ec11f0067b76e7122c4c3ad4f12fa998b4b2f08e1cbdf056ee34",
}


def without_diagnostics(text):
    lines, diagnostic = [], False
    for line in text.splitlines(keepends=True):
        if line.strip() == "#if DEBUG":
            if diagnostic:
                raise ValueError("Unexpected nested diagnostic conditional")
            diagnostic = True
        elif line.strip() == "#endif":
            if not diagnostic:
                raise ValueError("Unexpected conditional end")
            diagnostic = False
        elif not diagnostic:
            lines.append(line)
    if diagnostic:
        raise ValueError("Unclosed diagnostic conditional")
    text = "".join(lines)
    # The only release-visible rewrite is the semantically identical one-call wrapper.
    text = text.replace("Button(action: {\n                        dismiss()\n                    }) {",
                        "Button(action: dismiss) {")
    text = text.replace(", diagnosticFile: StaticString = #fileID", "")
    return text.rstrip() + "\n"


def check(root):
    for name, digest in ORIGINAL.items():
        text = (Path(root) / name).read_text()
        if hashlib.sha256(without_diagnostics(text).encode()).hexdigest() != digest:
            raise ValueError("Non-diagnostic source/layout/test change: " + name)
    return True


if __name__ == "__main__":
    check(Path.cwd())
