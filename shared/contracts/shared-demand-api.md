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
