# Request outcome return · 2026-11-08

The confirmed request now returns to its refreshed original outcome, with later-page recovery and authority checks. The final affected primary/carried UI journeys pass strict2/2 on iOS26.2, including the named44point comparison disclosure. Earlier targeted model22 and UI6 results are retained with their exact source pins. Minimum-iOS17 full UI acceptance remains open after a matched XCTest instrumentation crash; no warning suppression was used. Final-source unsigned arm64 Release compilation and bundle checks pass.

## Original baseline failure

With original product commit **8f5adbf47217aa29f23f80f1d31e5d01a612b02c** plus only the frozen UI-test overlay, the complete selected request-pack journey failed at **“Confirmed Apply must return without another Cancel tap.”** Native exit was **65**, strict exit **1**, duration **205.034 seconds**, with zero runtime-warning occurrences recorded across the one examined test. This is a retained product-return failure, not a passing baseline or a fixed-source result.

The failure screenshot, already reviewed by root, shows **Review request** still open, **Cancel** visible, **Decision confirmed by the household**, and **Added to the plan**. The paired accessibility hierarchy contains the updated original request row behind that sheet (lines 78/82), the sheet/Cancel controls (98–102), and the confirmed/Added text (128/135). Fixture counters report one applied decision and one saved line. The evidence establishes a confirmed update with the review sheet still present at the return postcondition; it does not establish restored accessibility focus or successful later row assertions.

The test overlay replaces the former extra Cancel tap with a bounded ten-second disappearance assertion, then requires the original row and exact outcome to be visible/hittable without scrolling and checks single-row/effect counts. The baseline stopped at disappearance; later predicates were not reached. Existing case allowances remain 720/900 seconds. The selected case is `HouseholdRequestPackUITests/testReviewedCheapestAvailablePackUsesActualDecisionAndCancelHasNoWrite` on iOS 26.2 build 23C54, light appearance, Large text, increased contrast disabled, using the fixture Debug flags recorded in `baseline/run.json`.

## Retained evidence

- `baseline/inspection/`: native/strict verification, strict output, summary, tests and recorded-zero-warning receipt. The inspection confirms original result and source preservation.
- `baseline/failure-review/`: exact single PNG, exact hierarchy TXT, attachment manifests, bounded export receipt, agent analysis and root visual-review receipt. The image was displayed resized; its original bytes are retained unchanged. No physical-device or accessibility-focus acceptance is claimed.
- `baseline/source/`: original and overlaid 556-file hash manifests, preparation receipt, exact frozen test and test-only patch. Independent file checks confirm only `ios/UITests/HouseholdRequestPackUITests.swift` differs between manifests and all 556 frozen source files match the overlay manifest; the other 555 files remain unchanged.
- `baseline/failure-boundary.txt`: two exact console records with physical LF line numbers and the original full-log SHA-256. The full log is not copied.

The overlay test SHA-256 is `62240fc0e69fbaf958ab14f1e4df346f1d15d98a7dd147dedaa3cdbfde516858`; patch SHA-256 is `728e953c043ea25c8f6e6bde205235648b634cdd4aecb19a3afee4e66e9065b4`. `provenance.json` maps copied files to their exact original paths and hashes. The preparation receipt retains its earlier “no overlay yet” snapshot; the overlay manifest and completed run establish the subsequently executed state.

The original baseline remains failed. Fixed-source model and critical screen results are recorded separately below; the minimum-OS UI and Release qualification are pending. No result bundle, archive, full stdout or video is copied. `manifest.json` hashes all publication files except itself.

## Fixed model qualification

All 16 HouseholdRequestPackReviewTests cases pass native and strict verification (eight existing and eight added). This covers receipt/authority/revision readiness, held and failed refresh, later-page retrieval, cursor cycles and changed shop, known/newer outcomes, revocation and lost-reply/conflict states. Zero runtime warnings were recorded; source and original bundle stayed unchanged. `fixed-models/` contains exact selectors and receipts. The critical screen results below supplement these model results; model passes alone do not establish screen navigation or actual assistive focus.

## Fixed critical screen qualification

`fixed-critical/` records two selected cases passing native and strict validation on iOS 26.2 build 23C54, light/Large, with zero runtime warnings recorded across both examined tests. The original request-pack journey passed in 216.867 s and the later-page Lee return case passed in 194.897 s. The original baseline failure above remains unchanged. `source/causal-test-identity.json` records identical SHA-256 values for the baseline/fixed request-pack test method and its exact return assertion helper; this supports the before/after comparison without weakening that predicate. Exact fixed source manifest/patch, run command, selectors and preservation receipts are retained.

Activity metadata was inspected first. Exactly one final-return PNG per passed case was then exported by its exact attached filename from the completed inspection copy, under a 4,000,000-byte per-file limit and 45-second bound. Both exports succeeded; original result hashes remained unchanged. No video, full attachment export, app launch or test run occurred during evidence collection. Full activity trees remain in private scratch; their hashes and selected attachment metadata are retained here.

