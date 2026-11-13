# Supply editor readability addendum

Proposal only; no additional patch or source change. The existing ingredient proposal remains unchanged.

The R2 screenshots establish two separate visible limitations in IdeaSupplyEditor: the inline navigation title is ellipsized, and entered yield/price/source values replace their only visible purpose labels. Preserve the native inline navigation title and Cancel toolbar control; add a complete wrapping, body/headline-sized in-content “Review ingredient supply” heading at the start of the Form. Keep it scrollable so it does not permanently displace the keyboard editing viewport or the existing Done row. A visible full heading provides an explicit route to the complete title; the inline title may still truncate, and that limitation must be described accurately.

For ideaSupplyYield, ideaSupplyPrice and ideaSupplySource, add persistent wrapping labels with the existing localized wording. Keep the native editable field, its existing identifier, field enum focus binding, conditional budget visibility, and keyboard Done ownership. Do not apply focused to the wrapping stack, suppress Dynamic Type, cap field lines, abbreviate the currency qualifier, or alter values on entry. Retain the unit control and all domain validation.

If full long field values require vertical growth, treat the name/amount newline and XCTest element-type risks already documented in the ingredient proposal as applicable here. Source values especially can exceed a single line; visual completion needs measured long-value examples. A label-only change solves lost purpose but does not by itself prove arbitrary values are untruncated.

Qualify English/Spanish, empty/entered/long values, default size and AX5, supported OS versions, keyboard open/closed, all five original Done probes, unchanged Cancel, and persistence after applying reviewed details. Verify the full content heading is actually reachable and readable. Do not claim that a full accessibility title or the present passing Done assertions substitute for this visible-content review.
