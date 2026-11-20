# What the November 9 ASO research changes for launch

Reviewed November 20, 2026. The source is the supplied Room-in-the-Cart-ASO-V3-2026-11-09.zip. Paths below are relative to its aso-v3-2026-11-09 directory. The package combines archived AppTweak measurements, public Apple catalog observations, publisher screenshots, recent competitor reviews and proposed creative. The [localized listing](APP-STORE-LISTING-DRAFT.json) is the working copy for the current private iPhone workflows.

## Where to spend the keyword field

| US iPhone query | Archived volume / difficulty | Decision |
|---|---:|---|
| grocery list | 53 / 2 | Keep the full phrase in the English name. Its volume score stayed between 52 and 53 on 83 observed days of 87 returned. |
| meal planner grocery list | 48 / 0 | The existing name and subtitle cover the words naturally. Connect a list to one dinner in the first three images. |
| shopping list | 48 / 2 | Keep shopping in the English keyword field. Use that space to complement the name. |
| pantry inventory | 37 / 0 | Keep both words. Historical volume stayed between 34 and 37 on 83 days. Show a small pantry that someone could realistically keep up to date. |
| grocery budget / grocery calculator | 37 / 2 and 27 / 0 | Keep budget visible and calculator in keywords. Use a pack comparison with shopper-entered prices to prove the benefit. Budget’s history had only 25 observed days of 87. |
| receipt scanner | 48 / 19 | Keep receipt and describe the photo or screenshot review. Broad scanner traffic can include bookkeeping. Test whether people expect a grocery pantry or an expense report. |
| lista de compras | 28 / 0 | Use the intact phrase near the start of Spanish copy. The archived popularity score was 5. No fresh Spanish exact-query catalog check accompanied the English collection. |
| escanear recibos | 25 / 4 | Explain the actual review-and-save flow in Spanish. Test the feature with US Spanish speakers before assigning it a dedicated acquisition page. |

AppTweak scores are relative measures. A difficulty score of zero can coexist with hundreds of catalog results. No term in this table has a demonstrated conversion rate for Room in the Cart. Sources in the archive include `analysis/curated-target-keywords.json`, `analysis/keyword-history-reanalysis.json`, `analysis/spanish-target-keywords.json` and `analysis/default-listings-v3.json`.

V3 contains 338 curated English terms and 50 Spanish targets. Only two Spanish targets had an archived volume score above the floor of 5. The English expansion added 56 curated candidates, of which 28 had measured metrics, 21 had suggestion evidence and seven appeared only in paid observations. The November 9 catalog sample contains 562 observations across 390 distinct app IDs and 24 English queries. Only ten expansion candidates received an exact-query check. A term like “leftover food” could attract shoppers seeking surplus-food deals. Keep it out of the launch metadata. [Apple’s search guidance](https://developer.apple.com/app-store/search/)

The archived November 8 competitor rank snapshot adds context to those scores. For “grocery list,” AnyList ranked first, OurGroceries second and Listonic eighth. For “pantry inventory,” Pantry Check ranked first, Cooklist second and KitchenPal sixth. Only 39 of 200 app–query pairs had a returned rank. None of the ten sampled competitors had a returned “grocery budget” rank. That makes the budget story worth testing, while the sample says little about competitors outside those ten. Source in the archive: `archives/aso-v2-2026-11-08/v1-archive/analysis/competitor-ranks.json`.

## What to show shoppers

1. **Start with a real list.** Show several readable groceries and one dinner they are for. Compare that opening against a simple list on its own at the size of an actual search result. Ask a shopper what they expect to do first. The project has no outside shopper sessions yet.
2. **Prove the budget benefit with one decision.** Show what 12 wraps cost in packs of eight at $3.20 versus packs of six at $2.70. Both choices take two packs, costing $6.40 and $5.40. The saved comparison is independently reproducible. Mark prices as entered by the shopper. The archived TapCook and Whipp shelves already advertised budget planning, so “plan and save” alone gives shoppers little reason to choose this app.
3. **Make Pantry look manageable.** Show three familiar items, change one remaining amount, then reopen the item. Use an actual receipt screenshot as a later scene. Show the proposed lines and the shopper’s correction before saving. For a barcode, show what happens when manual matching is needed. Capture text at a legible size in each locale.
4. **Reserve sharing imagery for verified production access.** The archived 50-review AnyList sample contains 20 automatic sharing/sync topic matches. These include praise and complaints. Treat them as a prompt to test a complete loop with two people, from request to the contributor seeing the shopper’s decision. A picture of an invitation alone cannot demonstrate that loop.

Source trails include `analysis/scene-library-v3.json`, `direct-expansion/report.md`, `archives/aso-v2-2026-11-08/analysis/review-sample-summary.json` and `deliverables/04-SCREENSHOTS.md`. The six newly reviewed competitor shelves contain 41 screenshots. Publisher screenshots establish what the listing communicates. The archive did not task-test those six apps.

## What to learn after launch

Start with one default page. The archive's 22 briefs and 44 reusable scenes give us alternatives for later. If there is enough relevant traffic, the first two custom pages worth testing are the **whole-pack budget comparison** (P01) and **small pantry inventory** (P21). Each has an obvious first task that works without household setup. Record the version and locale, acquisition source, date range, exposure and Apple-reported uncertainty before treating a difference as repeatable.

Use Apple’s default-page Product Page Optimization to test **one change at a time**. Keep the first image’s copy and captures fixed when testing its plum framing. Use a separate experiment for screenshot order. For custom pages, compare matched routes and report the limitations of traffic assignment. Pair conversion evidence with a shopper demonstrating the promised first task. Use existing consented measurement where applicable or observe a voluntary test session. [Product Page Optimization](https://developer.apple.com/app-store/product-page-optimization/) · [Custom product pages](https://developer.apple.com/app-store/custom-product-pages/)

Before entering the final fields, confirm the live build still supports the description and each screenshot. Keep subscription, household sync and guardian claims tied to signed-build evidence. The research’s category ranks, suggested prices, ads observations and proposed screenshots are inputs to decisions. They provide no estimate of this app’s revenue or future App Store ranking.
