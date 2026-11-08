#!/usr/bin/env python3
"""Host observer only. Reads one PID-named probe file; never launches or controls an app."""
import datetime, hashlib, json, math, os, plistlib, re, stat, subprocess, threading, time
from pathlib import Path

TARGET = 'ContextualNavigationUITests/testFreeContextualRoutesKeepPrivateAndSharedWorkSeparate'
CASE = re.compile(rb"^Test Case '-\[([A-Za-z0-9_.]+) ([A-Za-z0-9_]+)\]' (started|passed|failed)(?:[. (]|$)")
FILE_CAP = 128 * 1024
EVENT_CAP = 1024 * 1024 - 4096
MAX_PROCESS_POLL_FAILURES = 3  # Total failures, never reset on recovery.
OFFSETS = [0, 0.016, 0.05, 0.1, 0.25, 0.5, 1, 2, 4, 8, 16, 32, 64]
KEYBOARD_EVENTS = {'willFrame', 'didFrame', 'willHide', 'didHide'}

def utc(): return datetime.datetime.now(datetime.timezone.utc).isoformat()
def digest(data): return hashlib.sha256(data).hexdigest()

def decode_probe(data):
    if len(data) > FILE_CAP: raise ValueError('probe byte limit')
    # A partial last line is retained as bytes but never interpreted as a record.
    lines = data.splitlines(keepends=True)
    rows = [json.loads(line) for line in lines if line.endswith(b'\n')]
    if len(rows) > 1024 or any(not isinstance(r, dict) for r in rows):
        raise ValueError('probe row limit/type')
    closed = bool(rows and rows[-1].get('event') == 'sinkFinished' and data.endswith(b'\n'))
    if closed:
        if rows[-1].get('bytesBeforeFooter') != len(data) - len(lines[-1]):
            raise ValueError('footer byte count mismatch')
    return rows, closed

