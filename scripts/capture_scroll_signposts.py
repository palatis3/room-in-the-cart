#!/usr/bin/env python3
"""Diagnostic only: bounded external live/persisted metadata around ONE original case.

No raw log files, environment dumps, logging configuration writes or metric changes.
Unsupported capabilities/schema stop before XCTest. Native execution is opt-in through
the caller; importing this module never invokes native tools.
"""
import argparse
import datetime as dt
import hashlib
import hmac
import json
import os
from pathlib import Path
import platform
import plistlib
import re
import selectors
import signal
import subprocess
import threading
import time
import uuid

from check_ios_performance_environment import toolchain_identity

SELECTOR = 'RoomInTheCartUITests/ReleasePerformanceUITests/testScrollingPerformanceOnFiveHundredItemPickup'
RUNTIME = 'com.apple.CoreSimulator.SimRuntime.iOS-27-0'
KNOWN = ('com.apple.UIKit', 'ScrollView', 'Scroll_DraggingAndDeceleration')
MAX_EVENTS, MAX_METADATA, MAX_RAW, MAX_LINE = 2048, 512 * 1024, 4 * 1024 * 1024, 65536
STREAM_SECONDS, CONTROL_SECONDS, SHOW_SECONDS, COMMAND_SECONDS = 300, 5, 30, 10
# Infrastructure policy for simulator inventory only, not a measured app
# performance baseline. Toolchain/help commands retain COMMAND_SECONDS.
INVENTORY_COMMAND_SECONDS = 30
PUMP_PHASES = ('commandEntry', 'workerEntry', 'budgetStart', 'spawnStart', 'spawnReturned',
               'pipesReady', 'firstRead', 'deadlineObserved', 'cleanupStart', 'cleanupComplete')
MAX_SELECTOR_RETURNS, LATE_READ_BYTES_PER_PIPE = 4096, 8192
HELP_TOKENS = {
    'stream': ('--signpost', 'ndjson', '--timeout', '--predicate', '--level'),
    'show': ('--signpost', 'ndjson', '--start', '--end', '--predicate', '--info', '--debug'),
    'emit': ('signpost-event', '--type', '--subsystem', '--category'),
}
SOURCE_PINS = {
    'ios/UITests/ReleasePerformanceUITests.swift': 'af3ce3e975b57940a45314f29f8f6b97fe81d7ae48b7d676b0d2a497af79b788',
    'scripts/check_ios_performance.py': 'f203f21510455a8a83300ee6968e8c5ac2bb14dd8c6afd5a6adb5caa7ce8a4c7',
    'scripts/scroll_signpost_diagnostic.py': 'e8fa85d6ceee7eb9c9a098338a002ea577df7605165d7b7b76b7cc9deb5aefa1',
    'ios/UITests/Fixtures/ReleaseLedger500.txt': '7411eb3a8a10911d6599237e1f2f618c0c3508667909a4766a4b5b14bef6e3b8',
    'scripts/check_ios_performance_environment.py': 'ca015a9ab4bcbf90d9a37220a00372d4dc714a5f0f8f4c156aad3f538c8f4300',
    'scripts/ios_performance_baselines.json': '38742a9b5f5eea668c608f117db602ac6a2b73aa56691c3ec3f90c291d15c38e',
}
STAGES = {'source-contract', 'xctestrun-contract', 'toolchain', 'toolchain-identity', 'devices', 'runtimes',
          'runtime-identity', 'help-stream', 'help-show', 'help-emit', 'emit-pre', 'emit-post'}
STDERR_MARKERS = {
    b'unknown command': 'unknown_command', b'unrecognized option': 'unrecognized_option',
    b'invalid option': 'invalid_option', b'permission denied': 'permission_denied',
    b'operation not permitted': 'operation_not_permitted', b'no such file': 'not_found',
    b'timed out': 'reported_timeout', b'unable to boot': 'boot_unavailable',
}


