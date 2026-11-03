# Room in the Cart · screens and navigation

## Where people enter

On iPhone, use three SwiftUI tabs with independent navigation stacks. **Shop** opens the current pickup (S01). **Dinners** opens planning choices (S13) or the meal the shopper last viewed. **Records** opens saved pickups and files (S20). A gear on each root opens durable settings. Returning from a detail restores the originating tab, query, scroll position and selected shop. A sheet carries a proposed change. Dismissing it discards edits unless the screen explicitly saves a draft. Identify a restored destination by household, shop and stable record ID. Recheck access on resume.

On a shared phone, an invited contributor enters their own S22 space. Returning to adult tabs requires unlocking the adult session. On mobile web, an invite opens redemption then S22. A separate current-view link opens a narrow, dated shop view with its own grant. A cook can read the complete plain-text instruction in their usual messaging app. Only a separately authorized editor may propose edits to a shared view. Identify the shop, last update and expiry before showing content. On revocation or expiry, end online access and offer a path to request a fresh link. Prior exported messages remain readable.

**First free pickup.** From S01 choose **Start pickup**, paste a list at S02, then enter a $38 whole-pickup cap at S03. At S04 link the twelve wraps already listed to two dinners and lunch. S05 shows the actual packages and whether deferring a flexible line keeps the order under $38. At S06 the shopper first freezes the reviewed basket, then explicitly copies or shares the list. Copy alone never places or freezes an order. The shopper checks out with the retailer and returns to confirm placement. At pickup, S08 records discrepancies. S09 repairs a dinner if necessary, S10 sends the cook instructions and S11 closes the shop. S12 starts a new draft from one familiar dinner and reviewed carryovers. Each short route also works independently. A shopper comparing two packages can go directly from S01 to S04 and leave with an answer. Accounts, household invitations and subscription previews enter only when the shopper selects those features.

## Shop and pickup

### S01 · Start or resume
**Entry and action.** Shop root for a local or authorized household shopper. Show the dated pickup, next available action, last local save and last household sync. Offer Start pickup (S02), Compare packs (S04), Check one change (S05), Something is missing (S08) and the household inbox (S23) when authorized. Starting a pickup creates a local draft. Opening an existing shop reads its saved state.

**Check.** On first launch in airplane mode, two pack offers yield a usable comparison without setup. On restart after an offer expires, resume at Await pickup with the local deadline. Switching to a contributor clears adult navigation and previews.

### S02 · Bring the list
**Entry and action.** Shopper from S01, selected-text extension or a saved draft. Type, dictate, paste or share selected text into an editable import preview. Show original wording, parsed units and unresolved lines together. Confirm once to add or link contributions. Explicitly distinguish checking a line from opening its detail. Keep notes, aisle/store grouping, search, recently checked, undo and the large-print list accessible. Keep entry and search pinned. Open detail by tapping the label and check using the separate control. Ordinary search excludes trash. Preserve original import order independently of a shop-specific sort. Recently checked, Handled and Trash expose Restore or Reopen by stable ID, including after restart. Handling a need records who took care of it. Checking a line records list progress. Deleting a line previews effects on active needs.

**Check.** Paste “12 wraps” twice. Prompt for merge or add, and let the shopper link six to tacos within the existing twelve. Cancel a share import, then return from detail on a long filtered list. Preserve existing lines, search and position.

### S03 · Describe this pickup
**Entry and action.** Shopper from list or checkout comparison. Ask only for facts needed by the decision. Capture cap amount, scope, currency and firmness, branch, fulfillment mode, slot, and retailer preview with its source, time and included charges. Mark essentials and genuinely flexible lines. Saving a changed branch, slot or mode invalidates affected quotes. Show old and new full dates, times and fees before applying. Only when an authorization hold is binding, the shopper may enter the retailer-displayed hold and optionally compare it with funds available for that payment method. Keep available funds session-local and private. S05 presents the hold gap separately from the spending cap. An unknown hold stays unknown.

**Check.** A $35 dinner limit with unknown household goods remains dinner-only. Cancelling a slot change restores the previous basis. A fee of unknown applicability leaves a conditional total.