def probe_quality(rows):
    """Coverage of this unchanged bounded probe, separate from transport closure."""
    reasons = []
    before = [r for r in rows if r.get('event') == 'beforeDismiss']
    after = [r for r in rows if r.get('event') == 'afterDismiss']
    dismissals = [r for r in rows if r.get('event') == 'dismissReturned']
    finished = [r for r in rows if r.get('event') == 'finished']
    footers = [r for r in rows if r.get('event') == 'sinkFinished']
    offsets = [r.get('due') for r in after]
    numeric = lambda value: type(value) in (int, float) and math.isfinite(value)
    offsets_complete = (len(offsets) == len(OFFSETS) and all(numeric(v) for v in offsets)
                        and sorted(offsets) == OFFSETS)
    if not offsets_complete: reasons.append('missingDuplicateOrInvalidScheduledSamples')
    if len(before) != 1 or before[0].get('due') != 0: reasons.append('missingOrInvalidBeforeDismiss')
    if len(dismissals) != 1: reasons.append('missingOrDuplicateDismissReturned')
    window_complete = len(finished) == 1 and finished[0].get('reason') == 'windowComplete'
    if not window_complete: reasons.append('missingUnknownOrEarlyFinish')
    sink_drops = footers[0].get('droppedRecords') if len(footers) == 1 else None
    zero_drops = type(sink_drops) is int and sink_drops == 0
    if not zero_drops: reasons.append('sinkDropsOrUnknownLoss')
    samples = before + after
    limited_samples = []
    for sample in samples:
        limits = []
        if not numeric(sample.get('t')) or not numeric(sample.get('due')) or sample['t'] < sample['due']:
            limits.append('invalidSampleTime')
        if sample.get('truncatedTraversal') is not False: limits.append('truncatedOrUnknownTraversal')
        for key in ('skippedInterestingRecords', 'truncatedAnimationKeys', 'skippedChildren'):
            if type(sample.get(key)) is not int or sample[key] != 0: limits.append(key+'NonzeroOrUnknown')
        count, windows = sample.get('windowCount'), sample.get('windows')
        if type(count) is not int or not 0 <= count <= 8 or not isinstance(windows, list) or len(windows) != count:
            limits.append('windowLimitOrUnknownCoverage')
        for key in ('scrolls', 'responders'):
            values = sample.get(key)
            # Exactly eight reaches a silent cap: it does not prove overflow, or absence of overflow.
            if not isinstance(values, list) or len(values) >= 8: limits.append(key+'CapReachedOrUnknown')
        for key in ('windows', 'layers', 'scrolls', 'responders'):
            values = sample.get(key)
            if not isinstance(values, list) or any(not isinstance(v, dict) or type(v.get('layer')) is not int
                                                  or v['layer'] <= 0 for v in values):
                limits.append(key+'InvalidOrExhaustedObjectIDs')
        layers = sample.get('layers')
        if not isinstance(layers, list) or any(not isinstance(v, dict) or type(v.get('parent')) is not int
                                               or v['parent'] < 0 for v in layers):
            limits.append('invalidOrExhaustedParentIDs')
        if limits: limited_samples.append(dict(event=sample.get('event'),due=sample.get('due'),limits=limits))
    if limited_samples: reasons.append('sampleInventoryLimitedOrUnknown')
    keyboard_count = sum(r.get('event') in KEYBOARD_EVENTS for r in rows)
    if keyboard_count >= 16: reasons.append('keyboardEventCapReachedLossUnknown')
    known = KEYBOARD_EVENTS | {'beforeDismiss','afterDismiss','dismissReturned','finished','sinkFinished'}
    if any(r.get('event') not in known for r in rows): reasons.append('unknownEvent')
    if len(finished) == 1 and (not numeric(finished[0].get('t')) or finished[0]['t'] < 64):
        reasons.append('finishBeforeFullWindowOrUnknownTime')
    if len(footers) != 1 or not rows or rows[-1].get('event') != 'sinkFinished':
        reasons.append('missingDuplicateOrMisplacedFooter')
    if len(rows) < 2 or rows[-2].get('event') != 'finished': reasons.append('finishIsNotImmediatelyBeforeFooter')
    return dict(completeForDeclaredScope=not reasons, reasons=reasons,
                windowComplete=window_complete, scheduledSamplesComplete=offsets_complete,
                expectedAfterDismissOffsets=OFFSETS, observedAfterDismissOffsets=offsets,
                beforeDismissCount=len(before), afterDismissCount=len(after), dismissReturnedCount=len(dismissals),
                finishReasons=[r.get('reason') for r in finished], zeroSinkDrops=zero_drops,
                droppedRecords=sink_drops, keyboardEventCount=keyboard_count,
                keyboardCapReached=keyboard_count >= 16, inventoryLimitedSamples=limited_samples,
                scope='scheduled samples of public app-owned roots; not continuous or system-wide animation coverage')