class Journal:
    """Fixed labels and bounded structured fields only; atomically save each boundary."""
    def __init__(self, receipt, path):
        self.receipt, self.path = receipt, path
        self.receipt['stages'] = []
        self.save()

    def save(self):
        temporary = self.path.with_suffix(self.path.suffix + '.tmp')
        with temporary.open('w') as output:
            output.write(json.dumps(self.receipt, separators=(',', ':')) + '\n')
            output.flush()
            os.fsync(output.fileno())
        temporary.replace(self.path)

    def run(self, name, action):
        if name not in STAGES or len(self.receipt['stages']) >= 32:
            raise ValueError('invalid_journal_stage')
        entry = {'stage': name, 'status': 'running', 'exitCode': None, 'startedUTC': utc_now()}
        self.receipt['stages'].append(entry)
        self.save()
        started = time.monotonic()
        try:
            result = action(entry)
            entry['status'] = 'passed'
            return result
        except BaseException as error:
            entry['status'] = 'interrupted' if isinstance(error, (KeyboardInterrupt, SystemExit)) else 'failed'
            entry['reason'] = 'command_failed' if entry.get('commandObserved') else 'validation_failed'
            raise
        finally:
            entry['elapsedSeconds'] = round(time.monotonic() - started, 3)
            self.save()


def stage(journal, name, action):
    return journal.run(name, action) if journal else action({})


def digest(value):
    return hashlib.sha256(value).hexdigest()


def utc_now():
    return dt.datetime.now(dt.timezone.utc).isoformat(timespec='microseconds')


def log_date(stamp, end=False):
    value = dt.datetime.fromisoformat(stamp)
    if end:
        value += dt.timedelta(seconds=1)
    # log(1) documents a SPACE, not an ISO T; round the start down and end up.
    return value.isoformat(sep=' ', timespec='seconds')


def terminate_owned(process):
    """Only private child process groups, never a simulator or unrelated native run."""
    if process.poll() is None:
        os.killpg(process.pid, signal.SIGTERM)
        try:
            process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait(timeout=1)


class Metadata:
    def __init__(self, namespace, salt):
        self.namespace, self.salt = namespace, salt
        self.events, self.controls = [], set()
        self.metadata_bytes = 0
        self.errors = set()
        self.finished = False

    def label(self, text):
        # Unknown labels may contain dynamic/private text: retain equality only.
        return hmac.new(self.salt, text.encode(), hashlib.sha256).hexdigest()

    def line(self, raw):
        try:
            event = json.loads(raw)
            if not isinstance(event, dict):
                raise ValueError()
            if 'finished' in event:
                # The public NDJSON format documents a terminal record, but does
                # not promise loss-free delivery. Nonzero/unknown trailer fields
                # conservatively make this diagnostic unqualified.
                self.finished = True
                if any(value not in (0, False, None, '') for key, value in event.items() if key != 'finished'):
                    self.errors.add('unqualified_terminal_record')
                return
            if event.get('eventType') != 'signpostEvent':
                raise ValueError()
            stamp, pid = event['timestamp'], event['processID']
            if not isinstance(stamp, str) or len(stamp) > 64:
                raise ValueError()
            normalized = re.sub(r'([+-]\d{2})(\d{2})$', r'\1:\2', stamp.replace('Z', '+00:00'))
            parsed = dt.datetime.fromisoformat(normalized)
            if parsed.tzinfo is None or type(pid) is not int or pid <= 0:
                raise ValueError()
            labels = [event.get(key, '') for key in ('subsystem', 'category', 'signpostName')]
            if not all(isinstance(value, str) and len(value) <= 1024 for value in labels):
                raise ValueError()
            kind, identifier = event['signpostType'], event['signpostID']
            if kind not in ('event', 'begin', 'end'):
                raise ValueError()
            if type(identifier) is int and identifier >= 0:
                identifier = str(identifier)
            elif isinstance(identifier, str) and re.fullmatch(r'(?:0x[0-9a-fA-F]+|[0-9]+)', identifier):
                identifier = str(int(identifier, 16 if identifier.startswith('0x') else 10))
            else:
                raise ValueError()
            if len(identifier) > 32:
                raise ValueError()
            control = labels[0] == self.namespace
            if control:
                if labels[1] not in ('pre', 'post') or kind != 'event':
                    raise ValueError()
                scope = 'control-' + labels[1]
            else:
                path = event['processImagePath']
                if not isinstance(path, str) or Path(path).name != 'RoomInTheCart':
                    raise ValueError()
                scope = 'app'
            safe = {'timestamp': parsed.astimezone(dt.timezone.utc).isoformat(), 'pid': pid,
                    'scope': scope, 'type': kind, 'id': identifier,
                    'originalScrollTaxonomy': tuple(labels) == KNOWN,
                    'taxonomyTokens': [self.label(value) for value in labels]}
            size = len(json.dumps(safe, separators=(',', ':')).encode())
            if len(self.events) >= MAX_EVENTS or self.metadata_bytes + size > MAX_METADATA:
                self.errors.add('metadata_cap')
                return
            self.metadata_bytes += size
            self.events.append(safe)
            if control:
                self.controls.add(labels[1])
        except (ValueError, KeyError, TypeError, OverflowError, RecursionError):
            self.errors.add('unsupported_record_or_schema')


