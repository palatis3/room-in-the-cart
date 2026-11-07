# Offline consent OSLog reconciliation

`reconcile_consent_logs.py` never starts a process, contacts a service, captures logs, or changes app/test state. It reads two already-retained **narrowly filtered** compact logs and writes a diagnostic JSON report. Root owns any future collection. `capture-contract.json` fixes the predicate, format and metadata requirements; it is not an executable collector.

Conventions inspected: `scripts/scroll_signpost_diagnostic.py` and its tests (scoped parsing, diagnostic-only outputs, incomplete evidence retained); the original keyboard compact OSLog; and `.build/KeyboardDiagnostic20261106/baseline-independent-review/REVIEW.md:29`, where persisted exports omitted whole launches despite live-capture liveness.

## Input contract

Both inputs must use compact OSLog, info level, and only this predicate:

`subsystem == "dev.roominthecart.measurementconsentdiagnostic" AND category == "events"`

Report schema version 2 preserves the original `timestampRaw`. It records `wallTimeZone` and `timezoneProvenance` separately for each source. `log stream` has no `--timezone` option, so live timestamps default to unknown timezone. Do not label them UTC based on a host assumption or change the system timezone. `log show --timezone UTC` establishes UTC display for that export only; explicit start/end offsets (for example `+0000`) establish the requested window. Supply `--export-timezone UTC` only with that command provenance. Unknown is the default for both sources. The timezone argument records caller evidence; the parser cannot verify it. Wall-clock strings do not enter event identity.

The parser accepts the exact overlay schema and RoomInTheCart process envelope. JSON/NDJSON, changed fields/event names, truncated/redacted payloads, malformed timestamps, invalid flags and impossible sequence values remain unparsed scoped lines; it never silently accepts another schema. Keep raw originals outside the report. Do not pass a whole system log or environment/credential dump. Unrelated lines are counted and ignored; malformed lines are reported by line number only, never echoed. Only allowed structural fields and OSLog timestamp/PID/line metadata enter the output.

For future collection, retain live stdout/stderr and bounded persisted stdout/stderr separately, start capture before the invocation, and export before cleanup. Record each command's start/finalization outcome and liveness separately. Never replace live output with persisted output. No sleep or change to test actions is required. Explicit capture `ok` means the collector operation reported success, **not** that delivery was complete. Use `unknown` unless outcome evidence exists.

## Offline use

From this helper directory, after root has reviewed and supplied existing filtered artifacts:

```sh
python3 reconcile_consent_logs.py --live events-live.log --export events-export.log \
  --live-status ok --export-status ok --export-timezone UTC --expected-pid 101 --output reconciliation.json
```

Replace the example PID with OS process metadata independently correlated to the test logs. Repeat `--expected-pid` for known launches; omit it when unknown. Do not infer expected launches by array position or use a domain/workspace identifier. Missing/unreadable/non-UTF8 files generate unavailable/inconclusive reports. Exit 0 means the report was written; it is never a test pass or evidence gate. Invalid CLI configuration exits nonzero.

## Evidence preserved

The report retains per-source input order, per-process sequences, missing prefix and internal gap ranges, exact duplicate occurrence counts, all event variants, cross-source live-only/export-only/shared unique counts, activation presence and conflicting same-PID/sequence records. Uptime comparison is exact decimal without floating-point/context rounding. Equal events across streams are corroborating observations, not duplicates within one stream. Conflicts remain explicit; no preferred stream or variant wins. Sequence restarts under a reused PID are ambiguous rather than silently treated as one clean process. Known processes absent from both streams remain represented.

Sequence identity uses PID, sequence, exact uptime, event and all structural flags; wall-clock formatting is retained but does not create artificial conflicts between otherwise equal observations. Capture windows must belong to the same invocation/device; this script cannot verify their provenance. SHA-256 hashes identify the supplied input bytes, not any user/domain identity.

Every report is `diagnosticOnly: true`, `status: inconclusive`, `exhaustiveDeliveryEstablished: false`, `noSetterInferencePermitted: false`, and `absenceMeaning: not_observed`. Positive event observations remain available for analysis. Healthy status, identical streams, gap-free sequences, and a fixture marker never prove absence of missing events: an unseen suffix or whole launch may leave no gap. Even an observed setter is not proof of actual tap targeting or UI completion. Conflict variants cannot establish a unique delivered Boolean.

Validation: 21 synthetic tests pass, covering full agreement, invisible tails, whole-launch export loss, expected missing processes, missing activation, huge sequence gaps without range expansion, duplicates, cross-source conflicts, PID reuse, input ordering, empty/failed captures, export-only events, private-string non-echo, fixed-schema rejection, exact precision, rejection/reset events, offline CLI behavior, raw timestamp provenance, and cross-timezone event reconciliation. No actual consent logs or native/hosted execution were used for validation. These offline helpers do not modify the four-file native overlay.
