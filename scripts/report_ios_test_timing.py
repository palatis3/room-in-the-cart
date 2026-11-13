#!/usr/bin/env python3
"""Explain native run timing from its retained log; never change test acceptance."""
import argparse
from datetime import datetime
import hashlib
import json
from pathlib import Path
import re

STAMP = r"\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d+"
SUITE = re.compile(
    rf"^Test Suite '(Selected tests|All tests)' (started|passed|failed) at ({STAMP})\.$"
)
OBSERVER = re.compile(
    rf"^({STAMP}) xcodebuild\[.*?\].*IDETestOperationsObserverDebug: "
    r"([0-9]+(?:\.[0-9]+)?) elapsed -- Testing started completed\.$"
)
COUNT = re.compile(r"^\s*Executed (\d+) tests?, with .* in ([0-9]+(?:\.[0-9]+)?) \(([0-9]+(?:\.[0-9]+)?)\) seconds$")
DIAGNOSTIC_TIMEOUT = re.compile(
    r"Failure collecting diagnostics from simulator: Timed out after ([0-9]+(?:\.[0-9]+)?) seconds"
)


def summarize(log):
    boundaries, observers, timeouts = [], [], []
    lines = log.splitlines()
    for index, line in enumerate(lines):
        if match := SUITE.fullmatch(line):
            boundaries.append((index, *match.groups()))
        if match := OBSERVER.fullmatch(line):
            observers.append((index, *match.groups()))
        if match := DIAGNOSTIC_TIMEOUT.search(line):
            timeouts.append(float(match[1]))
    report = {
        "schemaVersion": 1,
        "observationOnly": True,
        "rootSuite": None,
        "suiteWallSeconds": None,
        "reportedCaseSeconds": None,
        "reportedCaseCount": None,
        "observerElapsedSeconds": None,
        "postSuiteObserverSeconds": None,
        "diagnosticTimeoutSeconds": timeouts,
        "notes": [
            "Wall intervals use timestamps from this one log; they are not benchmark measurements.",
            "The post-suite interval includes remaining diagnostics/teardown; it is not pure export time.",
            "Timing availability never establishes test success or changes strict result validation.",
        ],
    }
    # Restarts or multiple root suites cannot be collapsed into a single useful
    # duration without reconstructing the individual attempts. Preserve unknowns.
    if len(boundaries) != 2:
        report["notes"].append("No unique complete root-suite window; no suite timing inferred.")
        return report
    first, last = boundaries
    if first[1] != last[1] or first[2] != "started" or last[2] not in ("passed", "failed"):
        report["notes"].append("Root-suite boundaries are incomplete or ambiguous.")
        return report
    start, finish = (datetime.fromisoformat(row[3]) for row in (first, last))
    seconds = (finish - start).total_seconds()
    if seconds < 0:
        report["notes"].append("Root-suite clock moved backwards; timing is unavailable.")
        return report
    report.update(rootSuite={"name": first[1], "outcome": last[2],
                             "startedLocal": first[3], "finishedLocal": last[3]},
                  suiteWallSeconds=seconds)
    if last[0] + 1 < len(lines) and (count := COUNT.fullmatch(lines[last[0] + 1])):
        report.update(reportedCaseSeconds=float(count[2]), reportedCaseCount=int(count[1]))
    if len(observers) == 1 and observers[0][0] > last[0]:
        _, stamp, elapsed = observers[0]
        tail = (datetime.fromisoformat(stamp) - finish).total_seconds()
        if tail >= 0 and float(elapsed) >= seconds + tail:
            report.update(observerElapsedSeconds=float(elapsed), postSuiteObserverSeconds=tail)
        else:
            report["notes"].append("Observer timing is inconsistent with the root-suite window.")
    else:
        report["notes"].append("No unique later observer completion; post-suite timing is unavailable.")
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--test-log", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    if args.test_log.stat().st_size > 32 * 1024 * 1024:
        parser.error("test log exceeds the 32 MiB observation bound")
    raw = args.test_log.read_bytes()
    report = summarize(raw.decode("utf-8", errors="replace"))
    report["testLogSHA256"] = hashlib.sha256(raw).hexdigest()
    # The first attempt remains evidence if a later infrastructure retry runs.
    with args.output.open("x", encoding="utf-8") as stream:
        stream.write(json.dumps(report, indent=2) + "\n")
    print("Native timing: suite=%s s; after suite=%s s (observation only)" %
          (report["suiteWallSeconds"], report["postSuiteObserverSeconds"]))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
