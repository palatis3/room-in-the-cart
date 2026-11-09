# Shared-meal date sheet

Shared meal dates now show a complete localized civil date. Calendar changes stay
inside a sheet until confirmation, before the separate shop review. Cancel and
interactive dismissal discard the selection. Confirming the same day preserves
its deadline; confirming a changed day clears the old deadline. Occurrence identity
is retained, and stale selection guards still check the current occurrence/day.

The outer Form owns presentation so scrolling or recycling a row cannot dismiss
the sheet. Standard text uses the native graphical calendar; accessibility text
uses adjustable native wheels with the duplicate visible label hidden. The
localized accessibility label, title, full-date preview and production Dynamic
Type remain intact. Test-only counters/readbacks no longer crowd the AX5 fixture.

Final r6 validation on Xcode 27.1/iOS 27.0/iPhone 17: Debug fixture build and compiled bundle
checks pass; all four date-sheet journeys pass native and strict validation on one
unchanged source/product snapshot (English/Spanish, ordinary/largest text). Root
reviewed all four saved selection screenshots. The tests retain cancel, unchanged
confirmation, changed confirmation, deadline and identity assertions; ordinary
text additionally exercises interactive sheet dismissal. The existing contributor
inventory contains all four selectors once, without adding a shard. The workflow
source suite passed 457 checks, plus structural localization and shell syntax.

Earlier evidence remains separate: r4 passed all nine affected journeys, including
civil dates across four time zones, optional-night identity and deadline review.
Its Spanish AX5 screenshot still exposed overlapping calendar-header arrows. R5's
wheel adaptation passed English AX5 and both ordinary-language cases but failed
Spanish AX5 because its duplicate visible label wrapped into a narrow column.
R6 corrected that one layout line without changing the tests. Earlier dismissal-
gesture, fixture-layout and row-presentation failures are retained. R4's missing
validator-resource links were corrected and the same products reverified without
rebuilding; an invalid requested selector was rejected before native execution.

The first full system-diagnostic attempt timed out after 600 seconds following a
completed UI batch. Explained local follow-ups retained result bundles, logs,
screenshots, recordings, source/products and strict gates while omitting another
verbose system dump. Hosted defaults are unchanged. Every superseded source and
product snapshot is preserved with verified bytes/modes under the native archive.

[Verification and retained hashes](verification.json) identify the exact scopes.
This is focused local evidence, not full combined CI, minimum-iOS, physical-device,
human VoiceOver or App Store acceptance. No service migration or deployment.