### S04 · Inspect an ingredient
**Entry and action.** Shopper from a line, meal or stand-alone pack check. Read the original need, linked requests, manually added quantity, meal shares, reservations, available stock and package offers. Show buyable packs, cost for enough usable food, unit basis and remainder. Edit one contribution, link within existing quantity or explicitly add demand. Return to the source or compare at S05. Show ingredient use and whole packs bought on separate lines. Bound derived carryover by confirmed physical stock on a comparable basis. Package photo or barcode capture opens a manual match here.

**Check.** Six taco wraps, four quesadilla wraps and two lunches need two eight-packs with no stock. Hiding lunches changes presentation only. A lower price per pound still requires checking actual pack weight. Leave mass-to-volume unknown without an ingredient-specific basis.

### S05 · Compare checkout choices
**Entry and action.** Shopper from Shop, item detail or a request review. Compare like-for-like pickup previews, including remaining original quantities, protected portions, applicable promotions, fees, taxes and other commitments. Name the affected dinners, line ceiling, overall cap and unresolved terms. Ask the fewest preference questions needed to identify a sufficient option. Save a reviewed choice or leave the draft intact.

**Check.** With $34.80 protected, $4.60 coffee, $1.50 salsa and an applicable $4.95 fee below $35, deferring coffee alone produces $36.30. Deferring both produces $39.75. Two simultaneous changes share one allowance. When exact weight is missing, show the maximum weight that fits if calculable.

### S06 · Prepare the retailer handoff
**Entry and action.** Active shopper from the reviewed list. Save an immutable, readable dated snapshot, protect that basket for checkout and route incoming requests to Next shop. Copy or share the household-authored lines. Track those actions separately. On return offer I placed this order, Still checking out and Reopen draft. Placement records who reported it, when and against which frozen revision. A later amendment requires independent retailer confirmation.

**Check.** Cancel share, open an empty retailer cart or lose connectivity. The frozen list remains available and placement is unconfirmed. An authorized local placement report queues for sync. If authority changed meanwhile, preserve the separately attributed report for the current shopper to reconcile.

### S07 · Review a store offer
**Entry and action.** Shopper from an order line or optional deadline reminder. Enter the replacement, quantity of original still expected, offered pack, price, local cutoff and impacted meals. Read dish-specific acceptance and maximum price. Show combined cost and uncovered portions. Record the household preference and retailer response separately. Offer a deadline reminder only on request. Offer Preview retailer note and Copy from this offer. Include the required usable quantity, authorized offer-specific price or weight ceiling, cutoff and the fallback if short. Omit household budget, available funds and family details. Both copy and cancel preserve the pending decision.

**Check.** A replacement can fit the basket but exceed a saved line ceiling. Ask before accepting. Reopen an unresolved offer after restart. Once its cutoff passes, display Await pickup with time and keep the fill unknown. Never assign a new placement fee just because the retailer later shorts the order.

### S08 · Record what came home
**Entry and action.** Shopper from the order or missing-item shortcut. Allow discrepancy-only review. For each original or substitute record no-fill, partial, wrong, late or split fulfillment, actual arrival, usable amount and protected portions. Link evidence and corrections to the same delivery. Show an unchecked line as unverified. Keep later deliveries pending until confirmed in time. When opened from Something is missing without a prior order, ask what food is short, what meal needs it, how much is available, and by when. Create a private local planning need and a reviewed stock observation, then open S09. A due time may remain unknown. Reopening offline restores this need. This branch creates zero orders, fills or charges. Receipt-line capture belongs to the order branch.

**Check.** One delivered eight-pack with six usable and two reserved supplies four to tacos. Correcting usable to seven supplies five. Replaying the same save adds no new pack. Two separately confirmed deliveries survive. A credit alone leaves the dish short.

### S09 · Repair the meal
**Entry and action.** Shopper from S08 or an affected dinner. Show required vs available quantities, named reservations, timing and exclusions. Enter a free manual fix, confirm freezer stock, choose a top-up, deliberately repeat or change a dinner, or leave it open. Household assistance ranks accepted feasible dishes. Obtain explicit agreement before introducing another trip or repeating a meal. Before labeling a fallback feasible, compare remaining elapsed preparation time with the meal deadline. If a recipe needs two hours of marinating and dinner is in 45 minutes, ask whether that step is already complete or suggest another reviewed meal. Unknown timing stays conditional.

