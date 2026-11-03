# Room in the Cart

Product baseline for Codex · Foundation 2.1 · US iPhone first release

**Room in the Cart helps the person doing a family's grocery pickup answer two questions together. Can we afford this change to the whole pickup? Will the food we bring home still cover the dinners and lunches we promised?** The app connects requests, meals, actual package sizes, checkout costs and what came home. A person can get a useful answer on their first visit by comparing two packs, without an account, a network connection or a week of meals already entered.

Use this file to orient a new Codex chat. Foundation 2.1 is the accepted build specification. At handoff, the repository contains research, an older Expo scaffold, a browser interaction study and executable reference checks. The native iPhone app, live service and paid subscription still need to be built and tested. When resuming development, inspect the checkout and test results to find out what has shipped since this handoff.

## One pickup from the family's point of view

Mia has a $38 cap on Tuesday's pickup. The expected checkout is $37.20. Sam asks for one box of cereal. His phone shows that the request was received. On Mia's phone, the $3.49 box brings the expected checkout to **$40.69, or $2.69 over** if the other charges stay the same. She can link a box already in the basket, ask for clarification, explicitly accept the overage, or save the request for next shop. Deferring leaves this checkout at $37.20. Sam sees his own outcome. The household budget stays private.

Mia also needs six wraps for tacos, four for quesadillas and two for lunch. With eight per pack and none at home, she needs two packs. If only six usable wraps come home, setting two aside for lunch leaves four for tacos. Two taco wraps and four quesadilla wraps are still missing. The shopper can change dinner, use confirmed freezer stock, agree to a top-up trip or leave the need open. The cook gets a dated instruction explaining what to use and what to save. A family discovering the same shortage on a fresh install can enter it directly from Shop.

## Where features belong

| Home | What a person comes here to do |
|---|---|
| **Shop** | Start or resume a pickup. Type, paste, dictate or import a list. Review duplicates and keep meal quantities separate from staples. Compare usable packs, set a cap, review requests, and compare two manually entered store quotes including fees, extra travel cost and time. Freeze a reviewed basket, copy or share the dated list, check out with the retailer, report placement, review substitutions and log what actually arrived. Repair a shortage, tell the cook and carry unresolved items into the next trip. |
| **Dinners** | Save familiar meals, recipe sources, ingredients, exclusions, portions and known prep lead time. Review an editable dinner idea, choose it for this shop, and assign a night when ready. The meal week supports guests, away nights and protected lunches. Preview how a change affects portions and whole packs. Show the cost effect only to an adult with budget access for that shop. Household can also compare the revised instructions with the last copy sent to a particular cook. Keep a reusable rotation separate from this week's edits. |
| **Records** | Find dated pickups, sent instructions, costs, credits, price evidence and permitted budget history. Compare backups, restore earlier work, export or delete data. Settings exposes membership, seats, privacy and preferences. A cook's current-view link is created at the handoff and can be revoked through grant management. |

The design has **27 screen contracts** across three tab roots, 15 pushed views, eight contextual sheets and one scoped contributor destination. Invited people on iPhone or Android can use mobile web. A contributor sees their own requests. A cook sees the fields granted for one shop. A static dated message also works in the cook's usual messaging app.

Optional shortcuts include package and receipt capture, barcode matching, recipe OCR, speech with an editable preview, device-local product-name corrections, dinner readback, print, share, widgets and reminders. A typed path is always available. Captured content waits for review before it becomes a fact used in a decision.

## Access, money and trust

