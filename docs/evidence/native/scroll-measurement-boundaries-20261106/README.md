# Measurement-boundary diagnostic proposal — exact 807

Base: `807aa3c73ed872d4a83f6cbd71f7633797bb6fc8`. This folder is an unapplied scratch proposal. `proposal.patch` changes exactly three files: the Release performance test, the existing diagnostic parser, and its offline tests. `base/` is copied from the hash-verified frozen source; `files/` is the proposed result. No tracked files, Git state, remote state, native execution, or frozen evidence were changed.

The question is whether 807's long interval after its first swipe is spent inside the existing `stopMeasuring()` call, and whether the lone endpoints in its first two diagnostic windows are begin or end events or have counterparts nearby. The existing evidence cannot answer these questions. This proposal collects discriminating observations without attempting a fix.

## Test-side receipt

The scroll test buffers six `ProcessInfo.processInfo.systemUptime` readings per invocation:

1. Immediately before and after the existing `startMeasuring()` call.
2. Immediately before and after the existing `list.swipeUp(velocity: .fast)` call.
3. Immediately before and after the existing `stopMeasuring()` call.

The tuple array reserves capacity for six invocations before `measure` and is appended after `stopMeasuring` returns. No logging, formatting, attachment, wall-clock read, or serialization occurs during the measure closure. The buffer is serialized into the `scroll-measurement-boundaries` JSON attachment only after `measure` returns. A bracketed wall-clock/uptime anchor is collected before and after the whole measurement to estimate correlation with UTC signpost events and expose clock drift. No sleep, polling, additional gesture, warm-up, measurement call, retry, metric wrapper/subclass, or assertion is introduced. Every original Swift line remains present and in order. Original metrics, measurement options, five iterations, reset/check assertions and velocities remain unchanged.

Observed invocation indices are zero-based and all completed invocations are retained, including the expected warm-up. Six invocations are expected from the two retained executions; the receipt does not instruct XCTest to discard any invocation or independently certify its warm-up/sample mapping. The first-as-warm-up interpretation must be checked against the actual execution, expected six-invocation shape and original metric cardinality. An unexpected count is diagnostic incompleteness, not permission to relabel, drop, or synthesize samples. Extra invocations remain visible and are not silently capped. Early failure, process termination or a measurement abort can prevent the post-measure receipt; its absence does not prove that a boundary was never reached. Attachment serialization failure is reported only after measurement and is not converted into a test pass claim.

The timestamps bracket public calls, not internal XCTest collection start/stop or event delivery. The reads between start and stop perturb measured work; clock reads, array setup, buffered writes and surrounding bookkeeping can also affect scheduling/memory/cache state. The buffer is preallocated to reduce, not eliminate, perturbation. Any result from this modified test is diagnostic and cannot establish release acceptance or instrumented/uninstrumented equivalence. No baseline is updated.

## Endpoint receipt

The existing parser's schema version becomes 2 and adds `endpointEvidence`. Existing summary windows, pair rules and summary status calculation remain unchanged. The receipt keeps only parsed UIKit scrolling-signpost fields: begin/end kind, time relative to the first enclosing swipe activity, numeric `originUnixUTC` copied from that validated activity start, per-receipt process/signpost ordinal tokens and diagnostic window indices. Equal tokens preserve correlation within one receipt; tokens are not raw PIDs/IDs or unique gesture identities, and have no cross-run meaning. Raw messages, unrelated logging and app records are not retained.

Scope is first reset activity start minus 5 seconds through the final following activity start plus 5 seconds. This includes resets and inter-window intervals as well as measured swipe activity windows. Only the first 128 scoped endpoints in captured order are retained; total/retained/omitted counts and `truncated` status are explicit. The scope and each window's start/synthesis/following offsets are retained. Adding any endpoint offset to `originUnixUTC` reconstructs its UTC timestamp, subject to the original log precision and the test-side clock-anchor uncertainty. Events outside a swipe window have an empty `windowIndices` list. Existing inclusive boundary and exact-two-matching-endpoint pair rules remain intact. Neither this bounded receipt nor the log query establishes complete OS emission/delivery. An endpoint farther outside this scope will remain unavailable; truncation never authorizes selecting a convenient pair.

Consumers must check `endpointEvidence.status` independently of the original summary status. For example, invalid reset timing makes endpoint scope unavailable without changing the previously computed pair verdict. Missing, truncated or malformed endpoint evidence is not a complete diagnostic. Its status never replaces native, warning, lifecycle, metric-cardinality, persistence or baseline gates.

The existing workflow already exports all XCTest attachments and retains the parser JSON, so no workflow change is proposed. Raw filtered logs and exported activity JSON remain temporary as before. Exact workflow/checker/baseline/fixture hashes are in `validation.json`.

## Interpretations and limits

A long before/after stop interval would locate elapsed time within that call, but would not identify the cause as signpost waiting rather than another framework operation. A short interval would place the earlier unrecorded delay elsewhere. A begin/end receipt could show a counterpart outside the activity window or identify the lone endpoint kind; it cannot establish that XCTest consumed an emitted event. UTC correlation is approximate: anchor bracket widths and possible wall-clock drift must be considered before asserting boundary ordering, especially at millisecond scales. Monotonic call durations do not need that conversion.

A passing repeat could be nonreproduction under instrumentation. A missing five-sample duration series remains a failure even when diagnostic pairs exist; four pairs never replace five duration samples. No timing delay, sample deletion or causal race finding is proposed. The historical f117/807 outcomes remain unchanged.

## Offline validation and review boundary

- 16 parser tests pass (9 preserved plus 7 receipt tests), covering missing begin/end, nearby out-of-window events, scope exclusion, token equality/redaction, bounded overflow, unavailable scope, failed capture and UTC-origin reconstruction.
- Python AST parsing passes. The patch applied cleanly to a scratch copy and produced the exact proposed files.
- Static checks preserve every original Swift line, original measurement/gesture call counts, metric block and measurement options.
- All 357 f117 and 359 807 frozen files rehash unchanged.
- No Swift typecheck/build/native test was performed by this helper. This is a reviewable proposal, not compiled or runtime-qualified code. Root owns any subsequent review, application or separately authorized execution.

`validation.json` records source and patch SHA256 values; `offline-tests.log` and `patch-application.log` retain the bounded validation results. `proposal-manifest.json` hashes the proposal artifacts.
