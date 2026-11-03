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
