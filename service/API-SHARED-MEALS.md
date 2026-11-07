# Reviewed shared meal changes (S17/S25)

These local APIs extend the existing named meal-planner grant. The authenticated adult planner needs an active named paid seat; the current assigned shopper can review and apply with Free. A selected helper view or child never gains meal or basket authority. The planner response contains meal facts and proposals, not the shopper's basket, quote, caps, or stock.

- `GET /v1/households/:household/shops/:shop/meal-plan/changes`: current authorized meal facts, source revision/authority/grant, phase, and bounded proposal status.
- `POST .../meal-plan/changes`: immutable `SharedMealChangeRequest`. Existing-occurrence proposals bind proposal UUID, occurrence UUID, exact occurrence revision, shop revision, authority epoch and grant revision. Calendar day stays unchanged. Exact retries retain the original identity/payload; changed content under the same ID returns `key_reused`. A stale new submission is refused, never silently rebased.
- `POST .../meal-plan/changes/dismissals`: shopper-only explicit dismissal bound to current shop revision/epoch/grant.
- Existing `shop.patch` adds `mealEdit.changeProposalId`. The server checks exact proposed meal, active author/current planner grant, occurrence revision, shop revision/authority and pending status within the existing household-serialized transaction. The command changes meal revision, explicitly reviewed packs and whole-checkout quote atomically. Existing command receipts make concurrent exact retries apply once. Planner proposals alone never mutate basket lines.

Migration 016 stores proposals with tenant RLS and privacy cleanup. Migration 017's separately owned idea flow allows explicit approved-idea creation (`baseMealRevision:null`, `original:null`) with approved idea ID/revision; this never turns a missing existing occurrence into implicit creation.

## Exact planning facts

Optional `SharedMeal.planning` is backward compatible. It records stable group and ingredient UUIDs, exact positive rational amounts, original quantity literals, units, exclusions, and optional explicit per-group ingredient bindings. Unknown ingredient quantities are explicit null. Typed UUIDs normalize to lowercase before comparison; user-entered labels retain their text semantics. Binding references must exist and be unique; complete bindings must sum exactly to the entered ingredient quantity in the same unit. All arithmetic uses integers/BigInt, never floating-point quantity comparison.

Existing protected meal portions, group identities/servings, protected ingredient allocations and exclusions cannot be silently removed, reassigned or reduced by proposals or direct edits. Exact protected bindings stay reserved while guest allocations elsewhere can decrease. Without exact bindings, the server conservatively protects the entered ingredient quantity instead of guessing a protected share.

## Native routes and review

The shared Dinners home opens shared changes. A local preview may explicitly seed one shared proposal using `SharedMealChangeSeed(preview:occurrenceID:state:)`; the adult must choose the exact existing shared occurrence. No name match is inferred. Device-private prices, stock, ledger and checkout caps are not uploaded. `DinnerPreview.reviewedPortionBindings(from:)` derives resulting bindings from a copy of the exact reviewed planning state; no local mutation or receipt is committed.

A named planner reviews original/proposed facts and submits a proposal. The current shopper reviews it with the actual shared packs and checkout quote, then explicitly applies. The shopper's own local seed takes the direct reviewed shared-draft route instead of impersonating a planner. Cancel leaves both meal and basket unchanged. No automatic pack recalculation, retailer acceptance, or post-placement fee is claimed.

Frozen or placed shops can retain amendment proposals. They cannot apply an ordinary `shop.patch`; retailer/order reconciliation remains separate. Changed sources are visibly stale, not automatically updated.

Native pending bytes use the existing protected, backup-excluded HistoryPendingStore actor with dedicated optional `sharedMealChanges` namespace. Exact retries survive restart. Deletion/signout/scoped household exit purge the namespace and rotate the store epoch; native account/enrollment/role/shop generations prevent late async work from restoring or displaying erased data. Restoring pending content requires fresh authorized access. Paid lapse hides private content while retaining unsent retry bytes until valid access or explicit cleanup. Clearing local retry after fresh status review does not withdraw or undo a shared proposal.

## Explicit limits and evidence

The pre-existing shared meal `portions` field is an integer. Local seeds with fractional *total* servings are refused rather than rounded; fractional group quantities and ingredient amounts are preserved exactly when the total portions are integral. Protected local groups require complete reviewed quantity bindings. Unsupported/incomplete seed evidence produces a review error; it is never guessed.

Focused evidence lives in `/tmp/ritc-shared-meal`: host model/store tests, isolated real PostgreSQL HTTP tests, and actual Swift planner/shopper round trips over pinned loopback HTTPS. Guarded native UI fixture: `S17SharedMealFixtureRoot`, `--ui-testing --shared-meal-fixture`; add `--shopper-meal-seed` for the direct shopper seed path. `SharedMealChangeUITests` is compiled only with `DEBUG && CONTRIBUTOR_CAPTURE_UI_FIXTURE`. Simulator execution is reserved to the lead; staged UI tests are not themselves a passing UI claim.

## Physical delivery evidence for a placed shared order

The assigned adult shopper can open `GET /v1/households/{householdId}/shops/{shopId}/delivery-evidence`. A closed order keeps its evidence readable. Each page returns the placed snapshot revision, current shop revision, authority epoch, supply revision, server time, up to 50 delivery sources and an optional UUID cursor. When combining pages, restart the read if the authority epoch or supply revision changes.

Use the regular household command endpoint, device-bound replay window, client key and shop base for these three actions. Save the exact original command for a retry. Each successful action increments the supply revision by one. The shop revision and sealed order stay intact.

| Command | Reviewed body fields |
| --- | --- |
| `delivery.register` | Supply revision, placed revision, sealed line ID, stable segment key, actual food name and exclusion tags. The receipt returns the server-assigned source ID. A separately confirmed delivery of the same line has its own segment key. |
| `delivery.arrival` | Supply revision, source ID, new observation ID, previous arrival ID (null for first), arrival time and received quantity. Time and quantity can each be unknown. |
| `delivery.usable` | Supply revision, source ID, new observation ID, previous usable ID (null for first), current arrival observation ID, confirmation time and usable quantity. Null records unknown. Zero records a confirmed zero. |

Quantities use the shared meal amount, unit and original literal. A positive or zero usable observation requires a known physical arrival and a compatible received quantity. The server rejects confirmation before arrival, future confirmation, excess quantity, concurrent stale edits and a receipt from a previous shopper authority epoch. Every source read includes the latest arrival and usable review. Use the `confirmed` field for available food. A corrected arrival needs a fresh usable review. Registration and correction do not allocate portions to a dinner or lunch.
