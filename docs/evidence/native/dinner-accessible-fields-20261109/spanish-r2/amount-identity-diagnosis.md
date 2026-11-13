# R2 Spanish AX5 amount identity diagnosis and R3 review

Candidate source manifest SHA-256: `e45a7cae9013d1510bdd5bd04a98cf09e747e87d39a7187ac950e2a370824623`. This is a read-only source/log/retained-export review; no source, DerivedData, native execution or exports were changed.

## Established failure

The original Spanish journey failed at FreeJourneyUITests.swift:1704 because acceptance remained disabled after the second Review. Both amount Done probes passed; supply entry was not reached. The test restored 4 into cabbage instead of the originally cleared Tortillas field.

- `spanish-ax5/inspection/screens/F2ED3CEE-9C9D-4B9B-BA18-CB4B637DD062.png` shows the cleared Tortillas field with unit unidades.
- `spanish-ax5/inspection/screens/C4C02211-9084-49D1-B38B-63E37E04DA36.png` shows restored 4 with unit tazas.
- `spanish-ax5/inspection/scroll/72B70D4E-793D-433A-A2DF-C63D2BB60775.txt` searches backward from the lower form and finds the first materialized Amount field after seven gestures; its identifier is empty.
- `spanish-ax5/inspection/scroll/7B090571-995C-4EAD-B654-5D072D3973D5.txt`, gesture 2, records Tortillas, Cantidad sin resolver; Frijoles cocidos, 1 taza; Repollo rallado, 4 tazas. The same trace later records cabbage's recipe need as 4 cups.
- DinnerPatternCatalog.swift:34 seeds cabbage at one cup. native.log:2181–2190 deletes one existing character and types 4 into the duplicate localized Amount query.

The global editableElement(amountLabel).firstMatch query can resolve to a different lazily materialized ingredient after scrolling. It does not preserve the originally selected row. Exact-value Done assertions establish retention in the queried field, not identity continuity across the review transition.

The app paths are consistent with this diagnosis: dinnerDraftBinding resolves the existing UUID on every get/set; DinnerIngredientDraft.ingredient converts its own amount; DinnerEntry.quantity maps whitespace to nil; review rebuilds the template from every draft ingredient; DinnerIdeaEngine.review rejects acceptance when any quantity is nil. No binding or persistence defect is demonstrated by this failure.

## Proposed R3 assessment

Adding accessibilityIdentifier(key) to the ingredientField editable leaf uses the existing ingredient.UUID.field focus identity. It leaves localized accessible names, focus keys, bindings and domain behavior intact. Retain the exact field identifier as an immutable string after the initial amount reveal, validate the ingredient/UUID/amount shape, and use that captured ID for both clearing and restoration. Do not substitute a row position, dynamically resolved duplicate label, or a hardcoded fixture UUID.

Read the initial identifier and original value from the same revealed field/snapshot where practical. Re-query that identifier for mutation and continue requiring the same identifier during the before/after Done evidence. Since the helper can also accept labels, the captured-ID path must use the generated identifier, never replace it with the localized label later.

An optional expectedPriorValue argument to fill, checked after its existing reveal and before deletion/typing, is the clearest minimal state assertion: use the original amount for the clear and exact whitespace for restoration. This prevents an extra reveal from acquiring a second gesture allowance. If a separate pre-reveal is used instead, it must be the single discovery operation, with fill performing no further gesture search; merely expecting its second reveal to return immediately does not structurally preserve the budget on a failure.

Keep the original 24-gesture limit, coordinate-center amount taps, five Done checks, disabled/enabled acceptance assertions, contrast/padding checks and full persistence/empty-list journey. Stable identity may require traversing farther than the incorrect cabbage target; do not widen the gesture limit preemptively.

## Query compatibility audit and documented resolution

Independently read Apple's official Markdown documentation for both [matching(identifier:)](https://developer.apple.com/documentation/xcuiautomation/xcuielementquery/matching(identifier:)) and [matching(_:identifier:)](https://developer.apple.com/documentation/xcuiautomation/xcuielementquery/matching(_:identifier:)). Both document matching across identifying properties, including the accessibility identifier and label, rather than requiring the identifier property alone. Adding a nonempty unique identifier therefore preserves the documented localized-label lookup behavior.

The concrete independent helper at FreeJourneyUITests.swift:685–688, local field(_:) in `testUnavailableRecipeSourceLeavesServingsAndPortionAllocationEditableAfterRestart`, uses matching(identifier: name) followed by editable-type filtering. It reads Ingredient name and Amount at lines 759–760, 792, 824 and 836–837. That helper and editableElement can remain unchanged under the documented contract. My earlier suggestion to make their label fallback explicit was precautionary, not an established defect; the official documentation resolves that uncertainty. No additional helper modification or unavailable-recipe qualification run is required by this finding.

SharedMealIdeaUITests uses Ingredient name in a separate unchanged household editor. DinnerDecisionSheet queries target dinnerGuestServings, not these fields. No further concrete affected direct queries were found in the UI-test source audit.

The final proposed R3 remains minimal: add the leaf identifier, capture the selected amount's stable identifier after its initial reveal, use it for both fills, and check expectedPriorValue after the single existing reveal/tap but before deletion/typing. Check the original amount before clearing and exact whitespace before restoring. This retains all original state and Done assertions without adding a scroll budget. No objection to this revised approach.

The existing two additional original qualification cases remain `testFreeDinnerProtectedLunchShortFillRepairSettlementAndNextShop` and `testDinnerMoveAcrossDisplayedWeeksKeepsLunchAndOccurrence`, due to the earlier R2 query substitutions. No new probe or weakened scope is recommended.
