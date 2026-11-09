# R2 Spanish AX5 retained screenshot review

Done separation and the sampled post-tap retained state are supported; product readability limitations remain. Not a complete AX5 accessibility pass.

Scope: five before/after Done pairs plus their five geometry and five target-before records. All files are referenced and hashed in visual-review.json. Nothing was exported, rebuilt or executed.

Every before screenshot renders Listo fully on its own row, below the navigation title and separate from Back/Cancelar. Every after screenshot has no Listo or keyboard. Retained geometry records equal before/after values, retained editor/sheet, a 115.33 × 63.33-point Done frame and a 44 × 44-point sampled region; Done starts 8 points below the navigation frame. These are sparse samples, not an exhaustive touch-target or Cancel qualification.

| Pair | Observed result | Visible limit |
| --- | --- | --- |
| cleared_amount | Blank amount is consistent with a space but exact whitespace cannot be verified visually; it is retained in geometry. Done and keyboard disappear; editor and Tortillas remain. | Notes/exclusions prompts visibly ellipsized after Done. Removal wording is ellipsized and partly behind the tab bar at this captured scroll position. Amount has no persistent visible purpose label. |
| restored_amount | 4 is fully visible before and after Done; keyboard and Done disappear; editor and Tortillas remain. | Notes/exclusions prompts and removal label visibly ellipsized after Done. Amount purpose is absent once its placeholder is replaced. |
| supply_yield | 8 is fully visible before and after Done. Keyboard and Done disappear; Cancel and the same supply sheet remain. | Native inline sheet title visibly ellipsized before and after. 8 has no persistent visible Usable amount per pack label; Observed pack, optional is group context only. |
| supply_price | 2.50 is fully visible before and after Done; 8 and the units control remain visible. Keyboard and Done disappear; Cancel and the sheet remain. | Native inline sheet title visibly ellipsized before and after. Price per pack in USD disappears when the value replaces the placeholder; 2.50 alone omits that purpose and currency qualifier. |
| supply_source | Bag label is fully visible before and after Done; 2.50 remains visible. Keyboard and Done disappear; Cancel and the sheet remain. | Native inline sheet title visibly ellipsized before and after. Evidence source disappears when the value replaces the placeholder. The red dotted underline under Bag is visible; this review does not infer a validation error from it. |

The supply inline title is ellipsized in all six supply frames. Its complete accessibility name would not make that rendered title complete. The filled values 8, 2.50 and Bag label are readable, but their original quantity/price/source purpose labels are absent after the placeholders are replaced. The ingredient after frames retain visibly truncated notes/exclusion/removal wording.

Scrolled content appears under translucent navigation/tab chrome at some positions. The images do not establish that this content is unreachable. Light supply placeholders warrant measurement if assessed for contrast; no contrast ratio was calculated here.

The original run failed later during root recovery. These observations support the five sampled Done interactions only; they are not full-journey, global accessibility or release acceptance.
