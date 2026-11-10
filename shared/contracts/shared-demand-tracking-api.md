# Shared tracking API v2 (disabled pending complete integration)

This supplements the existing shared-demand API; it does not change graph arithmetic schema v1 or authorize deployment. Every route remains assigned-shopper-only inside the existing authorized household transaction. Production composition does not enable `HouseholdRepository.options.trackingV2`.

Paths are relative to `/v1/households/{household}/shops/{shop}`:

| Method/path | Contract |
|---|---|
| GET `demand/tracking` | `schemaVersion:2`, `shopId`, `shopRevision`, `authorityEpoch`, `status`, exact `state` or `projection`, `basisDigest`, scoped `coverage`, canonical `checkout`, required-null `freezeReview` |
| GET `demand/tracking/operations` | Content-free recorded operation IDs, revision/time, `reviewRoute:tracking|requestAcceptance|trackingMeal` and current-preview-required/unavailable status. No historical content or eligibility guarantee. |
| POST `demand/tracking/candidates` | Strict discriminated intent below; returns candidate ID/digest/expiry, exact normalized action, after-state and complete changes/pickup/before-and-after-money disclosure. No command is sent. |
| POST `demand/tracking/previews` | `{candidateId,candidateDigest,acknowledgedDisclosure,acceptOverage,acceptUnknown}` exactly matching the complete displayed candidate; revalidates facts and returns `previewId,previewDigest,trackingVersion:2,expiresAt,action,disclosure,moneyAcknowledgments`. Explicit overage/unknown acceptance cannot be inferred from the general disclosure acknowledgment. |
| GET `records/tracking-snapshot` | Separate v2 assigned-shopper record retaining bound/unbound catalog, original text, amounts, protection and basket/pack distinction. Not a portable export grant or recovery token. |

Every candidate has `base:{shopRevision,authorityEpoch,graphRevision,stateDigest}`. Intent variants (all reject unknown fields):

* `adopt`: original `action`, v1 `change`, explicit `packs`; complete immutable first-adoption evidence can include quote, meal and request changes. Request acceptance compounds use the dedicated request-family inverse route; a food-only inverse is never substituted.
* `change`: original `action`, v1 `change`, explicit `packs`, exact `unboundFactIds`. The server derives all authoritative sources and rejects omission/relabeling of already-bound commitments. Existing transferred IDs cannot be reintroduced as new rows. An actual related meal change may include explicit `transferredChanges` as specified below.
* `review`: original shop.patch `action` and explicit `packs`; graph/source relationships unchanged. Packs, price/fees/quote and legacy basket wording can be reviewed without inventing food amounts. Tracked food names or basket membership require a graph change.
* `firstAdoptionUndo`: target operation ID and fresh packs. Complete retained certificate/current source/store/privacy evidence only; disclosure lists all reversed assertions and restored basket fields.
* `mealOperationUndo`: target operation ID and explicit fresh packs; whole ordinary meal-effect inverse using exact graph/partition/meal history, including transferred rows.
* `rebind`: `{factId,line,basket,packReview}[]`; no client-supplied contribution. Exact server-retained transferred identity/protection is restored, with no old allocations.
* `recover`: fresh `packs` only; derives from the current worker-created surviving projection, never a client history payload.

Apply uses the existing durable command envelope and the returned exact action, adding `body.demandReview:{previewId,previewDigest,trackingVersion:2}`. Original actor/device/replayWindow/clientKey semantics and reserved operation ID remain. No direct write endpoint exists. V1 previews omit the version and cannot be interpreted as v2.

After successful Apply, the read's current `freezeReview` is `{previewId: acceptedReviewId, previewDigest: acceptedReviewDigest, trackingVersion:2}`. This is a different review identity from the Apply preview. Partial pickup uses `shop.freeze` with `{trackingReview: freezeReview}`. It binds the complete current state/catalog, prices, protected unknowns and incomplete-coverage disclosure. Old/erased/stale/expired reviews cannot freeze. A valid frozen snapshot does not claim an actual fill or free unbound supply.

Tracking proof hashes use the tracking module's code-point canonicalization; existing graph/quote/shop-snapshot hashes retain the legacy storage canonicalization. Never relabel one as the other. Maximum candidate/review payload is 1,800,000 bytes, maximum 100 outstanding private candidates per actor, expiry at most ten minutes.

## Enabled partial meal and selected-store review

See the strict source schemas; every addition remains behind the same existing V2 admission. This does not activate production deployment.

