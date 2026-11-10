# Shared food tracking integration contract

This records the reviewed implementation boundary for Foundation D05, D07, D08 and D09. The current pure domain is installed; persistence and client activation remain unfinished. It is not a deployment or release approval.

## Product behavior

Undo of first tracking is a compensating revision covering the whole original Apply: quantity assertions, allocations, reviewed pack facts and affected basket fields. Preserve unrelated later groceries, untouched price fields, authoritative meal/request facts, protected quantities and every used identity. Preview all reversed assertions; do not label the action as removing only the newly added item.

Sources can be tracked or explicitly unbound. Unbound food is never inferred as available supply. A tracked subtotal is not a household total. Preserve unknown quantities and original wording instead of inventing conversions or mappings.

Foundation D05 allows a missing ingredient conversion to remain unknown; D07 allows unresolved needs; D09 freezes the exact revision before sharing. Therefore an explicitly reviewed partial record may support an ordinary manual pickup. Requiring all food to be quantified or mapped is not a release prerequisite. The review must disclose all unbound commitments, protection, unknown totals/restrictions and unpriced basket rows, and bind the complete current basket/catalog, authority and privacy revision. Stale, erased, unreviewed or tampered records cannot authorize placement.

## Integration requirements

- Capture initial before-state inside the existing household-locked authorized transaction before basket, meal, request or graph mutation. Create immutable lineage only for newly observed operations; do not promote old unproven receipts.
- Persist state by shop revision, since legitimate price-only edits can advance the shop without advancing the graph. Bind snapshot and graph references separately.
- Use explicit v2 read/preview contracts and a bound version marker. Existing v1 clients may continue on proven fully tracked state; they cannot flatten or mutate partial state or reinterpret a v2 preview.
- Rebinding must restore only identities proven by retained transferred evidence. General reuse of old IDs remains forbidden. Preserve every unrelated source and graph fact.
- Privacy recovery starts from a server-projected surviving state and a fresh review. Preserve unaffected IDs; erase all copied historical/current source text, revoke old digests and previews, and never revive erased lineage.
- Track source-member provenance independently of graph membership so unbound catalogs and transfers are covered. Continue household-wide transient preview invalidation, including copies held by other shoppers before adoption.
- Preserve the existing original-author/adopter/grant checks for an unchanged selected store. Recheck source consent and authorization at preview, Apply and exact replay.
- Audit every writer and consumer: ordinary patch, request acceptance, meal/proposal edits, internal store price-only bypass, raw Undo, snapshot/freeze/reopen, direct/reconciled placement, Records, cook/delivery/recovery projections and signed privacy-journal restore.
- Records must explicitly represent bound/unbound requests and tracked/legacy basket/pack facts. Do not weaken v1 completeness checks to accept a partial payload.

## Evidence required before activation

Pure same-ID rebinding and redacted-state recovery need direct positive/negative regressions. Database and HTTP tests must prove atomic capture, Cancel zero writes, lost-response exact retry, preserved later edits, cross-household denial, old-client rejection before mutation, reviewed-partial pickup, stale/erased placement denial, source/store revocation and selective erasure followed by actual restore/journal replay. Native review and durable retry must then use the same contracts.

Current proof: [domain integration](evidence/service/shared-demand-tracking-20261110/README.md). Detailed scratch file/route matrix: `.build/SharedDemandGraphNov09/mixed-adoption-persistence-plan-r1/`; its blanket partial-placement rejection is superseded by the reviewed-partial behavior above. Migration 046 is reserved for tracking but must be checked for availability before integration.
