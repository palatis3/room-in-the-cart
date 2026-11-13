#!/usr/bin/env python3
"""Publish only allowlisted results for the private Records fixture suites."""

import json
import os
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
SHARED_SUITE = "SharedRecordsUITests"
SHARED_METHODS = (
    "testSharedRecordsENPrivateExportCancelDedupeAndInertRecovery",
    "testSharedRecordsESPrivateExportCancelDedupeAndInertRecovery",
)
SUITES = {
    SUITE: ("Records Media", (METHOD,)),
    SHARED_SUITE: ("Shared Records", SHARED_METHODS),
}
COUNTS = {
    "Passed": "passedTests",
    "Failed": "failedTests",
    "Skipped": "skippedTests",
    "Expected Failure": "expectedFailures",
}


def read_json(path):
    return json.loads(path.read_text(encoding="utf-8"))


def modern_location(case, source, line_count, build_source=None):
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
            if (not isinstance(path, str) or path not in (str(source.resolve()), build_source) or
                    type(line) is not int or not 1 <= line <= line_count):
                return "invalid", None
            locations.add(line)
        if not locations:
            return "missing", None
        return ("valid", next(iter(locations))) if len(locations) == 1 else ("invalid", None)
    except (TypeError, ValueError, OSError, RuntimeError):
        return "invalid", None


def legacy_location(bundle_json, source, line_count, case_name=f"{SUITE}.{METHOD}()", build_source=None):
    try:
        issues = bundle_json["issues"]["testFailureSummaries"]["_values"]
        if not isinstance(issues, list):
            return "invalid", None
        lines = set()
        for issue in issues:
            if issue["testCaseName"]["_value"] != case_name:
                continue
            location = issue.get("documentLocationInCreatingWorkspace")
            if location is None:
                continue
            url = urlsplit(location["url"]["_value"])
            if (url.scheme != "file" or url.netloc or url.query or
                    re.search(r"%2f|%5c", url.path, re.IGNORECASE) or
                    unquote(url.path) not in (str(source.resolve()), build_source)):
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


def read_legacy_bundle(evidence):
    bundle = evidence / "Tests-retry.xcresult"
    if not bundle.is_dir():
        bundle = evidence / "Tests.xcresult"
    if not bundle.is_dir():
        return {"issues": {"testFailureSummaries": {"_values": []}}}
    try:
        data = subprocess.check_output(
            ["xcrun", "xcresulttool", "get", "object", "--legacy", "--format", "json", "--path", str(bundle)],
            stderr=subprocess.DEVNULL, timeout=5,
        )
        return json.loads(data)
    except (OSError, ValueError, TypeError, KeyError, AttributeError, subprocess.SubprocessError):
        return None  # Invalid legacy data suppresses any modern location.


def read_legacy_location(evidence, source, line_count):
    return legacy_location(read_legacy_bundle(evidence), source, line_count)


def combined_location(modern, legacy):
    if modern[0] == "invalid" or legacy[0] == "invalid":
        return None
    lines = {line for status, line in (modern, legacy) if status == "valid"}
    return next(iter(lines)) if len(lines) == 1 else None


def verified_warning_count(evidence, expected_count):
    warnings = read_json(evidence / "test-runtime-warnings.json")
    warning_count = warnings["runtimeWarningCount"]
    warning_status = warnings["status"]
    if (type(warning_count) is not int or not 0 <= warning_count <= 10_000 or
            type(warnings["examinedTestCount"]) is not int or warnings["examinedTestCount"] != expected_count or
            warning_status not in ("passed", "unexpected-warnings")):
        raise ValueError("Invalid Records runtime warning evidence")
    if (warning_count == 0) != (warning_status == "passed"):
        raise ValueError("Inconsistent Records runtime warning evidence")
    return warning_count


