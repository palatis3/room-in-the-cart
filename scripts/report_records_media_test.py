#!/usr/bin/env python3
"""Publish only allowlisted Records Media result fields."""

import json
from pathlib import Path
import re
import subprocess
import sys
from urllib.parse import parse_qs, unquote, urlsplit

from check_ios_test_results import test_cases


SUITE = "RecordsMediaUITests"
METHOD = "testSelectedPhotoDisclosureEncryptedPreviewCancelSiblingRecoveryAndReadablePhoto"
SELECTOR = f"RoomInTheCartUITests/{SUITE}/{METHOD}"
SOURCE = Path(f"ios/UITests/{SUITE}.swift")
COUNTS = {
    "Passed": "passedTests",
    "Failed": "failedTests",
    "Skipped": "skippedTests",
    "Expected Failure": "expectedFailures",
}


def read_json(path):
    return json.loads(path.read_text(encoding="utf-8"))


def assertion_line(bundle_json, source, line_count):
    issues = bundle_json["issues"]["testFailureSummaries"]["_values"]
    lines = set()
    for issue in issues:
        if issue["testCaseName"]["_value"] != f"{SUITE}.{METHOD}()":
            continue
        url = urlsplit(issue["documentLocationInCreatingWorkspace"]["url"]["_value"])
        if url.scheme != "file" or url.netloc or url.query or unquote(url.path) != str(source.resolve()):
            continue
        fields = parse_qs(url.fragment)
        start = fields.get("StartingLineNumber", [])
        end = fields.get("EndingLineNumber", [])
        if start == end and len(start) == 1 and re.fullmatch(r"[0-9]{1,6}", start[0]):
            line = int(start[0]) + 1  # xcresult workspace locations are zero-indexed.
            if line <= line_count:
                lines.add(line)
    return next(iter(lines)) if len(lines) == 1 else None


def read_assertion_line(evidence, source, line_count):
    bundle = evidence / "Tests-retry.xcresult"
    if not bundle.is_dir():
        bundle = evidence / "Tests.xcresult"
    try:
        data = subprocess.check_output(
            ["xcrun", "xcresulttool", "get", "object", "--legacy", "--format", "json", "--path", str(bundle)],
            stderr=subprocess.DEVNULL, timeout=5,
        )
        return assertion_line(json.loads(data), source, line_count)
    except (OSError, ValueError, TypeError, KeyError, AttributeError, subprocess.SubprocessError):
        return None


def report(evidence, source, runner_status):
    source_text = source.read_text(encoding="utf-8")
    expected = (evidence / "test-plan" / f"{SUITE}.txt").read_text(encoding="utf-8").splitlines()
    if expected != [SELECTOR] or f"func {METHOD}(" not in source_text:
        raise ValueError("Unexpected Records Media selector")
    summary = read_json(evidence / "test-summary.json")
    nodes = read_json(evidence / "test-details.json")["testNodes"]
    (actual, case), = test_cases(nodes)
    result = case["result"]
    if actual != SELECTOR or result not in COUNTS:
        raise ValueError("Unexpected Records Media execution")
    counts = [summary[key] for key in ("totalTestCount", *COUNTS.values())]
    if any(type(count) is not int or count not in (0, 1) for count in counts):
        raise ValueError("Invalid Records Media result counts")
    if counts[0] != 1 or sum(counts[1:]) != 1 or summary[COUNTS[result]] != 1:
        raise ValueError("Inconsistent Records Media result counts")
    if summary["result"] not in ("Passed", "Failed") or (summary["result"] == "Passed") != (result == "Passed"):
        raise ValueError("Inconsistent Records Media summary result")
    warnings = read_json(evidence / "test-runtime-warnings.json")
    warning_count = warnings["runtimeWarningCount"]
    warning_status = warnings["status"]
    if (type(warning_count) is not int or not 0 <= warning_count <= 10_000 or
            type(warnings["examinedTestCount"]) is not int or warnings["examinedTestCount"] != 1 or
            warning_status not in ("passed", "unexpected-warnings")):
        raise ValueError("Invalid Records Media runtime warning evidence")
    if (warning_count == 0) != (warning_status == "passed"):
        raise ValueError("Inconsistent Records Media runtime warning evidence")
    passed = runner_status == 0 and result == "Passed" and warning_status == "passed"
    rows = [
        f"Records Media verification **{'passed' if passed else 'failed'}**.",
        "",
        "| XCTest selector | Result | Executed | Passed | Failed | Skipped | Expected failures | Runtime warnings |",
        "| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |",
        f"| `{SELECTOR}` | {result} | " + " | ".join(map(str, [*counts, warning_count])) + " |",
    ]
    if result == "Failed":
        line = read_assertion_line(evidence, source, len(source_text.splitlines()))
        if line is not None:
            rows.extend(["", f"Failure location `{SOURCE}:{line}`."])
    return "\n".join(rows), 0 if passed else 1


def main():
    try:
        _, evidence, runner_status = sys.argv
        source = Path(__file__).resolve().parents[1] / SOURCE
        text, status = report(Path(evidence), source, int(runner_status))
    except Exception:
        # Raw result strings and parser errors can contain private fixture data.
        text, status = "Records Media verification failed. Structured evidence was unavailable or invalid.", 1
    print(text)
    return status


if __name__ == "__main__":
    raise SystemExit(main())
