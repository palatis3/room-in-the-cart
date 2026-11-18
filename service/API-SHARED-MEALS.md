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

The assigned adult shopper can open `GET /v1/households/{householdId}/shops/{shopId}/delivery-evidence`. A closed order keeps its evidence readable. The bootstrap advertises `delivery_evidence` for an assigned shopper with a placed snapshot. The first page includes selectable lines from that snapshot, excluding erased line descriptions. Each line returns its ID and name, with `packs` when the sealed snapshot records a whole-pack count. Each page returns the placed snapshot revision, current shop revision, authority epoch, supply revision, server time, up to 50 delivery sources and an optional UUID cursor. When combining pages, restart the read if the authority epoch or supply revision changes.

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

When the bootstrap advertises `cook_corrections`, the app may attach a versioned `factIndex` to a save whose exact wording matches the reviewed delivery, physical-food or recovered-meal projection. It identifies generated sections by stable keys, UTF-8 byte lengths and unresolved flags within the saved text. An edit or an older save has no index. The free history stores the complete wording in either case.

The shopper can request a comparison by posting `{occurrenceId,copyId,previousCopyId,previousSendId,recipient,destinationConfirmed:true}` to the shop’s `/cook-copies/correction`. A live named adult seat, current shopper, newest copy, source revisions and exact recipient baseline are required. The app verifies current usable-food facts again before showing or sharing changes. The comparison includes changed coverage scope and unresolved requirements. Different languages, an unknown destination or missing reviewed facts use the editable full copy. Share and mark sent remain explicit, separate actions.

Saved instructions and recipient baselines outlive ordinary operation-response expiry. Account erasure removes affected authored or source-dependent instructions and their sends. Erasing the latest send clears its baseline, including when an older send still exists. Recovery from an older backup uses the existing erasure replay.

## Household pantry without a shop

The household endpoints below use the normal live session and enrolled device. An active organizer or an explicitly granted adult receives the `household_pantry` capability. The organizer also receives `household_pantry_grants`. A selected shop has no bearing on these grants. Helper-view and own-requests sessions cannot use these endpoints.

| Method | Path under `/v1/households/{householdId}` | Result |
| --- | --- | --- |
| GET | `/pantry?cursor={lotId}` | A version 1 page with `householdId`, `grantEpoch`, `pantryRevision`, `asOf`, up to 50 `lots`, and `nextCursor`. |
| POST | `/pantry/commands` | A version 1 receipt with `kind`, `householdId`, `operationId`, `lotId`, `grantEpoch`, and committed `pantryRevision`. |
| GET | `/pantry/staples?zone={IANA time zone}` | The current adult’s opt-in, revision, reviewed purchase groups and eligible questions in this household. |
| POST | `/pantry/staples` | Applies a reviewed opt-in, recall, purchase-group edit or answer and returns the current projection. |
| GET | `/pantry/grants` | The organizer’s version 1 `adults` list. Each active non-organizer adult has `memberId`, `label`, `enabled`, and `grantEpoch`. |
| POST | `/pantry/grants` | Send `{v:1, memberId, enabled, expectedGrantEpoch}` and receive the current grants list. |

Each lot includes its physical `observation` (observation ID, confirmation time and quantity), `foodName`, `origin`, `location`, `storedAt`, `useFirstAt`, and `exclusionTags`. A missing or unquantified observation means the physical quantity is unknown. Zero is an explicit count. A placed shop’s separate coverage projection accounts for meal commitments.

The separately authorized household page also includes nullable `purchaseObservation` for delivery lots: the reviewed usable receipt observation ID, confirmation time and original usable quantity. A later cook balance (including zero remaining) does not replace this purchase evidence. Manual lots have no purchase observation. Older servers may omit this additive field; clients must then withhold purchase review rather than infer it from the physical count. The shop-only pantry projection does not include this field.

To add a lot, submit `{v:1, kind:"pantry.addLot", clientKey, replayWindow, grantEpoch, pantryRevision, body}`. The body contains `foodName`, `location` (`pantry`, `fridge` or `freezer`), nullable `storedAt` and `useFirstAt`, `exclusionTags`, `confirmedAt`, and nullable `quantity`. A quantity uses the existing exact rational amount, unit and original literal. The server commits one lot and its initial observation together under the household stock revision. A retry from the same device with the original live grant and replay window returns the original receipt. A changed intent needs a new client key. After a grant changes or a stock review goes stale, read the current page before submitting a new intent.

