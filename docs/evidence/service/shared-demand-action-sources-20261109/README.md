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


The combined typed-client lane now passes all10 Node integration cases and27 exact
Swift XCTest scenarios over pinned loopback HTTPS and fresh PostgreSQL, with zero
failures/skips. The added scenarios verify normalized catalog labels and Cancel
without writes, protected unknown-to-known quantity confirmation plus exact retry
after a deliberately lost successful response, revoked proposal authority at
catalog/preview/prepared Apply, and explicit conversion reconfirmation preserving
existing source/edge identity. The database stopped and successful private fixture
state was removed. [Exact source, result and cleanup hashes](native-wire-verification.json).

The first candidate passed9/10 Node cases and24 Swift phases before a new test
expected409 for a domain-validation rejection. The established HTTP mapping is422;
all three related domain assertions were corrected together, while stale-state409
checks and every exact error-code/rejection assertion remain. No service change
was needed. The corrected Swift target was freshly built before the complete
10/27 lane; the first failure remains preserved separately.

The complete current service regression subsequently passed595 offline tests and
292 PostgreSQL tests across40 and17 test files. One database-only offline case and
three optional browser journeys were explicitly skipped. This reused the verified
137-entry service build from the successful wire run; all239 source files, compiled
bytes/modes, tools and dependencies remained unchanged. The original privacy-journal
harness fenced successfully, and the private PostgreSQL instance stopped. Its
fixture state remains local with0700 directory permissions. No browser, native,
mixed-device or deployment acceptance is implied.
[Full backend verification](backend-regression-verification.json).
