# Cook destination confirmation diagnostic — scratch only

Prepared against HEAD a0195caa8eea9a5247cf1232902cbb2e215844d7 and the exact working-file hashes in `source-pins.json`. The proposed patch touches only `SharedCookHistoryView.swift` and one launch-environment line in the original saved-copy test. It does not touch the three installed S24 diagnostic files, later SharedDelivery cases, product safeguards, helpers, limits or workflows. No source installation, compilation or native execution occurred.

## Existing ownership and reset audit

`SharedCookSavedView` owns `destinationConfirmed` in local `@State`. The only explicit writes are initialization to false, the existing Toggle setter, and `invalidate()` (current source lines 87, 158, 238). The setter clears request/correction state then assigns the supplied Bool; the patch only surrounds this exact existing setter, without replacing its Binding or transaction behavior.

Existing reset routes:

| Route | Effect on destination | Proposed observation |
| --- | --- | --- |
| Recipient change | `invalidate()` resets confirmation, review and correction | recipient-changed then invalidate-enter/return |
| `allowed` becomes false | Clears recipient/sharing and invalidates; recipient change can invalidate again | allowed-changed plus both existing invalidations |
| Scene becomes inactive/background | Invalidates | scene-changed then invalidation |
| Navigation disappearance | Invalidates | disappear then invalidation |
| Check previous send | Explicit invalidation before asynchronous baseline request | check-recipient-enter/exit, invalidation, baseline-accepted |
| Mark sent | Explicit invalidation before save, then rechecks on success | mark-sent-enter/exit, invalidation, nested baseline markers |
| Paid access changes | Clears request/assisted sharing/correction, **not** destination | paid-changed, clear-correction |
| Seat deadline expires | Clears assisted sharing/correction, **not** destination | seat-deadline-fired, clear-correction |
| Full wording changes | Clears wording confirmation only | No new marker; cannot reset destination |
| Async correction review | Captures destination; rejects result if request/review/destination changed; changes correction or sharing, never destination | review-enter/result/exit; clear-correction if existing error/access path uses it |

`onAppear` may restore a pending recipient, which can trigger the existing recipient invalidation. No custom saved-view initializer reconstructs a draft or writes destination. Parent `SharedCookHistoryView` loads its copies through `.task(id: page)`/refresh and owns the `ForEach` navigation destination. Parent/list changes can affect state lifetime; the random diagnostic `@State` token and lifecycle markers help distinguish retained versus newly installed state storage, not ordinary recreation of the SwiftUI View value.

`HouseholdShopModel` does not hold this local Bool. `cookCopyBaseline` updates model review ownership/read tokens; `reviewedCookCorrection` calls guarded service reads and checks generation/page/authority. `markCookCopySent` goes through the existing saved operation and preserves deliveryRecord for cook-copy operations. None directly sets destination. Errors that end access/session can run `handle`/clear; scope/shop refresh (`updateScope`, `refreshFacts`) can clear deliveryRecord and therefore flip `allowed`. `HouseholdModel` may clear/replace sharedShop on authority/scope changes. The proposed read-only allowed/model/page/copy observations expose that boundary without logging any actual model, household, recipient or copy identifier.

## Marker contract

Compile gate: `DEBUG && CONTRIBUTOR_CAPTURE_UI_FIXTURE`. Runtime gate: all existing `--ui-testing`, `--shared-delivery-fixture`, `--shared-cook-copies-fixture` arguments plus environment value exactly equal to the fixed original selector. Only the target test sets it. No arbitrary environment text is printed.

`S24_COOK_DESTINATION_TRACE` records monotonic process uptime, PID, fixed test scope/event, a random diagnostic state-lifetime UUID, old/requested Bool when relevant, current destination Bool, and presence/access/scene Booleans. It includes no recipient, wording, payload length, product/request/server IDs, error text, network data or persisted value. The token is not a business identifier and is not stored outside process stdout. No server/model mutation, UI element, notification, custom event or new asynchronous work is introduced. Release/ordinary nonfixture source after conditional removal is whitespace-normalized identical to the original.

Use full xcresult app stdout as the authoritative capture, consistent with the root-qualified S24 sink. Console absence alone is not evidence that a setter was not called. Preserve the full original five-case selector/order file supplied here (the target is fifth, following the readback case); retain the speech warning and strict failure independently. A singleton could qualify this trace's capture but would not reproduce the original preceding-case context.

## Interpretation and limits

- `setter-enter from=false to=true` followed by `setter-return confirmed=true` proves the app binding received and stored true in that state storage. It does not alone prove UIKit displayed/retained it or XCTest observed it.
- A subsequent same-token invalidate sequence ending false identifies the local explicit reset; the preceding event identifies its existing route. A true-to-false state-change with no captured reset requires inspection for setter(false), capture completeness and lifecycle.
- A new token at appearance establishes different diagnostic state storage in this instrumented execution. It does not identify which SwiftUI parent caused replacement. A repeated appearance with the same token does not prove there was no transient lifecycle transition.
- No setter marker despite a delivered physical-center touch, with qualified complete surrounding stdout, narrows the boundary to pre-binding event handling. It does not prove which recognizer/control/framework lost the action. Missing/partial stdout cannot support that inference.
- A passing instrumented run qualifies the trace and preserves a control, but does not resolve the original failure. Print overhead, extra read-only onChange modifiers and fixture diagnostic state can perturb timing/SwiftUI identity; this is a diagnostic, not a production correction.
- SwiftUI onChange may coalesce transient writes; immediate setter and invalidation markers are the stronger evidence. Async entry/exit markers report the view boundary; they are not service-level causality or unique request correlation.

The original `control.tap()` and immediate `XCTAssertEqual(..., "1")`, full remaining correction/share/history assertions, all helper bounds and all other test source remain byte-identical after removing the single environment assignment. `git apply --check` passes at the pinned sources. No compilation or native result is claimed. Root should recheck source hashes before installation; do not apply by weakening failed context checks.