The placed-shop pantry endpoint retains its pantry/freezer location vocabulary. A shopper with standalone pantry authority can select compatible standalone lots through the existing shop commands. The joint allocator uses those same physical observations for reservations and shortfalls.

### Tonight from shared pantry food

With migration 059, an enrolled adult uses the `household_tonight` capability to open Tonight from Dinners or the household pantry. Clients connected to an earlier server keep their existing pantry and private Tonight routes.

| Action | Service contract |
| --- | --- |
| Browse | `GET /pantry/tonight` reads the household’s reviewed recipes and current stock independently of the selected shop. Reading creates no pickup, reservation or meal. |
| Review a recipe | An organizer calls `POST /pantry/tonight/recipes` with the reviewed recipe, explicit ingredient-to-lot links, grant epoch and a device-bound replay window. An edit uses the recipe ID and revision from the original organizer’s review. After a lost reply, retry the original command. |
| Choose a dinner | The assigned shopper confirms a destination draft shop and sends the existing shopper command envelope with kind `meal.chooseTonight`. Its body binds the recipe ID and revision, review token, pantry grant epoch, day and occurrence ID. A stale review requires a fresh read. A successful exact retry confirms the same occurrence. |

Quantities reflect the food still available after existing commitments. The response distinguishes confirmed coverage, a known missing amount and an unresolved amount. An incomplete checkout estimate stays visible when the available evidence cannot establish a price. Household preference details retain their separate read permission.

## Reviewed household meal preferences

Migration 052 stores one revisioned household profile. An enrolled organizer opens Household Settings to edit it and separately choose which active adult members can read it. The service checks household membership, the current device and the preference grant on each request. A pantry or shop-planning grant conveys no permission to read the profile. Private iPhone preferences have their own storage and revision.

- `GET /v1/households/:household/meal-preferences` returns `v:1`, household ID, grant epoch, revision, settings and `canWrite`. An erased profile retains its new revision and returns null settings. The selected shop has no bearing on this household read.
- `POST /v1/households/:household/meal-preferences` requires an organizer, a live device-bound replay window, a fresh client key, the reviewed grant epoch, exact expected revision and new settings or null. A repeated original command can confirm its accepted revision. A newer write requires another review.
- `GET` and `POST` to `meal-preferences/grants` manage read access for active non-organizer adults. A change sends the member ID, enabled state and expected grant epoch. Revoking access takes effect on the next request.
- A historical note may supply one explicitly chosen rule through optional `sourceDecision`. It binds the shop, decision ID, version, field and exact new term. The organizer must also be the currently assigned shopper with a current paid seat. Removing either source author's data removes dependent rules and leaves unrelated rules in place.
- A shared idea shows eligible, blocked, unresolved and soft categories for the meal being reviewed. An approval binds the current preference revision. A new occurrence based on that approval rechecks it. A changed ingredient in an existing occurrence requires a current revision and any necessary reviewed ingredient, appliance or brand evidence. Previous receipts and exact derived undo retain their historical evidence.

The optional cooking-time limit contains `maximumMinutes` and `strict`. It compares the same recipe’s reviewed total elapsed preparation or lead time. Missing time remains unknown. The page advertises `supportsTimeLimit`. An organizer who reviews the limit sends `timeLimitReviewed:true`, which permits an explicit removal. Earlier clients preserve a limit when saving their known fields.

### Personal staple reminders in a household

The write envelope includes `v: 1`, `zone`, `grantEpoch`, `pantryRevision`, `expectedRevision` (null on first use), `clientKey`, `replayWindow` and a discriminated `action`. The service locks the household and checks the current membership, pantry grant, enrolled device and replay window. Replaying an accepted command returns the current projection. Turning reminders off forgets that adult’s groups and answers.

An adult can `remember` a name for manual recall. The `purchase` action records the receipt day and the exact usable observation of a stored, confirmed delivery lot. It takes an existing `groupId` or a new `name`, with the other field set to null. One physical lot contributes once per adult. `removePurchase` unlinks a reviewed purchase, and `forget` removes the group.

Three comparable purchase days establish an interval. Split lots on one day count together, and a change in usable amount starts a new series. Unresolved source corrections and equivalent or unclassified open demand withhold the question. The pantry projection omits other shoppers’ request details. The `answer` action binds Still have it, Dismiss or a seven-day Snooze to the current question’s basis. Each adult’s enrolled devices read the same answer.