class Pump:
    """Bounded nonblocking reader; raw bytes never reach a file or stdout."""
    def __init__(self, argv, seconds, metadata=None, help_channels=False):
        self.origin = time.monotonic()
        self.phase_seconds = dict.fromkeys(PUMP_PHASES)
        self.phase_seconds['commandEntry'] = 0.0
        self.selector_returns = 0
        self.selector_returns_capped = False
        self.max_loop_gap = 0.0
        self.deadline_observation = None
        self.argv, self.seconds, self.metadata = argv, seconds, metadata
        self.stop = threading.Event()
        self.stdout = bytearray()  # Only used for bounded, non-log preflight data.
        self.help_stderr = bytearray()
        self.help_channels = help_channels
        self.stderr_bytes = 0
        self.stderr_markers = set()
        self.stderr_tail = b''
        self.raw_bytes = 0
        self.errors = set()
        self.exit_code = None
        self.terminated_on_request = False
        self.process = None
        self.thread = threading.Thread(target=self.run, daemon=True)

    def start(self):
        self.thread.start()
        return self

    def mark(self, name, instant=None):
        if name not in PUMP_PHASES:
            raise ValueError('unknown_pump_phase')
        self.phase_seconds[name] = round((time.monotonic() if instant is None else instant) - self.origin, 6)

    def observe_deadline(self):
        # Diagnostics only, after the deadline error is permanent. Each pipe is
        # already nonblocking: one read, no retry/wait, no parsing or acceptance.
        if 'deadline' not in self.errors or self.deadline_observation is not None:
            return
        observation = {'processState': 'unknown', 'exitCode': None, 'pipes': {}}
        self.deadline_observation = observation
        try:
            code = self.process.poll()
            observation.update(processState='running' if code is None else 'exited', exitCode=code)
        except OSError:
            observation['processState'] = 'poll_error'
        remaining = max(0, MAX_RAW - self.raw_bytes)
        for name, pipe in (('stdout', self.process.stdout), ('stderr', self.process.stderr)):
            row = {'attempts': 0, 'bytes': 0, 'status': 'raw_budget_exhausted'}
            observation['pipes'][name] = row
            if remaining == 0:
                continue
            row['attempts'] = 1
            try:
                data = os.read(pipe.fileno(), min(LATE_READ_BYTES_PER_PIPE, remaining))
                row.update(bytes=len(data), status='bytes_discarded' if data else 'eof')
                remaining -= len(data)
            except BlockingIOError:
                row['status'] = 'would_block'
            except InterruptedError:
                row['status'] = 'interrupted'
            except OSError:
                row['status'] = 'read_error'

    def observation(self):
        deadline = None
        if self.deadline_observation is not None:
            deadline = dict(self.deadline_observation)
            deadline['pipes'] = {name: dict(row) for name, row in dict(deadline['pipes']).items()}
        return {'phaseSeconds': dict(self.phase_seconds), 'selectorReturns': self.selector_returns,
                'selectorReturnsCapped': self.selector_returns_capped,
                'maxLoopGapSeconds': round(self.max_loop_gap, 6),
                'deadlineObservation': deadline}

    def run(self):
        self.mark('workerEntry')
        buffer = bytearray()
        selector = selectors.DefaultSelector()
        budget_start = time.monotonic()
        deadline = budget_start + self.seconds
        self.mark('budgetStart', budget_start)
        try:
            self.mark('spawnStart')
            self.process = subprocess.Popen(self.argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                            start_new_session=True)
            self.mark('spawnReturned')
            for pipe, channel in ((self.process.stdout, 'out'), (self.process.stderr, 'err')):
                os.set_blocking(pipe.fileno(), False)
                selector.register(pipe, selectors.EVENT_READ, channel)
            last_loop = time.monotonic()
            self.mark('pipesReady', last_loop)
            while selector.get_map():
                now = time.monotonic()
                self.max_loop_gap = max(self.max_loop_gap, now - last_loop)
                last_loop = now
                if self.stop.is_set():
                    break
                if now >= deadline:
                    self.errors.add('deadline')
                    self.mark('deadlineObserved', now)
                    self.observe_deadline()
                    break
                ready = selector.select(timeout=0.1)
                if self.selector_returns < MAX_SELECTOR_RETURNS:
                    self.selector_returns += 1
                else:
                    self.selector_returns_capped = True
                for key, _ in ready:
                    data = os.read(key.fd, 8192)
                    if not data:
                        selector.unregister(key.fileobj)
                        continue
                    if self.phase_seconds['firstRead'] is None:
                        self.mark('firstRead')
                    self.raw_bytes += len(data)
                    if self.raw_bytes > MAX_RAW:
                        self.errors.add('raw_cap')
                        self.stop.set()
                        break
                    if key.data == 'err':
                        self.stderr_bytes += len(data)
                        fragment = (self.stderr_tail + data).lower()
                        self.stderr_markers.update(code for token, code in STDERR_MARKERS.items() if token in fragment)
                        self.stderr_tail = data[-64:]  # Transient only; never serialized.
                        if self.help_channels:
                            if len(self.stdout) + len(self.help_stderr) + len(data) > MAX_LINE:
                                self.errors.add('preflight_output_cap')
                                self.stop.set()
                                break
                            self.help_stderr.extend(data)
                        else:
                            self.errors.add('stderr_present')
                        continue
                    if self.metadata is None:
                        if len(self.stdout) + len(self.help_stderr) + len(data) > MAX_LINE:
                            self.errors.add('preflight_output_cap')
                            self.stop.set()
                            break
                        self.stdout.extend(data)
                        continue
                    buffer.extend(data)
                    while b'\n' in buffer:
                        line, _, buffer = buffer.partition(b'\n')
                        if len(line) > MAX_LINE:
                            self.errors.add('line_cap')
                        elif line.strip():
                            self.metadata.line(line)
                    if len(buffer) > MAX_LINE or self.metadata.errors:
                        self.errors.update(self.metadata.errors or {'line_cap'})
                        self.stop.set()
                        break
            if buffer.strip():
                # Never accept a partial final record as evidence.
                self.errors.add('partial_record')
        except (OSError, subprocess.SubprocessError):
            self.errors.add('process_io_error')
        finally:
            self.mark('cleanupStart')
            selector.close()
            if self.process is not None:
                if not self.stop.is_set() and not self.errors and self.process.poll() is None:
                    try:
                        self.process.wait(timeout=1)
                    except subprocess.TimeoutExpired:
                        self.errors.add('exit_timeout')
                self.terminated_on_request = self.stop.is_set() and self.process.poll() is None
                terminate_owned(self.process)
                self.exit_code = self.process.returncode
                self.process.stdout.close()
                self.process.stderr.close()
            self.mark('cleanupComplete')

    def close(self):
        self.stop.set()
        self.thread.join(timeout=4)
        if self.thread.is_alive():
            raise RuntimeError('collector_cleanup_failed')

    def receipt(self):
        return {'exitCode': self.exit_code, 'errors': sorted(self.errors),
                'pump': self.observation(),
                'terminatedOnRequest': self.terminated_on_request,
                'rawBytesConsumed': self.raw_bytes, 'stderrBytesDiscarded': self.stderr_bytes,
                'events': self.metadata.events if self.metadata else [],
                'appPIDsObserved': sorted({event['pid'] for event in self.metadata.events
                                          if event['scope'] == 'app'}) if self.metadata else [],
                'controls': sorted(self.metadata.controls) if self.metadata else [],
                'finishedRecord': self.metadata.finished if self.metadata else False}