**Check.** Replacing Wednesday’s dinner leaves Tuesday’s shortage visible. A frozen batch of five portions cannot serve four plates and two protected lunches. If every approved option misses a requirement, preserve the open need and its due date.

### S10 · Tell the cook
**Entry and action.** Shopper or authorized adult from a meal or revision. Preview a complete dated plain-text instruction with portions, what to set aside, unresolved needs and revision. Select recipient language, edit wording and explicitly choose any private fields for this copy. Read aloud on demand with pause, stop and repeat. Share through the system sheet. Explicitly marking a recipient and version sent establishes that recipient’s comparison baseline. Offer Send dated copy and Share current view as distinct choices. For a live link, select one shop, fields, read or propose access, expiry and recipient, then explicitly issue. A scoped helper opens the current permitted fields with the revision and as-of time shown. An editor may propose a change to S17 for the shopper. Link management opens S21 for an authorized administrator. The cook can still use a static message after a link expires.

**Check.** An Android cook can act from the message alone. A US Spanish handoff preserves original product constraints, quantities and local date. Cancelling share leaves the baseline intact. A sent version proves neither receipt nor acknowledgment. Stop readback before VoiceOver speaks.

### S11 · Close the pickup
**Entry and action.** Shopper from actual fill or order history. Record posted charges, holds, credits, additional trips and top-ups with evidence. Keep paid-to-date, unresolved money and dinner outcomes separate. Confirm bought status for the relevant family request if known. Offer optional feedback including already knew, unchanged, wrong, too late and unknown.

**Check.** A pending $2.40 credit leaves $37.20 posted as $37.20 paid. Posting a credit already reflected in a net charge cannot subtract it twice. Declining feedback permits closure and preserves unresolved items for later correction.

### S12 · Start the next shop
**Entry and action.** Shopper from Shop or a closed pickup. Start blank or reuse one familiar dinner free. Present individual deferrals, needs with deadlines and household requests saved for next shop. Mark already handled, keep deferred, dismiss or explicitly price and accept for this trip. Household assistance recalls approved staples by purpose and store. Write a fresh draft without changing prior history.

**Check.** Coffee bought elsewhere adds $0. A checked market line remains checked until reopened. Previous offer prices are cleared, a stale reminder expires, and the shopper can recheck a carried item without duplicating the old purchase.

## Dinners, membership and records

### S13 · Choose a way to plan
**Entry and action.** Dinners root for a local shopper or authorized adult planner. Offer manual meal entry, one free reusable dinner, usual rotations and an isolated Household preview. Continue to S14, S15 or S16. A preview copies the source references and records the base revision. Leaving the preview discards its changes. Show This week (S25) and Dinner ideas (S26) within Dinners, alongside the manual S14 route. The adult planning grant applies to the shared week and ideas.

**Check.** A free shopper tries a pairing and returns to the original list unchanged. A second adult can prepare a proposal for the active shopper. Only the active shopper can apply it to the pickup.

### S14 · Choose familiar dinners
**Entry and action.** Adult from Dinners. Record title, servings, source URL, notes, meal-specific approvals, hard exclusions, named portions and linked ingredients. Select one meal or permitted rotation nights. Import the supported library file through a batch preview showing matches, duplicates, skipped fields and original source. Recipe photo/OCR opens the same editable review. Save this week separately from the usual dinner. Separate Accept as a candidate from Choose for this shop. A chosen dinner may have no assigned night. Its occurrence and grocery demand exist once. Assign a date at S25 by updating that same occurrence. Offering or declining a candidate creates no shop need. Offer optional known elapsed lead time and already-completed steps for the timing warning at S09/S10.

**Check.** A broken recipe link leaves servings and allocations editable. Undoing a library import removes that batch’s changes without deleting unrelated records. A one-week substitute becomes a usual preference only by explicit choice.

### S15 · Pair dinners across a pack
**Entry and action.** Authorized adult from Dinners, or isolated preview. Compare accepted meal pairs using confirmed unreserved food. Show each complete alternative’s diners, ingredient and pack changes, protected portions, prep time, fees and total cash. Select a proposal for S17. Return to manual planning if no viable pair fits. Compare a proposed pairing with the actual current schedule. If both dinners are already chosen, report no new pairing. After Apply the next preview starts from the accepted revision. Cancel leaves the old revision active.

