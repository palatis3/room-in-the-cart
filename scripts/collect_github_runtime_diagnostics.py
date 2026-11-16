#!/usr/bin/env python3
"""Collect best-effort evidence without one stalled service hiding the other."""
import json
from pathlib import Path
import subprocess
import time


CAPTURES = (
    ("final.json", ["xcrun", "simctl", "runtime", "list", "-j"], 45),
    ("runtime-events.log", [
        "/usr/bin/log", "show", "--style", "compact", "--last", "2h",
        "--predicate", 'process == "simdiskimaged" OR process CONTAINS "CoreSimulatorService"',
    ], 90),
)


def collect(directory):
    directory = Path(directory)
    directory.mkdir(parents=True, exist_ok=True)
    results = []
    for name, command, timeout in CAPTURES:
        started = time.monotonic()
        result = {"file": name, "timeoutSeconds": timeout}
        with (directory / name).open("wb") as output, (directory / (name + ".stderr")).open("wb") as errors:
            try:
                completed = subprocess.run(command, stdout=output, stderr=errors, timeout=timeout)
                result.update(status="completed", exitCode=completed.returncode)
            except subprocess.TimeoutExpired:
                result["status"] = "timed-out"
            except OSError as error:
                result.update(status="unavailable", error=str(error))
        result["elapsedSeconds"] = round(time.monotonic() - started, 3)
        results.append(result)
        # Persist each outcome even if the outer workflow is subsequently cancelled.
        (directory / "diagnostic-capture.json").write_text(json.dumps(results, indent=2) + "\n")
    return results


if __name__ == "__main__":
    # Diagnostic availability never substitutes for the separate strict runtime gate.
    collect(".build/github-ios-runtime")
