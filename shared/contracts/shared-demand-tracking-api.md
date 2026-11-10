# Shared tracking API v2 (disabled pending complete integration)

This supplements the existing shared-demand API; it does not change graph arithmetic schema v1 or authorize deployment. Every route remains assigned-shopper-only inside the existing authorized household transaction. Production composition does not enable `HouseholdRepository.options.trackingV2`.

Paths are relative to `/v1/households/{household}/shops/{shop}`:

| Method/path | Contract |
|---|---|
| GET `demand/tracking` | `schemaVersion:2`, `shopId`, `shopRevision`, `authorityEpoch`, `status`, exact `state` or `projection`, `basisDigest`, scoped `coverage`, optional `freezeReview` |
| GET `demand/tracking/operations` | Content-free new certificate IDs, revision/time and current-preview-required/unavailable status. No historical content or eligibility guarantee. |
| POST `demand/tracking/candidates` | Strict discriminated intent below; returns candidate ID/digest/expiry, exact normalized action, after-state and complete changes/pickup disclosure. No command is sent. |
| POST `demand/tracking/previews` | `{candidateId,candidateDigest,acknowledgedDisclosure}` exactly matching the complete displayed candidate; revalidates facts and returns `previewId,previewDigest,trackingVersion:2,expiresAt,action,disclosure`. |
| GET `records/tracking-snapshot` | Separate v2 assigned-shopper record retaining bound/unbound catalog, original text, amounts, protection and basket/pack distinction. Not a portable export grant or recovery token. |

Every candidate has `base:{shopRevision,authorityEpoch,graphRevision,stateDigest}`. Intent variants (all reject unknown fields):

* `adopt`: original `action`, v1 `change`, explicit `packs`; supported initial certificate requires unchanged quote and no meal/request action.
* `change`: original `action`, v1 `change`, explicit `packs`, exact `unboundFactIds`. The server derives all authoritative sources and rejects omission/relabeling of already-bound commitments. Existing transferred IDs cannot be reintroduced as new rows.
* `review`: original shop.patch `action` and explicit `packs`; graph/source relationships unchanged. Packs, price/fees/quote and legacy basket wording can be reviewed without inventing food amounts. Tracked food names or basket membership require a graph change.
* `firstAdoptionUndo`: target operation ID and fresh packs. Complete retained certificate/current source/store/privacy evidence only; disclosure lists all reversed assertions and restored basket fields.
* `rebind`: `{factId,line,basket,packReview}[]`; no client-supplied contribution. Exact server-retained transferred identity/protection is restored, with no old allocations.
* `recover`: fresh `packs` only; derives from the current worker-created surviving projection, never a client history payload.

Apply uses the existing durable command envelope and the returned exact action, adding `body.demandReview:{previewId,previewDigest,trackingVersion:2}`. Original actor/device/replayWindow/clientKey semantics and reserved operation ID remain. No direct write endpoint exists. V1 previews omit the version and cannot be interpreted as v2.

After successful Apply, the read's current `freezeReview` is `{previewId: acceptedReviewId, previewDigest: acceptedReviewDigest, trackingVersion:2}`. This is a different review identity from the Apply preview. Partial pickup uses `shop.freeze` with `{trackingReview: freezeReview}`. It binds the complete current state/catalog, prices, protected unknowns and incomplete-coverage disclosure. Old/erased/stale/expired reviews cannot freeze. A valid frozen snapshot does not claim an actual fill or free unbound supply.

Tracking proof hashes use the tracking module's code-point canonicalization; existing graph/quote/shop-snapshot hashes retain the legacy storage canonicalization. Never relabel one as the other. Maximum candidate/review payload is 1,800,000 bytes, maximum 100 outstanding private candidates per actor, expiry at most ten minutes.

Unsupported complete Undo remains explicit: compound first adoption with quote changes, meal creation/edit/proposal or request acceptance; existing ordinary combined commands remain functional without a new certificate. General later-operation Undo on partial state needs a tracking-aware composition adapter. No full Foundation closure is claimed by this increment.
