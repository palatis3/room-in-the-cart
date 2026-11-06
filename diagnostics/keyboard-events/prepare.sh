#!/bin/bash
set -euo pipefail
out=.build/keyboard-events
mkdir -p "$out"
test "$(git rev-parse HEAD)" = "$EXPECTED_SHA"
xcodebuild -version > "$out/toolchain.txt"
test "$(cat "$out/toolchain.txt")" = $'Xcode 26.3\nBuild version 17C529'
test "$(uname -m)" = arm64
sw_vers > "$out/host.txt"
xcrun simctl list -j > "$out/simulator-inventory.json"
python3 - <<'PY'
import hashlib,json,os,subprocess,uuid
from pathlib import Path
out=Path('.build/keyboard-events');data=json.loads((out/'simulator-inventory.json').read_text())
runtime,=[r for r in data['runtimes'] if r['identifier']=='com.apple.CoreSimulator.SimRuntime.iOS-26-2' and r['isAvailable']]
assert runtime['buildversion']=='23C54'
device=subprocess.check_output(['xcrun','simctl','create','RITC Keyboard events','com.apple.CoreSimulator.SimDeviceType.iPhone-17',runtime['identifier']],text=True).strip();uuid.UUID(device)
(out/'simulator-id.txt').write_text(device+'\n')
with open(os.environ['GITHUB_ENV'],'a') as f:f.write('SIMULATOR_ID='+device+'\n')
meta={k:os.environ.get(k) for k in ['EXPECTED_SHA','GITHUB_RUN_ID','GITHUB_RUN_ATTEMPT','ImageOS','ImageVersion']}
meta.update(runtime=runtime['identifier'],runtimeBuild=runtime['buildversion'],simulatorID=device,diagnosticOnly=True,releaseAcceptance=False)
(out/'identity.json').write_text(json.dumps(meta,indent=2)+'\n')
paths=subprocess.check_output(['git','ls-files','-z','ios','shared','config','scripts','diagnostics','.github/workflows/ios-fixtures.yml']).decode().split('\0')
hashes={p:hashlib.sha256(Path(p).read_bytes()).hexdigest() for p in paths if p}
(out/'source-sha256.json').write_text(json.dumps(hashes,indent=2)+'\n')
PY
