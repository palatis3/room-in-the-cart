# Shared-food item and quote editor

The existing shared-shop editor now reads authoritative food-tracking status before
approval. Enabled shops carry the exact entered quote, item IDs, prices and packs
into food review. Rename and manual/import removal require explicit review;
meal, request and protected commitments require an explicit Keep action. Cancel
retains the outer draft without queuing a command. Apply and relaunch retry use
the existing durable parent outbox and exact prepared operation.

Privacy recovery permits replacement of an expired quote and monetary changes,
while ordered item identities/labels and all surviving food facts stay unchanged.
The actual HTTP/PostgreSQL case verifies review, Cancel, Apply, retained quantities
and the saved fresh quote after an author's erasure. Its initial fixture reused a
pre-erasure item label; the server correctly rejected it. The corrected fixture
reads the authoritative post-erasure label. Production backend code was unchanged.

Xcode27.1 Debug build-for-testing passed in119.856 seconds. All59 selected native
model tests passed in23.950 seconds with zero skips and strict inspection. Exact
compiled selectors and the newly produced arm64 test plan were checked before
launch. The earlier qualified products were preserved before the incremental build.
Localization structure passes4419 EN/ES entries across27 catalogs and project
generation is current. The unchanged client package was not redundantly rebuilt.
The one selected real PostgreSQL regression passed; its disposable database stopped.
The prior569 offline/285 PostgreSQL results are separate, unchanged-backend evidence,
not a newly executed full suite.

[Verification hashes](verification.json) bind retained originals under
`.build/SharedDemandNativeEditorNov09/r1`,
`.build/SharedDemandLegacySourcesNov09/quote-recovery-r1` and `quote-recovery-r2`,
and the frozen source under `.build/SharedDemandGraphNov09/native-shop-editor-r1`.
UI journeys, real mixed-device acceptance, graph-aware meal/request editing and
shared export/import remain open. Migration043 is not deployed; no performance,
minimum-iOS, full-candidate, signed-device or App Store acceptance is implied.