def command(argv, seconds=COMMAND_SECONDS, help_receipt=None, journal=None, stage_name=None):
    return stage(journal, stage_name, lambda entry: command_result(argv, seconds, help_receipt, entry))


def help_result(argv, pump):
    # Only the exact simulator-local help invocation used by runtime_preflight.
    mode = (argv[6] if len(argv) == 7 and argv[:3] == ['xcrun', 'simctl', 'spawn']
            and argv[4:6] == ['log', 'help'] and argv[6] in HELP_TOKENS else None)
    combined = bytes(pump.stdout) + b'\n' + bytes(pump.help_stderr)
    normalized = combined.replace(b'--[no-]', b'--').replace(b'--[no]-', b'--')
    usage = bool(mode and combined.lstrip().startswith(('usage: log ' + mode + ' ').encode()))
    tokens = bool(mode and all(token.encode() in normalized for token in HELP_TOKENS[mode]))
    return {'stdoutBytes': len(pump.stdout), 'stderrBytes': len(pump.help_stderr),
            'stdoutSHA256': digest(pump.stdout), 'stderrSHA256': digest(pump.help_stderr),
            'combinedSHA256': digest(combined), 'exitCode': pump.exit_code,
            'fixedHelpCommand': mode is not None, 'recognizedUsage': usage,
            'requiredTokensPresent': tokens,
            'acceptedUsageExit64': bool(pump.exit_code == 64 and not pump.errors and usage and tokens)}


