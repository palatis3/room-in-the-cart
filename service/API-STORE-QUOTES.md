# Private entered store quotes (S27 / A03)

Manual two-store comparison is Free. The current assigned adult shopper has implicit access. Another active adult needs an explicit budget grant for this shop and shopper authority epoch. A paid seat, meal-planner assignment, household administration, contributor permission, or cook link supplies no budget permission. The budget grant may belong to an adult with contribution disabled. An explicitly selected cook-link context remains restricted even if that adult separately holds a budget grant.

All routes use the ordinary verified live identity, enrolled device, household transaction, and optional `X-Shop-ID` boundary. `store_quotes` in bootstrap and the shop selector advertise only the separately permitted scope. A grant never permits the shopper's generic shop, inbox, preview, command, or meal-planning routes. History access is governed separately in `API-HISTORY.md`.

## Read

`GET /v1/households/:household/shops/:shop/store-quotes?cursor=:pairUUID`

The response contains:

- `shopId`, `shopRevision`, `authorityEpoch`, `grantRevision` (zero for the assigned shopper), `shopper`, and `phase`.
- `commitments`: the current server-snapshotted basket line identities, original labels, and whole-pack counts, as `{id,label,packs}`. Each saved pair preserves its own exact commitment snapshot and shop revision. No device-private meal, stock, or local ledger is inferred or uploaded.
- `adults`: only for the assigned shopper, eligible other adults with `{id,label,revision,enabled}`. Other readers receive an empty array.
- `currentBasis`: the last adopted `{store,branch,mode,slot,revision}`, or null when none exists or its personal proof was erased. This is a reviewed choice of store, not a price or order.
- `pairs`: at most 30 dated immutable pairs, with `pairId`, `baseRevision`, `authorityEpoch`, `grantRevision`, `stale`, `savedAt`, `own`, `commitments`, `options`, `comparison`, and `proposals:[{proposalId,choice}]`. `nextCursor` identifies the last returned pair when more exist. Cursors are scoped to the same authorized shop and visible pair set.

An adult sees their own saved proof while currently authorized, including older read-only proof marked stale. The shopper sees another adult's pair only after that adult explicitly proposes it, and only while its original grant and authority epoch remain active. One budget reader never receives another reader's private pair. A revoked grant blocks reads and successful write retries. A new grant revision does not make an old proposal eligible again. Frozen, placed, and closed shops remain readable within current permission; ordinary new pair/proposal/adoption writes are draft-only.

## Exact write envelope

`POST .../store-quotes/pairs`, `/proposals`, `/adoptions`, or `/grants` takes the common fields:

```json
{"operationId":"uuid","shopRevision":1,"authorityEpoch":1,"grantRevision":0}
```

Add only the fields for that action:

