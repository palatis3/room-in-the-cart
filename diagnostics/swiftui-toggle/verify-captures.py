#!/usr/bin/env python3
"""Require the six fictional control captures; execution uses the shared strict guard."""
import hashlib
import json
import math
from pathlib import Path
import sys


def verify(directory):
    manifest = json.loads((directory / "manifest.json").read_text())
    (case,) = manifest
    if case.get("testIdentifier") != "FormToggleDiagnosticUITests/testOneTapAfterInputDoneAndScroll()":
        raise ValueError("Unexpected diagnostic attachment test identity")
    captures = {}
    timestamps = []
    for phase, value in [("before", "0"), ("after", "1")]:
        for kind in ["state", "AX", "screen"]:
            prefix = f"Toggle-{phase}-{kind}_"
            (item,) = [a for a in case["attachments"] if a["suggestedHumanReadableName"].startswith(prefix)]
            name = item["exportedFileName"]
            if Path(name).name != name or item["isAssociatedWithFailure"]:
                raise ValueError("Invalid capture path or failed capture")
            data = (directory / name).read_bytes()
            if not data:
                raise ValueError("Empty capture")
            if kind == "screen" and not data.startswith(b"\x89PNG\r\n\x1a\n"):
                raise ValueError("Expected PNG screenshot")
            if kind == "AX" and "Retailer total already includes all charges" not in data.decode():
                raise ValueError("Switch missing from accessibility capture")
            if kind == "state":
                pairs = [line.split(": ", 1) for line in data.decode().splitlines()]
                facts = dict(pairs)
                if len(facts) != len(pairs):
                    raise ValueError("Duplicated diagnostic state")
                for key, expected in {"Exists": "true", "Enabled": "true", "Hittable": "true",
                                      "Keyboard": "false", "Value": f'Optional({value})'}.items():
                    if facts.get(key) != expected:
                        raise ValueError(f"Unexpected diagnostic state: {key}")
                if not all(facts.get(key) for key in ["Frame", "Requested point", "Content area"]):
                    raise ValueError("Missing diagnostic geometry")
                timestamp = float(facts["Timestamp"])
                if not math.isfinite(timestamp) or timestamp <= 0:
                    raise ValueError("Invalid capture timestamp")
                timestamps.append(timestamp)
            captures[f"{phase}-{kind}"] = {"file": name, "sha256": hashlib.sha256(data).hexdigest()}
    if timestamps[0] >= timestamps[1]:
        raise ValueError("Capture timestamps must preserve before/after order")
    (movement,) = [a for a in case["attachments"] if a["suggestedHumanReadableName"].startswith("Toggle-scroll-movement_")]
    name = movement["exportedFileName"]
    if Path(name).name != name or movement["isAssociatedWithFailure"]:
        raise ValueError("Invalid scroll evidence")
    rows = [line.split(": ", 1) for line in (directory / name).read_text().splitlines()]
    values = dict(rows)
    if len(rows) != 2 or set(values) != {"Before midpoint Y", "After midpoint Y"}:
        raise ValueError("Missing or duplicated scroll positions")
    before, after = float(values["Before midpoint Y"]), float(values["After midpoint Y"])
    if not all(math.isfinite(x) for x in [before, after]) or abs(after - before) <= 1:
        raise ValueError("Requested drag did not establish measurable Form movement")
    return {"status": "passed", "captures": captures, "scrollMidpointY": {"before": before, "after": after},
            "scope": "Standalone control only; not proof of the app failure's cause or a release gate."}


if __name__ == "__main__":
    print(json.dumps(verify(Path(sys.argv[1])), indent=2))
