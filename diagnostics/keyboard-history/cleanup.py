#!/usr/bin/env python3
"""Delete only the simulator whose UUID/name/runtime we created in this run."""
import json
import os
from pathlib import Path
import subprocess
import uuid

out = Path('.build/keyboard-history')
if not (out / 'identity.json').exists():
    raise SystemExit(0)
identity = json.loads((out / 'identity.json').read_text())
device = (out / 'simulator-id.txt').read_text().strip()
uuid.UUID(device)
assert identity['simulatorID'] == device and identity['GITHUB_RUN_ID'] == os.environ['GITHUB_RUN_ID']
assert identity['GITHUB_RUN_ATTEMPT'] == os.environ['GITHUB_RUN_ATTEMPT']
runtime = 'com.apple.CoreSimulator.SimRuntime.iOS-26-2'
assert identity['runtime'] == runtime
inventory = json.loads(subprocess.check_output(['xcrun', 'simctl', 'list', 'devices', '-j']))
matches = [d for d in inventory['devices'].get(runtime, []) if d['udid'] == device]
if not matches:
    (out / 'cleanup.json').write_text(json.dumps({'ownedSimulatorAlreadyAbsent': True, 'simulatorID': device}) + '\n')
    raise SystemExit(0)
assert len(matches) == 1 and matches[0]['name'] == identity['simulatorName']
shutdown = subprocess.run(['xcrun', 'simctl', 'shutdown', device], capture_output=True)
(out / 'shutdown.log').write_bytes(shutdown.stdout + shutdown.stderr)
delete = subprocess.run(['xcrun', 'simctl', 'delete', device], capture_output=True)
(out / 'delete.log').write_bytes(delete.stdout + delete.stderr)
(out / 'cleanup.json').write_text(json.dumps({'simulatorID': device, 'shutdownExit': shutdown.returncode,
                                            'deleteExit': delete.returncode, 'ownedSimulatorOnly': True}) + '\n')
raise SystemExit(delete.returncode)