def command_result(argv, seconds, help_receipt, entry):
    entry['timeoutSeconds'] = seconds
    pump = Pump(argv, seconds, help_channels=help_receipt is not None).start()
    try:
        pump.thread.join(seconds + 4)
    finally:
        try:
            pump.close()
        finally:
            entry.update({'commandObserved': True, 'exitCode': pump.exit_code,
                          'errors': sorted(pump.errors), 'stdoutBytes': len(pump.stdout),
                          'stderrBytes': pump.stderr_bytes, 'rawBytesConsumed': pump.raw_bytes,
                          'stderrMarkers': sorted(pump.stderr_markers),
                          'pump': pump.observation(),
                          'terminatedOnRequest': pump.terminated_on_request})
            if help_receipt is not None:
                help_receipt.update(help_result(argv, pump))
                entry['help'] = dict(help_receipt)  # Hashes/status survive failed help commands too.
    accepted_help_usage = help_receipt is not None and help_receipt.get('acceptedUsageExit64') is True
    if pump.errors or (pump.exit_code != 0 and not accepted_help_usage):
        raise ValueError('capability_command_failed')
    if help_receipt is not None:
        return bytes(pump.stdout) + b'\n' + bytes(pump.help_stderr)
    return bytes(pump.stdout)


def environment_summary(plist):
    def selected(mapping):
        rows = []
        for key, value in mapping.items():
            if key.startswith(('OS_ACTIVITY_', 'OS_LOG_')):
                # No unknown key names or values retained; no full env dump.
                rows.append({'knownKey': key if key in ('OS_ACTIVITY_MODE', 'OS_ACTIVITY_DT_MODE',
                             'OS_LOG_DT_HOOK_MODE') else 'other_logging_key',
                             'valueClass': value if value in ('disable', 'enable', 'YES', 'NO', '1', '0')
                             else 'other_redacted'})
        return rows
    rows = [{'location': 'wrapper', 'keys': selected(os.environ)}]
    def visit(value):
        if isinstance(value, dict):
            for key, child in value.items():
                if 'EnvironmentVariables' in key and isinstance(child, dict):
                    rows.append({'location': 'xctestrun_environment', 'keys': selected(child)})
                else:
                    visit(child)
        elif isinstance(value, list):
            for child in value:
                visit(child)
    visit(plist)
    if len(rows) > 32 or sum(len(row['keys']) for row in rows) > 64:
        raise ValueError('logging_environment_metadata_cap')
    return rows


def source_contract():
    if os.environ.get('PERFORMANCE_CASE') != 'scroll':
        raise ValueError('not_the_original_scroll_case')
    if os.environ.get('ENFORCE_BASELINES') != 'false':
        raise ValueError('instrumented_diagnostic_requires_calibration_mode')
    if any(digest(Path(path).read_bytes()) != expected for path, expected in SOURCE_PINS.items()):
        raise ValueError('protected_source_drift')
    return SOURCE_PINS