def report(evidence, source, runner_status, suite=SUITE, build_source=None):
    label, methods = SUITES[suite]
    selectors = [f"RoomInTheCartUITests/{suite}/{method}" for method in methods]
    source_text = source.read_text(encoding="utf-8")
    expected = (evidence / "test-plan" / f"{suite}.txt").read_text(encoding="utf-8").splitlines()
    if expected != selectors or any(f"func {method}(" not in source_text for method in methods):
        raise ValueError("Unexpected Records selectors")
    summary = read_json(evidence / "test-summary.json")
    nodes = read_json(evidence / "test-details.json")["testNodes"]
    cases = list(test_cases(nodes))
    by_selector = dict(cases)
    if len(cases) != len(selectors) or set(by_selector) != set(selectors):
        raise ValueError("Unexpected Records execution")
    results = [by_selector[key]["result"] for key in selectors]
    if any(result not in COUNTS for result in results):
        raise ValueError("Invalid Records result")
    counts = [summary[key] for key in ("totalTestCount", *COUNTS.values())]
    if (any(type(count) is not int for count in counts) or
            counts != [len(selectors), *(results.count(result) for result in COUNTS)]):
        raise ValueError("Inconsistent Records result counts")
    all_passed = all(result == "Passed" for result in results)
    if summary["result"] != ("Passed" if all_passed else "Failed"):
        raise ValueError("Inconsistent Records summary result")
    try:
        warning_count = verified_warning_count(evidence, len(selectors))
    except (KeyError, TypeError, ValueError, OSError):
        if suite == SUITE:
            raise  # Preserve the original single-test report contract.
        # Valid case results can still diagnose a failure when the strict
        # verifier could not complete its independent runtime-warning scan.
        warning_count = None
    passed = runner_status == 0 and all_passed and warning_count == 0
    rows = [f"{label} verification **{'passed' if passed else 'failed'}**.", ""]
    if suite == SUITE:
        rows.extend([
            "| XCTest selector | Result | Executed | Passed | Failed | Skipped | Expected failures | Runtime warnings |",
            "| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |",
            f"| `{SELECTOR}` | {results[0]} | " + " | ".join(map(str, [*counts, warning_count])) + " |",
        ])
    else:
        rows.extend(["| XCTest selector | Result |", "| --- | --- |"])
        rows.extend(f"| `{selector}` | {result} |" for selector, result in zip(selectors, results))
        warning_summary = (f"Runtime warnings across both tests: {warning_count}." if warning_count is not None
                           else "Runtime warning verification unavailable.")
        rows.extend(["", warning_summary])
    if "Failed" in results:
        legacy = read_legacy_bundle(evidence)
        line_count = len(source_text.splitlines())
        for method, selector, result in zip(methods, selectors, results):
            if result != "Failed":
                continue
            line = combined_location(modern_location(by_selector[selector], source, line_count, build_source),
                                     legacy_location(legacy, source, line_count, f"{suite}.{method}()", build_source))
            if line is not None:
                prefix = "Failure location" if suite == SUITE else f"Failure location for `{method}`"
                rows.extend(["", f"{prefix} `ios/UITests/{suite}.swift:{line}`."])
    return "\n".join(rows), 0 if passed else 1


def main():
    label = "Records Media"
    try:
        _, evidence, runner_status, *option = sys.argv
        suite, = option or [SUITE]
        label, _ = SUITES[suite]
        relative_source = Path("ios", "UITests", f"{suite}.swift")
        source = Path(__file__).resolve().parents[1] / relative_source
        # The fixture can execute on a different runner from its compiler.
        workspace = os.environ.get("RECORDS_BUILD_WORKSPACE")
        build_source = str(Path(workspace) / relative_source) if workspace and Path(workspace).is_absolute() else None
        text, status = report(Path(evidence), source, int(runner_status), suite, build_source)
    except Exception:
        # Raw result strings and parser errors can contain private fixture data.
        text, status = f"{label} verification failed. Structured evidence was unavailable or invalid.", 1
    print(text)
    return status


if __name__ == "__main__":
    raise SystemExit(main())