- **Free covers an entire ordinary pickup.** It includes the family request inbox, basic budget preview, one reusable dinner, manual meal-week planning and repair, reviewed dinner ideas, manual two-store comparison, dated handoffs, and access to saved records and exports.
- **Household pays for repeated planning.** Up to two named adult planners can use rotations, pack pairings across meals, guest and budget scenarios, assisted recovery and next-trip planning, history tools, and automatic comparison with the last instruction sent to a particular cook. The proposed US price is **$49.99 per year**. Use StoreKit 2 and Apple's actual localized offer, with purchase, restore and manage controls. Grocery payments happen with the retailer.
- **Only the assigned shopper can commit a shared basket change.** A second adult with planning access can propose. An invited child needs guardian setup and sees only their own request and status. Paying for a seat, holding a cook link and being the shopper are separate permissions. Losing paid access preserves permitted Free data and manual work.
- **Keep unknowns visible.** Compare enough usable food for the same commitments. Include known fees, taxes, discounts and the remaining original items. Label scope, source and time. A missing price or an unknown yield can make the answer unresolved. Keep a payment hold separate from posted spending. Treat a pending credit as pending, and never count a refund twice.
- **Save what happened, in order.** A request, an approval, a copy to the retailer, a reported order, an actual fill and a posted charge are distinct events. Seal the original order. A cancelled preview changes nothing. Reconnects and double taps must apply an authorized change once. A stale proposal goes back for review. Count pantry or freezer food only after someone confirms its usable quantity and matches it to the need. Protect lunch reservations and recheck dependent dinners whenever usable stock changes.

## How the product should feel

Use the established spruce and linen palette. In light mode the canvas is **#F7F5EF**, surfaces are **#FFFFFF**, text is **#172925** and the primary action is **#195848**. In dark mode use **#121A17**, **#1C2923**, **#F4F5EC** and **#91DBBB** for those same roles. Give each decision one prominent action. Explain an overage, shortage or stale price in words beside the affected meal or amount. Keep quantities and prices still while other details appear.

Use native Dynamic Type, VoiceOver, at least 44-point touch targets and immediate updates with Reduce Motion. Checking a list item and opening its detail need distinct controls. After an action, return focus to its result. Support US English and US Spanish, including a cook receiving instructions in a different language from the shopper. Preserve original food names, units, exclusions and currency.

## Release scope and build direction

The first release has **52 requirements**. Direct retailer cart integration is deferred. Release one hands off a dated list and lets the shopper report placement. The six product boundaries cover operating a grocery marketplace, universal deal routing, medical or allergy judgments, unrestricted recipe generation or nutrition coaching, general family scheduling or social feeds, and mandatory scanning or retailer credential collection. The meal calendar, reviewed dinner ideas and two shopper-entered quotes are all in scope.

Build a **native SwiftUI iPhone client** with local SQLite persistence and a narrow TypeScript web client for invitees. The proposed backend is one TypeScript service backed by PostgreSQL. Keep checkout and allocation calculations outside views. The service rechecks household, role, permission, shop revision and shopper authority on shared changes. The reference database and fixtures illustrate these rules. Product acceptance requires real routes, persistence, accessible interaction and tests on the intended devices.

**First implementation milestone, B00–B01.** A new user opens Shop, compares two pack offers offline, saves the answer, quits and reopens it. An unknown quantity stays unresolved. Test it with VoiceOver, large text and both launch languages. A one-item comparison must never claim that the whole pickup fits the budget.

For a build assignment, place this file beside the extracted `foundation-gen2.1` folder. Start with the [complete Codex brief](foundation-gen2.1/CODEX-MASTER.md). Use the [feature register](foundation-gen2.1/02-features.md) for tier and acceptance, the [screen contracts](foundation-gen2.1/03-screens.md) for placement and the [build tickets](foundation-gen2.1/08-build.md) for sequence. The foundation's detailed contracts govern implementation. For launch work, use the [Apple billing guide](foundation-gen2.1/12-apple-billing.md) and the [keyword planner](foundation-gen2.1/launch/Room%20in%20the%20Cart%20keyword%20planner.xlsx). The initial listing hypothesis is a shared grocery list that connects family requests to meal planning and the grocery budget. Publish claims only for behavior the submitted build demonstrates.