def preflight(simulator, test_run, argv, journal=None, identity_path=None):
    expected = ['xcodebuild', '-xctestrun', str(test_run), '-destination', f'platform=iOS Simulator,id={simulator}',
                '-parallel-testing-enabled', 'NO', '-test-timeouts-enabled', 'YES',
                '-default-test-execution-time-allowance', '900', '-maximum-test-execution-time-allowance', '1200',
                '-resultBundlePath', '.build/performance/Performance.xcresult', '-collect-test-diagnostics', 'on-failure',
                '-only-testing:' + SELECTOR, 'test-without-building']
    if argv != expected or os.environ.get('PERFORMANCE_CASE') != 'scroll':
        raise ValueError('not_the_original_scroll_command')
    stage(journal, 'source-contract', lambda _: source_contract())
    def inspect_test_run(_):
        if test_run.stat().st_size > 1024 * 1024:
            raise ValueError('xctestrun_size_cap')
        return {'xctestrunSHA256': digest(test_run.read_bytes()),
                'loggingEnvironment': environment_summary(plistlib.loads(test_run.read_bytes())),
                'environmentLimitation': 'Actual launched app environment is not observed.'}
    local = stage(journal, 'xctestrun-contract', inspect_test_run)
    return dict(runtime_preflight(simulator, journal, identity_path), **local)


def read_toolchain_identity(path, simulator, architecture):
    if (os.environ.get('SIMULATOR_ID') != simulator
            or os.environ.get('DEVELOPER_DIR') != '/Applications/Xcode_27.1.app/Contents/Developer'
            or not path.is_file()):
        raise ValueError('toolchain_identity_context_mismatch')
    with path.open('rb') as source:
        raw = source.read(8193)
    if len(raw) > 8192:
        raise ValueError('toolchain_identity_size_cap')
    observed = json.loads(raw)
    expected = toolchain_identity(os.environ, 'Xcode 27.1\nBuild version 27A9275', architecture)
    if (not isinstance(observed, dict) or type(observed.get('schemaVersion')) is not int
            or observed.get('passed') is not True or observed.get('releaseAcceptance') is not False
            or observed != expected):
        raise ValueError('toolchain_identity_mismatch')
    return digest(raw)


def runtime_preflight(simulator, journal=None, identity_path=None):
    architecture = platform.machine()
    if architecture != 'arm64':
        raise ValueError('toolchain_drift')
    identity_hash = None
    if identity_path is None:
        if command(['xcodebuild', '-version'], journal=journal, stage_name='toolchain').decode().strip() != 'Xcode 27.1\nBuild version 27A9275':
            raise ValueError('toolchain_drift')
    else:
        identity_hash = stage(journal, 'toolchain-identity',
                              lambda _: read_toolchain_identity(identity_path, simulator, architecture))
    # CLI substring filtering reduces returned inventory only; it is not identity
    # or availability validation. The exact selected-device checks below remain.
    inventory = json.loads(command(['xcrun', 'simctl', 'list', 'devices', simulator, '-j'],
                                   seconds=INVENTORY_COMMAND_SECONDS, journal=journal, stage_name='devices'))
    inventory.update(json.loads(command(['xcrun', 'simctl', 'list', 'runtimes', RUNTIME, '-j'],
                                        seconds=INVENTORY_COMMAND_SECONDS, journal=journal, stage_name='runtimes')))
    devices = [(runtime, device) for runtime, items in inventory['devices'].items()
               for device in items if device.get('udid') == simulator]
    runtimes = [item for item in inventory['runtimes'] if item.get('identifier') == RUNTIME]
    if (len(devices) != 1 or devices[0][0] != RUNTIME or devices[0][1].get('state') != 'Booted'
            or not devices[0][1].get('isAvailable')
            or devices[0][1].get('deviceTypeIdentifier') != 'com.apple.CoreSimulator.SimDeviceType.iPhone-17'
            or len(runtimes) != 1 or not runtimes[0].get('isAvailable')
            or runtimes[0].get('version') != '27.0' or runtimes[0].get('buildversion') != '24A434'):
        raise ValueError('runtime_drift')
    prefix = ['xcrun', 'simctl', 'spawn', simulator, 'log']
    capabilities = {}
    for mode, tokens in HELP_TOKENS.items():
        help_receipt = {}
        help_text = command(prefix + ['help', mode], help_receipt=help_receipt, journal=journal, stage_name='help-' + mode)
        # Both optional-negation spellings appear in the installed public manual.
        normalized_help = help_text.replace(b'--[no-]', b'--').replace(b'--[no]-', b'--')
        if not all(token.encode() in normalized_help for token in tokens):
            raise ValueError('unsupported_' + mode + '_capability')
        capabilities[mode] = dict(help_receipt, helpSHA256=digest(help_text), requiredTokensPresent=True)
    return {'protectedSourceSHA256': SOURCE_PINS,
            'toolchainIdentitySource': 'same-job-receipt' if identity_path is not None else 'direct-query',
            'toolchainIdentitySHA256': identity_hash,
            'exactRuntime': {'xcode': '27.1', 'xcodeBuild': '27A9275', 'iOS': '27.0',
                            'iOSBuild': '24A434', 'deviceType': 'iPhone 17', 'hostArchitecture': 'arm64'},
            'capabilities': capabilities}


