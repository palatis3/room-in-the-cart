# S14 run1 Notes accessible-purpose failure

**The Notes value remains visibly present, but the same editable-purpose query no longer finds it after filling.** The production fix candidate remains the one-line localized Notes accessibility label; the exact S14 UI assertions stay unchanged.

The copied run1 shows Notes matching an editable field at39.01–39.39s, successful typing at40.26–41.65s, Done at41.91s, then no match for the same Notes/editable-type query beginning42.65s. Bounded reveal fails at103.569s. Source URL, allocations and persistence actions were never reached, so this run does not fail or accept the broken-link planning clause itself.

## Inspected allowlisted artifacts

Exactly the pre-fill snapshot, first-post-Done snapshot and `Free-flow-failure` screenshot were exported from the immutable copied `run1/inspection/S14.xcresult` to this folder. `extraction-manifest.json` binds payloadIDs, timestamps, SHA256 and export results. The original result was not edited.

Both UI snapshots are binary NSKeyedArchiver plists. They were parsed with Python plistlib, resolving the root, class, elementType, children and value UIDs. The pre-fill archive has27objects; the post-Done archive has29. Each contains exactly one XCElementSnapshot: application elementType2 with402×874frame and an empty children array. **Neither archive contains editable field AX nodes.** Therefore neither the Notes label/type nor its change can be established from these attachments. `*-elements.json` records the resolved available root data; this is not a string-search inference.

The1206×2622failure screenshot visibly shows the entire entered text, “Warm the wraps and serve the lentils separately.”, in its original form row. The row is above the blank source URL and fully in the viewport, with no keyboard covering it. That excludes erased text, an offscreen row or keyboard occlusion as the immediate reason the purpose query finds nothing at failure. The precise field AX label/type is unavailable in the exported root-only snapshots; name/trait mapping remains the narrow mechanism inferred from source and the observed query transition.

## Focused production proposal

`DinnerEditors.swift` is byte-identical to run1, SHA256 `7e5bbe3087a6dc8ca13a48ec3f0dfeaab0c91142ee372e36fe1682360ff06286`. Notes uses a vertical SwiftUI TextField with placeholder text and focus, but no explicit accessibility label. The proposed `notes-persistent-label.patch` adds `.accessibilityLabel(dinnerText("Notes"))` to that actual field. Existing Dinners localization supplies Notes/Notas.

This keeps the purpose independent of the value, following the already-used approach for the sibling Ingredient exclusions field and the shared meal evidence editor. It adds no test-only identifier, no locator based on entered value, and no visual label or layout change. The proposed source hash is `0c32312815fb9de54ba411840d1a6300a15ce4163b8c25544c7e916dc1e73a67`.

Sibling review is in `source-manifest.json`: same-component Hard exclusions, Completed steps and Ingredient notes share the unlabelled multiline pattern; separate idea fields also use it. Run1 did not fill those fields, so the candidate does not expand into unobserved fixes. Ingredient exclusions already has a localized explicit label.

## Root validation

Use root's fresh isolated source copy with this production-only line and the exact unchanged S14 UI selector. The run must show the existing Notes/editable query reading the exact value after Done, then execute all subsequent source, serving, binding, restart and original-recipe assertions. Do not query by entered value, remove Notes from the flow, weaken post-fill/readback checks, or count initial entry as the full S14 clause.

The decisive comparison is run1's failed same-purpose query versus the corrected run's successful exact-value query and after-restart readback. If the corrected run still fails, retain it and inspect a fresh full accessibility hierarchy; do not assume the root-only attachments contain field metadata. An optional `app.debugDescription` attachment immediately after filling Notes may retain that hierarchy without changing any assertion, but the existing strict case can run unchanged.

This supports a test-observed accessible-purpose correction if validation passes. It is not a human VoiceOver or Spanish execution claim. No native build/test, simulator operation, main-source edit, Git operation or raw Records/media access was performed in this investigation; the only newly authorized native tool calls exported the three specified synthetic artifacts.
