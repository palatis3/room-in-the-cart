# Shared draft demand API v1

This service contract accompanies `shared-demand.schema.json`. Native UI/Swift DTO and shared export integration are still required. Nothing automatically infers typed usable quantity from legacy pack counts.

## Scope and transaction

Both routes use the existing live session/device, tenant, member/consent and assigned-shopper checks. Helpers, planners and contributors do not receive the raw graph. The existing household transaction locks the household before bases and previews are evaluated. All graph, basket, meal, operation, event and snapshot effects commit or roll back together.

`GET /v1/households/{household}/shops/{shop}/demand` returns `schemaVersion:1`, shop ID/revision/authority epoch, status `legacy|enabled|reviewRequired`, and nullable current graph. Legacy has no graph. The graph carries its own independent revision.

The read also returns `totals` in graph-line order, one row for each non-trashed line
with active contributions: `{lineId,unit,quantity,activeContributionIds}`. `quantity`
is the canonical reduced `{numerator:string,denominator:string}` food amount after
duplicate and within-existing allocations, or explicit `null` when unresolved.
It is not a pack count. Legacy reads return `totals:[]`. Retired contributions are
excluded from `activeContributionIds`; their original graph records remain intact.
The server derives these rows using the same arithmetic used by pack verification.
A known amount does not establish that restrictions, conversions on other lines,
prices or fulfillment are resolved.

`POST .../demand/previews` accepts at most 1,800,000 bytes and:

- `mode`: `adopt|change|undo|review`.
- `base`: exact shop revision, authority epoch and graph revision (zero only before adoption).
- `change`: the shared-demand change fields excluding schemaVersion, operationId, householdId, shopId, baseRevision and at; those are server-owned.
- Optional `undoOperationId`: trusted persisted operation receipt to invert; required only for Undo. Undo acts on touched IDs against the current graph and preserves unrelated additions.
- `action`: kind `shop.patch|request.apply` and the exact ordinary command body, without nested demandReview. Request decisions must be add/link and reference the existing current request preview.
- `packs`: one `{lineId,usablePerPack,acceptUnresolved}` per active basket line. A usable quantity is explicit or null. Known totals must fit the entered integer packs. Accepting unresolved facts does not waive a known insufficient quantity. Inherited restriction labels stay exact and individually mapped or unresolved; unresolved restrictions cannot qualify allocations as safe.

The response has before/after graphs, their `beforeTotals`/`afterTotals` in the same
format, reducer receipt, reviewed packs, exact shop/authority bases, previewId,
previewDigest and expiresAt. Each totals array belongs to its corresponding graph
revision. The server reserves the applying operation UUID, uses database time, and binds actor/device, shop, authority, graph digest, normalized action, source facts and reviewed quote. Lifetime is ten minutes; at most 100 live actor previews per household. Cancellation makes no graph/basket/meal/operation change; transient previews may remain until expiry cleanup.

Apply uses the existing `/v1/households/{household}/commands` envelope and original action body plus `demandReview:{previewId,previewDigest}`. The command retains the existing 65,536-byte limit and exact replay-window/client-key/device rules. Apply reauthorizes, recomputes the preview and consumes it only in the successful transaction. Exact retry returns the one original operation while its authority/content remain available. A privacy-erased receipt cannot replay or Undo.

## Stable protection and compatibility

A protected reservation may have an unknown quantity and null binding without inventing an allocation. Explicit `quantifyReservationIds` permits that same stable reservation to acquire its real binding and known quantity after review; occurrence, ingredient, group and reservation identities stay fixed. Its accepted protected minimum cannot be silently reduced or undone into unknown. Whole-protected known totals can remain one reservation without fabricated per-group shares.

Explicit optional `clarifyReservationProductIds` permits only reviewed product identity clarification for existing active reservations whose `productKey` is null. Each listed contribution must be supplied with a non-null key and every other field unchanged: stable ID, line, source identity/binding, original text, product name, quantity, product facts, exclusions and removal state. Unknown, repeated, removed, non-reservation or already-identified IDs are rejected; the same row cannot also be quantified or rebound. Omitting this intent preserves the ordinary protected-product guard. Undo cannot carry clarification IDs or revert an accepted protected product identity to unknown. This does not authorize merging, allocation, restriction resolution, quantity changes or reassignment of a known product.

Graph-enabled shops reject old pack-only draft edits and request add/link with `demand_review_required`. Existing unadopted shops retain their original behavior. The server-only store-price path preserves identical line identities, names and pack counts and never changes the graph. Snapshots pin graph revision/digest. Privacy invalidates affected digests/receipts and all transient household demand previews, including copies created by a different shopper before any graph was committed. Persisted unrelated contributions remain selective. The current affected head becomes reviewRequired; it never selects an older head. Reopen may pin an explicit `{schemaVersion:1,revision,digest:null,status:"reviewRequired"}` reference so a frozen shop can recover. That reference and every erased dated snapshot remain ineligible for direct placement or reconciliation; fresh review and an accepted snapshot are required.

Deploying migration043 does not backfill or activate native adoption. Once adopted graphs exist, rollback to a server without writer/privacy fences is unsafe: preserve history and roll forward or explicitly stop affected writes. Do not drop graph history to undo deployment. Shared native export/import, scoped downstream projections and original-route mixed-device acceptance remain separate required integration work.

