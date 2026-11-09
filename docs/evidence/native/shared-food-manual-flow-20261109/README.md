# Native shared-food entry, review and durable save

Shared shoppers can review authoritative legacy meal/request sources, enter exact
manual food needs separately from whole packs, and explicitly confirm duplicate or
within-existing relationships. The review shows server totals and preserved sources,
then saves through the existing durable parent outbox. Unknown amounts stay unknown.
Inherited restrictions need explicit mapping; product labels never silently merge
needs. Protected unknown identities use the dedicated identity-only confirmation.

The installed app builds under Xcode27.1 and passes the compiled-bundle check.
All **45 selected simulator model tests** pass strict result validation:18 new
shared-food cases,19 existing shared-shop cases and8 helper-review cases. Coverage
includes exact fractions/Spanish decimal entry, stable source IDs, protected needs,
pack-only review, cancellation, revoked access, and a lost response followed by
relaunch and retry of the same reserved operation. The client package passes
**122 tests**, with3 expected integration-only skips and zero failures.

The first local test selection assigned eight existing helper tests to the wrong
class. Compiled-selector admission stopped before XCTest. A subsequent setup check
found an old dual-architecture test plan beside the current arm64 plan in reusable
DerivedData. Both setup failures are retained. Corrected class/plan selection reused
the same source and products; no build or app test was repeated for either failure.

Original source/copy review is in
`.build/SharedDemandGraphNov09/native-manual-flow-r1/`; installed-source, build,
package and strict model evidence is in `.build/SharedDemandNativeManualNov09/r1/`.
The installed catalog has90 English/Spanish keys. Translation presence is not human
localization acceptance.

This is the first manual-food vertical path, not complete F01/F02 acceptance.
Existing quote/item editing, request Add/Link and meal/proposal editing still need
graph-aware saves. The next milestone is quote/item integration, including expired
quotes. Request integration must retain its exact reviewed decision/line UUID;
changed-meal integration needs a proposed-action source catalog from the service.
Original UI journeys, accessibility/localization walkthroughs, mixed-device wire
qualification and final combined regression remain required. No staging rollout
or App Store readiness is claimed.
