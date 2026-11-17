#!/usr/bin/env python3
"""Record the compiled candidate and exact simulator identity on this CircleCI Mac."""

import json
import os
from pathlib import Path
import platform
import subprocess
from uuid import UUID

from select_ci_iphone import runtime_identity, select_iphone, simctl


def output(*command):
    return subprocess.check_output(command, text=True).strip()


def main():
    revision = output("git", "rev-parse", "HEAD")
    xcode = output("xcodebuild", "-version")
    architecture = platform.machine()
    if revision != os.environ["CIRCLE_SHA1"]:
        raise SystemExit(f"Unexpected checkout: {revision}")
    if xcode != "Xcode 27.1\nBuild version 27A9275" or architecture != "arm64":
        raise SystemExit(f"Unexpected CircleCI toolchain: {xcode} on {architecture}")

    identifier = "com.apple.CoreSimulator.SimRuntime.iOS-27-0"
    runtime = runtime_identity(identifier)
    if (runtime["version"], runtime["buildversion"]) != ("27.0", "24A434"):
        raise SystemExit(f"Unexpected CircleCI simulator runtime: {runtime}")
    devices = json.loads(simctl("list", "devices", "available", "-j"))["devices"]
    _, device = select_iphone(devices, identifier, "iPhone 17")
    if device.get("deviceTypeIdentifier") != "com.apple.CoreSimulator.SimDeviceType.iPhone-17":
        raise SystemExit(f"Unexpected simulator device type: {device}")
    udid = str(UUID(device["udid"])).upper()
    receipt = {
        "revision": revision,
        "xcode": xcode,
        "architecture": architecture,
        "runtime": runtime,
        "device": device["name"],
        "deviceTypeIdentifier": device["deviceTypeIdentifier"],
        "simulatorUDID": udid,
    }
    Path(".build/circle-evidence/environment.json").write_text(json.dumps(receipt, indent=2) + "\n")
    print(udid)


if __name__ == "__main__":
    main()
