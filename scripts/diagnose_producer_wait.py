#!/usr/bin/env python3
"""Diagnostic-only: sample one owned build still running after five minutes."""
import json
import os
from pathlib import Path
import subprocess
import sys
import time

DIRECTORY = Path('.build/producer-wait')
DEVELOPER = '/Applications/Xcode_27.1.app/Contents/Developer'


def collect(command, path, timeout):
    """Bound only the evidence command, never signal the build being observed."""
    with path.open('wb') as output, path.with_suffix(path.suffix + '.stderr').open('wb') as errors:
        process = subprocess.Popen(command, stdout=output, stderr=errors)
        try:
            return {'status': 'completed', 'exitCode': process.wait(timeout=timeout)}
        except subprocess.TimeoutExpired:
            result = {'status': 'timed-out'}
            try:
                process.kill()
            except OSError as error:
                result.update(termination='kill-failed', error=str(error))
            else:
                try:
                    result.update(termination='reaped', exitCode=process.wait(timeout=5))
                except subprocess.TimeoutExpired:
                    result['termination'] = 'unreaped'
                except OSError as error:
                    result.update(termination='reap-failed', error=str(error))
            return result


def owned_process(text, pid, parent, uid):
    rows = [line.split(None, 3) for line in text.splitlines() if line.strip()]
    return (len(rows) == 1 and len(rows[0]) == 4 and
            rows[0][:3] == [str(pid), str(parent), str(uid)] and
            rows[0][3] == DEVELOPER + '/usr/bin/xcodebuild')


def package_graph_phase(text):
    if 'Resolve Package Graph' not in text:
        return 'no-graph-marker'
    if 'Resolved source packages:' in text.rsplit('Resolve Package Graph', 1)[1]:
        return 'graph-completed'
    return 'graph-started'


def print_sample_excerpt(path):
    if not path.is_file():
        print('Owned xcodebuild sample excerpt: file unavailable.', flush=True)
        return
    with path.open(errors='replace') as sample:
        text = sample.read(16001)
    excerpt = ''.join(text[:16000].splitlines(keepends=True)[:120])
    print('BEGIN owned xcodebuild sample excerpt (at most 120 lines / 16000 characters)', flush=True)
    print(excerpt, flush=True)
    print('END owned xcodebuild sample excerpt; ' +
          ('TRUNCATED; full file retained.' if len(excerpt) < len(text) else 'complete.'), flush=True)


def observe(build):
    receipt = {'buildPid': build.pid, 'observedAt': time.time()}
    def save():
        (DIRECTORY / 'capture.json').write_text(json.dumps(receipt, indent=2) + '\n')
    try:
        if build.poll() is not None:
            receipt['outcome'] = 'build-already-exited'
            return
        # comm excludes arguments/environment; this snapshot contains no app data.
        receipt['processTree'] = collect(
            ['/bin/ps', '-ww', '-axo', 'pid=,ppid=,uid=,stat=,etime=,comm='], DIRECTORY / 'process-tree.txt', 10)
        identity = DIRECTORY / 'build-identity.txt'
        receipt['identity'] = collect(
            ['/bin/ps', '-ww', '-p', str(build.pid), '-o', 'pid=,ppid=,uid=,comm='], identity, 10)
        if (receipt['identity'] != {'status': 'completed', 'exitCode': 0} or
                not owned_process(identity.read_text(), build.pid, os.getpid(), os.getuid()) or
                build.poll() is not None):
            receipt['outcome'] = 'owned-live-build-not-confirmed'
            return
        # Log delivery can lag the process. Label the observation, but never use
        # a buffered marker to decide whether to collect this diagnostic sample.
        try:
            text = Path('.build/ios-build-evidence/build.log').read_text(errors='replace')
            receipt['packageGraphPhase'] = package_graph_phase(text)
        except OSError as error:
            receipt.update(packageGraphPhase='unknown', buildLogError=str(error))
        # The retained Popen owns this unreaped child. A PID cannot be reused
        # before it is reaped; no external PID or process-name match is sampled.
        save()
        receipt['sample'] = collect(
            ['/usr/bin/sample', str(build.pid), '3', '1', '-file', str(DIRECTORY / 'build.sample.txt')],
            DIRECTORY / 'sample-command.log', 15)
        print_sample_excerpt(DIRECTORY / 'build.sample.txt')
        receipt['outcome'] = 'sample-attempted'
    except Exception as error:
        receipt.update(outcome='capture-failed', error=str(error))
    finally:
        save()
        print('Producer wait capture: ' + receipt['outcome'] +
              '; phase=' + receipt.get('packageGraphPhase', 'unknown') +
              '; tree=' + receipt.get('processTree', {}).get('status', 'not-run') +
              '; sample=' + receipt.get('sample', {}).get('status', 'not-run') +
              '; sample-exit=' + str(receipt.get('sample', {}).get('exitCode', 'unavailable')), flush=True)


def run(command):
    assert os.environ.get('RUNNER_ENVIRONMENT') == 'github-hosted'
    assert os.environ.get('GITHUB_REPOSITORY') == 'palatis3/room-in-the-cart'
    assert os.environ.get('DEVELOPER_DIR') == DEVELOPER and os.getuid() != 0
    assert command and command[0] == 'xcodebuild' and command[-1] == 'build-for-testing'
    DIRECTORY.mkdir(parents=True, exist_ok=True)
    # Resolve to the same reviewed toolchain explicitly; preserve every argument.
    build = subprocess.Popen([DEVELOPER + '/usr/bin/xcodebuild', *command[1:]])
    print('Producer wait observer: started; one capture after 300 seconds if the owned build is still running.', flush=True)
    try:
        status = build.wait(timeout=300)
        (DIRECTORY / 'capture.json').write_text(json.dumps({'outcome': 'build-exited-before-observation', 'exitCode': status}) + '\n')
        print('Producer wait capture: build-exited-before-observation', flush=True)
    except subprocess.TimeoutExpired:
        try:
            observe(build)
        except Exception:
            print('Producer wait capture: evidence-write-failed; build continues.', flush=True)
        status = build.wait()  # Original native allowance remains the workflow's 35-minute job cap.
    return status if status >= 0 else 128 - status


if __name__ == '__main__':
    assert sys.argv[1] == '--'
    raise SystemExit(run(sys.argv[2:]))
