#!/usr/bin/env python3
"""Require the optimized XCTest bundle to match the Release performance case matrix."""

import argparse
import json
import os
from pathlib import Path
import re
import subprocess

from ci_mac_slots import with_macos_slots

from check_ios_performance import METHODS, SUITE
from plan_ios_tests import UI_TARGET


CLASS_PREFIX = f"@objc {UI_TARGET}.{SUITE}."
TEST_SYMBOL = re.compile(r"(test\w*)\(\)(?: async)?(?: throws)? -> \(\)")


def performance_matrix(demangled):
    compiled = set()
    for line in demangled.splitlines():
        if not line.startswith(CLASS_PREFIX + "test"):
            continue
        match = TEST_SYMBOL.fullmatch(line.removeprefix(CLASS_PREFIX))
        if not match:
            raise ValueError(f"Malformed compiled performance XCTest symbol: {line}")
        method = match[1]
        if method in compiled:
            raise ValueError(f"Duplicate compiled performance XCTest method: {method}")
        compiled.add(method)

    expected = set(METHODS.values())
    if not expected or len(expected) != len(METHODS):
        raise ValueError("Performance case declarations are empty or contain duplicate methods")
    if compiled != expected:
        raise ValueError(f"Compiled performance XCTest inventory differs. "
                         f"Missing {sorted(expected - compiled)}; extra {sorted(compiled - expected)}")
    return {"include": with_macos_slots([{"case": case, "selector": f"{UI_TARGET}/{SUITE}/{method}"}
                        for case, method in METHODS.items()], ("case",))}


def plan_from_binary(binary):
    symbols = subprocess.check_output(["xcrun", "nm", "-Uj", str(binary)])
    demangled = subprocess.check_output(["xcrun", "swift-demangle", "--compact"], input=symbols)
    return performance_matrix(demangled.decode("utf-8"))


def validate_request(event, requested_case):
    if not isinstance(requested_case, str):
        raise ValueError("Performance case must be a string")
    if requested_case and (event != "workflow_dispatch" or requested_case not in METHODS):
        raise ValueError("Only an explicit manual dispatch may select launch, rendered or scroll")


def select_matrix(full_matrix, event, requested_case):
    validate_request(event, requested_case)
    rows = full_matrix["include"]
    # Require the full validated inventory even when selecting one diagnostic.
    if len(rows) != len(METHODS) or {row["case"] for row in rows} != set(METHODS):
        raise ValueError("Performance selection requires the complete case matrix")
    return {"include": [row for row in rows if not requested_case or row["case"] == requested_case]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path, nargs="?", help="optimized XCTest bundle executable")
    parser.add_argument("--validate-request", action="store_true", help="validate dispatch before allocating macOS")
    args = parser.parse_args()
    if args.validate_request == bool(args.binary):
        parser.error("Supply either a compiled binary or --validate-request")
    try:
        event = os.environ.get("GITHUB_EVENT_NAME", "")
        requested = os.environ.get("REQUESTED_PERFORMANCE_CASE", "")
        validate_request(event, requested)
        if args.validate_request:
            print(json.dumps({"scope": "targeted diagnostic" if requested else "full performance suite",
                              "cases": [requested] if requested else list(METHODS)}))
            return
        matrix = select_matrix(plan_from_binary(args.binary), event, requested)
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"Could not plan iOS performance tests: {error}\n")
    print(json.dumps(matrix, separators=(",", ":")))


if __name__ == "__main__":
    main()