class Collector:
    def __init__(self, device, evidence):
        self.device = device
        self.root = Path.home() / 'Library/Developer/CoreSimulator/Devices' / device
        self.out = evidence / 'observer'; self.out.mkdir()
        self.log = evidence / 'Tests.log'
        self.stop = threading.Event(); self.ready = threading.Event()  # Thread-start handshake, not discovery readiness.
        self.started = time.monotonic(); self.written = 0; self.polls = 0
        self.offset = 0; self.pending = b''; self.current_case = None
        self.target_started = False; self.target_ended = False
        self.previous = {}; self.candidates = {}; self.transitions = 0
        self.ambiguous = False
        self.absent_pids = set()
        self.poll_attempts = 0; self.poll_failures = 0; self.recovered_gaps = 0
        self.discovery_gap = None; self.discovery_exhausted = False
        self.discovery_target_affected = False; self.max_failed_poll_ms = 0.
        self.thread_started_utc = None; self.initial_snapshot_state = 'notAttempted'
        self.first_successful_snapshot_utc = None
        self.fatal_discovery_error = None
        self.max_poll_ms = 0.; self.error = None
        self.events = (self.out / 'events.ndjson').open('xb')

    def event(self, kind, **fields):
        data = (json.dumps(dict(event=kind, observedUTC=utc(), elapsedSeconds=time.monotonic()-self.started,
                                **fields), separators=(',', ':')) + '\n').encode()
        if self.written + len(data) > EVENT_CAP: raise ValueError('metadata byte cap')
        self.events.write(data); self.events.flush(); self.written += len(data)

    def cases(self):
        if not self.log.exists(): return
        if self.log.stat().st_size < self.offset: raise ValueError('native log shrank')
        with self.log.open('rb') as f:
            f.seek(self.offset); chunk = f.read(256 * 1024)
        start = self.offset - len(self.pending); self.offset += len(chunk)
        lines = (self.pending + chunk).split(b'\n'); self.pending = lines.pop()
        for line in lines:
            match = CASE.match(line)
            if match:
                cls, method, state = (s.decode('ascii') for s in match.groups())
                name = cls.split('.')[-1] + '/' + method
                self.event('caseMarker', test=name, state=state, logByteOffset=start)
                if state == 'started': self.current_case = name
                elif self.current_case == name: self.current_case = None
                if name == TARGET:
                    if state == 'started': self.target_started = True
                    else: self.target_ended = True
            start += len(line) + 1
        if len(self.pending) > 16384: raise ValueError('incomplete native log line exceeds bound')

    def processes(self):
        result = subprocess.run(['/bin/ps', '-ww', '-axo', 'pid=,comm='], capture_output=True, timeout=2, check=True)
        found = {}
        for line in result.stdout.decode(errors='replace').splitlines():
            parts = line.strip().split(None, 1)
            if len(parts) != 2 or not parts[0].isdigit(): continue
            p = Path(parts[1])
            if not p.is_relative_to(self.root / 'data/Containers/Bundle/Application'): continue
            if p.name != 'RoomInTheCart' or p.parent.name != 'RoomInTheCart.app': continue
            if plistlib.loads((p.parent / 'Info.plist').read_bytes()).get('CFBundleIdentifier') != 'dev.roominthecart.app.debug': continue
            found[int(parts[0])] = str(p.relative_to(self.root))
        return found

    def process_events(self, current):
        for pid in set(current) | set(self.previous):
            if current.get(pid) != self.previous.get(pid):
                self.transitions += 1
                if self.transitions > 64: raise ValueError('process transition cap')
                if pid not in current:
                    self.absent_pids.add(pid)
                elif pid in self.absent_pids:
                    self.ambiguous = True
                    self.event('PIDReappeared', pid=pid, activeCase=self.current_case,
                               executableRelativeToOwnedDevice=current[pid],
                               interpretation='same numeric PID observed absent then present; identity reuse cannot be excluded')
                self.event('processPresent' if pid in current else 'processAbsent', pid=pid,
                           executableRelativeToOwnedDevice=(current.get(pid) or self.previous[pid]),
                           activeCase=self.current_case, logByteOffsetObserved=self.offset)

    def case_log_caught_up(self):
        return not self.pending and (not self.log.exists() or self.log.stat().st_size == self.offset)

    def mark_gap_target(self):
        gap = self.discovery_gap
        if gap and self.target_started and not gap['targetEndedBeforeGap']:
            gap['targetAssociationAffected'] = True
            self.discovery_target_affected = True
            self.ambiguous = True  # A later baseline can never undo target ambiguity.

    def poll_processes(self):
        """Missing discovery is unknown, not absence. No app/native-test retry."""
        began = time.monotonic(); began_utc = utc(); ended_before = self.target_ended
        self.poll_attempts += 1
        if self.poll_attempts == 1: self.initial_snapshot_state = 'inProgress'
        try:
            current = self.processes()
        except (subprocess.TimeoutExpired, subprocess.CalledProcessError) as error:
            elapsed_ms = (time.monotonic()-began)*1000
            if self.poll_attempts == 1: self.initial_snapshot_state = 'failed'
            self.poll_failures += 1; self.max_failed_poll_ms = max(self.max_failed_poll_ms, elapsed_ms)
            if self.discovery_gap is None:
                self.discovery_gap = dict(startedUTC=began_utc, startedElapsedSeconds=began-self.started,
                                          targetEndedBeforeGap=ended_before, targetAssociationAffected=False)
            # Read newly written markers after the failed query before classifying the gap.
            self.cases(); self.mark_gap_target()
            self.event('processPollFailed',attempt=self.poll_attempts,totalFailures=self.poll_failures,
                       totalFailureLimit=MAX_PROCESS_POLL_FAILURES,errorType=type(error).__name__,
                       exitCode=getattr(error,'returncode',None),requestedTimeoutSeconds=2,pollMS=elapsed_ms,
                       activeCase=self.current_case,logByteOffsetObserved=self.offset,
                       targetAssociationAffected=self.discovery_target_affected,
                       interpretation='No process snapshot; previous identities retained without asserting presence or absence.')
            if self.poll_failures >= MAX_PROCESS_POLL_FAILURES:
                self.discovery_exhausted = True
                raise RuntimeError('process discovery exhausted after three failed polls total') from error
            return None
        except Exception as error:
            if self.poll_attempts == 1: self.initial_snapshot_state = 'failed'
            self.fatal_discovery_error = type(error).__name__
            raise  # Identity/parser/file failures are not transient ps timeout recovery.
        self.polls += 1
        if self.poll_attempts == 1: self.initial_snapshot_state = 'succeeded'
        if self.first_successful_snapshot_utc is None: self.first_successful_snapshot_utc = utc()
        # Case output may have arrived while ps ran; do not label recovery pre-target from stale markers.
        self.cases(); self.mark_gap_target()
        if self.discovery_gap is not None and self.case_log_caught_up():
            gap = self.discovery_gap
            # Before the target, only an observed empty owned-app snapshot establishes a fresh baseline.
            # If a process remains and markers are delayed, keep the gap unresolved rather than guessing.
            can_close = gap['targetAssociationAffected'] or gap['targetEndedBeforeGap'] or (not self.target_started and not current)
            if can_close:
                self.recovered_gaps += 1
                self.event('processDiscoveryRecovered',gapStartedUTC=gap['startedUTC'],
                           gapSeconds=time.monotonic()-self.started-gap['startedElapsedSeconds'],
                           targetAssociationAffected=gap['targetAssociationAffected'],
                           recoveredBeforeTarget=not self.target_started and not current,
                           activeCase=self.current_case,logByteOffsetObserved=self.offset,
                           priorTargetAmbiguityRetained=self.ambiguous)
                self.discovery_gap = None
        return current

    def discovery_summary(self):
        return dict(status='exhausted' if self.discovery_exhausted else 'fatalSnapshotFailure' if self.fatal_discovery_error else
                    'unresolvedGap' if self.discovery_gap else
                    'recoveredWithLoss' if self.poll_failures else 'noObservedPollFailures',
                    attempts=self.poll_attempts,successfulPolls=self.polls,totalFailures=self.poll_failures,
                    totalFailureLimit=MAX_PROCESS_POLL_FAILURES,recoveredGaps=self.recovered_gaps,
                    unresolvedGap=self.discovery_gap,targetAssociationAffected=self.discovery_target_affected,
                    maxFailedPollMS=self.max_failed_poll_ms,
                    startupHandshake='threadStartedOnly',threadStartedHandshakeObserved=self.ready.is_set(),
                    threadStartedUTC=self.thread_started_utc,initialSnapshotState=self.initial_snapshot_state,
                    successfulSnapshotObserved=self.first_successful_snapshot_utc is not None,
                    firstSuccessfulSnapshotUTC=self.first_successful_snapshot_utc,
                    fatalDiscoveryError=self.fatal_discovery_error,requestedPerQueryTimeoutSeconds=2,
                    allProcessObservationsPresent=self.poll_attempts>0 and self.poll_attempts==self.polls)

    def bind(self, pid, executable):
        if len(self.candidates) >= 8: raise ValueError('target PID cap')
        preexisting = pid in self.previous
        if preexisting: self.ambiguous = True
        # One exact bundle container query per observed target-case PID. No directory walk.
        r = subprocess.run(['/usr/bin/xcrun', 'simctl', 'get_app_container', self.device,
                            'dev.roominthecart.app.debug', 'data'], capture_output=True, text=True, timeout=5, check=True)
        container = Path(r.stdout.strip())
        parent = self.root / 'data/Containers/Data/Application'
        if container.parent != parent or not re.fullmatch(r'[A-Fa-f0-9-]{36}', container.name):
            raise ValueError('container is outside exact owned device')
        p = container / 'tmp' / f'ui09-animation-{pid}.ndjson'
        for ancestor in (container, container / 'tmp'):
            if ancestor.is_symlink(): raise ValueError('symlink container')
        self.candidates[pid] = dict(path=p, executable=executable, latest=None, closed=False,
                                    firstObservedUTC=utc(), reads=0, maxReadMS=0.)
        self.event('targetPIDBound', pid=pid, executableRelativeToOwnedDevice=executable,
                   fileRelativeToOwnedDevice=str(p.relative_to(self.root)), logByteOffsetObserved=self.offset,
                   presentBeforeTargetBinding=preexisting,
                   association='sampled executable while target case marker active; not filename ordering')

    def read_probe(self, pid, candidate, live):
        if candidate['closed']: return
        p = candidate['path']; began = time.monotonic()
        try:
            fd = os.open(p, os.O_RDONLY | os.O_NOFOLLOW)
        except FileNotFoundError: return
        try:
            before = os.fstat(fd)
            if not stat.S_ISREG(before.st_mode) or before.st_size > FILE_CAP: raise ValueError('probe type/size')
            data = os.read(fd, FILE_CAP + 1); after = os.fstat(fd)
        finally: os.close(fd)
        if len(data) > FILE_CAP: raise ValueError('probe byte cap')
        if (before.st_ino, before.st_size, before.st_mtime_ns) != (after.st_ino, after.st_size, after.st_mtime_ns):
            return  # A writer was active; the last stable bounded snapshot remains available.
        candidate['reads'] += 1
        candidate['maxReadMS'] = max(candidate['maxReadMS'], (time.monotonic()-began)*1000)
        candidate['latest'] = dict(data=data, observedUTC=utc(), fileMTimeNS=after.st_mtime_ns,
                                   inode=after.st_ino, closed=False, footerPresent=False, rows=None, pidPresent=live,
                                   quality=dict(completeForDeclaredScope=False,reasons=['notDecoded']))
        try:
            rows, closed = decode_probe(data)
        except (ValueError, TypeError) as error:
            candidate['latest']['quality'] = dict(completeForDeclaredScope=False,reasons=['invalidBoundedPayload'],
                                                  decodeError=type(error).__name__)
            return  # Keep exact stable bytes even when their final record cannot be interpreted.
        candidate['latest'].update(footerPresent=closed,rows=len(rows),quality=probe_quality(rows))
        if closed:
            # Footer precedes close() in the compiled sink. Confirm no descriptor remains open.
            holders = subprocess.run(['/usr/sbin/lsof', '-t', str(p)], capture_output=True, timeout=2)
            if holders.returncode == 1 and not holders.stdout and not holders.stderr:
                sealed = os.stat(p, follow_symlinks=False)
                if (sealed.st_ino, sealed.st_size, sealed.st_mtime_ns) == (after.st_ino, after.st_size, after.st_mtime_ns):
                    candidate['latest']['closed'] = True
                    self.save(pid, candidate, 'footerCompleteNoOpenDescriptorAndSourceStable')
                else:
                    candidate['latest']['closed'] = False
            else:
                candidate['latest']['closed'] = False

    def save(self, pid, candidate, reason):
        latest = candidate['latest']
        if latest is None or candidate['closed']: return
        suffix = 'closed' if latest['closed'] else 'incomplete'
        path = self.out / f'ui09-animation-{pid}.{suffix}.ndjson'
        if path.exists(): return
        path.write_bytes(latest['data'])
        self.event('probePreserved', pid=pid, status=suffix, reason=reason, bytes=len(latest['data']),
                   sha256=digest(latest['data']), snapshotUTC=latest['observedUTC'], rows=latest['rows'],
                   sourceInode=latest['inode'], sourceMTimeNS=latest['fileMTimeNS'],
                   processPresentAtSnapshot=latest['pidPresent'], maxReadMS=candidate['maxReadMS'])
        self.event('probeCoverage',pid=pid,transportSealed=latest['closed'],**latest['quality'])
        candidate['closed'] = latest['closed']

    def run(self):
        try:
            self.thread_started_utc = utc()
            self.event('collectorStarted', device=self.device, target=TARGET, pollSeconds=1,
                       perFileBytes=FILE_CAP, targetPIDLimit=8, eventBytes=EVENT_CAP,
                       startupHandshake='threadStartedOnly; process discovery not established',
                       uncertainty='one-second sampling, query duration and log buffering; no unique mapping if target has multiple PIDs')
            self.ready.set()
            while not self.stop.is_set() and time.monotonic()-self.started < 2400:
                began = time.monotonic(); self.cases(); current = self.poll_processes()
                if current is not None:
                    self.process_events(current)
                    if self.current_case == TARGET:
                        if len(current) > 1: self.ambiguous = True
                        for pid, exe in current.items():
                            if pid not in self.candidates: self.bind(pid, exe)
                for pid, candidate in self.candidates.items():
                    if current is not None and pid in current and current[pid] != candidate['executable']: raise ValueError('PID reused')
                    self.read_probe(pid, candidate, None if current is None else pid in current)
                    if current is not None and pid not in current: self.save(pid, candidate, 'PIDAbsentWithoutFooter')
                if current is not None: self.previous = current
                self.max_poll_ms = max(self.max_poll_ms, (time.monotonic()-began)*1000)
                # Failed polls wait one second before the next ordinary sampling cycle; no tight retry loop.
                self.stop.wait(1 if current is None else max(0, 1-(time.monotonic()-began)))
        except Exception as error:
            self.error = type(error).__name__ + ': ' + str(error)
        finally:
            for pid, candidate in self.candidates.items():
                try: self.save(pid, candidate, 'collectorEndingWithoutFooter')
                except Exception as error: self.error = self.error or ('finalSave: '+str(error))
            self.events.close()
            receipt = dict(target=TARGET, device=self.device, finishedUTC=utc(), polls=self.polls,
                           elapsedSeconds=time.monotonic()-self.started, maxPollMS=self.max_poll_ms,
                           error=self.error, targetStarted=self.target_started, targetEnded=self.target_ended,
                           targetPIDs=list(self.candidates), uniqueSampledPID=len(self.candidates)==1,
                           associationAmbiguous=self.ambiguous or len(self.candidates)>1,
                           processDiscovery=self.discovery_summary(),
                           probes=[dict(pid=pid,transportSealed=c['closed'],
                                        quality=c['latest']['quality'] if c['latest'] else None)
                                   for pid,c in self.candidates.items()],
                           missingDataIsInconclusive=True, eventsSHA256=digest((self.out/'events.ndjson').read_bytes()))
            (self.out/'receipt.json').write_text(json.dumps(receipt, indent=2)+'\n')
