# Design system and interaction contract

**One person should be able to read the next decision while standing in a grocery aisle.** Lead with the item or meal, give the quantity and its consequence, then one primary action. On a $38 cap, the hero reads “Expected checkout $40.69 · $2.69 over $38.” Keep the fee basis and unknowns beside it. For a contributor the same event reads “Cereal · Saved for next shop.” Do not render the adult card underneath a privacy overlay.

The retained visual studies show [light and dark checkout](references/grocery28/Recommended%20appearance.png), [shop and arrival screens](references/grocery28/Working%20screens.png), [household requests](references/grocery30/Family%20inbox%20study.png), [text hierarchy](references/grocery29/Typography%20study.png) and [motion](references/grocery28/motion-study.gif). They illustrate behavior. Register, permission and state contracts govern any older labels in the images.

## Color placement

[theme.json](contracts/theme.json) is the token source. Generate named colors in the iOS asset catalog and CSS custom properties for web from the same file. A build check compares the generated values. Views reference roles such as `Theme.action` backed by `accent`. Raw hex values belong only in that generation step. Follow device appearance by default and offer System, Light or Dark in device settings.

| Role | Light / dark | Where it belongs |
|---|---|---|
| Canvas | #F7F5EF / #121A17 | Page behind the working surface, including empty states. |
| Surface | #FFFFFF / #1C2923 | List sections, sheets and editable cards. Keep most of the shop quiet. |
| Ink / secondary | #172925 / #F4F5EC; #475D55 / #B4C4B9 | Money, quantities and essential state use ink. Source, store and update time use secondary. Never fade a shortage into a caption. |
| Primary action and its label | #195848 with #FFFFFF / #91DBBB with #112A21 | One filled action per decision, such as Review request or Apply. Use a labeled secondary button for Next shop or Cancel. Spruce does not certify budget, availability or retailer success. |
| Selection | #E3EEE6 / #263C32 | Selected option, with checkmark, text and selected accessibility state. |
| Attention | #835009 on #FFF1D3 / #F4C375 on #372B19 | Overage, missing quote, expiring offer. Name the condition and remedy. Overage is a valid explicit choice, not a system failure. |
| Error | #9C382D on #FBE9E5 / #F6A899 on #402624 | Failed save, invalid amount, denied action or destructive confirmation. Keep editable input. |
| Focus / interactive edge | #245F9C / #9ACBF5; #66796E / #90A797 | Keyboard focus and controls that need a visible edge. Divider #D9E1DA / #3B5145 is decorative only. |

Build a small component gallery, available in debug builds, for both modes, both locales, increased contrast, RTL layout stress, and largest accessibility sizes. Check opaque normal text at 4.5:1 and meaningful control boundaries at 3:1. Test rendered controls over actual backgrounds. States also need words, symbols, and assistive labels. [Apple color guidance](https://developer.apple.com/design/human-interface-guidelines/color)

## Type, layout and interaction

Use native dynamic text styles or their web equivalents. Expected checkout uses large title (~34 pt) with tabular digits. Section titles use title/title 2 (~28/22). Body, quantity, controls, deadline and shortage use body/headline (~17). Provenance uses subheadline/footnote (~15/13). Optional system serif is reserved for a short dinner title. Align comparable numbers; keep amount and currency together. A narrow or very large layout stacks cards vertically in reading order. Never ellipsize the unit, excluded ingredient, monetary qualifier, date boundary or action.

Use 16–20 pt side margins, 8 pt between related facts, 20–24 pt between groups, at least 44 × 44 pt hit areas. Keep the checkbox independent of row detail; provide accessible named actions and a visible equivalent to every swipe. Scroll oversized sheets. Avoid promotional banners during shopping/cooking. Use real item names with icons; offer photos primarily where the family chooses a meal.

| Reusable component | Content and behavior contract |
|---|---|
| ShopContext / status strip | Shop, branch/mode, dated slot, last local save and last confirmed sync. Display Pending, stale or locked with text. Do not collapse all of these into a green “Saved.” |
| MoneyComparison | Before/after, cap scope, known components, missing components, source/time and difference. Align numbers; VoiceOver says basis, value, direction, over/under and uncertainty in that order. |
| QuantityRow / allocation detail | Original literal, number of packs, usable per pack and purpose. Checked, deleted, handled, reserved and purchased are distinct. Recently checked remains reachable after Undo expires. |
| RequestRow / DecisionSheet | Own-status variant for a contributor; household-private actor, duplicates and delta for the shopper. Show destination and freshness before confirming. Default disclosure differs by role. |
| ChangePreview | Current vs proposed on the same basis, affected meals and protected lunches, Apply/Cancel. Disable duplicate submit while awaiting durable result; on stale data show the changed facts and require a fresh review. |
| MealCard / WeekDay / IdeaDraft | Distinguish approved candidate, scheduled dinner and actual cooked outcome. Day shows confirmed serving groups and unresolved demand. A new idea starts as an editable proposal. |
| QuoteComparison | Columns for shop A/B, scope, availability, freshness, checkout, incremental travel money and travel minutes. Stack at large type. Never color an incomplete option as the winner. |
| CookInstruction / HandoffPreview | Self-contained text with date, version, actor's chosen language and confirmed quantities. Buttons to copy, share, speak or print. Reset optional disclosures every time. |
| Empty / offline / permission / conflict panels | Explain what can still be done. Show “Type item” on camera/speech denial; local draft on offline failure; visible retry and correction on conflict. Never lose focus or saved text. |

**Movement.** Press ~100 ms, selection emphasis ~160 ms, explanatory reveal at most 180 ms, durable local-save emphasis ~120 ms. Keep money and units still. Respect Reduce Motion with immediate in-place updates; optional haptic follows a verified local action. An in-flight animation never delays commit or announces success. On interruption, pause/stop spoken output; do not compete with VoiceOver or automatically restart.

**Translation.** Separate UI locale, recipient language, source food wording, unit basis, zone and currency. Currency stays USD for a US shop when the interface changes. Use structured localizable strings with plurals, numbers and full dates. Grocery notes remain user-authored; preserve the original next to any reviewed translation. Compare “two 15 oz cans, no salt added” across en-US and US Spanish text, spoken output and paper. A Spanish-first contributor must complete invite, entry, correction and status without switching to English. Test mixed-language names and left-to-right numeric fragments in RTL layouts. Ship human-reviewed purchase, support and deletion flows in both launch languages.

**The first impression.** Use the owner's chosen name on app, invite, export, print footers and purchase UI. Suggested listing is “Room in the Cart: Grocery List” and “Family Meal Planner & Budget.” Keep store copy subordinate to the actual shipping build. An unconfirmed retail transfer, a proposed $49.99 price, or a research example must not become a store promise.

Use [the launch handoff](09-keywords.md) for the exact draft fields, supporting screens and evidence. The name on the Home Screen, invite and export is **Room in the Cart**. The listing descriptor is store metadata only.