- Original request returned without manual dismissal: `fixed-critical/return-capture/png-0/ED422AC4-799A-4AFC-AE75-90B9BDACD1F8.png`.
- Later-page Lee returned to durable outcome without scrolling: `fixed-critical/return-capture/png-1/1DBFF268-F32F-42C2-B8BE-081520294909.png`.

These automated results establish the asserted sheet disappearance, original-row return and outcome predicates for these two cases. Physical VoiceOver focus remains unverified. The four related regression cases subsequently passed, as recorded below. Minimum-iOS UI and final-source Release qualification remain pending.

Root visually reviewed both final-return captures: original Sam and later-page Lee outcomes are fully visible after sheet dismissal. [Review](fixed-critical/root-visual-review.json) records the exact images and limits. Physical VoiceOver remains unverified.

## Related regression and minimum-OS models

All four selected related UI cases pass native and strict verification on iOS26.2: protected-lunch cancellation, carried request with current price, duplicate comparison with only Sam decided, and Spanish AX5 original wording/read-only comparison. The last two retain their existing extended scrolling journeys. Zero runtime warnings and zero runner restarts were recorded. [Exact results](fixed-regressions/inspection/strict.txt) retain durations, selectors and unchanged source/original verification.

All six existing meal-context model tests pass native and strict verification on iOS17.0/21A328, covering source-revision refresh, unchanged field commits, known/unknown meals, cancellation and access loss. [Results](minimum-ios-models/inspection/strict.txt). This supplements the 16 request-pack models on iOS26.2; it is not a whole-suite minimum-OS claim.

## Minimum-OS disclosure failure and follow-up

The first complete iOS17 request-pack journey failed before Apply: the comparison row was visible, but its stock disclosure exposed only an unnamed10.5×13.5point chevron Button beside a separate StaticText. The named Button query could not match. Native65/strict1,92.881s; original source/products/result preserved. [Root-reviewed failure](minimum-ios-original-failure/root-failure-review.json) includes exact screenshot and hierarchy. This is not evidence of failed outcome return on17 because the test never reached Apply.

The follow-up uses the app's existing `LabeledFormDisclosureStyle` on this one comparison and strengthens its primary test to require the exact label, collapsed/expanded value, ≥44point height, wide target and a label-side tap. The calculation and automatic-return assertions remain unchanged. The final current-OS and Release results below supersede that pending preparation state; minimum17 acceptance remains open.

The first labeled-disclosure follow-up passed the exact name/size/value/label-side expansion checks, then failed before quantity input because the first field had not acquired keyboard focus. Its frame652–696 extended beyond the667point viewport. [Retained second failure](minimum-ios-partial-input-failure/root-review.json) shows the clipping and no keyboard; this does not prove sole touch-failure causality. The subsequent test-only correction requires the existing fully-visible reveal before the same single field tap. Product source is unchanged; no timeout or retry allowance changed. Subsequent results are recorded below.

The full-visibility follow-up progressed through pack entry but the app process then crashed in XCTest's logging/accessibility instrumentation: null `strcmp` from the runtime-issue callback after libtrace high-volume quarantine. [Exact termination summary](minimum-ios-instrumentation-crash/termination-summary.json) binds the private report and matching compiled-product UUIDs. This matches earlier retained17 automation failures; it does not establish a business-logic fault or a successful minimum17 journey. No logging suppression was applied. Current-OS UI and unsignedRelease pass separately below, with minimum17 acceptance explicitly open.

## Final current-OS qualification

Both affected request-pack journeys pass native/strict on iOS26.2/23C54 against the final source: primary comparison/Apply/automatic return and carried-request current-price/Apply/automatic return. The primary case now also asserts exact named disclosure semantics, full-width44point action and collapsed→expanded state from a label-side tap. Zero recorded runtime warnings, zero runner restarts and zero observed animation-idle misses across2315log lines. [Exact results](final-current-ios/inspection/strict.txt). [Final source pins and patch](final-source/) preserve the two-line disclosure correction and full-visibility test precondition in addition to the earlier return fix. No minimum17 pass follows from this separate current-OS result.

## Final Release compilation

The final frozen source built successfully for generic arm64 iPhone using the Release scheme with signing disabled. Existing compiled-bundle checks pass. Source and preserved previous products remained unchanged. [Release receipt](final-release/run.json) and [bundle checks](final-release/bundle-check.txt). This is compilation/package validation, not an App Store archive, device install or resolution of the open minimum17 automation failure.

The fixture planner includes the new later-page test exactly once, for70cases total. Planner16, ordinary planner6, discovery7 and UI automation contract1 checks pass; localization/theme/project checks retain their recorded scope in [source checks](source-checks.json). The discovery tests mock native commands. Original failures remain failures; no test was skipped, muted or given a larger timeout to produce these passes.
