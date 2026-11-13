#!/usr/bin/env python3
"""Enumerate the compiled iPhone tests and retain each discovery attempt."""

import argparse
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
from uuid import UUID

from plan_ios_tests import DURATIONS_PATH, make_plan, write_plan


BUNDLE_ID = "dev.roominthecart.app.debug"
# The single complete enumeration.errors entry from Xcode 26.3 in job 127611996888.
# Fail closed if Xcode reports a different cause or app, including in the same entry.
NOT_FOUND = (
    'The request was denied by service delegate (SBMainWorkspace) for reason: NotFound '
    f'("Application "{BUNDLE_ID}" is unknown to FrontBoard").'
)
HOST_MISSING = (
    "RoomInTheCart encountered an error. (Underlying Error: Failed to install or launch the test runner. "
    f"(Underlying Error: Simulator device failed to launch {BUNDLE_ID}. {NOT_FOUND} "
    f'(Underlying Error: The request to open "{BUNDLE_ID}" failed. {NOT_FOUND} '
    f'(Underlying Error: The operation couldn’t be completed. Application "{BUNDLE_ID}" is unknown to FrontBoard.))))'
)


def discover(simulator, products, diagnostics, plan_dir):
    diagnostics.mkdir(parents=True)  # A new directory prevents stale or overwritten evidence.
    stages = diagnostics / "stages.txt"
    stages.write_text("Checking compiled test run and simulator ID\n", encoding="utf-8")
    UUID(simulator)  # Only accept a specific simulator, never the "booted" alias.
    test_runs = list(products.glob("RoomInTheCart_iphonesimulator*.xctestrun"))
    if len(test_runs) != 1:
        raise ValueError(f"Expected one compiled test run, found {len(test_runs)}")

    def run(stage, command):
        with stages.open("a", encoding="utf-8") as log:
            print(stage, file=log, flush=True)
            result = subprocess.run(command, check=False)
            print(f"{stage}: exit {result.returncode}", file=log)
            result.check_returncode()

    def enumerate_tests(attempt):
        path = diagnostics / f"attempt-{attempt}.json"
        run(f"enumeration {attempt}", [
            "xcodebuild", "-xctestrun", str(test_runs[0]),
            "-destination", f"platform=iOS Simulator,id={simulator}", "-parallel-testing-enabled", "NO",
            "-enumerate-tests", "-test-enumeration-style", "flat", "-test-enumeration-format", "json",
            "-test-enumeration-output-path", str(path.resolve()), "test-without-building",
        ])
        return path, json.loads(path.read_bytes())

    run("bootstatus", [sys.executable, str(Path(__file__).with_name("boot_ios_simulator.py")), simulator])
    path, inventory = enumerate_tests(1)
    if isinstance(inventory, dict) and inventory.get("errors") == [HOST_MISSING]:
        app = products / "Debug-iphonesimulator/RoomInTheCart.app"
        with (app / "Info.plist").open("rb") as file:
            info = plistlib.load(file)
        if info.get("CFBundleIdentifier") != BUNDLE_ID or info.get("CFBundleSupportedPlatforms") != ["iPhoneSimulator"]:
            raise ValueError("Recovery requires the compiled Debug simulator app")
        print("FrontBoard could not find the Debug test host. Installing it before a second enumeration.", flush=True)
        run("install Debug host", ["xcrun", "simctl", "install", simulator, str(app)])
        run("confirm Debug host", ["xcrun", "simctl", "get_app_container", simulator, BUNDLE_ID, "app"])
        path, inventory = enumerate_tests(2)

    plan = make_plan(inventory, json.loads(DURATIONS_PATH.read_bytes()), ui_shards=10)
    write_plan(plan, plan_dir)
    shutil.copyfile(path, plan_dir / "test-enumeration.json")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--simulator", required=True)
    args = parser.parse_args()
    try:
        discover(args.simulator, Path(".build/DerivedData/Build/Products"),
                 Path(".build/test-discovery"), Path(".build/test-plan"))
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"Could not discover iPhone tests: {error}\n")
