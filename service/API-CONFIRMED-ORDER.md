# Retailer-confirmed shared order changes

The current assigned adult shopper can record manual evidence of a change the retailer already confirmed. This Free operation is distinct from a meal proposal, original placement, physical arrival, purchase outcome, charge, refund and settlement. It never contacts a retailer.

`GET /v1/households/{household}/shops/{shop}/confirmed-order` requires current shopper authority. Bootstrap advertises `confirmed_order` for an assigned shop with placement evidence. Placed and closed shops are readable and can receive confirmation evidence.

The response is `ConfirmedOrderPage` in `shared/contracts/service-v1.d.ts`: shop identity/revision/authority epoch, original placed revision, `asOf`, original lines/quote/snapshot creation time, effective current lines/head amendment ID, and the complete ordered amendment history. There is no pagination or truncated-history success response. Each event identifies its predecessor, reporting actor ID (plus optional current `actorLabel`), retailer reference, retailer confirmation time and service recording time. Original lines and each event contain at most 200 lines; the historical union may exceed 200.

`POST /v1/households/{household}/commands` accepts the usual exact-retry envelope with kind `amendment.recordResponse`, current `{shopRevision,authorityEpoch}` base, and body:

```json
{
  "placedRevision": 2,
  "predecessorId": null,
  "retailerReference": "Retailer confirmation #42",
  "confirmedAt": "2026-11-07T15:00:00Z",
  "lines": []
}
```

`lines` is the complete current order using the existing basket-line schema (`lineId`, `originalItem`, positive whole `packs`, nullable `unitPriceMinor`, `feeEligible`). Empty means the retailer confirmed cancellation of every line. The retailer reference is trimmed, nonblank, at most 240 UTF-16 code units, with no control characters. Confirmation time cannot precede the original snapshot or prior confirmation, and cannot be in the future. A retained line cannot change its food name; a replacement needs a fresh UUID. Removed identities cannot be reused. Reordering alone is not an amendment.

The receipt is `ConfirmedOrderReceipt`: normal shopper receipt fields, `disposition:"recorded"`, `amendmentId` equal to `operationId`, and unchanged `placedRevision`. Only shop revision advances, by one. The original basket, quote, frozen snapshot, placed revision, physical supply, household meal plan, pending proposals and financial evidence do not change. Exact replay returns the same receipt while current actor/device/window/authority and retained evidence still authorize it. A changed base, stale predecessor, altered reused key or erased evidence requires review.

Delivery evidence includes identities from the original order and every retained amendment, so added replacement lines can be independently registered as physical sources. Existing `packs` remains the original count (or first count for a new identity). Optional `currentOrderedPacks` reflects the latest confirmed order, including zero for removed lines. Earlier delivery observations remain intact after cancellation. Registration does not imply arrival or usable food. Clients must not limit the historical union to 200 or treat zero currently ordered as zero physically received.

Migration 042 enables/forces tenant RLS and grants the runtime only SELECT/INSERT on immutable amendment evidence. Original snapshots continue through the established erasure path. Authorized privacy erasure invalidates copied amendment chains and exact receipts, removes amendment-derived physical sources and downstream copies/recovery facts, and retains a content-free shop fence. Subsequent confirmed-order reads/writes return `order_evidence_removed`; they never silently restore the original order as current. This removal of physical evidence is privacy erasure, not cancellation. Unaffected original physical identities remain.

`tests/order-amendments.integration.mjs` covers exact retries, no implied payment/food, cancellation, delivery registration, identity lifecycle, malformed confirmation, authority change, closed orders and real worker/journal erasure. The companion web client remains limited to own requests and scoped cook instructions; it receives no amendment or price projection.
