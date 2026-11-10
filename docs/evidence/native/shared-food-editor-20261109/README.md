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


Independent review found that the two existing meal UI fixtures returned 404 for
the new status lookup. They now return an exact, authorized legacy page at their
current revision, with no invented adoption catalog. Production still rejects
unavailable or unauthorized status reads. The original S17 planner/shopper
Cancel/Send/Cancel/Apply journey and S26 fractional idea/approval/proposal/shopper
journey both pass on one contributor build. Strict inspection records zero
runtime warnings and no retries/restarts. Review screenshots show the unchanged
monetary fields and disabled publish control before acknowledgment. This is legacy
compatibility evidence, not the new graph editor's UI acceptance or a complete
accessibility audit. [Exact UI proof](legacy-ui-verification.json).


The original graph-editor journeys now pass in both English and Spanish on the
same r6 build, alongside148 selected model tests and122 client-package tests
(3 expected database-only skips). Each UI result passes strict selection and
runtime-warning inspection. The journeys cover fresh quote replacement, explicit
food review, Cancel preserving the outer draft, Apply with a deliberately lost
response, relaunch and an exact durable retry with only one saved change.

The first failures exposed a no-op control write invalidating an open review and
index-based bindings outliving arrays cleared by Cancel. Identical draft writes
now preserve the current review; actual changes still invalidate it. Stable-ID
bindings re-resolve current rows and return redacted empty values after Cancel or
revocation; stale setters cannot restore data or write into a neighboring row.
The qualified original source/products and both results remain local under
`.build/SharedDemandNativeRequestsNov09/combined-r6`.
[Compact r6 hashes](graph-ui-r6-verification.json) distinguish this fixture UI
proof from actual service and release acceptance. A subsequent combined candidate
adds meal normalization, explicit conversion reconfirmation and wire coverage;
its results must be recorded separately.


The meal/request successor passes153 strict model checks,122 client-package tests
(3 expected wire skips), and both original UI journeys. R7 qualifies the models
and English; r8 fixes only the Spanish expected title and qualifies Spanish.
The production app and model-test product bytes are identical between those
builds. The initial Spanish failure, old title and corrected title remain recorded.
[Successor proof](graph-meal-r7-r8-verification.json) binds exact sources and results.

Meal actions trim only the text edges normalized by the server contract, including
ECMAScript whitespace, while preserving IDs, internal wording and exact quantity
fractions. When a changed authoritative quantity invalidates an old conversion,
the shopper can explicitly supply fresh conversion evidence while the amount,
unit and original quantity wording remain fixed. Request/protected identities and
relationship decisions retain their existing approval gates. Known-direction UI
searches preserve all assertions and reduced observed English/Spanish test-process
times from316.8/300.6s to252.3/246.5s; these are not app-performance baselines.
