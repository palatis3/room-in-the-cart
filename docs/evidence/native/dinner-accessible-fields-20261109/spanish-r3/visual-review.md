# R3 Spanish AX5 retained visual review

Reviewed all 11 exported screenshots (five Done pairs and the full-heading capture) plus all 10 geometry/target records. Source manifest: `1173047f5a367d44384a7d64919ab117c85bc45929f880d266eee5ae707f1573`. Evidence paths and hashes are recorded in visual-review.json.

The original journey did not pass: native65/strict1, zero animation-idle messages. Its unchanged 720-second allowance expired while relaunching the app. All five Done probes and heading evidence completed, but post-relaunch persistence and empty-list assertions remain unverified.

## Ingredient identity and amounts

Both amount geometry records use ingredient.60FAD324-EDB2-472A-B387-829051D60301.amount. Clear retains exact whitespace; restore retains 4. Screens show Tortillas and unidades for clearing, and 4 with unidades after restoration. No cabbage/cups substitution remains in these records.

## Ingredient label visibility

Cantidad, opcional and Notas del ingrediente wrap without ellipsis in fully visible sampled portions. Tortillas is fully readable. Nombre del ingrediente and the full exclusions wording are partly outside the viewport or under chrome; Remove ingredient is not shown. These captures cannot qualify all ingredient labels or removal wording.

## Supply heading

The complete body heading Revisar el abastecimiento del ingrediente is visibly rendered, with a line-break hyphen within abastecimiento. The native inline navigation title remains ellipsized. Full AX text is not a claim of full inline rendering.

## Supply values and purpose

Before/after pairs show complete wrapping purpose labels Cantidad aprovechable por paquete, Precio por paquete en USD, and Fuente de la información, with values 8, 2.50 and Bag label retained. Bag has a spellcheck underline, not truncation.

## Done and navigation

All five before images show complete Listo separately below native navigation and apart from Back or Cancelar. All five after images show no keyboard or Listo. Geometry confirms editor/sheet retained, 115.333 by 63.333 point Done frame, a contained 44 by 44 region and five sparse center/top/bottom/left/right samples. Done begins 8 points below navigation.

## Remaining observed truncation

The full-heading screenshot visibly ellipsizes the selected value of the matched-food picker (rendered as Sin c...rmada). The full picker label wraps, but its selection is not fully rendered in this capture. This existing adjacent control is not covered by a global visual pass.

## Scope limits

- Original journey failed: native65/strict1; 720-second allowance expired at app relaunch. No overall journey pass or post-relaunch persistence/empty-list qualification.
- Only the 11 retained screenshots and 10 geometry/target records were reviewed. No new exports, native execution or source changes.
- Geometry samples do not qualify every point of a touch target; Cancel target size, VoiceOver traversal, other devices/OS versions, dark mode and long input values are not independently qualified.
- Viewport clipping/transparent native chrome in scrolled screenshots does not by itself prove unreachability; unobserved text is not counted as visually complete.
