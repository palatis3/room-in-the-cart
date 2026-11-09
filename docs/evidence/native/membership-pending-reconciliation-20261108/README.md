# Recover an available approval after a pending purchase result

The Spanish hosted StoreKit scenario at50e89363 saw one verified matching current
transaction but no delivery callback or outcome. The update listener remains
necessary, but its observed gap must not strand an approval already available
when purchase returns pending.

MembershipModel now reads unfinished transactions once after that pending result,
using its existing verified callback/durable-service-delivery path. It preserves
the pending purchase report (the snapshot does not identify which request was
approved), rejects other account tokens and discards snapshots after scope stop.
It neither polls nor calls StoreKit sync; it never finishes or unlocks access
without the existing durable service acknowledgement.

Apple documents unfinished as an [on-demand recovery sequence](https://developer.apple.com/documentation/StoreKit/Transaction/unfinished)
and keeps [transaction updates](https://developer.apple.com/documentation/storekit/transaction/updates)
as the live event mechanism. This change complements that listener; it does not
establish what caused the hosted event-delivery gap.

Validation on the owned iPhone17Pro/iOS26.2/23C54 with local Xcode27.1:

- App/core build and Debug bundle checks passed.
- All60 MembershipTests passed native and strict checks, including three new
  regressions for absent updates with failed/durable delivery, wrong accounts,
  and sign-out during the snapshot. Existing model scenarios remain passing.
- The unchanged Spanish Ask to Buy scenario passed native and strict checks with
  the original ten-second predicate and120-second test allowance. The summary
  confirms the exact Spanish app/Mexico offer/USA storefront configuration.
- Both distinct build profiles' products and original results are retained under
  `.build/MembershipPendingReconciliationNov08`; core products were preserved
  before generating the LocalStoreKit plan in the reused build directory.

The initial local launch guard selected the older core xctestrun in the shared
build directory and rejected its missing TestConfigurations before any test
started. Selecting the explicitly named LocalStoreKit plan corrected that
preparation error; no test retry or timeout adjustment occurred.

This proves the recovery behavior in deterministic model cases and one real
local StoreKit execution. The hosted failure's original trace did not measure
unfinished availability at the exact pending-return instant; a complete hosted
repair and full bilingual billing suite remain unproven. A new reviewed source
revision needs hosted validation; do not blindly rerun the old failed revision.
No provider settings, database migrations, paid products or App Store deployment
were changed.
