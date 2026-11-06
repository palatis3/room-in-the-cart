#!/usr/bin/env python3
"""One original UI02 history on pinned products; no source/product rebuild."""
import argparse
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import threading
import time
import run
from run import (BUNDLE, PREDICATE, command, write, frozen, verify_runtime, stop_capture,
                 invocation_succeeded)
from history_archive import PRODUCTS, restore
from history_protocol import CASES, SELECTORS, CaseLog, compare_history, parse_cases, candidate_evidence

OUT = Path('.build/spanish-done-history')
INPUTS = Path('.build/spanish-done-history-inputs')


def capture_stills(device, out, stop, started, result):
    for delay in (5, 15):
        if stop.wait(max(0, started + delay - time.monotonic())):
            return
        item = {'requestedDelaySeconds': delay, 'requestDelaySeconds': time.monotonic() - started,
                'requestUTC': time.time(), 'exposureTimeKnown': False}
        try:
            with (out / f'still-{delay}.stderr').open('w') as error:
                call = subprocess.run(['xcrun', 'simctl', 'io', device, 'screenshot',
                    str(out / f'after-bQuantity-Done-{delay}s.png')], stdout=subprocess.DEVNULL,
                    stderr=error, timeout=15)
                item['exit'] = call.returncode
        except (OSError, subprocess.SubprocessError) as error:
            item['error'] = str(error)
        finally:
            item['completedUTC'] = time.time()
            item['completionDelaySeconds'] = time.monotonic() - started
            result.append(item)


