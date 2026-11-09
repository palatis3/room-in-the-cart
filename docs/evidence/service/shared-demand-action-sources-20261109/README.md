# Authoritative meal-action source catalog

The enabled shared-food graph now supplies a read-only catalog for a precisely
bound proposed meal/proposal change. Existing contribution and reservation IDs,
original wording, line bindings, restrictions and unchanged confirmed conversions
survive. New quantities, source retirement and overlap still require explicit
review. Protected unknown-to-known quantities are labeled for the existing explicit
quantification gate. Catalog reads never consume proposals or authorize Apply;
preview and commit independently recheck current grants/proposal/idea facts.

Strict compilation and116 offline checks passed, including24 catalog controls.
The r2 candidate passed91 actual HTTP/PostgreSQL cases across the existing demand,
meal-change and meal-idea routes, with no skips. R3 changes only quantification
classification and its tests; its new affected HTTP/PostgreSQL scenario passes,
including rejected unacknowledged preview, read-only Cancel, Apply, exact replay
and stale-base rejection. The91-case r2 run remains separately scoped evidence.
All database tests used fresh verified local roles, migrations and privacy-journal
fixtures. Both databases stopped; no hosted database or deployment changed.

Independent review found and fixed loss of unchanged conversion evidence; its
regression fails against r1. Native integration review found the same-identity
protected quantification classification gap; its regression fails against r2.
Earlier fixture/preparation failures are retained under the raw candidate paths.

[Verified receipts and hashes](verification.json). Original packages and execution
results remain under `.build/SharedDemandGraphNov09/action-source-catalog-*`.
Native meal-editor integration, broader combined qualification and deployment remain
separate acceptance work.