## Proposed meal-action source catalog

`GET .../demand` additionally returns `graphDigest`: the server's current graph
fingerprint only when status is `enabled`; otherwise `null`. Clients echo this
value; they do not duplicate server canonicalization.

`POST .../demand/action-sources` is read-only and retains the ordinary 65,536-byte
request cap. It accepts `{base,action}`. `base` contains exact `shopRevision`,
`authorityEpoch`, positive `graphRevision`, and lowercase 64-hex `graphDigest`.
`action` is `{kind:"shop.patch",body:<ordinary shop.patch body>}` with exactly one
`mealEdit` and no `demandReview`. It accepts direct edits, approved change proposals
(`changeProposalId`) and existing move proposals (`proposalId`). The existing body
schema disallows both proposal IDs together. This milestone excludes request.apply.

Only an enabled graph is eligible. Legacy editing retains its original path;
there is no merge of legacy and proposed-action catalogs. `reviewRequired` must
first complete surviving-food recovery and reread the enabled graph/digest.
Absent graph or recovery state rejects with `demand_enabled_required`; mismatched
graph revision/digest rejects with `stale_demand`. Existing shop/authority errors
remain unchanged. The endpoint runs within the authenticated household transaction
and requires the assigned adult shopper, live device/session, draft shop and bases.

The response is `{schemaVersion:1,shopId,base,graphDigest,normalizedAction,
actionDigest,sources,retirementCandidates,retainedContributionIds}`. `actionDigest`
binds the normalized ordinary action. `sources` enumerates authoritative *meal and
reservation* facts after the action; each row contains:

- `before`: the exact existing graph contribution, or `null` for a genuinely new source.
- `proposed`: the existing catalog fact shape (`id`, `source`, `sourceLabel`,
  `productName`, immutable `originalText`, `originalQuantityText`, exact reduced
  `quantity`, scoped `sourceExclusions`, and `requiredLineId`). Existing IDs and
  reservation purpose/identity are preserved. `requiredLineId` is the existing
  contribution line, or null for a new source. Matching scoped exclusion labels
  keep their existing reviewed mappings; new labels remain unresolved.
- `transition`: `retain|update|new|quantifyReservation`. Quantification is a fact
  transition, not permission: the final request must still explicitly list the
  reservation in `quantifyReservationIds` and pass the original reducer checks.

`retirementCandidates` lists disappeared nonprotected meal contribution IDs for
explicit review; it does not perform removal. `retainedContributionIds` identifies
all other graph contributions, including unrelated manual/import/request records
and tombstones, which remain unchanged. Existing allocation edges are not rewritten
by this catalog. Before/after preview remains the only way to validate repairs.

Matching preserves arbitrary existing IDs rather than replacing them with generated
legacy IDs. Whole-protected representations remain whole. Missing protected rows,
ambiguous matches, non-null binding replacement, retired provenance, or reused IDs
fail explicitly. There is no silent resurrection or weakening of protected needs.
No product key, product match, conversion, allocation or usable pack quantity is
inferred. Exact retained facts do not authorize a new product match.

Catalog and demand preview use the same read-only proposal checks as commit:
current actor/member, authority epoch, planner grant, shop/meal revisions, pending
proposal and exact proposed meal; new occurrences also revalidate their approved
idea and revision. Only commit consumes a proposal. A changed/revoked/dismissed
proposal or changed approved idea makes subsequent catalog/preview/Apply fail even
if the graph revision itself has not changed.

The catalog creates no preview, operation, graph, meal revision or proposal update.
It is informational, not an Apply token. Cancel has no effect. Existing demand
preview and Apply independently reauthorize and recompute source facts and enforce
conservation, quantities, exclusions, edge/pack rules and original command limits.
Source rows are capped at 2,000 and encoded response bytes at 1,800,000; over-limit
facts are rejected, never truncated. No schema version bump or migration is needed.


## Ordinary complete Undo after a reviewed store selection

`demand/operation-undo-candidates` and `demand/operation-undo-previews` may include
`storeBasis: { revision, pairId, choice: "first"|"second", selectionDigest }` for
ordinary complete changes under one unchanged selected store. This field is omitted,
not null, when no store selection exists. It is server evidence and part of the
accepted effect digest, not an Apply token or a client-selectable inverse.

New internal shop snapshots record content-free `storeBasis:{revision,reviewRequired}`
inside their existing digest. A selected-store inverse requires both target snapshots
to name the same reviewed basis as the current shop. The exact adoption/pair and live
author/adopter/original permission must still authorize that basis. A missing old
snapshot field does not authorize selected-store history. Existing public shop and
command receipt shapes are unchanged. Existing no-store Undo responses omit the new
field. An older strict client may reject the newly supported selected-store response;
it cannot silently apply it or acquire new authority.

Actual store selection/repricing operations remain unsupported. Switching away and
back to the same displayed store is a different revision and does not authorize the
old inverse. Price expiry, exact touched fields, protected source conservation,
explicit pack review and current shopper/base/device/epoch checks remain unchanged.
A successful exact retry acknowledges its prior result without reapplying; it still
requires retained original selection proof and current authorization. Missing/erased
proof or revoked original permission denies that retry. No migration or historical
backfill is performed.
