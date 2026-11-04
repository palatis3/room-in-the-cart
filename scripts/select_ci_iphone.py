#!/usr/bin/env python3
import json
import os
import sys


def main():
    devices_by_runtime = json.load(sys.stdin)["devices"]
    candidates = []
    for runtime, devices in devices_by_runtime.items():
        if ".iOS-" not in runtime:
            continue
        version = tuple(map(int, runtime.split(".iOS-", 1)[1].split("-")))
        for device in devices:
            if device["name"].startswith("iPhone") and device.get("isAvailable"):
                candidates.append((version, device))

    if not candidates:
        raise SystemExit("No available iPhone simulator")
    _, device = max(candidates, key=lambda pair: (pair[0], pair[1]["name"] == "iPhone 17"))
    print(f"Using {device['name']} simulator ({device['udid']})")
    with open(os.environ["GITHUB_ENV"], "a") as output:
        output.write(f"SIMULATOR_ID={device['udid']}\n")


if __name__ == "__main__":
    main()