**Check.** Three peppers cannot be allocated twice. Cover lunches and all ingredients in both alternatives before displaying a saving. Missing price or usable yield produces a conditional comparison with the unresolved input visible.

### S16 · Add a guest
**Entry and action.** Adult from a meal or Shop. Enter or speak a temporary change. Confirm meal, guest count, individual plates and sides, then preview pack and checkout effects. Include nights away and reduced servings. Free shoppers edit manually. Household assistance prepares a review for S17. A voice utterance never applies a change directly.

**Check.** Eight to nine needed wraps crosses an eight-pack boundary. Twelve to four still buys one twelve-pack. After pickup, skipping dinner opens a carryover check. Confirm remaining usable food before assigning it. Cancelling restores the base and named lunches.

### S17 · Apply and explain a revision
**Entry and action.** Adult from a meal change or a proposal. Compare the reviewed base with the current shop revision. Show the commitments affected by this proposed change. Active shopper applies once, then optionally prepares a corrected instruction. A changed base requires fresh review. For a placed order, retain the change as a proposed amendment. Free shows the previous dated copy and a manually editable full correction for this recipient. Only authorized Household assistance computes a recipient-specific difference. After lapse, keep both dated copies and manual resend available. A cook with an editor link submits only an allowed proposal. The shopper alone commits basket changes.

**Check.** Two adults review the same pickup. The second stale proposal cannot overwrite the first. A replay of the same apply creates one revision. If the prior destination is unknown, provide a full current message instead of a differences-only correction.

### S18 · Decide on Household
**Entry and action.** Adult from Settings or an intentionally selected planning feature. Show the annual offer, two named planning seats, renewal, current storefront terms, free route, Restore and Manage. Present the proposed US $49.99 annual price only when consistent with the actual storefront offer. Purchase through StoreKit and read verified entitlement state. Keep marketing experiments and purchase records separate.

**Check.** Pending purchase leaves paid tools inactive. On cancellation, honor the verified access period. On expiry retain free manual work, family requests, one reusable dinner, saved records and exports. A child cannot reach purchase controls.

### S19 · Manage the two seats
**Entry and action.** Authorized adult from Settings. Read entitlement and named seat assignments. Invite, redeem, remove or recover a second planner through the appropriate verified account. Show who organizes the household, who has paid tools and who shops this trip separately. Transfer the shop role only through an explicit authorized handover.

**Check.** Redeeming a seat grants no automatic shop or budget access. Reinstalling and restoring a purchase does not add a third seat. Removal, refund, grace period and entitlement expiry update the appropriate capability without erasing personal records.

### S20 · Find records and recover files
**Entry and action.** Records root for authorized adults. Find saved pickups, sent notes, past approvals, actual fills and unresolved outcomes. Display local save, household sync and exported backup times separately. Preview a minimally scoped helper copy or a personal readable/structured export. Compare backup source, stable identities, date, revision and conflicts before recovery. Show correction, support, deletion scope and undo where possible. Place price history and period planning under Records. Reveal a period aggregate only when the adult has current budget access to every contributing shop in that period. With partial access, return an explicitly scoped subtotal of permitted entries or withhold the summary. Suppress hidden-shop count, implied remainder and derived financial signals. Offer Manage shared views leading to the authorized S21 panel.

**Check.** An older backup opens beside newer work for review. Reimport recognizes the same source revision. Malformed input or cancellation leaves records intact. Apply deletion history before reconnecting a restored device. Imported records cannot restore revoked access, guardian consent or paid membership.

## Household requests

### S21 · Invite and manage household contributors
**Entry and action.** Organizer or guardian from Settings. Show household, invite scope, alias, devices and revoke controls. Offer an adult contributor invitation or guardian-managed child setup. Complete required guardian notice and verification before enabling child network participation. Issue an expiring single-use invite of the requested scope. Allow reissue and revocation. S19 owns paid seats. List active one-shop view grants separately from contributor invites and paid seats. Permit the authorized grant manager to inspect selected fields, expiry and scope and revoke the link. At the next access a revoked link ends the live session. A previously exported dated copy remains labeled with its as-of time.

