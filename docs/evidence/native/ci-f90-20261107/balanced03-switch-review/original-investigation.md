# Original balanced-03 matched-switch failure

Exact f90 run 42428215965 / job 128575557708 / artifact 13599104299 failed 1 of 10 cases. `HouseholdRequestPackUITests.testReviewedCheapestAvailablePackUsesActualDecisionAndCancelHasNoWrite` failed after 189.973 seconds at line 307: first pack A matched-switch value was 0 after one tap, expected 1. Pack B entry, comparison, selection, overage, and exactly-one-write assertions were not reached. No correction is supported by the retained evidence; no source change or native execution was performed.

## Observed boundary

- `Tests.log` lines 6502–6615 show real keyboard dismissal, successful nonexistent-keyboard expectation, two bounded scrolls, and the single normalized (0.92, 0.5) tap. The original screenshot and full failure hierarchy show no keyboard and a visible off switch. Pack A source still contains `Reviewed shelf a`.
- Failure hierarchy outer switch frame is {{16, 186.3}, {370, 72.3}}; nested physical switch is {{309, 208.7}, {63, 28}}. The synthesized-event payload records touch down/up at (356.4, 222.5), 0.05 seconds apart, inside that physical switch. The runner independently resolves the same frame before dispatch. This does not support another visibility or coordinate correction.
- Session log 566210–566325 records local synthesis at 01:42:11.732 UTC, `TouchEventsCompleted` from app PID 34760 at 11.845, completion callback at 12.019, and main-loop/animation idle replies at 12.025–12.026. The subsequent query at 12.161 still returns 0. These receipts establish completed touch processing, but do not establish that the SwiftUI Toggle binding setter ran.
- Preview diagnostics: previews 0, busy false, selected original request, choice add, empty decision price, preview none, notice none. No decision write or preview was in flight in the retained failure state.

## Source audit

All five audited test/product/fixture files are byte-identical to f90 (hashes in `review-receipt.json`). `RequestPackDraft.matched` starts false; the only direct write path is the Toggle's `draft.matched` binding. `first` and `second` are view-local @State drafts. Every pack-view onChange invokes `reset()`, which clears only comparison, reviewedScope, and failure. There is no onAppear, task, timer, async callback, or assignment rebuilding those drafts inside that view.

The parent conditionally includes the pack view while authorized, selected request matches, pending is nil, shop/choices exist, and choice is add. Removing/recreating that subtree could reconstruct @State, but no retained evidence demonstrates such a transition. The parent task selects the request when presented; inbox load and explicit service actions can update model facts, but no recurring refresh is installed here. The fixture creates its model once; callbacks update only post/line/preview counters. Retained source text, expanded disclosure, choice add, busy false and unchanged switch AX identity argue against broad reconstruction, without proving it impossible.

The previous keyboard/full-visibility correction and successful 3-case local validation are retained in `docs/evidence/native/household-pack-switch-20261105/validation.json`. This failure already contains that correction and occurs after full visibility; repeating it is unsupported.

## Diagnostics retained without causal attribution

The structured warning export has 0 runtime warnings for all 10 cases. Raw Tests.log still contains the multiple-destination warning and runner CA launch-measurement errors at startup. The original Session has symbolication errors after the failed readback (01:42:14.150 onward) and invalid-input-rect 10204 errors during teardown hierarchy collection (14.982 onward). Exact relevant lines are retained in `runner-tap-and-failure-excerpts.txt`; the complete original Session export is hashed in the receipt. These diagnostics are not suppressed and do not establish the cause of the earlier unchanged switch value.

## Smallest useful next diagnostic

Preserve the exact fixture context, single tap, immediate readback, complete journey, OS settings, all assertions, and existing timeouts. In an isolated diagnostic candidate, instrument only the matched Toggle binding setter (old/new Bool, existing draft UUID, pack index, selected request and choice), existing first/second onChange callbacks (old/new UUID and matched), and pack-view appearance/disappearance. Emit monotonic timestamps without user text or state mutation. Keep the original setter semantics and avoid additional UI reads/delays around the tap. Existing XCTest event/snapshot receipts plus these markers distinguish (a) touch completed but no binding setter, (b) setter received true then state was overwritten/reconstructed, and (c) retained state true with stale accessibility readback. A nonreproduction would remain limited evidence, not proof of resolution. No retry, coordinate change, timeout increase, or app correction is justified yet.

## Artifact integrity

API ZIP digest: `6dd0afced63ef9b8781e4f87f8f184e3b42619fb4bae88949ff27340ca9403d4` (54,480,673 bytes). The full ZIP was not downloaded, so this digest was not locally verified. Existing guarded range collection pins run/head/artifact/name/size/digest and verifies exact HTTP ranges, ZIP CRC, member paths/types/size/ratio, plus extracted SHA-256. Metadata, five exact failed-case attachments and one runner Session were fetched; all pristine member hashes and exported attachment hashes were rechecked. Monitor-owned small log/JSON receipts remain in sibling `balanced-03/`. Local `review-receipt.json`, three range receipts, pristine manifests and export receipts record exact scope and hashes.
