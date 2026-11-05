#!/bin/bash
set -euo pipefail

mkdir -p "$EVIDENCE"
xcodebuild -version | tee "$EVIDENCE/toolchain.txt"
test "$(cat "$EVIDENCE/toolchain.txt")" = $'Xcode 26.3\nBuild version 17C529'
test "$(uname -m)" = arm64
sw_vers > "$EVIDENCE/host.txt"
xcrun simctl list -j > "$EVIDENCE/simulator-inventory.json"
python3 - <<'PY'
import json, os
from pathlib import Path

data = json.loads((Path(os.environ["EVIDENCE"]) / "simulator-inventory.json").read_text())
runtime_id = "com.apple.CoreSimulator.SimRuntime.iOS-26-2"
runtime, = [item for item in data["runtimes"] if item["identifier"] == runtime_id and item["isAvailable"]]
if runtime["buildversion"] != "23C54":
    raise SystemExit("Expected hosted iOS 26.2 runtime build 23C54")
device, = [item for item in data["devices"][runtime_id] if item["name"] == "iPhone 17" and item["isAvailable"]]
with open(os.environ["GITHUB_ENV"], "a") as output:
    print(f"SIMULATOR_ID={device['udid']}", file=output)
PY
