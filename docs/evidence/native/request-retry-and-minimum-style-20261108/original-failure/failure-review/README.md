# Minimum-iOS carry replay failure: bounded review

Exact case: HouseholdRequestPackUITests/testShopperCarriesEarlierRequestOnceAndReviewsCurrentPackPrice(); failed at line50 after31.898s. Original native65/strict1 preserved. Only the three named attachments were exported from the already inspected COPY; no inspector rerun, native action or source edit. Original hashes match the existing wrapped manifest before/after; all four relevant current source files match the run pins. Initial flat-manifest assumption stopped before any export and is recorded in setup-note.txt.

## Observed

The PNG shows the root “S24 request decision” inbox, not the deferred destination or a decision sheet. It displays “Decision confirmed by the household” and “Ready for review in this pickup”; counters are2 attempted commands and0 saved lines. AX window375×667, navigation bar y106..202, list extends to667. “Requests for this shop” occupies y640..679, below which no successor row is materialized in this snapshot; scrollbar says2pages,0%. These establish successful navigation back and confirmed carry; they strongly support a viewport/lazy-row assumption in the test. They do not directly measure the offscreen row or prove its in-memory contents.

Raw log: Retry tap21.15s; line50 begins8s wait21.93s without any scroll; failure30.12s. The larger26.2 qualification/fixture-light-run log passes the same query at23.04s and the whole case109.684s. This is contextual engine/device evidence, not a controlled geometry-only experiment.

Fixture source97–99 returns the carried request once carryKey exists. Lines127–148 bind replay to exact original key/bytes, return the stored receipt, and create no additional line. Model marks confirmed then refreshes; DeferredRequestsView138–139 dismisses on confirmed carry. Screenshot is consistent with that flow, not a stale sheet or failed replay.

## Narrow proposal

In this carry test only, require return to the root navigation state, use its existing bounded reveal(successor), then retain the exact successor identity/status, one-row,2attempt/0line and later current-price assertions. Do not increase the8s wait, retry the command again, or change product scrolling solely to satisfy this assertion. Offscreen existence alone is not a portable List assertion. This proposal needs qualification; no patch or execution was performed.

## Separate concrete stale-notice issue

The diagnostics attachment still reports “The service could not confirm this decision. Retry the pending decision to avoid a duplicate.” despite the confirmed carry. Model.retry() does not clear notice; deliver() replaces delivery on accepted receipt but does not clear the earlier503 notice. This is a stale error, not proof the second POST failed. If addressed separately, clear that prior transport notice only when accepting the valid confirmed receipt, before outbox-cleanup/refresh can supply any new warning. Preserve those new failures. The note is not the cause of line50.

No audit finding disposition changed. Receipt records exact commands, timings, attachment hashes and original preservation. No full attachment export or videos.
