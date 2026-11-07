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


def modern_location(case, source, line_count):
    """Read direct failure children only; return (valid/missing/invalid, line)."""
    try:
        children = case.get("children", [])
        if not isinstance(children, list):
            return "invalid", None
        locations = set()
        for child in children:
            if not isinstance(child, dict):
                return "invalid", None
            if child.get("nodeType") != "Failure Message":
                continue
            if "sourceLocation" not in child:
                continue
            loc = child["sourceLocation"]
            if not isinstance(loc, dict):
                return "invalid", None
            path, line = loc.get("filePath"), loc.get("lineNumber")
            if (not isinstance(path, str) or path != str(source.resolve()) or
                    type(line) is not int or not 1 <= line <= line_count):
                return "invalid", None
            locations.add(line)
        if not locations:
            return "missing", None
        return ("valid", next(iter(locations))) if len(locations) == 1 else ("invalid", None)
    except (TypeError, ValueError, OSError, RuntimeError):
        return "invalid", None


def legacy_location(bundle_json, source, line_count):
    try:
        issues = bundle_json["issues"]["testFailureSummaries"]["_values"]
        if not isinstance(issues, list):
            return "invalid", None
        lines = set()
        for issue in issues:
            if issue["testCaseName"]["_value"] != f"{SUITE}.{METHOD}()":
                continue
            location = issue.get("documentLocationInCreatingWorkspace")
            if location is None:
                continue
            url = urlsplit(location["url"]["_value"])
            if (url.scheme != "file" or url.netloc or url.query or
                    re.search(r"%2f|%5c", url.path, re.IGNORECASE) or
                    unquote(url.path) != str(source.resolve())):
                return "invalid", None
            fields = parse_qs(url.fragment, keep_blank_values=True, strict_parsing=True)
            if set(fields) != {"StartingLineNumber", "EndingLineNumber"}:
                return "invalid", None
            start, end = fields["StartingLineNumber"], fields["EndingLineNumber"]
            if start != end or len(start) != 1 or not re.fullmatch(r"[0-9]{1,6}", start[0]):
                return "invalid", None
            line = int(start[0]) + 1  # Legacy URL is zero-based.
            if not 1 <= line <= line_count:
                return "invalid", None
            lines.add(line)
        if not lines:
            return "missing", None
        return ("valid", next(iter(lines))) if len(lines) == 1 else ("invalid", None)
    except (KeyError, TypeError, ValueError, AttributeError, OSError, RuntimeError):
        return "invalid", None


def assertion_line(bundle_json, source, line_count):
    status, line = legacy_location(bundle_json, source, line_count)
    return line if status == "valid" else None


def read_legacy_location(evidence, source, line_count):
    bundle = evidence / "Tests-retry.xcresult"
    if not bundle.is_dir():
        bundle = evidence / "Tests.xcresult"
    if not bundle.is_dir():
        return "missing", None
    try:
        data = subprocess.check_output(
            ["xcrun", "xcresulttool", "get", "object", "--legacy", "--format", "json", "--path", str(bundle)],
            stderr=subprocess.DEVNULL, timeout=5,
        )
        return legacy_location(json.loads(data), source, line_count)
    except (OSError, ValueError, TypeError, KeyError, AttributeError, subprocess.SubprocessError):
        return "invalid", None


def combined_location(modern, legacy):
    if modern[0] == "invalid" or legacy[0] == "invalid":
        return None
    lines = {line for status, line in (modern, legacy) if status == "valid"}
    return next(iter(lines)) if len(lines) == 1 else None


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
        line_count = len(source_text.splitlines())
        line = combined_location(modern_location(case, source, line_count),
                                 read_legacy_location(evidence, source, line_count))
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
