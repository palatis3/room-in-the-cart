#!/usr/bin/env python3
"""Require every selected XCTest to finish, with no missing or skipped cases."""
import argparse
import json
import os
from pathlib import Path
from urllib.parse import unquote, urlparse


def test_cases(nodes):
    for node in nodes:
        if node.get("nodeType") == "Test Case":
            parts = unquote(urlparse(node["nodeIdentifierURL"]).path).strip("/").split("/")
            yield "/".join(parts[-3:]), node
        else:
            yield from test_cases(node.get("children", []))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--selectors", type=Path, required=True)
    parser.add_argument("--summary", type=Path, required=True)
    parser.add_argument("--tests", type=Path, required=True)
    parser.add_argument("--expected-count", type=int, required=True)
    args = parser.parse_args()
    expected = args.selectors.read_text().splitlines()
    summary = json.loads(args.summary.read_text())
    cases = list(test_cases(json.loads(args.tests.read_text())["testNodes"]))
    actual = [identifier for identifier, _ in cases]
    failures = []
    if not expected or len(expected) != len(set(expected)) or len(expected) != args.expected_count:
        failures.append("Expected selection is empty, duplicated or does not match the build count")
    if len(actual) != len(set(actual)) or set(actual) != set(expected):
        failures.append(f"Unexpected execution inventory. Missing {sorted(set(expected) - set(actual))}; extra {sorted(set(actual) - set(expected))}")
    if summary.get("totalTestCount") != len(expected) or summary.get("passedTests") != len(expected):
        failures.append("Executed and passing counts do not match the selected tests")
    if summary.get("failedTests") or summary.get("skippedTests") or summary.get("expectedFailures") or summary.get("result") != "Passed":
        failures.append("The shard contains failures, expected failures or skipped tests")
    if any(node.get("result") != "Passed" for _, node in cases):
        failures.append("Every selected test must individually report Passed")
    report = [f"Executed {len(actual)} of {len(expected)} selected tests.", "", "| Test | Result | Seconds |", "|---|---|---|"]
    for identifier, node in sorted(cases, key=lambda item: item[1].get("durationInSeconds", 0), reverse=True):
        report.append(f"| {identifier} | {node.get('result', 'Unknown')} | {node.get('durationInSeconds', 0):.2f} |")
    report.extend(["", f"Runtime warnings recorded: {len(summary.get('runtimeWarnings', []))}."])
    report.extend(failures)
    output = "\n".join(report) + "\n"
    print(output)
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as handle:
            handle.write(output)
    if failures:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
