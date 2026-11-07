# Reviewed shared meal changes (S17/S25)

These local APIs extend the existing named meal-planner grant. The authenticated adult planner needs an active named paid seat; the current assigned shopper can review and apply with Free. A selected helper view or child never gains meal or basket authority. The planner response contains meal facts and proposals, not the shopper's basket, quote, caps, or stock.

- `GET /v1/households/:household/shops/:shop/meal-plan/changes`: current authorized meal facts, source revision/authority/grant, phase, and bounded proposal status.
- `POST .../meal-plan/changes`: immutable `SharedMealChangeRequest`. Existing-occurrence proposals bind proposal UUID, occurrence UUID, exact occurrence revision, shop revision, authority epoch and grant revision. Calendar day stays unchanged. Exact retries retain the original identity/payload; changed content under the same ID returns `key_reused`. A stale new submission is refused, never silently rebased.
- `POST .../meal-plan/changes/dismissals`: shopper-only explicit dismissal bound to current shop revision/epoch/grant.
- Existing `shop.patch` adds `mealEdit.changeProposalId`. The server checks exact proposed meal, active author/current planner grant, occurrence revision, shop revision/authority and pending status within the existing household-serialized transaction. The command changes meal revision, explicitly reviewed packs and whole-checkout quote atomically. Existing command receipts make concurrent exact retries apply once. Planner proposals alone never mutate basket lines.

Migration 016 stores proposals with tenant RLS and privacy cleanup. Migration 017's separately owned idea flow allows explicit approved-idea creation (`baseMealRevision:null`, `original:null`) with approved idea ID/revision; this never turns a missing existing occurrence into implicit creation.

## Exact planning facts

Optional `SharedMeal.planning` is backward compatible. It records stable group and ingredient UUIDs, exact positive rational amounts, original quantity literals, units, exclusions, and optional explicit per-group ingredient bindings. Unknown ingredient quantities are explicit null. Typed UUIDs normalize to lowercase before comparison; user-entered labels retain their text semantics. Binding references must exist and be unique; complete bindings must sum exactly to the entered ingredient quantity in the same unit. All arithmetic uses integers/BigInt, never floating-point quantity comparison.

Existing protected meal portions, group identities/servings, protected ingredient allocations and exclusions cannot be silently removed, reassigned or reduced by proposals or direct edits. Exact protected bindings stay reserved while guest allocations elsewhere can decrease. Protecting the entire meal extends these checks to every named group and its allocations. If any protected group has no exact binding for an ingredient, the server conservatively preserves the entered ingredient total.

## Native routes and review

The shared Dinners home opens shared changes. A local preview may explicitly seed one shared proposal using `SharedMealChangeSeed(preview:occurrenceID:state:)`; the adult must choose the exact existing shared occurrence. No name match is inferred. Device-private prices, stock, ledger and checkout caps are not uploaded. `DinnerPreview.reviewedPortionBindings(from:)` derives resulting bindings from a copy of the exact reviewed planning state; no local mutation or receipt is committed.

A named planner reviews original/proposed facts and submits a proposal. The current shopper reviews it with the actual shared packs and checkout quote, then explicitly applies. The shopper's own local seed takes the direct reviewed shared-draft route instead of impersonating a planner. Cancel leaves both meal and basket unchanged. No automatic pack recalculation, retailer acceptance, or post-placement fee is claimed.

Frozen or placed shops can retain amendment proposals. They cannot apply an ordinary `shop.patch`; retailer/order reconciliation remains separate. Changed sources are visibly stale, not automatically updated.

Native pending bytes use the existing protected, backup-excluded HistoryPendingStore actor with dedicated optional `sharedMealChanges` namespace. Exact retries survive restart. Deletion/signout/scoped household exit purge the namespace and rotate the store epoch; native account/enrollment/role/shop generations prevent late async work from restoring or displaying erased data. Restoring pending content requires fresh authorized access. Paid lapse hides private content while retaining unsent retry bytes until valid access or explicit cleanup. Clearing local retry after fresh status review does not withdraw or undo a shared proposal.

## Explicit limits and evidence

