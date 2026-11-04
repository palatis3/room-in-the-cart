#!/usr/bin/env python3
"""Require the optimized XCTest bundle to match the Release performance case matrix."""

import argparse
import json
from pathlib import Path
import re
import subprocess

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
    return {"include": [{"case": case, "selector": f"{UI_TARGET}/{SUITE}/{method}"}
                        for case, method in METHODS.items()]}


def plan_from_binary(binary):
    symbols = subprocess.check_output(["xcrun", "nm", "-Uj", str(binary)])
    demangled = subprocess.check_output(["xcrun", "swift-demangle", "--compact"], input=symbols)
    return performance_matrix(demangled.decode("utf-8"))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path, help="optimized XCTest bundle executable")
    args = parser.parse_args()
    try:
        matrix = plan_from_binary(args.binary)
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"Could not plan iOS performance tests: {error}\n")
    print(json.dumps(matrix, separators=(",", ":")))


if __name__ == "__main__":
    main()