| Action | Additional fields | Authority and effect |
| --- | --- | --- |
| `pairs` | `options:{first,second}` | Save an immutable private comparison. Pair ID equals operation ID. No shared basket change. |
| `proposals` | `pairId`, `choice:"first"\|"second"` | A non-shopper explicitly shares their own current pair and selected option with the shopper. One proposal per pair. No shared basket change. |
| `adoptions` | `pairId`, `choice`, `proposalId` (explicit null for a shopper's own private pair) | Assigned shopper only. Another adult's pair requires its exact submitted proposal and choice. Rechecks permission, quantities, availability, eligibility, shop revision, and draft phase. |
| `grants` | `adultId`, `enabled`, `targetRevision` (zero if absent) | Assigned shopper only. Changes only this adult's budget grant and increments its revision. Available on frozen/placed shops so permission can still be revoked. |

The response is `{operationId,shopRevision}`. Save/proposal/grant leaves the shared shop revision unchanged; adoption increments it once. Use a fresh operation ID for a changed intent. Keep the original validated body, ID, household, shop, grant revision and epoch for an exact retry. Inputs normalize UUID case and trim entered labels before fingerprinting. An ID reused for another validated action returns `operation_conflict`. Reauthorization happens before receipt lookup; a still-authorized exact retry returns its original receipt even if the draft has advanced or become frozen. No stale action is automatically rebased.

The household lock serializes concurrent saves, grant changes, proposals, adoptions, and ordinary shop commands. Adoption and its durable receipt either commit together or roll back. Content-free S27 receipts retain IDs, revision, and fingerprint for the lifetime of that actor's shop data, rather than expiring and allowing a delayed action to apply twice. Account erasure removes that actor's receipts.

## Entered option and comparison

Each of exactly two options records:

```json
{
  "label":"Second store","store":"Store B","branch":"West branch","mode":"pickup",
  "slot":"2026-11-04T17:00:00-05:00","observedAt":"2026-11-03T12:00:00-05:00",
  "source":"Manually reviewed basket","currency":"USD",
  "terms":"Equivalent whole packs; no membership required; fees, taxes and discounts included",
  "itemsMinor":3200,"checkoutMinor":3500,"allChargesIncluded":true,
  "available":true,"quantitiesMatched":true,"singleStore":true,"eligibilityConfirmed":true,
  "tripAlreadyPlanned":false,"tripMinor":400,"extraMinutes":18,
  "capMinor":3800,"capScope":"wholeCheckout"
}
```

`mode` is `pickup`, `delivery`, or `inStore`. Time values are ISO instants with offsets. `terms` preserves the entered package, fee, discount and eligibility explanation. `quantitiesMatched` explicitly confirms that the option covers the same complete server-snapshotted commitments; it never infers equivalence from equal spend. `singleStore` excludes incomplete split-store alternatives. Availability is true, false, or null. Missing eligibility defaults to unconfirmed. `itemsMinor`, `checkoutMinor`, `tripMinor`, `extraMinutes`, and `capMinor` preserve unknown as null, independently from zero. Monetary inputs are nonnegative integer USD cents, at most 1,000,000,000; optional time is an integer number of minutes up to 525,600. Future quote evidence beyond five minutes is refused. Source and observation time remain attached to dated proof; there is no fetched stock or freshness promise.

`comparison` separates `itemDelta`, `checkoutDelta`, `cashDelta`, and `minutesDelta`; every delta is second minus first. `firstCheckout`/`secondCheckout` are known only after included charges are confirmed. `firstTrip`/`secondTrip` add incremental trip cash once. Travel time remains its own unit and is never monetized. Missing charges propagate to checkout and trip totals. Conditional arithmetic may remain visible when availability or eligibility is unresolved, but `preferred` stays null. Unmatched quantities or split-store alternatives suppress comparison deltas. Ties have no preferred option.

For $38 versus $35 checkout with $0 versus $4 incremental trips and +18 minutes, the second checkout is $3 cheaper, total cash is $1 higher, and the first option is preferred. If the second trip cost is unknown while all other comparison/coverage facts are confirmed, `secondBreakEven:300` describes the maximum second-trip cash that would tie the first total; it does not claim a saving.

`firstCap` and `secondCap` contain `{amountMinor,scope,status,overMinor,headroomMinor}`. Each cap has its own `wholeCheckout` or `itemsOnly` scope and uses checkout or merchandise respectively, excluding travel cash. A known item subtotal fitting an item cap never establishes that the whole checkout fits. Missing amount/total leaves cap status unresolved. The client retains the scope beside the result.

## Adoption, stale offers and deletion

Choosing an option deliberately starts a price review on the current shared draft. The selected option must have confirmed coverage and eligibility, and both alternatives must describe comparable complete single-store commitments. A price can remain unknown; it is never installed as a verified line price. Adoption invokes the existing authenticated shopper patch transaction to preserve line/meal identities and quantities, clear every line price and all fee/tax/deposit/discount components, mark remaining-original-item coverage incomplete, and expire the previous checkout quote. It then records the chosen store basis and `storeReviewRequired:true`. Original entered proof remains unchanged.

Old request previews fail their revision/fingerprint check. Fresh purchase previews fail `stale_quote` until fresh prices are recorded. `shop.freeze` fails `store_review_required` until a shopper explicitly sends `shop.patch.body.reviewedStoreBasisRevision` matching `adultShop.storeBasisRevision`, with complete known prices/charges and an unexpired quote. A matching basis token with missing prices or an expired quote saves useful draft work while keeping the freeze guard; a wrong basis token still fails without saving. An ordinary patch without that explicit basis review does not clear the guard. Frozen/placed orders cannot be adopted or silently amended. No retailer request, trip, route, order, location lookup, or payment follows from a quote entry or adoption.

Migration 018 uses tenant RLS on all five new tables. Runtime may insert saved proof, proposals, adoptions and receipts, but may not update or delete them. A separate privacy worker removes an erased adult's source pairs, cascaded proposals/adoptions, grants and receipts, including adopted private source copies. It leaves invalidated prices unknown. A content-free last-adoption revision survives as the fresh-review token so deletion cannot strand the remaining shopper behind an impossible review requirement; the deleted store/source proof is not restored.

## Local verification

`tests/shared-store-quotes-math.test.mjs` exercises exact totals, separate travel/time, unknowns, ties, scope, and caps. `tests/shared-store-quotes.integration.mjs` runs migrations on an explicitly isolated loopback PostgreSQL database and uses the non-owner runtime role through real authenticated HTTP routes. It covers independent grants, private saves, explicit proposals, shopper-only adoption, exact concurrent retries, revocation/regrant/authority transfer, frozen/placed reads, tenant/helper/child boundaries, rollback after injected receipt failure, database immutability permissions, and the real account deletion worker followed by fresh price review.

With `RITC_TEST_NATIVE_WIRE=1`, the same integration file exercises actual Swift HouseholdClient adult and shopper calls through pinned loopback HTTPS into PostgreSQL using `tests/shared-store-quotes-native-wire.mjs`. This is host-client wire evidence, not a claim of iPhone accessibility or simulator acceptance. No remote provider, production migration, payment, or deployment is used.