The pre-existing shared meal `portions` field is an integer. Local seeds with fractional *total* servings are refused rather than rounded; fractional group quantities and ingredient amounts are preserved exactly when the total portions are integral. Protected local groups require complete reviewed quantity bindings. Unsupported/incomplete seed evidence produces a review error; it is never guessed.

Focused evidence lives in `/tmp/ritc-shared-meal`: host model/store tests, isolated real PostgreSQL HTTP tests, and actual Swift planner/shopper round trips over pinned loopback HTTPS. Guarded native UI fixture: `S17SharedMealFixtureRoot`, `--ui-testing --shared-meal-fixture`; add `--shopper-meal-seed` for the direct shopper seed path. `SharedMealChangeUITests` is compiled only with `DEBUG && CONTRIBUTOR_CAPTURE_UI_FIXTURE`. Simulator execution is reserved to the lead; staged UI tests are not themselves a passing UI claim.

## Physical delivery evidence for a placed shared order

The assigned adult shopper can open `GET /v1/households/{householdId}/shops/{shopId}/delivery-evidence`. A closed order keeps its evidence readable. The bootstrap advertises `delivery_evidence` for an assigned shopper with a placed snapshot. The first page includes selectable lines from that snapshot, excluding erased line descriptions. Each page returns the placed snapshot revision, current shop revision, authority epoch, supply revision, server time, up to 50 delivery sources and an optional UUID cursor. When combining pages, restart the read if the authority epoch or supply revision changes.

Use the regular household command endpoint, device-bound replay window, client key and shop base for delivery actions. Save the exact original command for a retry. Each successful action increments the supply revision by one. The shop revision and sealed order stay intact.

| Command | Reviewed body fields |
| --- | --- |
| `delivery.register` | Supply revision, placed revision, sealed line ID, stable segment key, actual food name and exclusion tags. The receipt returns the server-assigned source ID. A separately confirmed delivery of the same line has its own segment key. |
| `delivery.reserve` | Supply revision, source ID, sealed occurrence ID, meal revision, ingredient ID, named group ID, predecessor ID and quantity. A positive quantity sets or updates the promise. JSON null releases it. |
| `delivery.match` | Source ID, supply revision, sealed occurrence ID and meal revision, ingredient ID and the explicit matched/removed decision. A fresh command must change the existing match. |
| `delivery.arrival` | Supply revision, source ID, new observation ID, previous arrival ID (null for first), arrival time and received quantity. Time and quantity can each be unknown. |
| `delivery.usable` | Supply revision, source ID, new observation ID, previous usable ID (null for first), current arrival observation ID, confirmation time and usable quantity. Null records unknown. Zero records a confirmed zero. |

Quantities use the shared meal amount, unit and original literal. A positive or zero usable observation requires a known physical arrival and a compatible received quantity. The server rejects confirmation before arrival, future confirmation, excess quantity, concurrent stale edits and a receipt from a previous shopper authority epoch. Every source read includes the latest arrival and usable review. Use the `confirmed` field for available food. A corrected arrival needs a fresh usable review. Registration and correction do not allocate portions to a dinner or lunch.


The first delivery page includes the meal revisions referenced by the placed snapshot. Each source lists its current reviewed ingredient matches. A physical segment may match ingredients in multiple meals and an ingredient may have multiple sources. Each review binds one pair. The stored decision identifies food only. Quantity coverage requires a separate allocation that accounts for every protected portion and uses each physical quantity only once. Matching and removing a match leave quantities and prices intact. Erasing a source or a meal revision also removes its matches and prevents replay of its old match receipts.

## Delivered food by meal

The assigned shopper may read `GET /v1/households/{householdId}/shops/{shopId}/delivery-evidence/coverage` for a placed or closed order. The delivery page advertises `coverageAvailable`. Read the projection against the same shop, placed snapshot, authority and supply revisions. Refresh the delivery page if any revision changes. This read computes a projection from the sealed meal references, current reviewed ingredient matches and current confirmed usable quantities. It records no reservation or change to checkout.