def handshake(pump, prefix, namespace, name, journal=None):
    deadline = time.monotonic() + CONTROL_SECONDS
    # At most three markers, outside the native invocation, to tolerate log's
    # subscription startup. This never retries a native case. A single emitter
    # failure aborts; only successful emits without receipt may be repeated.
    for _ in range(3):
        remaining = deadline - time.monotonic()
        if remaining <= 0 or pump.errors or not pump.thread.is_alive():
            return False
        command(prefix + ['emit', '--type', 'signpost-event', '--subsystem', namespace,
                          '--category', name, 'RITC diagnostic transport control'], min(1, remaining),
                journal=journal, stage_name='emit-' + name)
        wait_until = min(deadline, time.monotonic() + 1)
        while time.monotonic() < wait_until:
            if pump.errors or pump.metadata.errors or not pump.thread.is_alive():
                return False
            if name in pump.metadata.controls:
                return True
            time.sleep(0.05)
    return False


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--simulator', required=True)
    parser.add_argument('--xctestrun', type=Path)
    parser.add_argument('--capabilities-only', action='store_true')
    parser.add_argument('--toolchain-identity', type=Path, help='optional successful identity from this same consumer job')
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('command', nargs=argparse.REMAINDER)
    args = parser.parse_args()
    argv = args.command[1:] if args.command[:1] == ['--'] else args.command
    if args.capabilities_only:
        if args.xctestrun is not None or argv:
            parser.error('Capabilities-only mode rejects xctestrun and native command arguments')
    elif args.xctestrun is None or not argv:
        parser.error('Capture mode requires xctestrun and the original native command')
    # Refuse accidental overwrite; all temporary raw data lives in bounded RAM.
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.touch(exist_ok=False)
    receipt = {'schemaVersion': 1, 'diagnosticOnly': True, 'releaseAcceptance': False,
               'nativeAttempted': False, 'status': 'preflight_incomplete',
               'capabilitiesOnly': args.capabilities_only,
               'limits': {'liveSeconds': STREAM_SECONDS, 'controlWaitSecondsEach': CONTROL_SECONDS,
                          'inventoryCommandSeconds': INVENTORY_COMMAND_SECONDS, 'otherCommandSeconds': COMMAND_SECONDS,
                          'persistedSeconds': SHOW_SECONDS, 'metadataEventsPerSource': MAX_EVENTS,
                          'metadataBytesPerSource': MAX_METADATA, 'rawBytesPerSource': MAX_RAW,
                          'rawLineBytes': MAX_LINE, 'childTermSeconds': 2, 'childKillSeconds': 1}}
    journal = Journal(receipt, args.output)
    namespace = 'dev.roominthecart.scrollprobe.' + uuid.uuid4().hex
    salt = os.urandom(32)  # Shared live/show equality; discarded, never written.
    prefix = ['xcrun', 'simctl', 'spawn', args.simulator, 'log']
    predicate = f'eventType == "signpostEvent" AND (process == "RoomInTheCart" OR subsystem == "{namespace}")'
    live = persisted = native = None
    native_code = None
    prior_handlers = {}
    def interrupted(signum, _frame):
        raise SystemExit(128 + signum)
    for signum in (signal.SIGTERM, signal.SIGINT):
        prior_handlers[signum] = signal.signal(signum, interrupted)
    try:
        if args.capabilities_only:
            stage(journal, 'source-contract', lambda _: source_contract())
            receipt['preflight'] = runtime_preflight(args.simulator, journal, args.toolchain_identity)
            receipt['status'] = 'capabilities_checked_not_transport'
            return 0
        receipt['preflight'] = preflight(args.simulator, args.xctestrun, argv, journal, args.toolchain_identity)
        start = utc_now()
        live = Pump(prefix + ['stream', '--signpost', '--style', 'ndjson', '--level', 'debug',
                              '--timeout', str(STREAM_SECONDS), '--predicate', predicate],
                    STREAM_SECONDS, Metadata(namespace, salt)).start()
        if not handshake(live, prefix, namespace, 'pre', journal):
            raise ValueError('pre_control_unqualified_no_native_run')
        receipt['nativeAttempted'] = True
        receipt['nativeStartUTC'] = utc_now()
        journal.save()  # A hard termination must not leave nativeAttempted=false.
        # Inherits stdout/stderr for the existing tee and unchanged test log.
        native = subprocess.Popen(argv, start_new_session=True)
        native_code = native.wait()  # Original XCTest and workflow deadlines retained.
        receipt['nativeExitCode'] = native_code
        receipt['nativeEndUTC'] = utc_now()
        journal.save()  # Persist native completion before any post-control work.
        if live.thread.is_alive():
            try:
                receipt['postControlReceived'] = handshake(live, prefix, namespace, 'post', journal)
            except ValueError:
                receipt['postControlReceived'] = False
        else:
            receipt['postControlReceived'] = False
        live.close()
        end = utc_now()
        # Same broad predicate, fixed actual experiment range; no persistence writes.
        persisted = Pump(prefix + ['show', '--start', log_date(start), '--end', log_date(end, end=True),
                                   '--signpost', '--info', '--debug',
                                   '--style', 'ndjson', '--predicate', predicate],
                         SHOW_SECONDS, Metadata(namespace, salt)).start()
        persisted.thread.join(SHOW_SECONDS + 4)
        persisted.close()
        receipt['captureStartUTC'], receipt['captureEndUTC'] = start, end
        receipt['status'] = 'captured_diagnostic_only'
    except (ValueError, OSError, KeyError, TypeError, RuntimeError) as error:
        # Avoid exception strings: OS errors may contain paths or arbitrary content.
        receipt['status'] = 'unqualified'
        receipt['errorClass'] = type(error).__name__
        if isinstance(error, ValueError) and re.fullmatch(r'[a-z_]+', str(error)):
            receipt['reason'] = str(error)
    except (KeyboardInterrupt, SystemExit):
        receipt['status'] = 'caller_interrupted'
        raise
    finally:
        for signum in prior_handlers:
            signal.signal(signum, signal.SIG_IGN)
        for pump, label in ((live, 'live'), (persisted, 'persisted')):
            if pump:
                try:
                    pump.close()
                except RuntimeError:
                    receipt['status'] = 'cleanup_failed'
                receipt[label] = pump.receipt()
        if native and native.poll() is None:
            terminate_owned(native)  # Only caller interruption/error; never capture cap.
        receipt['liveTransportQualified'] = bool(live and {'pre', 'post'} <= live.metadata.controls
             and not live.errors and not live.metadata.errors
             and (live.exit_code == 0 or (live.terminated_on_request and live.exit_code == -signal.SIGTERM)))
        receipt['persistedReadQualified'] = bool(persisted and persisted.exit_code == 0
             and persisted.metadata.finished and not persisted.errors and not persisted.metadata.errors)
        if receipt['status'] == 'captured_diagnostic_only' and not receipt['liveTransportQualified']:
            receipt['status'] = 'unqualified'
        journal.save()
        for signum, handler in prior_handlers.items():
            signal.signal(signum, handler)
    # After execution, retain original native status; separate diagnostic receipt
    # never masks the original strict result/metric/baseline checks that follow.
    return (native_code if native_code >= 0 else 128 - native_code) if native_code is not None else 78


if __name__ == '__main__':
    raise SystemExit(main())
