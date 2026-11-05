#!/usr/bin/env python3
"""Bounded macOS resource diagnostics. Never records argv, environments or PIDs."""

import argparse
import datetime
import decimal
import json
import math
import os
import re
import selectors
import signal
import subprocess
import sys
import threading
import time

INTERVAL_SECONDS = 30.0
MAX_SAMPLES = 61
MAX_DURATION_SECONDS = 1800.0
PROBE_TIMEOUT_SECONDS = 2.0
MAX_PROBE_BYTES = 1048576
MAX_LINE_BYTES = 8192
MAX_INTEGER = (1 << 63) - 1
STOP = threading.Event()

# Fixed executable and arguments. No shell, process arguments, environment output,
# privileged APIs, or arbitrary probe commands are accepted from the caller.
COMMANDS = {
    "processes": ("/bin/ps", "-ww", "-axo", "pid=,ppid=,rss=,pcpu=,lstart=,comm="),
    "virtual_memory": ("/usr/bin/vm_stat",),
    "swap": ("/usr/sbin/sysctl", "-n", "vm.swapusage"),
    "physical_memory": ("/usr/sbin/sysctl", "-n", "hw.memsize"),
}
CATEGORIES = {
    "compiler": frozenset(("swift-frontend", "swift-driver", "swiftc", "clang", "clang++")),
    "extractor": frozenset(("extractor.real",)),
    "build_service": frozenset(("xcodebuild", "SWBBuildService", "XCBBuildService")),
}
VM_FIELDS = {
    "Pages free": "pages_free",
    "Pages active": "pages_active",
    "Pages inactive": "pages_inactive",
    "Pages speculative": "pages_speculative",
    "Pages wired down": "pages_wired",
    "Pages purgeable": "pages_purgeable",
    "Pages occupied by compressor": "pages_compressor",
    "Pages stored in compressor": "pages_stored_in_compressor",
    "Compressions": "compressions",
    "Decompressions": "decompressions",
    "Pageins": "pageins",
    "Pageouts": "pageouts",
    "Swapins": "swapins",
    "Swapouts": "swapouts",
}


def numeric_integer(value):
    if not re.fullmatch(r"[0-9]{1,19}", value):
        raise ValueError
    result = int(value)
    if result > MAX_INTEGER:
        raise ValueError
    return result


def bounded_text(data):
    if len(data) > MAX_PROBE_BYTES:
        raise ValueError
    return data.decode("utf-8", errors="strict")


def parse_processes(data, parent_pid=None, identity_state=None):
    groups = {key: {"count": 0, "rss_kib": 0, "cpu_percent": 0.0} for key in CATEGORIES}
    rows = bounded_text(data).splitlines()
    if not rows or len(rows) > 8192:
        raise ValueError
    processes = {}
    for line in rows:
        if len(line) > 4096:
            raise ValueError
        fields = line.split(None, 9)
        if len(fields) != 10:
            raise ValueError
        pid_text, ppid_text, rss_text, cpu_text = fields[:4]
        pid, ppid = numeric_integer(pid_text), numeric_integer(ppid_text)
        if pid == 0 or pid in processes:
            raise ValueError
        rss = numeric_integer(rss_text)
        if not re.fullmatch(r"[0-9]{1,7}(?:\.[0-9]{1,4})?", cpu_text):
            raise ValueError
        cpu = float(cpu_text)
        if not math.isfinite(cpu) or cpu > 1000000:
            raise ValueError
        start = datetime.datetime.strptime(" ".join(fields[4:9]), "%a %b %d %H:%M:%S %Y")
        name = fields[9].rsplit("/", 1)[-1].split(".semmle.", 1)[0]
        category = next((key for key, names in CATEGORIES.items() if name in names), None)
        processes[pid] = (ppid, start, category, rss, cpu)
    # PID/PPID, executable strings and start dates stay in memory only.
    if parent_pid not in processes:
        return {"status": "unavailable"}
    state = identity_state if identity_state is not None else {}
    root_start = processes[parent_pid][1]
    if "root_start" in state and state["root_start"] != root_start:
        return {"status": "unavailable"}
    state["root_start"] = root_start
    previous = state.get("identities", {})
    current = {}
    uncertain = False
    for pid, (ppid, start, category, rss, cpu) in processes.items():
        if category is None:
            continue
        seen = set()
        cursor = pid
        verified = False
        while cursor in processes and cursor not in seen:
            seen.add(cursor)
            if cursor == parent_pid:
                verified = True
                break
            parent, child_start, _, _, _ = processes[cursor]
            if parent not in processes or processes[parent][1] > child_start:
                break
            cursor = parent
        if pid in previous and previous[pid] != start:
            verified = False
        if not verified:
            uncertain = True
            continue
        current[pid] = start
        group = groups[category]
        group["count"] += 1
        group["rss_kib"] += rss
        group["cpu_percent"] += cpu
        if group["rss_kib"] > MAX_INTEGER:
            raise ValueError
    state["identities"] = current
    for group in groups.values():
        group["cpu_percent"] = round(group["cpu_percent"], 4)
    return {"status": "partial" if uncertain else "ok",
            "scope": "verified_parent_descendants", "coverage": "partial", "categories": groups}