For each ingredient the result shows the required, covered and missing quantities and how much each physical source supplied, in the ingredient's unit. Computed rational numerators and denominators are decimal strings. Named groups with exact bindings are separate rows. An incomplete split keeps the original total together and reports the unresolved group split. A protected group with an unknown quantity holds its matched food until the shopper can resolve the amount. Meals without recorded ingredients are returned in `unplannedOccurrenceIds`.

Coverage assigns protected needs first, then follows saved meal dates. It can move an earlier group's coverage between its approved sources to fill a later need while preserving the earlier total. A correction to received or usable food, or the removal of an ingredient match, takes effect on the next read. This calculation covers recorded delivery requirements for this order. Private pantry stock, preparation deadlines, replacement decisions and cook instructions require their own reviewed facts.


## Named delivery reservations

The delivery evidence page advertises `reservationsAvailable`. Each source includes its latest reservation for each sealed occurrence, ingredient and group, including release records. A head contains `occurrenceId`, `mealRevision`, `ingredientId`, `groupId`, `reservationId` and the original `quantity` or null. Pass null as `predecessorId` for the first decision on this tuple. For subsequent decisions, pass the latest head ID even after release. The command receipt's `operationId` identifies the new head.

Creating or increasing a reservation requires a current ingredient match, a known requirement for the named group, compatible units, permitted food and enough confirmed usable stock. A single named group can use the ingredient's whole reviewed quantity. Multiple groups require a complete reviewed split. A write cannot reduce another promise's backing or a protected group's current coverage. Release active reservations before removing the ingredient match. When usable stock falls or becomes unknown, the assigned shopper can still reduce a promise in the same physical dimension or release it. Stale predecessors and supply revisions return `stale_supply`. An ineligible reservation or blocked unmatch returns `reservation_review_required`.

Each coverage row includes active `reservations` with `sourceId`, `reservationId`, `requested` and `backed`. The two fractions use the requirement's unit. An allocation includes the backed reservation plus any other coverage from the same source. The calculation honors protected needs first. Within each priority it honors source-specific promises before distributing remaining food. Where corrected stock cannot back all promises, the row includes `reservationShortfall` and still shows each request, including zero backing. Another confirmed source may cover the meal while the original set-aside remains short.

## Dated cook copies and recipient history

The assigned adult shopper can save a reviewed cook instruction for a meal sealed in a placed or closed shared order. The bootstrap advertises `cook_copies`. Saving, reading, manually correcting and marking a version sent are available on the free plan. Each immutable copy keeps its occurrence and meal revision, checkout and supply revisions, authority epoch, recipient language, exact text, version number and service creation time.

Use the household command envelope for `cookCopy.save`. The body carries `placedRevision`, `supplyRevision`, `occurrenceId`, `mealRevision`, `language` (`en` or `es`) and `text` (nonblank, up to 16,000 UTF-16 code units). The service checks the reviewed revisions and sealed meal and returns a shopper receipt with `disposition: "recorded"` and `copyId` equal to the save operation ID. The shop, supply and recipient baseline retain their current revisions.

Read up to 20 saved versions, newest first, through `GET /v1/households/{householdId}/shops/{shopId}/cook-copies?occurrenceId={id}`. Use `nextCursor` as the next request's `cursor`. Versions span both languages for one sealed occurrence. To look up the last explicit send, post `{occurrenceId,recipient}` to the same shop's `/cook-copies/baseline` route. The response contains `baseline: null` or the exact saved `copy` plus `send` with `sendId`, `copyId`, `recipient` and `sentAt`. The recipient is a case-sensitive, trimmed label of up to 80 UTF-16 code units. Names travel in request bodies.

Opening a preview, copying text, and completing or cancelling a system share leave the baseline untouched. After the shopper explicitly confirms the recipient and saved version, `cookCopy.markSent` records `{copyId,recipient,previousSendId}`. Supply corrections preserve prior versions. The shopper may deliberately mark an older saved version. A changed recipient baseline requires another review. An exact replay yields the original receipt under the original authority while retained. A send records only the shopper's report. A cook's receipt and acknowledgment remain unknown.

Saved instructions and recipient baselines outlive ordinary operation-response expiry. Account erasure removes affected authored or source-dependent instructions and their sends. Erasing the latest send clears its baseline, including when an older send still exists. Recovery from an older backup uses the existing erasure replay.
