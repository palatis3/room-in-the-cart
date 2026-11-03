# Screen placement and interaction audit

Keep **three tabs and 27 behavioral contracts** for the first release. A shopper comparing two packs needs Shop → Inspect an ingredient. A contributor needs one place to ask and check their own result. Making either person pass through all the pickup stages would defeat both uses. The following is the recommended compact-width presentation. Retain a contract ID when the same task adapts to a larger display.

| Presentation | Contracts | Reason |
|---|---|---|
| 3 tab roots | S01 Shop, S13 Dinners, S20 Records | Resume the current trip, work on meals, or find earlier evidence. Each preserves its own navigation state. |
| 15 pushed destinations | S02 list, S04 ingredient, S05 checkout comparison, S06 retailer handoff, S08 arrivals or private shortage entry, S09 meal repair, S10 cook handoff, S11 closeout, S14 familiar dinners, S19 seats, S21 grants, S23 inbox, S25 meal week, S26 dinner idea, S27 store quotes | These tasks can have long content, history or several edits. Give them Back and a stable return location. S19/S21 enter through settings or a contextual management link. S10 additionally has a grant-limited web rendering. |
| 8 contextual sheets | S03 pickup facts, S07 replacement offer, S12 next-shop selection, S15 pairing, S16 guest, S17 apply revision, S18 Household offer, S24 request decision | Each answers a decision in its parent. Use a scrollable full-height sheet at large type. Move from one review step to the next within the same presentation. Cancel returns to the origin with focus restored. |
| 1 scoped contributor destination | S22 request and own status | Native scoped session or invite on mobile web. The contributor sees no adult tab bar, checkout total, or other author's requests. |

Settings, system permission prompts, confirmation alerts, empty states and helper renderings appear where their task needs them. Count these separately for implementation estimates. Promote a sheet to a pushed view if testing shows people routinely need navigation history or lose work on dismissal. Add a tab only if repeated cross-task navigation shows an independent, frequent destination.

## Corrections from the source and implementation audit

The earlier-generation audit identified the following behaviors that needed either a clearer home or a stronger persistent invariant. The feature register retains every launch ID and identifies its tier, screens, build ticket and acceptance case. G10–G11 supply the register and two-shop walkthrough, G12–G15 refine that baseline, and A01–A03 add the owner's release decisions. G5 undo, G8 order-time fees and G9 deferral survive as regression cases.

| Source or gap | Owning surface and contract | Acceptance example |
|---|---|---|
| G1 available cash | S03/S05, private session calculation | $2 of budget headroom and a $4 authorization shortfall can coexist. |
| G2/G7 impossible yield | S04/S08/S15, quantity and allocation rules | Reject 4,176 g of same-form carryover from a 20 oz pack. A dependent meal stays unresolved. |
| G3 elapsed prep time, adopted for the manual recipe path | S14 records known lead time. S09 evaluates it and S10 conveys the result. | A two-hour marinade misses a 45-minute deadline unless enough of the required step is already complete. |
| G4 retailer-facing instruction | S07, D10 | At $6.49/lb with $19.99 available, the fixture's cents-rounding rule permits 3.08 lb. Copy the scoped ceiling and fallback. The offer remains pending. |
| G6/G12 dinner selection | S14/S15/S25/S17 | A candidate, a selected undated dinner and a dated occurrence have separate effects. The next pairing preview uses the current schedule and accepted revision. |
| G13/G14 shopping list recovery | S02, B02 | Restore by ID across checked, handled and trashed rows. Original source order survives store changes and local sorting. |
| G14/G15 capture entry | S04 package, S08 receipt, S14 recipe, E02 | Correct OCR while retaining the original. Capture alone creates no price or fulfillment fact. |
| G12/G15 recipient updates | S10/S17, P06 | A Free adult can correct and resend manually after lapse. Automated recipient differences require Household and relevant grants. |
| G15 share lifecycle | S10 create and open, S21 revoke, S17 proposal review | An editor proposes. Only the shopper applies. A revoked recipient cannot refresh. Previously sent text remains usable. |
| First-install urgent repair | S01/S08/S09/S10, B04 | One private need and cook handoff can exist before any order. |
| Placed order line membership | S06, B04/B07 | One transaction stages and seals the original rows. Reject a late line. Append a separate confirmed amendment. |
| Manual stock lacks food identity | S04/S08/S09, B04 | Give each manual lot a label. Require a reviewed match before reserving a lot for a particular need. |
| Period scope and currency | S20, B08 | Reject currency mismatches. Limit a partial reader to independently visible amounts without revealing a hidden shop or implied remainder. |
| G14 spoken guest shortcut | S16, B08/B09 | Typed and spoken review use the same planner, entitlement gate and apply-once command. |

## Four walkthroughs to build first

