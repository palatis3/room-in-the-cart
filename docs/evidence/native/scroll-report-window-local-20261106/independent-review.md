# Independent review: standalone scroll report-window witness

**No blocking implementation defect found for this scratch diagnostic preparation.** This review does not qualify XCTest runtime compatibility, approve dispatch, or establish that the original missing-series failure will reproduce. The pending endpoint/report correlator is a separate required review boundary.

## Exact overlay and protocol

Read-only comparisons independently confirm the retained original hash matches exact 0d5 (`c7954233968072b97fd5845d5c28877c9251495cfee33675169a960839d2625f`), the overlay hash matches preparation.json, the patch exactly represents original→overlay, and inline recorder/metric definitions equal the standalone files. The whole measure block, reset/gesture/assertion sequence and measurementOptions are byte-identical. The native scroll/memory/hitch metric construction and relative order remain unchanged; the standalone witness is appended afterward. Current baseline bytes still match the retained hash. No wrapper, delegate, synthesized signpost, manual-stop change, replacement sample, timing delay or baseline relaxation appears.

`WitnessMetric.swift:4–31` implements NSObject/XCTMetric and returns a new witness from copy(with:), using the same per-test recorder and a fresh ordinal. It does not return self or copy a built-in collector. Report callbacks read the supplied framework timestamps into scalar values, record them and return an empty measurement array. It never calls another metric's lifecycle/report methods. This avoids the prior wrapper's built-in-class replacement, but does not prove that XCTest accepts an empty custom measurement array or preserves other collectors under this composition.

## Storage, bounds and privacy

`WitnessRecorder.swift:38–85` locks all mutable shared fields, including identity allocation, global event sequence, report count, retained array and snapshot. No callback assumes the main thread. New instances and all callbacks share one recorder owned by this test; no global cache or cross-run identity exists. Retained events are capped at 128, counters include omitted events, and truncation takes precedence in status. A snapshot copies the scalar event array while locked; later writes use Swift array value semantics and cannot mutate the returned value. There is no disk I/O, UI query, sleeping, console output or JSON serialization in callbacks.

Payload contains only local ordinals, lifecycle labels, timing values and supplied-bound observations. No framework objects, stack traces, PIDs, grocery names, field values, source text or private Records survive in the recorder. UInt64 clocks are decimal strings, avoiding floating-point identifier/timestamp loss. Nonfinite supplied dates are retained explicitly with invalidUnixSeconds and no finite substitute; reversed bounds are preserved for later rejection. These behaviors are honest evidence retention, not validation success.

## Interpretation constraints for the correlator

1. **Lock order, not exact callback entry order.** Sequence and callbackUptime/callbackUnixUTC are captured after the lock is acquired, after supplied timestamps have already been copied for report events. Contending callbacks may serialize differently from their true entry order. Those fields identify recorder observation time/order, not collector start, stop, delivery, emission or exact callback entry. The two clock reads are sequential and do not form a bracketed clock-correlation sample.
2. **Recorded is not validated.** `status == recorded` means at least one report callback was counted without retained-event overflow. It intentionally says nothing about finite/reversed supplied bounds, duplicate reports, lifecycle completeness, copy consistency or warm-up mapping. The harness explicitly demonstrates invalid/reversed supplied bounds and duplicate reports can be retained. The correlator must independently reject/mark these unavailable rather than trusting that status.
3. **Snapshot cutoff.** The attachment is a snapshot after measure returns. It cannot establish that no later framework callback will ever occur. Missing attachment after measurement abort/process death is unavailable evidence, not proof that callbacks never happened. A complete lifecycle interpretation requires the actual retained per-instance callbacks; never infer a fixed five/six report count or discard report zero as warm-up.
4. **Different observer.** Supplied report bounds belong to this custom witness. They do not prove the built-in signpost collector's private windows or event receipt. Keep schema-2 endpoint origin, scope, token equality, source/attachment/result identity, nontruncation and precision checks independent. Boundary overlap within uncertainty remains ambiguous.

These are reporting/parser constraints, not requests to add clock reads or more actions inside the measured loop.

## Attachment and validation scope

The overlay serializes only after measure returns, attaches `scroll-report-window-witness` with keepAlways, then executes the original screenshot. Encoding failure can throw from the test after measurement; that would be a diagnostic failure, not an original omission reproduction. No error is swallowed and no failure is converted into an accepted metric. Framework abort can prevent this attachment, as with the rejected wrapper; preserve that distinction.

The retained Foundation-only harness records eight checks: empty recorder; identity/serial lifecycle; exact UInt64 JSON; nonfinite/reversed timestamps; prefix overflow counts; zero capacity; duplicate reports; and 1,000 concurrent instance/callback sequences. The concurrent case asserts 4,000 total events, 128 retained, 3,872 omitted and 1,000 reports. Its “ordered” claim applies to the recorder's serialized sequence only. It does not instantiate XCTest metric copies, run real callbacks, exercise report-window alignment, or test empty-array framework behavior. I reviewed the harness and results but did not execute them.

The typecheck and recorder-build logs are empty, consistent with root's reported successful local checks; empty logs alone are not independent exit-status/command receipts. `preparation.json` correctly records runtimeQualified=false. Xcode 27.1 typechecking is not compilation/runtime proof for hosted Xcode 26.3, nor proof of empty[] acceptance. Before execution use a separately frozen product/source identity and validate the report/endpoint correlator. A new null-date/framework assertion invalidates this probe; do not invent a sample to make it pass. A passing native run with duration is nonreproduction, not release acceptance or a causal fix.

## Provenance

Reviewed the prior `docs/evidence/native/scroll-report-window-proposal-20261106/REVIEW.md` and rejected-wrapper `docs/evidence/native/scroll-report-probe-20261106/REVIEW.md`. No source changes, builds, test/native execution, network, Git, dispatches or new agents. Only this review was written. Principal reviewed hashes:
- `original.swift`: `c7954233968072b97fd5845d5c28877c9251495cfee33675169a960839d2625f`
- `ReleasePerformanceUITests.swift`: `d1f2c40dfbf1603366ecf6309d264c3372ddce260ca97d4cfd7806b00622c06b`
- `WitnessRecorder.swift`: `bf73f5dc3109d864aba3bd6ea11538b9b1f4373c58929f2bbf6d8190828a27ee`
- `WitnessMetric.swift`: `e6fdca2cc8d45267cfa88245993df3aa998df81cbb4b6ce8c72a2d95e078243c`
- `test-overlay.patch`: `31743212678d58c8212076b5eed6b060117d4a43e2a442d2cec2792e10f777b3`
- `preparation.json`: `609c91bb8d897c7cd262d99faf4d22efd5fac96d7daf0386438b1cd971c26f97`
- `main.swift`: `82882878a6eef06b43975c7b3cb284a2061704fbd03d991fa55edb220c3d21fa`
- `recorder-checks.json`: `cb2ffce3284aef40b2e705938fa9239313e697433e69fce560e8ca2578b7bd99`
- `typecheck.log`: `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855`
- `recorder-build.log`: `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855`
