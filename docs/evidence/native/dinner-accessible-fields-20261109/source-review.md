# R2 source review

Reviewed candidate source manifest SHA-256 `e45a7cae9013d1510bdd5bd04a98cf09e747e87d39a7187ac950e2a370824623`. Every actual source file matched its manifest during the read-only check. The source root was `.build/EnglishKeyboardReviewNov08/current-r1/execution-r1/source` under `/Users/palatis/Room in the Cart`.

Comparison scope: R2 `source.json` against the prior product candidate manifest `7f68068a87a58630d4875a48bd9bbf40a39d8a42594d55a57a3c94523d3e1e1c`, the exact `test-followups.patch`, and surrounding test helpers. Only `ios/UITests/FreeJourneyUITests.swift` differs between those manifests; app source is unchanged.

No substantive regression or assertion weakening was found. Both Review buttons now use the existing scoped progress-aware helper, retaining the 24-gesture limit and following disabled/enabled acceptance, padding, contrast, five Done, saved-state and empty-list assertions. Root recognition requires a matching selected tab, matching visible navigation bar, no leading actionable Back control, and ultimately a hittable destination; it does not pass on title alone.

The two query substitutions preserve exact search names/identifiers and restrict results to native editable element types. They permit vertical text views while excluding the new static labels. Existing typing, coordinate checks, exact-value checks and Done checks are retained.

## Additional original cases affected

- `FreeJourneyUITests/testFreeDinnerProtectedLunchShortFillRepairSettlementAndNextShop`: its adjacent-field loop enters Ingredient name and Ingredient exclusions, one per line, then retains the existing value wait and Done dismissal checks.
- `FreeJourneyUITests/testDinnerMoveAcrossDisplayedWeeksKeepsLunchAndOccurrence`: its moveAcrossWeek-only loop enters Ingredient name and retains exact-value assertions. The English and Spanish dated-week list/grid cases do not execute this changed branch.

Qualification recommendation: run those two complete original cases alongside the planned original English and Spanish dinner approval journeys on the exact final candidate. The prior English Large product pass does not establish Spanish AX5 qualification. No additional probe or scope reduction is recommended.

## Persistent-label semantic review

Compared canonical baseline DinnerEditors.swift, DinnerIdeaSupplyViews.swift and workingTextField in Theme.swift with the isolated candidate helpers. Persistent visual labels are hidden only as duplicate accessibility elements; editable leaves retain explicit localized names, the same bindings and focus keys, and supply identifiers. No container combines or hides the editable children. Remove ingredient retains its wording, destructive role and original deletion closure. The additional body heading is intentionally an accessible header with its own identifier; it does not replace the native navigation title or Cancel.

No concrete accessibility semantic defect was found in this source comparison. Ingredient name and supply source intentionally become multiline editable controls; the scoped queries account for their native text-view representation. Numeric amount, yield and price remain horizontal. Keyboard Done visibility continues to depend on the same focus state, with focus modifiers on the editable leaves. Source review does not independently qualify VoiceOver traversal or multiline keyboard behavior; those are not claimed as proven by the retained screenshots.

Only this scratch report was written. No source, DerivedData, build products or native execution were changed by this review.