**Check.** A used, expired or revoked token cannot activate a device. A forwarded invite cannot broaden its grant. A child without completed guardian setup cannot submit online. Revocation prevents new server reads and writes, including queued actions on an old device.

### S22 · Ask the shopper
**Entry and action.** Invited contributor via iPhone or mobile web. Show household before entry. Type or speak item, amount, pack count and intended trip. Review original wording and parsed fields, correct one field, then send. List only this author’s own requests and statuses. Permit edit/withdraw while pending. Later corrections become follow-ups. Show waiting to sync locally and server confirmation separately.

**Check.** Retry a cereal request after disconnect without duplicating it. Show next-shop routing when protected or placed. An unknown quantity stays unresolved. Changing households clears the prior form or prompts to keep it with its original destination. Server payload and browser history expose no budget, other requests or private notes.

### S23 · Review family requests
**Entry and action.** Active shopper from Shop. Read submitted requests with alias, amount, server-received time, destination and revision. Show potential duplicates together while preserving each author and intended use. Ask for clarification, mark handled or dismiss with a scoped outcome. Select the package and quantity for S24. Keep completed decisions inspectable.

**Check.** Two authors request cereal. Ask whether one box covers both or a second is needed. Keeping separate sources lets each author receive their own outcome. If a request changes while open, refresh before acting. A former shopper cannot submit a decision.

### S24 · Choose this pickup or the next
**Entry and action.** Active shopper from S23. Read the request, shop revision, matched quantity, cheapest sufficient available pack on known terms, price basis, meals and inclusive before/after total. Offer Add to this pickup, Save for next shop and Cancel. Unknown price keeps the effect unknown. An overage requires explicit shopper acceptance. Commit basket change, decision and author-visible outcome together once.

**Check.** $37.20 plus $3.49 gives $40.69, or $2.69 over a $38 cap. One confirmed matching box already in the draft can cover a request at $0 incremental cost. Cancel leaves it pending. A revised quantity, changed authority or checkout lock invalidates the preview. Do not silently add it after placement. A contributor receives only their status.

## Meal week, dinner ideas and a two-store comparison

The financial portion of any preview requires the current shop's budget scope. When a planning adult has only meal access, render the authorized food effects without prices, cap, monetary delta or implied budget outcome. Route their proposal to the assigned shopper for the private review.

### S25 · Plan the household meal week
**Entry and action.** Authorized adult from Dinners or the guest sheet. Offer a week grid and an equivalent chronological list grouped by full local date. Select a meal, add a guest, mark an away night or reserve lunch portions. Use the same meal and reservation identities as S14–S16 so edits from either surface agree. Preview affected portions, packages, cost and previously sent instructions at S17. Only the active shopper applies changes to a pickup. Other authorized adults may propose changes. Show chosen dinners without dates in an Unscheduled section. Scheduling moves the same occurrence from this section to its date. Require a real date for a dated reminder. Accepting an idea alone does not put it here.

**Check.** Move one dinner across the week boundary while preserving a lunch reservation on its original day. Ask before moving a linked commitment. An away-night edit after purchase leaves the charge intact and offers dated carryover. An already submitted order requires a confirmed amendment. Show a stale edit for review and keep the ordinary rotation unchanged. Contributors and expired one-shop links cannot open the household week.

### S26 · Review a dinner idea
**Entry and action.** Adult with meal-planning access from Dinners or an open meal slot at S25. Create an editable idea draft, show suggested servings and ingredient quantities with units, flag missing information and household exclusions, and let the adult replace or remove an ingredient. Preview stock, usable yield, named reservations, whole packs and unresolved prices. Obtain explicit household adult approval of the meal and quantities before offering to link it to this week. Applying list changes still requires active-shopper review at S17. Saving an idea, approving a new usual dinner and committing a shopping change are separate actions.

**Check.** Generate an idea containing a household-excluded ingredient and an ambiguous package. Keep the proposal outside the list and accepted library. Let the adult correct both fields, inspect the remaining quantity after lunch reservations, then approve. Cancel or retry during generation without generating duplicate lines. An unavailable generator leaves manual meal entry available. A contributor cannot generate or approve on an adult’s behalf.

