#!/usr/bin/env python3
"""Plan offline UI fixture jobs from their source gates and compiled XCTest inventory."""

import argparse
import json
from pathlib import Path
import re

from plan_ios_tests import UI_TARGET, read_identifiers, selector, write_plan


UI_SOURCES = Path(__file__).resolve().parents[1] / "ios" / "UITests"
PROFILES = {
    "contributor": {
        "CONTRIBUTOR_CAPTURE_UI_FIXTURE": (
            "ContributorRequestUITests",
            "CorrectionPrivacyAcceptanceUITests",
            "GuardianEnrollmentUITests",
            "HistoryGrantReadUITests",
            "HouseholdDevicesUITests",
            "HouseholdRequestPackUITests",
            "MeasurementUITests",
            "RecipeLibraryAcceptanceUITests",
            "RecordsMediaUITests",
            "RequestDuplicateComparisonUITests",
            "SharedMealChangeUITests",
            "SharedMealCivilDateUITests",
            "SharedMealIdeaUITests",
            "SharedStoreQuoteUITests",
        ),
        "STOCK_REVIEW_UI_FIXTURE": ("StockReviewUITests",),
        "AWAY_CARRYOVER_UI_FIXTURE": ("DinnerAwayCarryoverUITests",),
    },
    "dinner": {"DINNER_DECISION_UI_FIXTURE": ("DinnerDecisionSheetUITests",)},
}
MICROPHONE_PROBE = f"{UI_TARGET}/FreeJourneyUITests/testNativeMicrophoneRefusalLeavesTypedCaptureReviewable"
CONDITIONAL = re.compile(r"^[ \t]*#(?:if|elseif)\s+([^\n]+)", re.MULTILINE)
FIXTURE_GATE = re.compile(r"\b[A-Z][A-Z_0-9]*_UI_FIXTURE\b")
CLASS_DECLARATION = re.compile(r"^[ \t]*(?:@?\w+[ \t]+)*class[ \t]+(\w+)", re.MULTILINE)
TEST_DECLARATION = re.compile(r"^[ \t]*(?:\w+[ \t]+)*func[ \t]+(test\w+)\s*\(", re.MULTILINE)


def source_inventory(directory):
    gates = {suite: gate for profile in PROFILES.values() for gate, suites in profile.items() for suite in suites}
    inventory = {}
    for path in sorted(directory.rglob("*.swift")):
        source = path.read_text(encoding="utf-8")
        active_gates = {gate for condition in CONDITIONAL.findall(source) for gate in FIXTURE_GATE.findall(condition)}
        if not active_gates:
            continue
        if len(active_gates) != 1 or not active_gates.issubset(gates.values()):
            raise ValueError(f"Unrecognized or mixed fixture gates in {path.name}: {sorted(active_gates)}")
        gate, = active_gates
        classes = list(CLASS_DECLARATION.finditer(source))
        for index, declaration in enumerate(classes):
            end = classes[index + 1].start() if index + 1 < len(classes) else len(source)
            methods = TEST_DECLARATION.findall(source, declaration.end(), end)
            if not methods:
                continue
            suite = declaration[1]
            if gates.get(suite) != gate:
                raise ValueError(f"Undeclared fixture suite or wrong profile: {suite} under {gate} in {path.name}")
            if suite in inventory or len(methods) != len(set(methods)):
                raise ValueError(f"Duplicate fixture suite or test method: {suite}")
            inventory[suite] = {f"{UI_TARGET}/{suite}/{method}" for method in methods}
    missing = sorted(set(gates) - set(inventory))
    if missing:
        raise ValueError(f"Declared fixture suites are missing from source: {missing}")
    return inventory


def suites_for(profile):
    return sorted(suite for suites in PROFILES[profile].values() for suite in suites)


def matrix():
    return {"include": [{"profile": profile, "shard": suite}
                        for profile in PROFILES for suite in suites_for(profile)]}


def make_plan(enumeration, profile, inventory):
    if not isinstance(enumeration, dict) or enumeration.get("errors") != []:
        raise ValueError("Xcode enumeration is invalid or reported errors")
    values = enumeration.get("values")
    if not isinstance(values, list) or len(values) != 1 or not isinstance(values[0], dict):
        raise ValueError("Xcode enumeration must contain exactly one test configuration")
    configuration = values[0]
    test_plan = configuration.get("testPlan")
    if not isinstance(test_plan, str) or not test_plan:
        raise ValueError("Xcode test configuration is missing its test plan")
    seen = set()
    enabled = read_identifiers(configuration, "enabledTests", seen)
    disabled = read_identifiers(configuration, "disabledTests", seen)

    suites = suites_for(profile)
    other_suites = set(inventory) - set(suites)
    for identifier in enabled + disabled:
        test_selector = selector(identifier)
        target, suite, _ = test_selector.split("/")
        if test_selector == MICROPHONE_PROBE or (target == UI_TARGET and suite in other_suites):
            raise ValueError(f"Incompatible test compiled for {profile}: {identifier}")

    shards = {}
    for suite in suites:
        prefix = f"{UI_TARGET}/{suite}/"
        selected_disabled = [identifier for identifier in disabled if identifier.startswith(prefix)]
        if selected_disabled:
            raise ValueError(f"Fixture tests must not be disabled: {selected_disabled}")
        selected = [identifier for identifier in enabled if identifier.startswith(prefix)]
        actual = {selector(identifier) for identifier in selected}
        expected = inventory[suite]
        if not selected or actual != expected:
            raise ValueError(f"Compiled fixture tests differ for {suite}. "
                             f"Missing {sorted(expected - actual)}; extra {sorted(actual - expected)}")
        shards[suite] = {"selector_file": f"{suite}.txt", "test_identifiers": selected}
    return {"profile": profile, "test_plan": test_plan, "shards": shards}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("matrix", help="validate the source inventory and print the class matrix")
    conditions = commands.add_parser("conditions", help="print the Swift compilation conditions")
    conditions.add_argument("profile", choices=PROFILES)
    plan = commands.add_parser("plan", help="validate compiled tests and write exact selectors")
    plan.add_argument("profile", choices=PROFILES)
    plan.add_argument("--enumeration", type=Path, required=True)
    plan.add_argument("--output-dir", type=Path, required=True)
    try:
        args = parser.parse_args()
        if args.command == "conditions":
            print(" ".join(("DEBUG", *PROFILES[args.profile])))
        else:
            inventory = source_inventory(UI_SOURCES)
            if args.command == "matrix":
                print(json.dumps(matrix(), separators=(",", ":")))
            else:
                enumeration = json.loads(args.enumeration.read_text(encoding="utf-8"))
                write_plan(make_plan(enumeration, args.profile, inventory), args.output_dir)
    except (OSError, ValueError) as error:
        parser.exit(1, f"Could not plan iPhone fixture tests: {error}\n")


if __name__ == "__main__":
    main()
