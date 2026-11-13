#!/bin/bash
set -euo pipefail
: "${EVIDENCE:?Missing evidence directory}"
mkdir -p "$EVIDENCE"
test "$(git rev-parse HEAD)" = "$EXPECTED_SHA"
xcodebuild -version | tee "$EVIDENCE/toolchain.txt"
test "$(cat "$EVIDENCE/toolchain.txt")" = $'Xcode 27.1\nBuild version 27A9275'
test "$(uname -m)" = arm64
sw_vers > "$EVIDENCE/host.txt"
xcrun simctl list -j > "$EVIDENCE/simulator-inventory.json"
python3 - <<'PY'
import json, os, subprocess, uuid
from pathlib import Path

root = Path(os.environ['EVIDENCE'])
data = json.loads((root / 'simulator-inventory.json').read_text())
runtime_id = 'com.apple.CoreSimulator.SimRuntime.iOS-27-0'
runtime, = [x for x in data['runtimes'] if x['identifier'] == runtime_id and x['isAvailable']]
if runtime.get('version') != '27.0' or not runtime.get('buildversion'):
    raise SystemExit('Expected hosted iOS 27.0 with an exact recorded runtime build')
with (root / 'simulator-id.txt').open('w') as identity_output:
    subprocess.run(['xcrun', 'simctl', 'create', 'RITC Form toggle control',
        'com.apple.CoreSimulator.SimDeviceType.iPhone-17', runtime_id], stdout=identity_output, check=True)
device = (root / 'simulator-id.txt').read_text().strip()
uuid.UUID(device)
with open(os.environ['GITHUB_ENV'], 'a') as output:
    print(f'SIMULATOR_ID={device}', file=output)
identity = {name: os.environ.get(name) for name in ['EXPECTED_SHA', 'EVENT_SHA', 'EVENT_NAME',
    'GITHUB_RUN_ID', 'GITHUB_RUN_ATTEMPT', 'ImageOS', 'ImageVersion']}
identity.update({'checkoutSHA': subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip(),
    'runtime': runtime_id, 'runtimeBuild': runtime['buildversion'], 'simulatorID': device,
    'scope': 'Standalone control; independent of required app acceptance.'})
(root / 'identity.json').write_text(json.dumps(identity, indent=2) + '\n')
PY
