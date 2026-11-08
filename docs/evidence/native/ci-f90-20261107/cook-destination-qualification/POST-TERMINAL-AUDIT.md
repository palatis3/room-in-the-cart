# Prepared post-terminal audit — unexecuted

Only after root observes terminal exec 95723 and its actual xcodebuild exit:

```
python3 .build/CookDestinationTraceNov08/post-terminal-audit.py --native-exit 0
```

Use `65` if that was the actual terminal exit. This argument is evidence, not a request to pretend success. The script also refuses a matching active xcodebuild, absent/ambiguous result banner, unfinished SQLite action, or changed selector list. It audits actual observed start order and runs the unchanged strict checker. Runtime issues for the preceding speech-readback case are kept separate from destination markers; strict failure does not prevent diagnostic recovery.

No new build, native test, simulator action or network access is performed. All outputs are fresh scratch under `post-terminal-audit/`; originals stay immutable. It first makes a hash-verified inspection copy (256 MB / 50,000 regular-file cap), then reads diagnostic directory objects. Only the exact app `StandardOutputAndStandardError-dev.roominthecart.app.debug.txt` object is exported, with hard child file-size limit 256 MB. Metadata is limited to 256 KB; result JSON/command stdout to 10 MB; validated markers to 1,000; commands time out at 120 seconds. No all-diagnostics bulk export occurs.

The preflight records the exact advertised directory entry, object reference, stored-object byte count and hash **before** stdout export. Existing directory entries may advertise only name/type, so expanded size can be unknown; compressed object size is never represented as expanded size. A full five-case stdout can legitimately exceed the initial 256 MB limit (the prior singleton was 173 MB). Such refusal is `unavailable`, not proof of missing markers or a missing setter. Root must review any exact scoped allowance separately; the script never raises its own caps or retries.

Validated fixed-scope markers yield per-PID/state-token setter, reset and lifecycle sequences. No payloads, business IDs, arbitrary error text or text-field values enter marker evidence. Full stdout remains private scratch; structured runtime issue descriptions are original diagnostic evidence for later review, not destination events. A complete capture can narrow received/reset/new-storage boundaries; it cannot identify a framework event-routing failure, prove all SwiftUI transitions were observed, or turn an instrumented pass into a fix. Do not copy full stdout, inspection bundle, or raw directory/private data into durable docs.

Preparation validation: Python syntax parsed; no audit command executed while the run was active. Root should inspect `audit-status.json`, `audit-unavailable.json`, `order-audit.json`, `strict-status.json`, `runtime-issues-separate.json`, `capture-receipt.json`, and `continuity.json` independently. The command's successful completion alone does not mean strict checks passed.
