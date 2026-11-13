# Shared-food operation Undo v1 — bounded candidate contract

This is a complete inverse for newly recorded eligible shop.patch operations: graph rows, basket line membership/fields, packs and quote. The additive existing-meal slice requires migration 045 and acceptance-time meal lineage; see [meal Undo contract](shared-food-meal-undo.md). Older meal effects, new-occurrence creation, request Add/Link acceptance, first adoption, store-review actions and historical operations without trusted effect lineage remain explicitly unsupported. An inverse operation cannot itself be undone. This is not complete D02/D08 product coverage.

All routes use existing authenticated household/device context and assigned-shopper authorization; draft shop only, no paid gate. Responses must not survive access revocation or erase invalidation in a client cache.

## History

`GET /v1/households/{householdId}/shops/{shopId}/demand/operations?beforeRevision={positive integer}`

Optional exclusive cursor; newest first, maximum 20 rows. Returns:

```
{ schemaVersion: 1, shopId, shopRevision, authorityEpoch,
  items: [{ operationId, kind: "shop.patch" | "request.apply", shopRevision,
            committedAt: ISO8601,
            eligibility: {status: "reviewable" | "unavailable", reason: string} }],
  nextBeforeRevision: string | null }
```

History contains no source text, request identity or copied meal. `reviewable` means a current explicit preview may be attempted, never an Apply token or a promise the current pack/source validators will accept it. Its reason is `explicit_current_preview_required`.

`unavailable` reasons:

- `food_undo_history_unavailable`: absent/redacted/inconsistent lineage or graph not enabled/reviewed.
- `food_undo_request_acceptance_unsupported`, `food_undo_first_adoption_unsupported`, `food_undo_meal_action_unsupported` (also date-only), `food_undo_store_action_unsupported`, `food_undo_missing_snapshot_unsupported`, `food_undo_operation_unsupported`.
- `food_undo_already_reversed`, `food_undo_inverse_operation_unsupported`.
- `food_undo_line_conflict`, `food_undo_quote_conflict`, `food_undo_graph_conflict`, `food_undo_expired_quote`, `food_undo_no_effect`.

Clients should display an honest unavailable explanation and fail closed on unknown reasons. Existing authorization/stale/error envelopes remain unchanged.

## Read-only inverse candidate

`POST .../demand/operation-undo-candidates` with `{targetOperationId, base:{shopRevision,authorityEpoch,graphRevision,graphDigest}}`.

Returns `{schemaVersion:1,shopId,base,targetOperationId,effectDigest,scope,action,before,after,beforeTotals,afterTotals,beforeCheckout,afterCheckout,packReviewLineIds:[UUID]}`. Scope/action have the shapes below; before/after are demand graphs. This read performs no preview/command/revision writes. It supplies exact surviving/restored line identities so clients can explicitly review their usable-pack facts without inferring an inverse. The graph is informative; final preview supplies reserved-operation receipt/timestamps. Candidate effectDigest binds target/current graph and derived action; it is not an Apply token. No historical pack facts are silently reused.

## Server-derived preview

`POST .../demand/operation-undo-previews`

```
{ targetOperationId, effectDigest,
  base: {shopRevision, authorityEpoch, graphRevision, graphDigest},
  packs: [{lineId, usablePerPack: DemandQuantity | null, acceptUnresolved: boolean}] }
```

No client action, old graph, receipt, snapshot, quote, line inverse or proposal is accepted. `base.graphRevision` is positive and graphDigest is the current demand-page digest. Packs are explicit current acknowledgments under the unchanged existing pack validator; callers include exactly candidate.packReviewLineIds or receive `demand_basket_mismatch`. The candidate effectDigest must still match the rederived current candidate. Missing usable quantities require explicit acceptUnresolved, never guessing.

Response extends existing SharedDemandPreview unchanged:

```
{ previewId, previewDigest, expiresAt, before, after, beforeTotals, afterTotals,
  receipt, packs, shopRevision, authorityEpoch,
  operationUndo: {targetOperationId, effectDigest,
    scope: {targetOperationId, baseShopRevision, resultShopRevision,
      touchedLines:[{lineId, fields:["membership"|"originalItem"|"packs"|"unitPriceMinor"|"feeEligible"]}],
      quoteChanged:boolean, graphRows:number, mealsChanged:false, requestsChanged:false}},
  action: {kind:"shop.patch",body:{lines:BasketLine[],quote:QuoteBasis}},
  beforeCheckout:BudgetResult, afterCheckout:BudgetResult }
```

Original 10-minute actor/device/base-bound preview machinery stores the exact server action, target and effect digest internally, rederives/revalidates on Apply, and reserves the inverse operation ID. The public existing `/demand/previews` endpoint cannot submit the internal `operationUndo` mode/digest.

## Apply, Cancel and retry

Use existing prepared-operation/outbox path and exact `shop.patch` envelope. Body is exactly response.action.body plus `{demandReview:{previewId,previewDigest}}`; base uses returned shopRevision/authorityEpoch. No new command kind, inverse arithmetic or arbitrary preimage is sent. Cancel sends no command. Apply commits graph/basket/quote/effect association in one existing transaction and returns the unchanged ShopperReceipt. Unique target association prevents a second intentional inverse; exact original command retry still returns its single receipt after authorization, payload/device and retained target-lineage checks. A stale/revoked/redacted basis fails closed.

The restored quote/price basis must be unexpired; v1 rejects an expired basis instead of substituting current prices under an Undo label. Target-touched line fields require exact accepted after-values; unrelated current line fields/rows survive. Quote is one atomic provenance basis. Graph rows use existing receipt-bound conservation/protection checks, so a dependent later source can block Undo rather than disappear.
