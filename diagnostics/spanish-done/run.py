#!/usr/bin/env python3
"""One opt-in diagnostic invocation; test status and capture integrity stay separate."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import signal
import stat
import subprocess
import sys
import threading
import time
from uuid import UUID, uuid4

from preservation import BASE, ORIGINAL, check
from protocol import MAX_JOURNAL_BYTES, compare_sinks, validate_png

SELECTOR = "RoomInTheCartUITests/RoomInTheCartUITests/testSpanishEntryPreservesOriginalFoodNameAndSavedAnswer"
BUNDLE = "dev.roominthecart.app.debug"
RUNTIME = "com.apple.CoreSimulator.SimRuntime.iOS-26-2"
PREDICATE = 'subsystem == "dev.roominthecart.spanishdone" AND category == "events"'


def write(path, value):
    temporary = path.with_name(path.name + ".tmp")
    temporary.write_text(json.dumps(value, indent=2) + "\n")
    temporary.replace(path)


def command(args, *, timeout=30):
    return subprocess.check_output(args, text=True, timeout=timeout)


def hashes(paths):
    result = {}
    for path in sorted(paths):
        if path.is_symlink() or not path.is_file():
            raise ValueError("Expected regular input file: " + str(path))
        result[str(path)] = hashlib.sha256(path.read_bytes()).hexdigest()
    if not result:
        raise ValueError("No frozen input files")
    return result


def frozen(out):
    identity = json.loads((out / "identity.json").read_text())
    if command(["git", "rev-parse", "HEAD"]).strip() != identity["sourceCommit"]:
        raise ValueError("Source commit changed")
    if command(["git", "ls-files", "--others", "--exclude-standard", "--", "ios", "shared", "config", "scripts", "diagnostics", ".github"]).strip():
        raise ValueError("Untracked source/harness input")
    for name in ("source-sha256.json", "product-sha256.json"):
        expected = json.loads((out / name).read_text())
        if hashes([Path(p) for p in expected]) != expected:
            raise ValueError("Frozen inputs changed: " + name)
    products = Path((out / "product-root.txt").read_text().strip())
    paths = list(products.rglob("*"))
    if any(p.is_symlink() for p in paths) or hashes([p for p in paths if p.is_file()]) != json.loads((out / "product-sha256.json").read_text()):
        raise ValueError("Product inventory changed")


def owned(out):
    identity = json.loads((out / "identity.json").read_text())
    device = identity["simulatorID"]
    UUID(device)
    inventory = json.loads(command(["xcrun", "simctl", "list", "devices", "-j"]))
    matches = [(runtime, item) for runtime, devices in inventory["devices"].items()
               for item in devices if item["udid"] == device]
    if len(matches) != 1 or matches[0][0] != identity["runtime"] or matches[0][1]["name"] != identity["name"]:
        raise ValueError("Owned simulator identity mismatch")
    return device, matches[0][1]


def verify_runtime(out, phase):
    device, item = owned(out)
    identity = json.loads((out / "identity.json").read_text())
    proof = {"phase": phase, "simulatorID": device, "runtime": identity["runtime"],
             "expectedBuild": identity["expectedRuntimeBuild"], "actualBuild": None,
             "matched": False, "observedUTC": time.time(), "queryTimeoutSeconds": 90}
    started = time.monotonic()
    try:
        actual = command(["xcrun", "simctl", "getenv", device, "SIMULATOR_RUNTIME_BUILD_VERSION"], timeout=90).strip()
        proof.update(actualBuild=actual, matched=actual == proof["expectedBuild"])
    except (OSError, subprocess.SubprocessError) as error:
        proof["queryError"] = str(error)
    proof["queryElapsedSeconds"] = time.monotonic() - started
    # Keep every observation, including a mismatch, even if another check is requested later.
    number = len(list(out.glob("runtime-check-*.json"))) + 1
    write(out / f"runtime-check-{number:03d}.json", proof)
    identity["actualRuntimeBuild"] = proof["actualBuild"]
    identity["runtimeBuildVerified"] = proof["matched"]
    write(out / "identity.json", identity)
    if not proof["matched"]:
        raise ValueError(f"Runtime build not verified: expected {proof['expectedBuild']}, observed {proof['actualBuild']!r}; no substitution/retry")
    return device, item


def prepare(out, wiring, runtime, runtime_build=None):
    out.mkdir(parents=True, exist_ok=False)
    if wiring and not runtime_build:
        raise ValueError("Local wiring requires an explicit expected runtime build")
    runtime_build = runtime_build or "23C54"
    if not re.fullmatch(r"[A-Za-z0-9]+", runtime_build):
        raise ValueError("Invalid expected runtime build")
    if not wiring and (runtime != RUNTIME or runtime_build != "23C54"):
        raise ValueError("Representative diagnostic requires exact iOS26.2/23C54")
    expected = os.environ["EXPECTED_SHA"]
    if not re.fullmatch(r"[a-f0-9]{40}", expected) or command(["git", "rev-parse", "HEAD"]).strip() != expected:
        raise ValueError("Expected exact checkout SHA")
    if command(["git", "status", "--porcelain", "--untracked-files=no"]).strip():
        raise ValueError("Tracked checkout is dirty")
    if command(["git", "ls-files", "--others", "--exclude-standard", "--", "ios", "shared", "config", "scripts", "diagnostics", ".github"]).strip():
        raise ValueError("Untracked source/harness input")
    if os.environ.get("GITHUB_RUN_ATTEMPT", "1") != "1":
        raise ValueError("No diagnostic rerun/retry")
    changes = command(["git", "diff", "--name-only", BASE, "HEAD"]).splitlines()
    if any(p not in ORIGINAL and p != ".github/workflows/ios-fixtures.yml"
           and not p.startswith("diagnostics/spanish-done/") for p in changes):
        raise ValueError("Changes outside the reviewed b359 diagnostic overlay")
    check(Path.cwd())
    toolchain = command(["xcodebuild", "-version"])
    (out / "toolchain.txt").write_text(toolchain)
    if not wiring and (toolchain.strip() != "Xcode 26.3\nBuild version 17C529" or os.uname().machine != "arm64"):
        raise ValueError("Representative diagnostic requires arm64 Xcode26.3/17C529")
    inventory = json.loads(command(["xcrun", "simctl", "list", "-j"]))
    write(out / "simulator-inventory.json", inventory)
    candidates = [r for r in inventory["runtimes"] if r["identifier"] == runtime and r["isAvailable"]]
    matches = [r for r in candidates if r["buildversion"] == runtime_build]
    write(out / "runtime-selection.json", {"runtime": runtime, "expectedBuild": runtime_build,
          "availableCandidates": candidates, "exactMatchCount": len(matches)})
    if len(matches) != 1:
        raise ValueError("Required runtime/build unavailable; no substitution")
    name = "RITC Spanish Done " + str(uuid4())
    device = command(["xcrun", "simctl", "create", name,
                      "com.apple.CoreSimulator.SimDeviceType.iPhone-17", runtime]).strip()
    UUID(device)
    write(out / "identity.json", {"simulatorID": device, "name": name, "runtime": runtime,
          "expectedRuntimeBuild": runtime_build, "inventoryRuntimeBuild": matches[0]["buildversion"],
          "actualRuntimeBuild": None, "runtimeBuildVerified": False, "sourceCommit": expected,
          "diagnosticOnly": True, "releaseAcceptance": False, "wiringOnly": wiring,
          "hostImage": os.environ.get("ImageVersion"), "runID": os.environ.get("GITHUB_RUN_ID")})
    # No retries/erasure; reject the observed exit-0 migration failure too.
    with (out / "boot.log").open("w") as log:
        result = subprocess.run(["xcrun", "simctl", "bootstatus", device, "-b"],
                                stdout=log, stderr=subprocess.STDOUT, timeout=420)
    result.check_returncode()
    boot = (out / "boot.log").read_text()
    if "Data Migration Failed" in boot or re.search(r"Status=3, isTerminal=YES(?:,|\.)", boot):
        raise ValueError("Simulator reported migration failure despite exit 0")
    verify_runtime(out, "post-boot")
    tracked = command(["git", "ls-files", "-z", "ios", "shared", "config", "scripts", "diagnostics",
                       ".github/workflows/ios-fixtures.yml"]).split("\0")
    write(out / "source-sha256.json", hashes([Path(p) for p in tracked if p]))
    (out / "selectors.txt").write_text(SELECTOR + "\n")


def freeze(out, products):
    data = json.loads((out / "enumeration.json").read_text())
    sys.path.insert(0, str(Path("scripts").resolve()))
    from plan_ios_tests import DURATIONS_PATH, make_plan, selector
    plan = make_plan(data, json.loads(DURATIONS_PATH.read_bytes()), ui_shards=10)
    selected = [selector(t) for shard in plan["shards"].values() for t in shard["test_identifiers"]]
    if selected.count(SELECTOR) != 1:
        raise ValueError("Original complete Spanish selector must be compiled exactly once")
    paths = list(products.rglob("*"))
    if any(p.is_symlink() for p in paths):
        raise ValueError("Linked product member")
    write(out / "product-sha256.json", hashes([p for p in paths if p.is_file()]))
    (out / "product-root.txt").write_text(str(products) + "\n")
    frozen(out)


def stop_capture(process, *, video=False):
    """Signals only the child object this invocation started; never an old stored PID."""
    status = {"pid": process.pid, "aliveBeforeStop": process.poll() is None, "forced": False}
    if process.poll() is None:
        process.send_signal(signal.SIGINT if video else signal.SIGTERM)
        try:
            process.wait(timeout=20 if video else 5)
        except subprocess.TimeoutExpired:
            status["forced"] = True
            process.kill()
            process.wait(timeout=5)
    status["exit"] = process.returncode
    return status


def capture_stills(device, out, stop, started, result):
    for delay in (5, 15):
        if stop.wait(max(0, started + delay - time.monotonic())):
            return
        target = out / f"after-bQuantity-Done-{delay}s.png"
        item = {"requestedDelaySeconds": delay, "actualDelaySeconds": time.monotonic() - started}
        try:
            with (out / f"still-{delay}.stderr").open("w") as error:
                call = subprocess.run(["xcrun", "simctl", "io", device, "screenshot", str(target)],
                                      stdout=error, stderr=subprocess.STDOUT, timeout=15)
            item["exit"] = call.returncode
        except (OSError, subprocess.TimeoutExpired) as error:
            item["error"] = str(error)
        result.append(item)


def invocation_succeeded(status):
    return (status.get("invoked") is True and status.get("exit") == 0
            and not status.get("signal") and not status.get("interrupted")
            and not status.get("harnessError"))


def execute(out, products):
    if (out / "invocation.json").exists():
        raise ValueError("Exactly one test invocation; no reuse/retry")
    frozen(out)
    device, _ = verify_runtime(out, "pre-test")
    runs = list(products.glob("RoomInTheCart_iphonesimulator*.xctestrun"))
    if len(runs) != 1 or (out / "selectors.txt").read_text() != SELECTOR + "\n":
        raise ValueError("Unexpected test run or selector")
    # This test must be the first opted-in process on the fresh owned device.
    container = Path(command(["xcrun", "simctl", "get_app_container", device, BUNDLE, "data"]).strip())
    journal_dir = container / "Library/Caches/SpanishDoneDiagnostic"
    if journal_dir.exists():
        raise ValueError("Unexpected pre-existing diagnostic journals")
    streams, children, stills = [], {}, []
    stop, watcher = threading.Event(), None
    test = None
    status = {"invoked": False, "exit": None, "signal": None}
    write(out / "invocation.json", {"selector": SELECTOR, "maximumInvocations": 1, "startedUTC": time.time()})

    def interrupted(number, _frame):
        status["signal"] = number
        raise KeyboardInterrupt

    old_handlers = {s: signal.signal(s, interrupted) for s in (signal.SIGINT, signal.SIGTERM)}
    try:
        live = (out / "events-live.log").open("w")
        live_error = (out / "events-live.stderr").open("w")
        video_error = (out / "video.stderr").open("w")
        streams.extend([live, live_error, video_error])
        children["live"] = subprocess.Popen(["xcrun", "simctl", "spawn", device, "log", "stream",
            "--style", "compact", "--level", "debug", "--predicate", PREDICATE], stdout=live, stderr=live_error)
        children["video"] = subprocess.Popen(["xcrun", "simctl", "io", device, "recordVideo",
            "--codec=h264", str(out / "screen.mp4")], stdout=video_error, stderr=subprocess.STDOUT)
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
                "-only-testing:" + SELECTOR, "test-without-building"]
        write(out / "test-command.json", args)
        test = subprocess.Popen(args, env=environment, stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, text=True, start_new_session=True)
        status["invoked"] = True
        with (out / "Tests.log").open("w") as log:
            for line in test.stdout:
                log.write(line)
                log.flush()
                print(line, end="", flush=True)
                if line.startswith("SDD_RUNNER|before|") and watcher is None:
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
        stop.set()
        if test is not None and test.poll() is None:
            # Cancellation only. This never retries or changes normal XCTest idleness/deadlines.
            os.killpg(test.pid, signal.SIGTERM)
            try:
                test.wait(timeout=10)
            except subprocess.TimeoutExpired:
                os.killpg(test.pid, signal.SIGKILL)
                test.wait(timeout=5)
            status["exit"] = test.returncode
        if watcher is not None:
            watcher.join(timeout=20)
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
    return 0 if invocation_succeeded(status) else 1


def collect_journals(source, target):
    """Copies only bounded fixed-token journals, never the rest of the app container."""
    if source.is_symlink() or not source.is_dir():
        raise ValueError("Missing or linked diagnostic directory")
    paths = list(source.iterdir())
    if not 1 <= len(paths) <= 8:
        raise ValueError("Missing/excessive process journals")
    target.mkdir(exist_ok=False)
    for path in paths:
        mode = path.lstat().st_mode
        if not re.fullmatch(r"process-[1-9][0-9]*\.events", path.name) or not stat.S_ISREG(mode) or path.stat().st_size > MAX_JOURNAL_BYTES:
            raise ValueError("Unexpected/linked/oversized journal member")
        shutil.copyfile(path, target / path.name)
    return {p.name: p.read_text() for p in target.iterdir()}


def collect(out):
    if not out.is_dir():
        return 1  # Preparation never created evidence; do not invoke native tools.
    # Always preserve the original result, even if input ownership/capture later fails.
    test = collect_test_result(out, validate=False)
    errors, records, journals = [], {}, {}
    try:
        frozen(out)
        device, _ = owned(out)
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        write(out / "capture-status.json", {"complete": False, "errors": [str(error)], "absenceInferenceAllowed": False})
        return 1
    test = collect_test_result(out)
    try:
        container = Path(command(["xcrun", "simctl", "get_app_container", device, BUNDLE, "data"]).strip())
        journals = collect_journals(container / "Library/Caches/SpanishDoneDiagnostic", out / "journals")
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        errors.append("Journal collection: " + str(error))
    with (out / "events-export.log").open("w") as log, (out / "events-export.stderr").open("w") as error_log:
        try:
            export = subprocess.run(["xcrun", "simctl", "spawn", device, "log", "show", "--last", "25m",
                "--info", "--debug", "--style", "compact", "--timezone", "UTC", "--predicate", PREDICATE],
                stdout=log, stderr=error_log, timeout=120)
            records["exportExit"] = export.returncode
            if export.returncode:
                errors.append("Persisted log export failed")
        except (OSError, subprocess.TimeoutExpired) as error:
            errors.append("Persisted log export: " + str(error))
    try:
        stops = json.loads((out / "capture-stop.json").read_text())
        if not stops["live"]["aliveBeforeStop"] or stops["live"]["forced"]:
            errors.append("Live stream ended early or required forced stop")
        video = stops["video"]
        if not video["aliveBeforeStop"] or video["forced"] or video["exit"] != 0 or (out / "screen.mp4").stat().st_size < 1024:
            errors.append("External video did not finalize normally")
        # Video is retained but not claimed decoded; completeness requires both fully decoded stills.
        records["videoDecoded"] = False
        stills = json.loads((out / "stills-status.json").read_text())
        if len(stills) != 2 or any(s.get("exit") != 0 for s in stills):
            raise ValueError("Both bounded external still captures are required")
        records["stills"] = [validate_png(out / f"after-bQuantity-Done-{delay}s.png") for delay in (5, 15)]
        records["events"] = compare_sinks(journals, (out / "events-live.log").read_text(),
                                         (out / "events-export.log").read_text(), (out / "Tests.log").read_text())
    except (OSError, ValueError, KeyError) as error:
        errors.append("Capture validation: " + str(error))
    write(out / "capture-status.json", {"complete": not errors, "errors": errors, "records": records,
          "absenceInferenceAllowed": False, "causalConclusion": None})
    return 0 if not errors and test.get("strictExit") == 0 and invocation_succeeded(test.get("raw") or {}) else 1


def collect_test_result(out, *, validate=True):
    test = {"raw": None}
    status_path = out / "test-status.json"
    if not (out / "invocation.json").exists() and not status_path.exists():
        test["notInvoked"] = True
        write(out / "test-result.json", test)
        return test
    try:
        if status_path.exists():
            test["raw"] = json.loads(status_path.read_text())
    except (OSError, ValueError) as error:
        test["statusReadError"] = str(error)
    if not validate:
        test["validationNotRun"] = True
        write(out / "test-result.json", test)
        return test
    try:
        for kind, name in (("summary", "test-summary.json"), ("tests", "test-details.json")):
            (out / name).write_text(command(["xcrun", "xcresulttool", "get", "test-results", kind,
                "--path", str(out / "Tests.xcresult"), "--compact"], timeout=90))
        args = [sys.executable, "scripts/check_ios_test_results.py", "--selectors", str(out / "selectors.txt"),
                "--expected-count", "1", "--summary", str(out / "test-summary.json"), "--tests", str(out / "test-details.json"),
                "--result-bundle", str(out / "Tests.xcresult"), "--test-log", str(out / "Tests.log")]
        with (out / "strict.log").open("w") as log:
            test["strictExit"] = subprocess.run(args, stdout=log, stderr=subprocess.STDOUT, timeout=120).returncode
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        test["exportOrStrictError"] = str(error)
    write(out / "test-result.json", test)
    return test


def cleanup(out):
    if not (out / "identity.json").exists():
        return 0
    device, item = owned(out)
    # Keep the owned device available for manual inspection; never delete or erase it here.
    status = 0 if item["state"] == "Shutdown" else subprocess.run(["xcrun", "simctl", "shutdown", device], timeout=30).returncode
    write(out / "cleanup-status.json", {"simulatorID": device, "shutdownExit": status, "deleted": False})
    return status


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=["prepare", "verify-runtime", "freeze", "execute", "collect", "cleanup"])
    parser.add_argument("--out", type=Path, default=Path(".build/spanish-done"))
    parser.add_argument("--products", type=Path, default=Path(".build/spanish-done-products/Build/Products"))
    parser.add_argument("--wiring", action="store_true", help="Explicit local wiring mode; never representative/release acceptance")
    parser.add_argument("--runtime", default=RUNTIME)
    parser.add_argument("--runtime-build", help="Required expected build for local wiring; representative default is23C54")
    args = parser.parse_args()
    try:
        if args.mode == "prepare":
            prepare(args.out, args.wiring, args.runtime, args.runtime_build)
        elif args.mode == "verify-runtime":
            verify_runtime(args.out, "pre-build")
        elif args.mode == "freeze":
            freeze(args.out, args.products)
        elif args.mode == "execute":
            sys.exit(execute(args.out, args.products))
        elif args.mode == "collect":
            sys.exit(collect(args.out))
        else:
            sys.exit(cleanup(args.out))
    except (OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        parser.exit(1, f"Spanish diagnostic {args.mode} failed: {error}\n")