### S27 · Compare two entered store quotes
**Entry and action.** The local shopper or a household adult with private budget scope (including the assigned shopper for that shop) opts in from S05. A non-shopper can save a comparison or propose a change. Only the current shopper may adopt it after reviewing an open draft. Enter both stores’ comparable packages or baskets with branch, source, date, slot, currency, eligibility, quantity, fees and availability. Identify whether the second option needs an extra trip. Allow explicit travel/parking costs, other known charges and optional time with its own unit. Show item-price difference, total checkout and total including incremental trip expense separately. Mark unmatched quantities or missing terms. Offer save comparison or explicitly revise the draft at the chosen store. Store choice invalidates old store-specific quotes and requires review.

**Check.** A second store’s basket is $3 cheaper but its extra trip costs $4. Show that it costs $1 more overall. Unknown trip cost shows a $3 break-even point if all other terms are comparable. Missing prices or availability leave the comparison conditional. No location tracking, fetched price, second trip, route or order follows from entering either quote. Invited contributors cannot access private price comparisons.

## Shared controls and secondary views

- **Input and capture.** Request permission when the person selects the microphone, camera or photo picker. Every capture has a typed equivalent and an original-versus-interpreted preview. Barcode identifies a candidate product. Receipt OCR proposes lines. Neither confirms price, purchase or fill. Offer a device-local spelling correction only after an explicit edit. Let the user inspect or forget learned names without rewriting prior records.
- **Food storage.** Open pantry and freezer batches from a need or Dinners. Edit storage date, usable amount, reservations and use-first hints. Confirm carryover before a meal consumes it. If a correction affects several meals, preview each effect and commit the change once.
- **Price records and period budgets.** Authorized adults open these from Records. Filter household-entered prices by branch, mode and evidence date. Separate web and warehouse prices. A pay-period view distinguishes planned future holds, posted charges, expected credits and unpriced shops. Deferment moves an expected expense. It cannot establish savings or a verified period balance.
- **Settings and privacy.** Put appearance (system by default), accessibility, readback, editable speech corrections, interface language, optional measurement, help, membership, privacy, export and household membership under the gear. Keep recipient language, list sorting, store label and reminders at their point of use. Ask notification permission for a selected need or cutoff with local time, quiet hours and expiry. Lock-screen widgets use a narrow read model and hide private notes and money. Avoid putting secrets, budget text or member names in deep-link parameters.
- **Appearance and access.** Follow Gen 13’s linen/white/ink/spruce light palette and dark canvas/raised surface/light ink/mint palette. Show affected item, dinner, dollars and action together. Use explicit words for uncertainty, pending sync, over cap and shortage. Support Dynamic Type and web text zoom with stacked comparisons, semantic group headings, native form labels and accessible checkbox actions. Check VoiceOver, mobile screen-reader and hardware-keyboard reading order with full dates, money and units. Support high contrast, light/dark and Reduce Motion. Keep numbers stationary, announce one committed result and return focus to the changed row. Every swipe action has a labeled button.
- **Language.** Ship human-reviewed US English and US Spanish across entry, shop, help, billing and exports. Set interface and recipient language independently. Preserve original names, exclusions and currency. Exercise long strings, plural forms, RTL resilience, interrupted speech and locale switches during a draft.
- **Operational boundaries.** Default handoff is the shopper-reviewed dated list. Direct retailer integration is deferred. The adult meal-week view, reviewed dinner ideas and two entered store quotes ship in the first release. Their scope excludes a general family calendar, unreviewed recipe-to-cart changes, universal deals and automatic multi-store routing. The planner does not provide a delivery marketplace, medical/allergy judgments, nutrition coaching, social feeds or mandatory scanning.

**Source map.** Screen IDs and service roles follow the Gen 15 release register, first-release plan and screen walkthrough. The navigation, settings, visual hierarchy and motion follow the Gen 13 design guide. Source-level editing, recovery, accessible list behavior and the recipient-specific change baseline draw on the Gen 11, Gen 12 and Gen 14 walkthroughs and feature maps. The monetary and allocation checks retain the Gen 4 pooled-limit, Gen 7 away-night and Gen 9 deferral cases.
