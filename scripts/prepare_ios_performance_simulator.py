#!/usr/bin/env python3
"""Prepare one owned performance simulator, preserving each setup failure stage."""

import argparse
import json
from pathlib import Path
import subprocess
import sys
import time
from uuid import UUID


APP_ID = "dev.roominthecart.app"


def prepare(simulator, case, fixture, output):
    UUID(simulator)  # Never operate on the ambiguous 'booted' alias.
    if case not in {"launch", "rendered", "scroll"}:
        raise ValueError("Unknown performance case")
    receipt = {"schemaVersion": 1, "case": case, "status": "running", "stages": []}
    output = Path(output)
    output.parent.mkdir(parents=True, exist_ok=True)

    def save():
        temporary = output.with_suffix(output.suffix + ".tmp")
        temporary.write_text(json.dumps(receipt, indent=2) + "\n")
        temporary.replace(output)

    def stage(name, action):
        entry = {"stage": name, "status": "running"}
        receipt["stages"].append(entry)
        save()
        print(f"Performance setup: {name} started", flush=True)
        started = time.monotonic()
        try:
            value = action()
        except Exception as error:
            entry["status"] = "failed"
            entry["exitCode"] = error.returncode if isinstance(error, subprocess.CalledProcessError) else 1
            receipt["status"] = "failed"
            raise
        else:
            entry["status"] = "passed"
            entry["exitCode"] = 0
            return value
        finally:
            entry["elapsedSeconds"] = round(time.monotonic() - started, 3)
            save()
            print(f"Performance setup: {name} {entry['status']}", flush=True)

    # The workflow's existing eight-minute step deadline remains authoritative.
    # No retries, extra sleeps, app installation, or metric changes occur here.
    stage("boot", lambda: subprocess.run([
        sys.executable, str(Path(__file__).with_name("boot_ios_simulator.py")), simulator,
    ], check=True))
    installed = stage("list-installed-apps", lambda: subprocess.run(
        ["xcrun", "simctl", "listapps", simulator], check=True, stdout=subprocess.PIPE,
    ).stdout)

    def require_absent():
        converted = subprocess.run(
            ["plutil", "-convert", "json", "-o", "-", "--", "-"],
            input=installed, stdout=subprocess.PIPE, check=True,
        )
        apps = json.loads(converted.stdout)
        if not isinstance(apps, dict) or any(not isinstance(value, dict) for value in apps.values()):
            raise ValueError("Unexpected installed-app inventory format")
        if APP_ID in apps or any(value.get("CFBundleIdentifier") == APP_ID for value in apps.values()):
            raise ValueError("Expected a fresh simulator without the Release app")

    stage("verify-app-absent", require_absent)
    if case != "launch":
        def paste():
            with Path(fixture).open("rb") as stream:
                subprocess.run(["xcrun", "simctl", "pbcopy", simulator], stdin=stream, check=True)
        stage("seed-pasteboard", paste)
    receipt["status"] = "passed"
    save()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--simulator", required=True)
    parser.add_argument("--case", required=True, choices=("launch", "rendered", "scroll"))
    parser.add_argument("--fixture", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        prepare(args.simulator, args.case, args.fixture, args.output)
    except subprocess.CalledProcessError as error:
        return error.returncode if error.returncode > 0 else 128 - error.returncode
    except (OSError, ValueError) as error:
        print(f"Performance simulator setup failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
