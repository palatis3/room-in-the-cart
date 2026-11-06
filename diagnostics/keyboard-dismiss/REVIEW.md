# Independent review — keyboard dismissal diagnostic preparation

**Approve this bounded preparation patch; no blocking source issue found.** Approval concerns reviewable instrumentation, not a production repair, execution authorization, runtime causality or release acceptance.

Reviewed `instrumentation.patch` SHA-256 `8aa530381307cb9ac5903663095a1920a5945b1c4210afc9cddfcbf7222b7a05`, its saved original/modified source, REVIEW, validation, manifest, provenance, selectors and the original tracked UI07 failure review. Base is recorded as `804030e68473d022e72b464940061c01c611a0bd`; no Git operation was used to independently re-resolve that commit.

## Independent checks

- All 29 files named by the supplied manifest exist and match their SHA-256 values.
- Reconstructing a unified diff from the saved before/after files exactly reproduces the patch. Its only source path is `ios/Features/Pickup/PickupRepairView.swift`.
- Removing the seven `DEBUG && KEYBOARD_DISMISS_DIAGNOSTIC` blocks leaves original code identical ignoring whitespace. Manual inspection confirms the only remaining difference is multiline formatting of the original `field = nil` closure. Normal-build semantics are preserved at source level; this is not a binary-equivalence claim.
- Six selectors are byte-identical to the retained original UI07 plan. Copied UI07 review is byte-identical to `docs/evidence/native/ui07-keyboard-idle-20261106/REVIEW.md`.
- Validation correctly distinguishes enabled-file parsing and isolated macOS logger typechecking from unperformed full iOS integration typing/build/runtime work. The reported 57 mocked reference tests concern the older collector, not a completed new runner. I did not repeat compiler or test commands.

## Payload privacy and behavior

Every interpolated payload is a fixed event enum, fixed focus/scene enum, UInt64 counter or system uptime. Field text, quantities, labels, household IDs, UUIDs, model data and notification object/userInfo do not reach the logger. Public privacy annotations therefore expose structural diagnostic data only. Process/thread metadata in OSLog's envelope must still be handled as diagnostic provenance. Runtime logging additionally requires the already existing `--ui-testing` argument.

Done entry and exit surround the original synchronous focus assignment without extra tasks, focus writes, responder actions, gestures, animation changes or model operations. Focus and scene observers read values and record them. Keyboard subscriptions discard notifications immediately and follow SwiftUI subscription lifetime; they are not separately installed global observers needing manual removal. No timer, periodic heartbeat, polling or app-file writer is introduced. Only the logger's own main-actor counter mutates.

The diagnostic build does add scene dependency tracking, view modifiers, subscriptions and synchronous logging. These can affect view evaluation and timing, including the phenomenon under investigation. Even with runtime logging disabled, those modifiers still exist in the diagnostic-flag build. Ordinary builds without the compile flag exclude them entirely. The original Theme Done geometry and other views are untouched.

`MainActor.assumeIsolated` is a runtime precondition, not a dispatch or a guarantee supplied by the type system. The patch relies on UIKit keyboard notification delivery on the main actor/thread; the preparation explicitly acknowledges that runtime callback isolation remains unverified. No speculative queue hop is needed for preparing this patch, but a future isolation failure must be retained as diagnostic interference, not interpreted as the original UI07 stall.

## Ordering, lifecycle and bounds

The main-actor record function has no suspension point: its sequence increment, uptime capture and log call occur synchronously. Sequence distinguishes equal uptime values; logging delivery order need not equal call order. Interpret sequence within a process incarnation and retain log-envelope identity, because it resets on process restart. The wrapping increment has a theoretical UInt64 rollover; it is not a realistic concern in the finite six-case diagnostic. Uptime is not a UTC timestamp or process identity.

`done.exit` means the focus write returned, not that SwiftUI rendered or the keyboard finished dismissing. Focus observation can coalesce changes. Initial scene observation can have equal old/new values and may recur after view installation. Keyboard notifications are process-wide while subscriptions exist; they do not identify the originating field, scene or a particular Done tap. Multiple live subscribed instances could observe one notification more than once. Sequence alone cannot remove that ambiguity.

The instrumentation has no event-count cap or delivery guarantee; events are driven by interactions/framework callbacks and the planned finite execution/capture windows. The preparation preserves the existing 720/900-second test bounds, 40-minute test step, 55-minute job and finite capture/export/shutdown limits. Those are proposed execution safeguards, not implemented-and-verified properties of a new runner. A future package still needs the stated collector adaptation, schema validation and reconciliation; the copied reference runner must not be run unchanged. Missing prefixes, gaps, suffixes or entire processes remain capture limitations rather than proof of absent app events.

## Adequacy for the causal question

Original UI07 first stalls in XCTest's post-event idle wait after the second Done, before Next shop is reached. The late app run-loop wait and missing usable visual attachment cannot establish whether that earlier handler ran. This patch directly observes the missing handler/focus/keyboard boundaries without rewriting that interaction or weakening idle/assertion gates. Positive entry/exit and focus/hide observations can narrow the investigation; missing observations alone cannot identify an app or XCTest defect.

Omitting a heartbeat is a reasonable way to avoid periodic interference, and the review correctly relinquishes any main-thread-liveness claim. The patch does not measure render completion, count animations, sample stacks or repair the original missing recording. Correlation with the original activity sequence and independently bounded capture would be needed later. A passing instrumented run could be timing-sensitive and does not close the original failure. UI06 and other Done controls are outside this UrgentRepair-only scope.

No tracked edit, Git operation, native command, network request, dispatch, retry or subagent was used for this review. Only this scratch review was written; verification used read-only Python hashing/text comparisons.
