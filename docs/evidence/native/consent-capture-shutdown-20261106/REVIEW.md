# Collector shutdown follow-up — scratch only

Prepared against exact **f019f16124a1edf4d825c2a860efb0c2ca1488cd**. The installation target, if root approves it, is the unpublished diagnostic checkout at `/Users/palatis/.codex/worktrees/consent-history-diagnostic/Room in the Cart`. This patch is **not for main's historical preparation bundle**. It changes only the hosted harness, its offline tests, and the two corresponding hashes in its overlay index. No installation, commit, push, dispatch, simulator, build or native test was performed.

`capture-stop.patch` SHA-256: **8f08b735b93d605934389dc9003d54d0d9bfa8f5078025e8318bd019f71c6a7b**. `manifest.json` proves exact before/after hashes and preserved functions; the patch dry-run passes against scratch originals. **57 offline tests pass**, including 11 new shutdown tests. Python syntax parsing passes. The workflow is byte-unchanged, so its previous lint result remains applicable; no linter policy was changed.

## Evidence and interpretation

The frozen `../independent-review/` proves seven original cases passed, with zero warnings, but retains owner exit -9, absent `capture-final.json`, and 18 live events versus zero persisted events. This does not identify a consent defect or fix.

Two source defects are confirmed: the old parent fallback immediately killed the helper after signaling its child, without allowing another completion interval; and later `stop_owned_capture()` calls overwrote the same cleanup receipt. The hypothesis that the initial TERM was consumed by CPython's macOS kqueue `OSError` catch is supported by the recorded 3.15.2 executable path and upstream source, but the actual suspended frame/installed library bytes were not retained. The patch must not turn that inference into a claimed proven hosted cause. The synthetic test models the known exception-class interaction; it is not a hosted reproduction.

## Focused behavior changes

- `modified/.../harness.py:294` uses `_CaptureStop(Exception)`, outside the `OSError` hierarchy. Once helper finalization begins, repeated TERM/INT cannot interrupt its one bounded finalization path.
- Line 298 writes `capture-stop-events.jsonl` with one `O_APPEND` write per small record. Identity checks, signal requests, signal results, wait starts/timeouts, reaping and exhausted budgets are distinct, timestamped stages. Later collect/cleanup calls append instead of erasing earlier evidence. The old overwritten `capture-cleanup.json` is no longer produced by this revision.
- Line 317 checks the recorded PID fingerprint before **every** TERM or KILL and records the request before executing it. Missing/mismatched identity or exhausted budget refuses the signal. There is no global process operation. Checks that time out remain unverified rather than authorizing a kill.
- Lines 351 and 394 bound child and parent finalization using monotonic deadlines. Child nominal waits remain 5+5 seconds, total **10**. Parent nominal waits become 12+2+3 instead of 12+5, total **17**: after initial grace expires, it signals the recorded child, waits for the helper's finalization, and only then escalates still-matching processes. Identity-query time is included in these deadlines, so no auxiliary budget increases.
- `execute()` reports owner reaping separately from helper receipt presence and confirmed graceful finalization. A forced reap or missing helper receipt cannot masquerade as graceful completion. Complete log delivery remains false regardless. Separate collect/cleanup processes perform bounded identity-checked signaling only and explicitly do not claim to reap processes they do not own.

The native command, all seven selectors/order, original test actions/assertions, source/product guards, compiled inventory, artifact transport, runtime selection, boot, strict warning checker, replay-copy preservation, OSLog schema, parser, and workflow are unchanged. XCTest allowances remain **720/900**, native step **40 minutes**, jobs **35/55 minutes**. The overlay index updates only harness and test hashes and keeps base 804 and all four Swift hashes intact.

## Verification and limits

New synthetic coverage includes the private exception versus an OSError-catching wait, actual handler registration, clean helper finalization, 10-second child escalation, clean parent grace, successful delayed finalization after child TERM without KILL, 17-second escalation, reused PID refusal, identity rechecks before KILL, budget consumed by identity lookup, append-only phase preservation, and preservation of native failure plus explicit missing-final-receipt state. Existing transport, exact-source, selectors, warning/replay preservation and parser tests also pass.

A hard runner termination can still prevent final writes, and PID mismatches intentionally leave completion unverified. The deadlines cap waits and identity subprocesses; ordinary filesystem/scheduler overhead is not a real-time guarantee. No healthy collector state authorizes no-setter inference. This proposal fixes collector robustness only and does not justify another diagnostic dispatch by itself.

Root can review/apply the three-file patch in the isolated diagnostic checkout, then document a main-branch pointer to this new collector-only revision without rewriting the original dispatched overlay's provenance. No diagnostic-branch push is part of this preparation.
