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
unfinished availability at the exact pending-return instant. The new hosted run
below now passes both complete locale suites; it does not establish the original
framework event-delivery cause or guarantee every possible transaction timing.
No provider settings, database migrations, paid products or App Store deployment
were changed.

Hosted validation passed in [run 42544579944](https://github.com/palatis3/room-in-the-cart/actions/runs/42544579944),
at source revisiond1705d920595be12a3eb8c378f50ad04dbf65ccd on
`codex/ci-focus-pending-recovery-20261108` (code change ccdbd768). All seven jobs
passed: Linux preflight, address and thread sanitizers, shared build, both locale
consumers and the final aggregate gate. English and Spanish each passed all 15
original scenarios and exact-configuration/strict result verification. Ask to Buy
passed in 2.707 seconds in English and 6.128 seconds in Spanish, within the
unchanged predicate and execution limits. No retry was dispatched.

The shared build took 306 seconds; English and Spanish jobs took 363 and 438
seconds, respectively (1,107 macOS seconds combined). These job windows include
setup and evidence collection. Native scenario totals were 35.255 and 41.804
seconds; the remainder must not be described as test execution or attributed to
one setup phase without further measurement. This is a passing focused deep run,
not a new full-release duration. The complete integration/release scope remains
open. Terminal inventory, input hashes and all 30 strict result rows are retained
in `hosted-terminal.json` and `hosted-test-excerpts.log` beside this report.