| Job | Path and return behavior | Evidence required on the native build |
|---|---|---|
| Pick a pack now | S01 → S04. Return to Shop at the same scroll position. | New, offline installation. Compare equivalent usable quantities. Leave an unknown yield unresolved. No account or setup questions. |
| Decide on Sam's cereal | S01 → S23 → S24 → same S23 row. | Sam asks once. Mia sees current and proposed checkout, two protected lunches and the $2.69 overage together. Deferral keeps $37.20. Accepting the overage produces $40.69 once. Only Sam's outcome returns to his view. |
| Rescue tonight without an order | S01 → S08 private shortage → S09 → S10. | Reopen the local need after a restart. Confirm available food and timing, retain lunch reservations and prepare a dated cook message. Zero order, delivery or financial records. |
| Choose dinners before choosing nights | S13 → S14 → S25, optional S16 → S17. | Accept as candidate creates no demand. Choose for this shop creates one occurrence. Assigning Tuesday moves the same occurrence. A cancelled guest preview restores the week and current basket. |

## How the screens should feel

In Shop, give the active pickup, its next action and any pending requests priority. Keep quick pack comparison and urgent repair within one selection from the root. Put frequent list entry and search above the scrolling list. Use short food names and fixed-position, tabular amounts. At large type, stack the amount directly beneath its label. In Dinners, photographs can help identify saved meals. In a checkout decision, use the same space for the affected dinner, amount and next action.

In the request decision, the shopper sees the projected total first, the overage in words next, and the two numbers that explain it beneath. Give the affordable next-shop choice the filled spruce action in this worked example. Keep the over-cap choice available and ask for explicit acceptance. After a decision, return to its original row and focus the durable outcome label. A repeated tap cannot create a second effect. When the server has not accepted an offline request, label the local and shared states separately.

Use the system navigation and sheet transitions. For custom feedback cap press emphasis at 100 ms, selection at 160 ms, detail disclosure at 180 ms and a confirmed local change at 120 ms. Do not animate currency counting, reorder rows under the finger or play a success haptic for an uncommitted preview. On dismissal, interruption or Reduce Motion, show the final state immediately. With VoiceOver, move focus to one concise result and avoid a duplicate announcement. Large type, Reduce Motion and dark appearance each need their own fixture.

**Inspected evidence.** The [interactive request study](experience/Motion%20study.html) runs offline in a browser. Captured states show the [inbox](experience/01-inbox.png), [request decision](experience/02-decision.png), [deferred result](experience/03-outcome.png) and [overage confirmation](experience/04-overage.png). The study exercises review, cancel, defer, accept and the reduced-motion control with fictional data. Its local page state resets when reloaded. It is one interaction sample. The build still needs real storage, service authorization, iPhone frame measurements, VoiceOver and the complete set of 27 route checks.

## Competitive comparison and release gate

| Baseline from the publisher | What the family should be able to do here |
|---|---|
| AnyList offers shared lists, quantity notes, recipe import, price entry and grocery lists from a meal calendar. [AnyList feature list](https://www.anylist.com/features) | On an ordinary shop, add and check an item as quickly as the family normally would. Surface the extra decision only when an item affects the whole pickup or a protected meal. |
| OurGroceries describes household list updates, item photos and aisle grouping across devices. [OurGroceries overview](https://www.ourgroceries.com/overview) | An invited person can ask from a mixed-phone household in one scoped destination. Measure the author's effort and the shopper's effort separately. |
| Paprika combines similar ingredients, builds aisle lists and supports reusable menus. [Paprika features](https://www.paprikaapp.com/) | Show what six usable wraps can actually cover after two lunches are reserved, then hand the cook a correction. Measure whether both people can explain what is still missing. |

The potential advantage is the point where a shared-list change affects both the full checkout and a meal already promised. Publisher descriptions establish baseline capabilities. They do not establish comparative speed, ease or preference.

**Proposed formative test.** Counterbalance app order with at least eight target shoppers, including mixed-phone households, and use the same device, quantities, prices and time limits per paired task. Record comparator version, tier, starting state and any manual workaround. Test ordinary list entry, a capped request, a short-fill with protected lunches and a corrected cook handoff. Log unassisted completion, elapsed time, backtracking, wrong financial/food conclusions, who did the work and blind-rated clarity of the final instruction. Ask separately which they prefer and why. For this small study, advance if at least seven of eight finish each critical task unassisted, nobody mistakes a financially wrong or under-covered plan for a good one, median ordinary entry time is within 10% of their normal workflow, and at least six of eight prefer this app for the exception workflow. If a gate misses, revise the failing path and retest. This is a design decision gate, separate from the longer household pilot.

**On-device sign-off.** Test on the oldest supported iPhone class and a current device, with the production navigation stack, largest Dynamic Type, both appearances, English/Spanish, VoiceOver, Reduce Motion, keyboard open and interrupted sync. Record a repeated 30-interaction run on device with Instruments, investigate visible hitches or repeated missed frame deadlines against the device's refresh cadence, and record permission denial, double tap and navigation interruption. Confirm every result remains legible and correct without animation. A judge can accept these specifications before any of these device or household results exist.
