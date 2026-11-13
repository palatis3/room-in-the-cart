#!/usr/bin/env python3
"""Run the actual Ubuntu performance preflight locally with a chosen dispatch profile."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import time
import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / '.github/workflows/ios-performance.yml'
STEP = 'Validate performance selection before allocating macOS'
FLAGS = ('enforce_baselines', 'fresh_performance_simulator', 'observe_app_scroll_signposts',
         'capture_scroll_signposts', 'capture_preflight_only', 'enable_performance_diagnostics',
         'simulator_signpost_control')


def input_manifest():
    names = subprocess.check_output(['git', 'ls-files', '-z', '--cached', '--others', '--exclude-standard', '--',
                                     'scripts', 'ios', 'shared', 'config', '.github/workflows'],
                                    cwd=ROOT, timeout=15).decode().rstrip('\0').split('\0')
    result = {}
    for name in sorted(set(names)):
        path = ROOT / name
        if not name or not path.is_file() or path.is_symlink():
            raise ValueError('Preflight source missing or redirected: ' + name)
        result[name] = {'sha256': hashlib.sha256(path.read_bytes()).hexdigest(),
                        'mode': path.stat().st_mode & 0o777}
    return result


def literal(value):
    if type(value) is bool:
        return 'true' if value else 'false'
    if isinstance(value, str):
        return value
    raise ValueError('Unsupported workflow value')


def profile(document, event, case, options):
    trigger = document.get('on', document.get(True))  # PyYAML's YAML 1.1 spelling.
    declared = trigger['workflow_dispatch']['inputs']
    if {name for name, row in declared.items() if row.get('type') == 'boolean'} != set(FLAGS):
        raise ValueError('Workflow boolean roster changed; review required')
    if set(options) != set(FLAGS) or not all(type(value) is bool for value in options.values()):
        raise ValueError('Explicit boolean profile required')
    if event not in ('workflow_dispatch', 'pull_request') or event not in trigger or case not in declared['case']['options']:
        raise ValueError('Unknown event or case')
    inputs = {name: row['default'] for name, row in declared.items()}
    inputs.update(options, case=case)

    def evaluate(expression):
        expression = expression.strip()
        if expression == 'github.event_name':
            return event
        if expression == "github.event_name == 'pull_request' || inputs.enforce_baselines":
            return literal(event == 'pull_request' or inputs['enforce_baselines'])
        if expression == "github.event_name == 'workflow_dispatch' && inputs.case != 'all' && inputs.case || ''":
            return case if event == 'workflow_dispatch' and case != 'all' else ''
        match = re.fullmatch(r'inputs\.(\w+)(?: \|\| false)?', expression)
        if match and match[1] in inputs:
            return literal(inputs[match[1]])
        raise ValueError('Unreviewed workflow expression: ' + expression)

    def expand(value):
        return re.sub(r'\$\{\{\s*(.*?)\s*\}\}', lambda match: evaluate(match[1]), literal(value))

    job = document['jobs']['performance-plan']
    if job['runs-on'] != 'ubuntu-24.04':
        raise ValueError('Only the existing cheap Ubuntu preflight may run locally')
    steps = [row for row in job['steps'] if row.get('name') == STEP]
    if len(steps) != 1 or steps[0].get('env') or job.get('env'):
        raise ValueError('Changed preflight environment or step needs review')
    script = expand(steps[0]['run'])
    environment = {name: expand(value) for name, value in document.get('env', {}).items()}
    environment['GITHUB_EVENT_NAME'] = event
    return script, environment, inputs


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--event', choices=('workflow_dispatch', 'pull_request'), default='workflow_dispatch')
    parser.add_argument('--case', choices=('all', 'launch', 'rendered', 'scroll'), default='all')
    for flag in FLAGS:
        parser.add_argument('--' + flag.replace('_', '-'), action=argparse.BooleanOptionalAction, default=False)
    parser.add_argument('--evidence', type=Path, required=True, help='new output directory; never replaces an attempt')
    args = parser.parse_args()
    original = WORKFLOW.read_bytes()
    script, selected, inputs = profile(yaml.safe_load(original), args.event, args.case,
                                      {flag: getattr(args, flag) for flag in FLAGS})
    args.evidence.mkdir(parents=True, exist_ok=False)
    (args.evidence / 'preflight.sh').write_text(script)
    manifest = input_manifest()
    manifest_bytes = (json.dumps(manifest, indent=2, sort_keys=True) + '\n').encode()
    (args.evidence / 'inputs.json').write_bytes(manifest_bytes)
    receipt = {'workflowSHA256': hashlib.sha256(original).hexdigest(), 'event': args.event,
               'inputs': inputs, 'workflowEnvironment': selected, 'status': 'running',
               'localPython': sys.executable,
               'sourceFiles': len(manifest), 'sourceManifestSHA256': hashlib.sha256(manifest_bytes).hexdigest(),
               'scope': 'Actual cheap workflow step only; no build, simulator or release qualification'}
    path = args.evidence / 'receipt.json'
    path.write_text(json.dumps(receipt, indent=2) + '\n')
    log_path = args.evidence / 'preflight.log'
    started = time.monotonic()
    environment = {**os.environ, **selected}
    # Use the interpreter that loaded this tool, not macOS's xcrun-backed python3
    # launcher. The hosted DEVELOPER_DIR is intentionally preserved as a setting.
    environment['PATH'] = str(Path(sys.executable).parent) + os.pathsep + os.environ.get('PATH', os.defpath)
    with log_path.open('xb') as log:
        child = subprocess.Popen(['bash', '--noprofile', '--norc', '-e', '-o', 'pipefail', '-c', script],
                                 cwd=ROOT, env=environment, stdin=subprocess.DEVNULL,
                                 stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        try:
            while child.poll() is None:
                if time.monotonic() - started > 300 or log_path.stat().st_size > 8 * 1024**2:
                    raise TimeoutError('Preflight wall/output bound exceeded')
                time.sleep(.05)
        except BaseException as exc:
            receipt['error'] = type(exc).__name__ + ': ' + str(exc)
            if child.poll() is None:
                os.killpg(child.pid, signal.SIGTERM)
                try:
                    child.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    os.killpg(child.pid, signal.SIGKILL)
                    child.wait(timeout=5)
        receipt['exitCode'] = child.returncode
    receipt.update(seconds=round(time.monotonic() - started, 3),
                   logSHA256=hashlib.sha256(log_path.read_bytes()).hexdigest(),
                   workflowUnchanged=WORKFLOW.read_bytes() == original,
                   sourceInputsUnchanged=input_manifest() == manifest)
    passed = receipt['exitCode'] == 0 and 'error' not in receipt and receipt['workflowUnchanged'] and receipt['sourceInputsUnchanged']
    receipt['status'] = 'passed' if passed else 'failed'
    path.write_text(json.dumps(receipt, indent=2) + '\n')
    print(json.dumps({'status': receipt['status'], 'seconds': receipt['seconds'], 'receipt': str(path)}))
    return 0 if passed else 1


if __name__ == '__main__':
    raise SystemExit(main())
