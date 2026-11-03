# Keywords and App Store handoff

An invited person asks for cereal, the shopper sees the price change, and the requester can see “Saved for next shop.” Use that sequence for the first US iPhone listing test. It puts a familiar search, **shared grocery list**, next to a behavior a screenshot can prove. The default English fields below also cover meal planning and budgeting. They are a draft for a verified release; no App Store record has been created.

| Field | Draft A · US English |
|---|---|
| Name | Room in the Cart: Grocery List |
| Subtitle | Family Meal Planner & Budget |
| Keywords | shared,shopping,dinner,weekly,pantry,pickup,menu,voice,household,cost,freezer,organizer,portion |

The name uses 30 characters, the subtitle 28 and the hidden field 95 UTF-8 bytes. Keep “shared” in the hidden field because it is absent from the visible fields. Search phrases are combinations to test; do not paste a list of whole repeated phrases into the field. Space in the field is optional. Remove any unsupported word before release. Recheck actual company-name duplication, storefront name availability and rights, locale-specific limits, proofs and screenshots in App Store Connect. [Apple product page guidance](https://developer.apple.com/app-store/product-page/) · [Apple field reference](https://developer.apple.com/help/app-store-connect/reference/app-information/platform-version-information/)

| Phrase to test | US English volume / difficulty | What the submitted build must show |
|---|---:|---|
| meal planner grocery list | 48 / 4 | S04/S14: a familiar dinner creates the correct pack demand and protects lunch. One reusable dinner is Free; assisted reuse is Household. |
| shared grocery list | 31 / 0 | S22–S24: invite, review, defer, then read own status. No family member can silently change the cart. |
| grocery budget | 41 / 0 | S03/S05: show the cap's scope, whole checkout and any unknown charges. |
| budget meals | 38 / 13 | S04/S15: show cost for enough food for the same meals and lunches. Identify paid pairing if shown. |
| grocery list organizer | 27 / 0 | S02: import, edit, group and restore a real list. |
| dinner planner | 36 / 2 | S25: an adult plans the week; moving dinner does not move a protected lunch. |

The scores are AppTweak panel observations carried forward in the research captured through November 2, 2026. They are relative scores, not traffic, conversion or installs. Difficulty zero is a reported score. A missing metric stays missing. Historical competitor rankings and Top Installs membership are separate evidence; neither predicts a download or the app's future position.

**US Spanish.** Start testing *lista de compras* for the shared list. Compare *menú semanal* and *planificador de comidas* for the meal week with the separate Spanish evidence. Do not carry English scores into Spanish. A US Spanish reviewer must verify meaning on the real screens, including whose budget is visible and whether a request was merely received or actually bought. Count accented UTF-8 bytes in the final hidden field and check it in App Store Connect. No approved Spanish listing copy yet.

**What can earn a keyword.** A meal calendar can support dinner planning, an editable idea can support meal inspiration, and manual two-store quotes can support explaining total trip cost. These are product-fit hypotheses, not new search measurements. Avoid competitor and retailer brand names, live inventory, automatic coupons, ordering or delivery, guaranteed savings, allergy certification, general family calendars and unrestricted AI recipes. A real receipt is not a bank connection. A scoped Android web invite is not a native Android app.

**When ready to submit:** (1) verify the corresponding screens in the actual candidate build, including language, access tier and permissions; (2) open the workbook's **Start here**, **Listing workshop**, **Listing copy** and **Priority phrases** sheets; record the exact fields, screens and baseline; (3) refresh the six searches in the same storefront, language and device class and record the dated organic results; (4) change one theme, compare equal windows in the **Release log**, and record impressions, product page views and first-time downloads from comparable App Store Search traffic. Record promotions and seasonality. The aggregate result cannot identify a single keyword as the cause. The account owner authorizes publication separately.

**Included evidence:** [editable keyword planner](launch/Room%20in%20the%20Cart%20keyword%20planner.xlsx) · [machine-readable Draft A](launch/listing.json) · [original evidence archive](launch/Gen%2015%20keyword%20evidence.zip). The workbook retains the 383-phrase reviewed English bank, historical and Spanish evidence, exclusions and alternative branded drafts B/C. Its original 19 intent categories are research classifications; three extra Feature guide rows connect A01–A03 to the current release. The archive is historical, including prior names and scopes. For building or publishing, use this foundation's decisions.
