#!/usr/bin/env python3
"""Build disjoint CI test shards from Xcode's flat test enumeration."""

import argparse
import json
from pathlib import Path
import re


MODEL_TARGET = "RoomInTheCartTests"
UI_TARGET = "RoomInTheCartUITests"
TARGETS = {MODEL_TARGET, UI_TARGET}
DURATIONS_PATH = Path(__file__).with_name("ios_test_durations.json")
TEST_SELECTOR = re.compile(r"[^/\s]+/[^/\s]+/[^/\s]+")


def selector(identifier):
    return identifier.removesuffix("()")


def read_identifiers(configuration, key, seen):
    cases = configuration.get(key)
    if not isinstance(cases, list):
        raise ValueError(f"Xcode enumeration must include a {key} array")
    identifiers = []
    for case in cases:
        identifier = case.get("identifier") if isinstance(case, dict) else None
        if not isinstance(identifier, str) or not TEST_SELECTOR.fullmatch(selector(identifier)):
            raise ValueError(f"Invalid Xcode test identifier in {key}: {identifier!r}")
        test_selector = selector(identifier)
        target = test_selector.split("/", 1)[0]
        if target not in TARGETS:
            raise ValueError(f"Unknown Xcode test target: {target}")
        if test_selector in seen:
            raise ValueError(f"Duplicate Xcode test selector: {test_selector}")
        seen.add(test_selector)
        identifiers.append(identifier)
    return sorted(identifiers)


def make_plan(enumeration, durations, ui_shards):
    if not isinstance(enumeration, dict) or not isinstance(enumeration.get("errors"), list):
        raise ValueError("Xcode enumeration must include an errors array")
    if enumeration["errors"]:
        raise ValueError(f"Xcode test enumeration reported errors: {enumeration['errors']!r}")
    configurations = enumeration.get("values")
    if not isinstance(configurations, list) or len(configurations) != 1:
        raise ValueError("Xcode enumeration must contain exactly one test configuration")
    configuration = configurations[0]
    if (not isinstance(configuration, dict) or not isinstance(configuration.get("testPlan"), str)
            or not configuration["testPlan"]):
        raise ValueError("Xcode test configuration is missing its test plan")

    seen = set()
    enabled = read_identifiers(configuration, "enabledTests", seen)
    disabled = read_identifiers(configuration, "disabledTests", seen)
    # StoreKit scenarios use their dedicated test plan. Every ordinary compiled
    # test must remain enabled so disabling a regression cannot make CI green.
    unexpected_disabled = [identifier for identifier in disabled
                           if not identifier.startswith(f"{MODEL_TARGET}/StoreKitScenarioTests/")]
    if unexpected_disabled:
        raise ValueError(f"Ordinary tests must not be disabled: {unexpected_disabled!r}")
    models = [identifier for identifier in enabled if identifier.startswith(f"{MODEL_TARGET}/")]
    ui_tests = [identifier for identifier in enabled if identifier.startswith(f"{UI_TARGET}/")]
    if not models or not ui_tests:
        raise ValueError("Xcode enumeration must contain enabled model and UI tests")
    if not 1 <= ui_shards <= len(ui_tests):
        raise ValueError(f"Cannot divide {len(ui_tests)} UI tests into {ui_shards} nonempty shards")

    hosted = durations["hosted_seconds"]
    local = durations["local_seconds"]
    multiplier = durations["local_multiplier"]
    default = durations["default_seconds"]
    if any(type(seconds) is not int or seconds <= 0
           for seconds in (multiplier, default, *hosted.values(), *local.values())):
        raise ValueError("Test durations and the local multiplier must be positive integers")
    estimates = {}
    for identifier in ui_tests:
        test_selector = selector(identifier)
        if test_selector in hosted:
            estimates[identifier] = hosted[test_selector]
        elif test_selector in local:
            estimates[identifier] = local[test_selector] * multiplier
        else:
            estimates[identifier] = default

    # Long cases go first. Break ties by name and shard index for stable plans.
    lanes = [[] for _ in range(ui_shards)]
    totals = [0] * ui_shards
    for identifier in sorted(ui_tests, key=lambda name: (-estimates[name], name)):
        index = min(range(ui_shards), key=totals.__getitem__)
        lanes[index].append(identifier)
        totals[index] += estimates[identifier]

    shards = {"models": {"selector_file": "models.txt", "test_identifiers": models}}
    for index, (identifiers, total) in enumerate(zip(lanes, totals), start=1):
        name = f"ui-{index:02d}"
        shards[name] = {
            "selector_file": f"{name}.txt",
            "test_identifiers": sorted(identifiers),
            "estimated_seconds": total,
        }

    return {
        "include": [
            {"shard": name, "expected_count": len(shard["test_identifiers"])}
            for name, shard in shards.items()
        ],
        "test_plan": configuration["testPlan"],
        "disabled_tests": disabled,
        "shards": shards,
    }


def write_plan(plan, output_dir):
    output_dir.mkdir(parents=True, exist_ok=True)
    for shard in plan["shards"].values():
        contents = "".join(f"{selector(identifier)}\n" for identifier in shard["test_identifiers"])
        (output_dir / shard["selector_file"]).write_text(contents, encoding="utf-8")
    (output_dir / "manifest.json").write_text(json.dumps(plan, indent=2) + "\n", encoding="utf-8")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--enumeration", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--ui-shards", type=int, default=10)
    args = parser.parse_args()
    try:
        enumeration = json.loads(args.enumeration.read_text(encoding="utf-8"))
        durations = json.loads(DURATIONS_PATH.read_text(encoding="utf-8"))
        plan = make_plan(enumeration, durations, args.ui_shards)
        write_plan(plan, args.output_dir)
    except (OSError, ValueError) as error:
        parser.exit(1, f"Could not plan iPhone tests: {error}\n")


if __name__ == "__main__":
    main()