def parse_virtual_memory(data):
    text = bounded_text(data)
    match = re.search(r"\(page size of ([0-9]{1,8}) bytes\)", text)
    if not match:
        raise ValueError
    page_size = numeric_integer(match.group(1))
    if not 512 <= page_size <= 1048576:
        raise ValueError
    values = {"page_size_bytes": page_size}
    for line in text.splitlines():
        match = re.fullmatch(r"([^:]+):\s*([0-9]{1,19})\.?\s*", line)
        if match and match.group(1) in VM_FIELDS:
            key = VM_FIELDS[match.group(1)]
            if key in values:
                raise ValueError
            values[key] = numeric_integer(match.group(2))
    if "pages_free" not in values:
        raise ValueError
    return {"status": "ok", "metrics": values}


def parse_swap(data):
    text = bounded_text(data).strip()
    match = re.fullmatch(
        r"total = ([0-9]{1,18}(?:\.[0-9]{1,4})?)([BKMGT])\s+"
        r"used = ([0-9]{1,18}(?:\.[0-9]{1,4})?)([BKMGT])\s+"
        r"free = ([0-9]{1,18}(?:\.[0-9]{1,4})?)([BKMGT])(?:\s+\(encrypted\))?",
        text,
    )
    if not match:
        raise ValueError
    values = {}
    for key, offset in (("total_bytes", 1), ("used_bytes", 3), ("free_bytes", 5)):
        scale = 1024 ** "BKMGT".index(match.group(offset + 1))
        value = int(decimal.Decimal(match.group(offset)) * scale)
        if not 0 <= value <= MAX_INTEGER:
            raise ValueError
        values[key] = value
    return {"status": "ok", "metrics": values}


def parse_physical_memory(data):
    value = numeric_integer(bounded_text(data).strip())
    if value == 0:
        raise ValueError
    return {"status": "ok", "metrics": {"physical_memory_bytes": value}}


PARSERS = {
    "processes": parse_processes,
    "virtual_memory": parse_virtual_memory,
    "swap": parse_swap,
    "physical_memory": parse_physical_memory,
}


def parent_present(parent_pid):
    # Direct-child identity check avoids probing/killing any arbitrary PID. On
    # parent death the OS reparents this child, ending collection even if that
    # parent's PID is subsequently reused.
    return parent_pid > 1 and os.getppid() == parent_pid


def stop_owned_probe(process):
    if process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=0.2)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=0.5)


def run_probe(name, stop=STOP, parent_pid=None):
    if name not in COMMANDS:
        return "unavailable", b""
    process = None
    selector = selectors.DefaultSelector()
    result = bytearray()
    deadline = time.monotonic() + PROBE_TIMEOUT_SECONDS
    try:
        process = subprocess.Popen(
            COMMANDS[name], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL, shell=False, close_fds=True,
            env={**os.environ, "LC_ALL": "C", "LANG": "C"},
        )
        os.set_blocking(process.stdout.fileno(), False)
        selector.register(process.stdout, selectors.EVENT_READ)
        eof = False
        while True:
            if stop.is_set() or (parent_pid is not None and not parent_present(parent_pid)):
                return "stopped", b""
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                return "timeout", b""
            if eof and process.poll() is not None:
                return ("ok", bytes(result)) if process.returncode == 0 else ("error", b"")
            for key, _ in selector.select(timeout=min(0.1, remaining)):
                chunk = os.read(key.fd, min(16384, MAX_PROBE_BYTES + 1 - len(result)))
                if not chunk:
                    selector.unregister(key.fileobj)
                    eof = True
                    continue
                result.extend(chunk)
                if len(result) > MAX_PROBE_BYTES:
                    return "output_limit", b""
    except (FileNotFoundError, PermissionError):
        return "unavailable", b""
    except (OSError, ValueError, subprocess.SubprocessError):
        return "error", b""
    finally:
        selector.close()
        if process is not None:
            try:
                stop_owned_probe(process)
            except (OSError, subprocess.SubprocessError):
                pass
            if process.stdout is not None:
                process.stdout.close()