def execute(out, products):
    if (out / "invocation.json").exists():
        raise ValueError("Exactly one test invocation; no reuse/retry")
    frozen(out)
    device, _ = verify_runtime(out, "pre-test")
    runs = list(products.glob("RoomInTheCart_iphonesimulator*.xctestrun"))
    if len(runs) != 1 or (out / "selectors.txt").read_text() != "\n".join(SELECTORS) + "\n":
        raise ValueError("Unexpected test run or selector")
    # This test must be the first opted-in process on the fresh owned device.
    container = Path(command(["xcrun", "simctl", "get_app_container", device, BUNDLE, "data"]).strip())
    journal_dir = container / "Library/Caches/SpanishDoneDiagnostic"
    if journal_dir.exists():
        raise ValueError("Unexpected pre-existing diagnostic journals")
    streams, children, stills = [], {}, []
    ledger = CaseLog()
    video_start = None
    stop, watcher = threading.Event(), None
    test = None
    status = {"invoked": False, "exit": None, "signal": None}
    write(out / "invocation.json", {"selectors": SELECTORS, "maximumInvocations": 1, "startedUTC": time.time()})

    def interrupted(number, _frame):
        status["signal"] = number
        raise KeyboardInterrupt

    old_handlers = {s: signal.signal(s, interrupted) for s in (signal.SIGINT, signal.SIGTERM, signal.SIGALRM)}
    signal.alarm(65 * 60)
    try:
        live = (out / "events-live.log").open("w")
        live_error = (out / "events-live.stderr").open("w")
        video_error = (out / "video.stderr").open("w")
        streams.extend([live, live_error, video_error])
        children["live"] = subprocess.Popen(["xcrun", "simctl", "spawn", device, "log", "stream",
            "--style", "compact", "--level", "debug", "--predicate", PREDICATE], stdout=live, stderr=live_error)
        write(out / "capture-start.json", {"startedUTC": time.time(), "simulatorID": device,
              "pids": {name: process.pid for name, process in children.items()}})
        time.sleep(0.5)
        if any(p.poll() is not None for p in children.values()):
            raise ValueError("External capture exited before test launch")
        environment = dict(os.environ, TEST_RUNNER_RITC_SPANISH_DONE_DIAGNOSTIC="1")
        args = ["xcodebuild", "-xctestrun", str(runs[0]), "-destination", f"platform=iOS Simulator,id={device}",
                "-resultBundlePath", str(out / "Tests.xcresult"), "-parallel-testing-enabled", "NO",
                "-test-timeouts-enabled", "YES", "-default-test-execution-time-allowance", "720",
                "-maximum-test-execution-time-allowance", "900", "-collect-test-diagnostics", "never",
                *["-only-testing:" + selector for selector in SELECTORS], "test-without-building"]
        write(out / "test-command.json", args)
        test = subprocess.Popen(args, env=environment, stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, text=True, start_new_session=True)
        status["invoked"] = True
        with (out / "Tests.log").open("w") as log:
            for line in test.stdout:
                log.write(line)
                log.flush()
                print(line, end="", flush=True)
                if ledger.feed(line):
                    requested = time.time()
                    started = time.monotonic()
                    children["video"] = subprocess.Popen(["xcrun", "simctl", "io", device, "recordVideo",
                        "--codec=h264", str(out / "screen.mp4")], stdout=video_error, stderr=subprocess.STDOUT)
                    time.sleep(0.5)
                    video_start = {"targetStartLine": ledger.line, "requestedUTC": requested,
                        "processReadyUTC": time.time(), "processReadyDelaySeconds": time.monotonic() - started,
                        "pid": children["video"].pid, "aliveAtReadiness": children["video"].poll() is None,
                        "firstFrameTimeKnown": False, "prefixUIRecorded": False}
                    write(out / "target-video-start.json", video_start)
                    if not video_start["aliveAtReadiness"]:
                        raise ValueError("Target video exited before readiness")
                if video_start is not None and "firstAppLaunchSeconds" not in video_start:
                    launch = re.search(r"t =\s*([0-9.]+)s\s+Launch dev\.roominthecart\.app\.debug", line)
                    if launch:
                        video_start["firstAppLaunchSeconds"] = float(launch[1])
                        video_start["firstAppLaunchLineReceivedUTC"] = time.time()
                        video_start["prelaunchFrameCoverageKnown"] = False
                        write(out / "target-video-start.json", video_start)
                if (not ledger.errors and ledger.active is not None and tuple(ledger.active["case"]) == CASES[-1]
                        and line.startswith("SDD_RUNNER|before|") and watcher is None):
                    video_start["targetBeforeMarkerReceivedUTC"] = time.time()
                    video_start["aliveBeforeTargetMarker"] = children["video"].poll() is None
                    write(out / "target-video-start.json", video_start)
                    if not video_start["aliveBeforeTargetMarker"]:
                        raise ValueError("Target video was not alive when the target marker was received")
                    watcher = threading.Thread(target=capture_stills,
                        args=(device, out, stop, time.monotonic(), stills))
                    watcher.start()
        status["exit"] = test.wait()
        if watcher is not None:
            watcher.join(timeout=35)
    except KeyboardInterrupt:
        status["interrupted"] = True
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        status["harnessError"] = str(error)
    finally:
        signal.alarm(0)
        stop.set()
        if test is not None and test.poll() is None:
            # Cancellation only. This never retries or changes normal XCTest idleness/deadlines.
            try:
                os.killpg(test.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass  # It exited after poll; still preserve status and stop captures.
            try:
                test.wait(timeout=10)
            except subprocess.TimeoutExpired:
                try:
                    os.killpg(test.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                test.wait(timeout=5)
            status["exit"] = test.returncode
        if watcher is not None:
            watcher.join(timeout=20)
        write(out / "case-sequence.json", ledger.proof())
        write(out / "test-status.json", status)
        write(out / "stills-status.json", stills)
        stops = {}
        for name, process in children.items():
            try:
                stops[name] = stop_capture(process, video=name == "video")
            except (OSError, subprocess.SubprocessError) as error:
                stops[name] = {"error": str(error), "pid": process.pid, "forced": True}
        write(out / "capture-stop.json", stops)
        for stream in streams:
            stream.close()
        for number, handler in old_handlers.items():
            signal.signal(number, handler)
    return 0 if invocation_succeeded(status) and ledger.proof()["complete"] else 1



def prepare(archive):
    restore(archive, INPUTS)  # No native calls until exact products/provenance pass.
    run.prepare(OUT, False, run.RUNTIME, '23C54')
    for name in ('source-sha256.json', 'product-sha256.json', 'provenance.json'):
        shutil.copyfile(INPUTS / name, OUT / ('original-' + name))
    shutil.copyfile(INPUTS / 'enumeration.json', OUT / 'enumeration.json')
    enumeration = (OUT / 'enumeration.json').read_text()
    for selector in SELECTORS:
        if enumeration.count('"' + selector + '()"') != 1:
            raise ValueError('Missing/duplicate compiled history selector: ' + selector)
    (OUT / 'selectors.txt').write_text('\n'.join(SELECTORS) + '\n')
    # Required by existing pre-invocation container check. Install exact app only;
    # no launch, data seeding or keyboard action before the original tests.
    command(['xcrun', 'simctl', 'install', json.loads((OUT / 'identity.json').read_text())['simulatorID'],
             str(PRODUCTS / 'Debug-iphonesimulator/RoomInTheCart.app')], timeout=120)
    run.freeze(OUT, PRODUCTS)
    if (OUT / 'product-sha256.json').read_bytes() != (INPUTS / 'product-sha256.json').read_bytes():
        # Compare semantic manifests too: formatting does not constitute product drift.
        if json.loads((OUT / 'product-sha256.json').read_text()) != json.loads((INPUTS / 'product-sha256.json').read_text()):
            raise ValueError('Frozen products differ from archived products')


def collect(out):
    # Keep full original raw result and journals even when classification fails.
    errors = []
    try:
        start = json.loads((out / 'capture-start.json').read_text())['startedUTC']
        if not 0 <= time.time() - start < 90 * 60:
            errors.append('90-minute export window cannot cover the whole capture')
        video = json.loads((out / 'target-video-start.json').read_text())
        if not video.get('aliveAtReadiness') or not video.get('aliveBeforeTargetMarker'):
            errors.append('Target video was not proven alive before receipt of the target before-marker')
    except (OSError, ValueError, KeyError) as error:
        errors.append('Target capture metadata: ' + str(error))
    def validate(journals, live, exported, tests):
        # This is checked after log export as well: strict result collection
        # may have consumed time since the initial window check.
        try:
            age = time.time() - json.loads((out / 'capture-start.json').read_text())['startedUTC']
            if not 0 <= age < 90 * 60:
                errors.append('90-minute export window expired during collection')
        except (OSError, ValueError, KeyError) as error:
            errors.append('Export-window proof: ' + str(error))
        result = compare_history(journals, live, exported, tests)
        if errors:
            raise ValueError('; '.join(errors))
        return result
    status = run.collect(out, expected_count=4, event_validator=validate, export_window='90m')
    try:
        tests = (out / 'Tests.log').read_text()
        journals = {path.name: path.read_text() for path in (out / 'journals').glob('process-*.events')}
        write(out / 'attribution-candidates.json', candidate_evidence(journals, tests))
        sequence = parse_cases(tests).proof()
        write(out / 'case-sequence.json', sequence)
        spanish = [case for case in sequence['cases'] if tuple(case['case']) == CASES[-1]]
        write(out / 'spanish-assessment.json', {'sequenceComplete': sequence['complete'], 'cases': spanish,
              'captureErrors': errors, 'diagnosticOnly': True, 'releaseAcceptance': False,
              'absenceInferenceAllowed': False, 'causalConclusion': None})
    except (OSError, ValueError) as error:
        if out.is_dir():
            write(out / 'spanish-assessment.json', {'complete': False, 'error': str(error)})
        return 1
    return status


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mode', choices=['prepare', 'execute', 'collect', 'cleanup'])
    parser.add_argument('--archive', type=Path, default=Path('.build/spanish-singleton-pinned.zip'))
    args = parser.parse_args()
    run.COMMAND_LOG = OUT / 'control-commands.jsonl'
    try:
        if args.mode == 'prepare':
            prepare(args.archive)
        elif args.mode == 'execute':
            sys.exit(execute(OUT, PRODUCTS))
        elif args.mode == 'collect':
            sys.exit(collect(OUT))
        else:
            sys.exit(run.cleanup(OUT))
    except (OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        parser.exit(1, f'History diagnostic {args.mode} failed: {error}\n')
