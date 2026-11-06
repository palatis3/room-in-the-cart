#!/bin/bash
set -euo pipefail
out=.build/keyboard-history
# This step cannot run before pinned source/product/archive checks succeed.
test -f "$out/restore-verification.json"
test "$(git rev-parse HEAD)" = "$EXPECTED_SHA"
test "$(uname -m)" = arm64
xcodebuild -version > "$out/toolchain.txt"
test "$(cat "$out/toolchain.txt")" = $'Xcode 26.3\nBuild version 17C529'
sw_vers > "$out/host.txt"
xcrun simctl list -j > "$out/simulator-inventory.json"
python3 - <<'PY'
import json,os,subprocess,uuid
from pathlib import Path
out=Path('.build/keyboard-history')
proof=json.loads((out/'restore-verification.json').read_text())
assert proof['archiveOnly'] is False and proof['runtimeSourceUnchanged'] is True
inventory=json.loads((out/'simulator-inventory.json').read_text())
runtime,=[r for r in inventory['runtimes'] if r['identifier']=='com.apple.CoreSimulator.SimRuntime.iOS-26-2' and r['isAvailable']]
assert runtime['buildversion']=='23C54'
name='RITC Keyboard history '+os.environ['GITHUB_RUN_ID']+'-'+str(uuid.uuid4())
device=subprocess.check_output(['xcrun','simctl','create',name,'com.apple.CoreSimulator.SimDeviceType.iPhone-17',runtime['identifier']],text=True).strip()
uuid.UUID(device)
(out/'simulator-id.txt').write_text(device+'\n')
identity={k:os.environ.get(k) for k in ['EXPECTED_SHA','GITHUB_RUN_ID','GITHUB_RUN_ATTEMPT','ImageOS','ImageVersion']}
identity.update(runtime=runtime['identifier'],runtimeBuild=runtime['buildversion'],simulatorID=device,
                simulatorName=name,sourceCommit=proof['sourceCommit'],sourceRunID=proof['sourceRunID'],
                diagnosticOnly=True,releaseAcceptance=False)
(out/'identity.json').write_text(json.dumps(identity,indent=2)+'\n')
with open(os.environ['GITHUB_ENV'],'a') as f:f.write('SIMULATOR_ID='+device+'\n')
PY
# Boot only our newly created simulator. No device erase or keyboard-default edits.
device=$(cat "$out/simulator-id.txt")
xcrun simctl bootstatus "$device" -b > "$out/boot.log" 2>&1