def elapsed_fields(started, prefix):
    elapsed = time.monotonic() - started
    valid = math.isfinite(elapsed) and 0 <= elapsed <= 86400
    return {prefix + "_seconds": round(elapsed, 3) if valid else None,
            prefix + "_status": "ok" if valid else "unavailable"}


def sample_header(index, started, event):
    return {
        "schema_version": 1,
        "event": event,
        "sample_index": index,
        "utc": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="milliseconds"),
        **elapsed_fields(started, "monotonic_offset"),
    }


def collect_sample(index, started, stop=STOP, parent_pid=None, runner=run_probe, identity_state=None):
    collection_started = time.monotonic()
    sample = sample_header(index, started, "sample_completed")
    for name, parser in PARSERS.items():
        probe_started = time.monotonic()
        status, data = runner(name, stop=stop, parent_pid=parent_pid)
        if status != "ok":
            sample[name] = {"status": status if status in {
                "stopped", "timeout", "unavailable", "error", "output_limit"
            } else "error"}
        else:
            try:
                sample[name] = (parse_processes(data, parent_pid, identity_state)
                                if name == "processes" else parser(data))
            except (ValueError, UnicodeError, OverflowError, decimal.InvalidOperation):
                sample[name] = {"status": "invalid"}
        sample[name].update(elapsed_fields(probe_started, "probe_elapsed"))
    sample.update(elapsed_fields(collection_started, "collection_elapsed"))
    return sample


def write_sample(stream, sample):
    encoded = (json.dumps(sample, separators=(",", ":"), allow_nan=False) + "\n").encode("utf-8")
    if len(encoded) > MAX_LINE_BYTES:
        raise ValueError
    # One bounded write per JSONL record; flush makes earlier complete records
    # available even if the surrounding build step is terminated.
    stream.write(encoded)
    stream.flush()



class ControlStop:
    def __init__(self, stop_file=None, deadline=None):
        self.stop_file = stop_file
        self.deadline = deadline

    def is_set(self):
        return (STOP.is_set()
                or (self.deadline is not None and time.monotonic() >= self.deadline)
                or (self.stop_file is not None and os.path.lexists(self.stop_file)))

    def wait(self, seconds):
        STOP.wait(seconds)
        return self.is_set()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True)
    parser.add_argument("--parent-pid", required=True, type=int)
    parser.add_argument("--stop-file", help="Owned control file; its creation requests a stop.")
    parser.add_argument("--once", action="store_true", help="Collect one diagnostic sample.")
    args = parser.parse_args()
    for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(sig, lambda _signum, _frame: STOP.set())
    if not parent_present(args.parent_pid):
        return 0
    started = time.monotonic()
    identity_state = {}
    stop = ControlStop(args.stop_file, started + MAX_DURATION_SECONDS)
    try:
        # Exclusive create avoids clobbering prior diagnostics or following an
        # existing symlink. The caller supplies a fresh job-local artifact path.
        fd = os.open(args.output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "wb", buffering=0) as stream:
            for index in range(1 if args.once else MAX_SAMPLES):
                due = started + index * INTERVAL_SECONDS
                while time.monotonic() < due:
                    if stop.wait(max(0.0, min(0.2, due - time.monotonic()))) or not parent_present(args.parent_pid):
                        return 0
                if stop.is_set() or not parent_present(args.parent_pid):
                    return 0
                if time.monotonic() - started > MAX_DURATION_SECONDS + 0.25:
                    break
                # Flush before any external probe. A start without completion
                # exposes an interrupted/stalled observer instead of silent absence.
                write_sample(stream, sample_header(index, started, "sample_started"))
                sample = collect_sample(index, started, stop=stop, parent_pid=args.parent_pid, identity_state=identity_state)
                write_sample(stream, sample)
                if stop.is_set():
                    break
    except Exception:
        # Diagnostic collection must never print exception details or paths.
        # Fixed stderr label only; the build wrapper redirects this diagnostic.
        sys.stderr.write("resource_sampler_unavailable\n")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