`POST demand/tracking/meal-action-sources` accepts `{base,action}` for an actual `shop.patch.mealEdit`. Its response contains `schemaVersion:2,shopId,base,normalizedAction,actionDigest,mealChange,sources,retirementCandidates,transferredRetirementCandidates,retiredUnboundFactIds,retainedContributionIds,proposedCatalog,beforeCoverage`. It is informational and never an Apply proof. The existing genuine-legacy `demand/tracking/action-sources` endpoint stays unchanged.

`mealChange` is `{occurrenceId,before:{revision,meal}|null,after:{revision,meal:null|SharedMeal}}`; after revision is the prospective shop revision. Each source retains the existing `{before:Contribution|null,proposed:LegacyDemandSource,transition}` and adds `{factId,revision,location:tracked|transferred|unbound|new}`. `factId` is an authoritative catalog identity; `proposed.id` is a contribution identity, which can differ for existing bound/transferred sources. Join exact binding identities. Plain-unbound sources have no contribution preimage; their existing facts are in the exact current page catalog. Their proposed ID/source is the retained server-derived fact identity, not inferred from labels. `beforeCoverage` exactly equals the current page coverage.

Graph retirement/retained IDs remain graph-only. `transferredRetirementCandidates` contains `{factId,contributionId}` and `retiredUnboundFactIds` contains plain fact IDs. `proposedCatalog` is the authoritative exact prospective Fact array, with current source revisions and required-null quantities; it is not client authority.

A `change` may add `transferredChanges:[{factId,after:Contribution|null}]`. Its meal action must authorize the exact fact change. IDs, original wording and protected constraints remain central reducer invariants. Null explicitly retires only a disappeared, nonprotected transferred fact; old identity remains non-reusable and original state remains in immutable 046 history. Omitted disappeared transfers are rejected. Unchanged transfers stay byte-identical and unallocatable. Existing explicit `quantifyReservationIds` / `clarifyReservationProductIds` may name detached protected rows, subject to the same narrow central policies. No implicit rebind or conversion is performed.

Forward meal `adopt` and `change` disclosures contain `changes:{kind:mealActionChange,mealChange,transferredChanges:[{factId,before:Contribution,after:Contribution|null}]}` (possibly empty). Thus a date/title/plain-unbound edit still acknowledges full before/after meal facts. The complete pickup and checkout disclosure is unchanged.

The `mealOperationUndo` changes disclosure is `{kind:mealOperationUndo,targetOperationId,mealUndo,transferredChanges:[{factId,before:UnboundEntry|null,after:UnboundEntry|null}],touchedBasket,quote:{before,after},graphRows,beforeCoverage,afterCoverage}`. `mealUndo` is the existing canonical whole-meal outcome. Exact snapshots/046 states and 045/047 effects are loaded under current authority; callers cannot supply history. Retired source restoration uses only authenticated historical identity/original wording and fresh authoritative prospective source facts. Later unrelated rows survive, changed or rebound touched rows conflict, and protected quantities cannot be reduced through Undo. Exact replay validates old private lineage without deriving against later mutable meal state.

An explicit `review` may clear a selected store's repricing gate only with the current `action.body.reviewedStoreBasisRevision`, live original store permission and unchanged food/source/partition/basket identity. Quote, prices, packs and fresh explicit pack reviews may change; full money acknowledgment is still required. This does not authorize reversal across store selections or promote old store-less snapshots.

## Compatibility and remaining boundary

No graph arithmetic schema version or database migration changes. Old clients fail closed on unknown routes/intents; install the coordinated strict native successor before exposing these flows. Completed operation replay preserves original bytes and receipts. Old uncommitted monetary previews require explicit refresh when complete disclosure cannot be proven; pending commands are never silently rewritten.

Actual store-switch reversal, general non-meal partial-operation Undo, native/UI/wire qualification of this successor and portable Records recovery remain separate acceptance. Neither partial subtotals nor unknown acknowledgments assert complete food coverage or free unbound supply. No full Foundation closure is claimed.

A newly recorded meal operation on an old complete V1 base can retain an internal versioned before-state capture in the new 046 review JSON. It binds the exact reserved operation, existing snapshot digest, before/after state digests and transaction revisions. Only a fully covered V1 before-state qualifies. It never mutates/promotes old snapshots, never accepts client history, and is erased with the review. Missing or redacted capture cannot be replaced with current facts.
