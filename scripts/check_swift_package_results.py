#!/usr/bin/env python3
"""Verify SwiftPM XCTest outcomes against compiled and reviewed inventories."""

import argparse
import json
from pathlib import Path
import re


SCRIPT_DIR = Path(__file__).resolve().parent
REVIEWED_INVENTORY = SCRIPT_DIR / "swift_package_test_inventory.json"
PACKAGE_ROOT = SCRIPT_DIR.parent / "ios" / "Packages"
PACKAGES = {"CoreDomain", "DeviceSurfaces", "HouseholdClient", "LocalStore", "RecordArchive"}

# The PostgreSQL/HTTPS integration lane runs these separately with its fixtures.
EXPECTED_SKIPS = {
    "HouseholdClient": {
        "HouseholdClientTests.NativeServiceWireTests/testNativeClientAgainstPostgres",
        "HouseholdClientTests.SharedMealNativeWireTests/testSharedMealClientAgainstPostgres",
        "HouseholdClientTests.StoreQuoteNativeWireTests/testStoreQuoteClientAgainstPostgres",
    },
}

SWIFT_NAME = r"[A-Za-z_]\w*"
TEST_CLASS = rf"(?:{SWIFT_NAME}\.)+{SWIFT_NAME}"
SELECTOR = re.compile(rf"{TEST_CLASS}/{SWIFT_NAME}")
TEST_EVENT = re.compile(
    rf"Test Case '-\[({TEST_CLASS}) ({SWIFT_NAME})\]' "
    r"(?:started|(passed|skipped|failed) \(\d+(?:\.\d+)? seconds\))\."
)


def require_exact(actual, expected, label):
    missing, unexpected = expected - actual, actual - expected
    if missing or unexpected:
        raise ValueError(f"{label}. Missing {sorted(missing)}. Unexpected {sorted(unexpected)}.")


def selectors(entries, label):
    if not isinstance(entries, list) or not entries:
        raise ValueError(f"{label} is empty or invalid")
    if not all(isinstance(item, str) and SELECTOR.fullmatch(item) for item in entries):
        raise ValueError(f"{label} contains an unsupported XCTest selector")
    if len(entries) != len(set(entries)):
        raise ValueError(f"{label} contains duplicate XCTest selectors")
    return set(entries)


def test_outcomes(log):
    starts = set()
    outcomes = {}
    for line in log.splitlines():
        if not line.startswith("Test Case "):
            continue
        match = TEST_EVENT.fullmatch(line)
        if not match:
            raise ValueError(f"Unrecognized XCTest event: {line}")
        test_class, method, status = match.groups()
        selector = f"{test_class}/{method}"
        if status is None:
            if selector in starts:
                raise ValueError(f"Duplicate XCTest start: {selector}")
            starts.add(selector)
        elif selector in outcomes or selector not in starts:
            raise ValueError(f"Duplicate or unmatched XCTest outcome: {selector}")
        else:
            outcomes[selector] = status
    require_exact(set(outcomes), starts, "XCTest starts and terminal outcomes differ")
    return outcomes


def verify_package(package, reviewed, compiled, log):
    expected = selectors(reviewed, "Reviewed inventory")
    discovered = selectors(compiled, "Compiled inventory")
    require_exact(discovered, expected, "Compiled tests differ from the reviewed inventory")
    outcomes = test_outcomes(log)
    require_exact(set(outcomes), discovered, "XCTest execution differs from the compiled inventory")
    failures = {name for name, status in outcomes.items() if status == "failed"}
    if failures:
        raise ValueError(f"Failed XCTest cases: {sorted(failures)}")
    skipped = {name for name, status in outcomes.items() if status == "skipped"}
    require_exact(skipped, EXPECTED_SKIPS.get(package, set()), "XCTest skips differ from the approved list")
    return len(outcomes) - len(skipped), len(skipped)


def verify_results(results, package_root, reviewed):
    if not isinstance(reviewed, dict):
        raise ValueError("Invalid reviewed package inventory")
    require_exact(set(reviewed), PACKAGES, "Reviewed package inventory differs from the required packages")
    require_exact({file.parent.name for file in package_root.glob("*/Package.swift")}, PACKAGES,
                  "Swift packages differ from the required packages")
    require_exact({file.stem for file in results.glob("*.log")}, PACKAGES, "Swift package logs differ from the required packages")
    require_exact({file.name.removesuffix(".inventory.txt") for file in results.glob("*.inventory.txt")}, PACKAGES,
                  "Compiled inventories differ from the required packages")
    for package in sorted(PACKAGES):
        try:
            compiled = (results / f"{package}.inventory.txt").read_text(encoding="utf-8").splitlines()
            log = (results / f"{package}.log").read_text(encoding="utf-8")
            passed, skipped = verify_package(package, reviewed[package], compiled, log)
        except (ValueError, OSError) as error:
            raise ValueError(f"{package}: {error}") from error
        print(f"{package}: {passed} passed, {skipped} deliberately skipped")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--results", type=Path, required=True)
    args = parser.parse_args()
    try:
        policy = json.loads(REVIEWED_INVENTORY.read_text(encoding="utf-8"))
        verify_results(args.results, PACKAGE_ROOT, policy["packages"])
    except (ValueError, OSError, KeyError, TypeError) as error:
        parser.exit(1, f"Invalid Swift package results: {error}\n")


if __name__ == "__main__":
    main()
