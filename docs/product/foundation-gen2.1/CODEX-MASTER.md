# Room in the Cart

**Codex product and build brief · Foundation Gen 2.1 · US iPhone first release**

Room in the Cart helps a household answer one question: *If we change this pickup, can we still afford it and make the dinners and lunches we promised?* It connects a shared request list to the actual packs, checkout fees, portions, and food that comes home. It does not sell groceries. The intended first user is the person already coordinating a family's weekly shop, often across more than one phone and more than one cook.

**How to use this file.** Give this Markdown file to Codex as the product brief. It includes the complete release register, all 27 screens, visual system, role rules, calculation examples, implementation order and keyword plan. For implementation also extract the companion foundation package: it supplies the executable relational reference, adversarial tests, visual studies, historical evidence and editable keyword planner. The current workspace contains a legacy Expo scaffold, not the product. Build the iPhone app in SwiftUI, with a narrow mobile web experience for invited people. Reference fixtures are fictional.

**First instruction to Codex:** Inspect the checkout. Start B00 and B01 in a native iOS target. From the real Shop tab, let a new user compare two pack offers with no account or network. Save, kill, reopen and get the same answer. Test known and unknown quantities, accessible controls, US English and US Spanish. Report the feature IDs, changed paths, actual test results and remaining device gates. Continue with B02 only when the first slice meets its evidence gate. Preserve the full launch scope; do not start a retailer integration or publish a listing.

**Jump to:** [features](#feature-register--all-first-release-behavior-and-boundaries) · [screens](#journeys-and-screens) · [design](#appearance-behavior-and-language) · [permissions](#who-may-see-or-change-each-fact) · [architecture](#build-architecture-storage-and-operations) · [calculations](#calculation-contract) · [build order](#development-order-and-release-evidence) · [keywords](#launch-keywords-and-listing-instructions).

## The household and its first pickup

Mia is the assigned shopper. Sam finishes the cereal, types or dictates a request, reviews one box, and sends it. His own phone can say “Received”; that does not add anything to the basket. Mia sees $37.20 expected checkout, $3.49 for the box and a $38.00 whole-pickup limit. If fees and other commitments are unchanged, the new checkout is $40.69, $2.69 over. Mia can link a box already on the list, add one after review, ask Sam a question, or save it for the next trip. Sam can see his own outcome, never the price or the household's other requests.

Mia also needs six wraps for tacos, four for quesadillas and two for lunch. With eight per pack and no confirmed stock, she needs two whole packs. One delivered eight-pack with only six usable does not cover dinner: reserve the two lunches and allocate the remaining four to tacos. Two taco wraps and four quesadilla wraps remain open. Alex gets the dated, corrected cooking instruction. The source report, usable observation and lunch reservation are three different facts. Comparing a cheaper pack only matters if it supplies the same commitments and the entire checkout works.

Free supports an account-free single item, urgent repair without an order, and an entire ordinary pickup through handoff, arrival, recovery and next shop. Household is a US $49.99/year price hypothesis for repeated planning, not a hardcoded storefront price. It offers up to two named adult planning seats. A child can contribute with guardian setup; an Android cook can read a narrow web view or a dated message. Neither a seat nor a link confers checkout control. Direct retailer connectivity is deferred; copy, share, optional external open and shopper-reported placement ship.

## How to make decisions from this brief

1. Use the feature ID to determine scope and acceptance. There are 52 launch requirements, one later integration and six boundaries, for 59 registered decisions. The three owner additions are included in launch.
2. Use the screen route and role rules to decide where a user can act and what can leave the device. Unknown price, yield, fees or eligibility must remain visible. Never fill a missing quantity with zero.
3. Use stable revisions, reviewed proposals, dated files and current grants. A copy, a placed report, a retailer acknowledgment, an actual delivery and a settled charge are different events.
4. Build the ordered vertical slices; use the release gates to decide whether a claim can ship. A check passing in the reference model does not establish a working application, paid demand, accessibility or regulatory clearance.

## Feature register · all first-release behavior and boundaries

### Day-to-day shop

**D01 · Start without setup**  
**Free** · B01 · S01 S04  
Offer quantity and two pack quotes to a pure PackComparison; store locally on Save. Return item-only headroom if the basket scope is incomplete. **Acceptance:** Open a quick check without an account, store, subscription or weekly menu. Two pack offers and the amount needed produce an item-level answer.

**D02 · Bring the list**  
**Free** · B02 · S02 S04  
Parse typed, explicit paste, selected text and voice into staged source contributions. Confirm duplicate vs additional amount; commit a reversible batch. Search excludes deleted lines. **Acceptance:** Type, paste or share selected text. Keep the original, preview lines, search and undo. Pasting 12 wraps twice asks whether to merge or add. Linking six to tacos within the 12 leaves 12 on the list.

**D03 · Describe this shop**  
**Free** · B02 · S03 S05  
Capture scope, currency, optional fixed reserves, fees, slot/zone and mode on ShopBasis. Edits invalidate dependent quote/guest previews. Keep a receipt/hold out of planned spend. **Acceptance:** Set the cap's scope, currency, store, mode and slot when relevant. Enter an inclusive preview or just the facts available. A $35 dinner limit stays labeled dinner-only even if the other groceries are unknown.

**D04 · Name meals and needs**  
**Free** · B02 · S03 S04 S14 S25  
Create a meal occurrence, serving groups, ingredient demands and protected allocations separately from shopping lines. Hiding or moving a meal does not remove staples or lunch reservations. **Acceptance:** Record the meal, optional night, servings and purpose of each need alongside staples and nonfood. Hiding lunches from view preserves their two wraps alongside six for tacos and four for quesadillas.

**D05 · Compare usable packages**  
**Free** · B01 · S01 S04 S07  
Normalize using a confirmed rational unit basis. Subtract confirmed usable supply, round up whole packs, compare total cost, remaining need, unit ceiling and leftovers. Return a question on unknown conversion. **Acceptance:** Compare whole packs by usable amount, price to buy enough and remainder after protected portions. A shopper can leave a weight or volume conversion unknown when its ingredient-specific basis is missing.

**D06 · Compare current checkouts**  
**Free basic budget preview** · B03 · S03 S05 S24  
Reprice complete equivalent alternatives in expected minor units. Re-evaluate eligible subtotal, fees, discounts and cap scope. Unknown costs propagate. An A03 cross-store scenario uses a separate comparison. **Acceptance:** Compare two same-store, same-slot checkout previews with time, source, included fees and commitments. A $34.80 subtotal plus a $4.95 fee shows $39.75 against $38. An uncertain fee produces a conditional result.

**D07 · Protect or defer a purchase**  
**Free** · B03 · S05 S12 S24  
Record need priority independently of line inclusion. Search only approved removals; persist a deferred need with source, destination and review status. A confirmed handled need is never revived automatically. **Acceptance:** Mark a line required, flexible or undecided. Offer keep, defer and leave unresolved. When the shopper defers filters, lunches keep their allocation and the filters reappear for review next shop.

**D08 · Explain a change**  
**Free** · B03 · S05 S16 S17  
A proposed patch records parent revision and affected contributions. Show delta and unpriced items; Apply once on matching base, Undo as a compensating revision. Post-placement edits require amendment. **Acceptance:** Preview changed lines, meals, packs and checkout before applying. Skip one dinner and check that its portion alone disappears. Undo restores the draft, including unrelated staples.

**D09 · Save a recoverable handoff**  
**Free** · B03 · S06 S10  
Freeze the exact revision before invoking copy/share/open. Record attempted, prepared, intentionally sent, manually reported placed and provider-confirmed as different evidence. **Acceptance:** Save a dated readable snapshot before copy, share or retailer open. Track each action separately from shopper-confirmed submission and retailer-confirmed amendment. Cancelling or opening an empty cart leaves the snapshot intact and the order unconfirmed.

**D10 · Resolve a changed item**  
**Free** · B04 · S07 S08  
Evaluate the offer against per-dish rules, remaining original charge, pack yield, joint headroom and local cutoff. Save a private decision and concise retailer note. Expire to await pickup even offline. **Acceptance:** Record an offer's affected lines, remaining original quantity, known price and local deadline. Check per-dish alternatives. At cutoff show Await pickup with the date/time and keep fill unknown until the bag arrives.

**D11 · Record what came home**  
**Free** · B04 · S08 S09 S11  
Append receipt fragments keyed by source event, original order line, branch and segment. Supersede usable counts separately; allocate protected portions first. Resolve shortfalls per dish independently of money. **Acceptance:** Record no-fill, partial, wrong, late or split items. Separate received, usable and reserved amounts, meal repair and refunds. A delivered eight-pack with six usable and two reserved supplies four to dinner. Retrying the same delivery adds nothing.

**D12 · Tell the cook**  
**Free** · B04 · S09 S10  
Project a complete cook instruction with date, revision, required action and usable portions. Reset optional private fields off per share. Use recipient-specific comparison only on known send history. **Acceptance:** Preview the complete dated instruction and revision in plain text before sharing. An Android caregiver can act without installing the app. Budget defaults private. Marking a version sent does not record acknowledgment.

**D13 · Reopen next shop**  
**Free** · B04 · S01 S12  
Create a new shop ID and draft from selected recurring inputs. Ask about open deferrals and one reusable dinner. Clear stale quotes, store offers and old checkout status. **Acceptance:** Reopen the last shop, reuse one familiar dinner and review outstanding staples in a new draft. If someone bought the coffee already, mark it handled and verify the new list has no coffee charge.

**D14 · Read and recover offline**  
**Free** · B01–B04 · S01 S08 S20  
Write data and local revision in one durable transaction. Replay after process death with local/remote timestamps; keep a recent working version, dated handoff and accessible retry. **Acceptance:** Restart in airplane mode and open the latest local save and last sent snapshot. At large type and with VoiceOver, read the item, quantity, dinner and status without relying on color or a swipe.

**D15 · Keep control of family data**  
**Free, including after membership ends** · B05 · S19 S20  
Separate helper projection from owner backup. Stage, validate and diff imports before a transaction. Provide correction, scoped deletion, restore and redacted support export on Free. **Acceptance:** Preview a scoped shared copy separately from a personal recovery file. Correct, undo, export readable and structured records, recover and delete with scope shown. Importing a backup beside newer records preserves them and offers help.

**D16 · Learn from the first result**  
**Free, consent optional** · B11 · S11 S20  
At end of shop offer optional coded outcome; tie to eligible shop and baseline with no grocery text. Suppress prompts during active planning and on consent decline. **Acceptance:** Let a shopper distinguish acted, unchanged, too late, unknown, already knew and wrong. Declining feedback leaves the trip usable. Measurement omits grocery text and assigns zero incremental benefit to an observed tie.

### Shared implementation contracts

**F01 · Quantities and money**  
**All quantities and calculations** · B01 · S03 S04 S05  
Use typed Money, Quantity and UnitBasis value objects. Keep original literal, normalized rational, confirmed conversion, currency and explicit rounding policy; null means unknown. **Acceptance:** Keep distinct IDs for lines, meal demands and packages, original text, decimal amount, unit, conversion basis, currency and rounding. Two 15 oz cans stay two packs. Dual printed measures describe one demand.

**F02 · Sources and allocations**  
**All list and meal edits** · B02 · S02 S04 S14  
Store contribution IDs and allocation edges. Merge only compatible units/products and confirmed duplicate semantics. Remove one source in isolation. Enforce exclusion rules before candidate ranking. **Acceptance:** Retain each manual, meal or reservation contribution when merging compatible lines. Remove one recipe and verify that other meals, lunches and a manual staple survive. An excluded ingredient cannot become an accepted match.

**F03 · Draft and sent versions**  
**All shops, snapshots and retailer actions** · B02–B04 · S06 S08 S17  
Give templates, occurrences, drafts, immutable revisions, submitted lines, proposals and fill events independent IDs. Every external-action receipt identifies its actual base. **Acceptance:** Version usual meal, weekly draft, sent copy, confirmed order and actual fill independently. Apply against the reviewed base once. An edit to a submitted order remains a proposed amendment until confirmed by the retailer.

**F04 · Price evidence**  
**All money figures** · B03 · S03 S05 S07 S11  
Attach store/mode/slot/time/eligibility source and charge basis to observations. Separate expected, hold, pending, posted, included credit and top-up; never add a net credit twice. **Acceptance:** Attach source, store, time, mode, slot, eligibility and included charges. Keep estimates, holds, posted charges, credits and top-ups distinct. $37.20 posted with a $2.40 pending credit still shows $37.20 paid. A net charge retains an included credit once.

**F05 · Offline and sharing rights**  
**All sharing and offline writes** · B06 · S19 S21 S23 S24  
Keep auth principal, household membership, role epoch, one-shop grant, planning seat and retailer authority distinct. Recheck them server-side on every read or mutation. **Acceptance:** Separate membership, link scope, editing and retailer action. Limit each shop to one active shopper. An authorized handover transfers that role. A forwarded note conveys information only. Retries deduplicate by operation while distinct real purchases survive.

**F06 · Language and access**  
**All languages and assistive access** · B01–B10 · S02 S10 S20 S22  
Use string catalogs and web locale catalogs, formatters and layout direction. UI language, original text/units, recipient language and transaction currency have separate scopes. **Acceptance:** Separate interface and recipient language from original food wording, units, currency and store region. Exercise long text, RTL layout, plurals and spoken labels. A US Spanish message preserves no-salt, pack size and USD.

**F07 · Storage and recovery**  
**All local records and exports** · B05 · S10 S20  
Identify files by origin, revision, projection, format and canonical digest. Use bounded decoding, staging and transactions. Keep conflicting revisions as siblings; identical retry reopens the earlier copy. **Acceptance:** Version and migrate structured files with stable identities. Preview selected media and recovery scope. Reopening an identical source and revision finds its existing copy. A malformed file leaves local records intact and support needs no full receipt.

**F08 · Connections and operations**  
**Offline baseline and online household service** · B06–B07 · S06 S21 S24  
Queue client operations with stable actor-scoped keys and synchronize authoritative revisions. Show local save, waiting, conflict, server received and retailer report as distinct states. **Acceptance:** Distinguish copying a list, syncing a request, saving a family decision and reporting an order placed. A failed sync retains a retryable local draft. A copied list never confirms an order.

**F09 · Purchase and measurement**  
**All billing and measurement** · B08 B11 · S18 S19  
Verify Apple transactions on the server for shared service, dedup notifications, reconcile restore and seats separately. Never restore authority or consent from a receipt or file. **Acceptance:** Keep consent, eligible weeks, comparison baseline, membership and Apple billing separate. Exercise pending, restore, grace, cancellation, expiry and refund. A second device or refunded sale cannot count as a second willing household.

### Household planning

**P01 · Usual dinners and rotations**  
**Household, with one reusable dinner free** · B08 · S13 S14 S25  
Clone chosen nights of approved versioned templates into weekly occurrences. Modify only this week unless an authorized adult explicitly changes the template. Support pins and rotations. **Acceptance:** Select multiple familiar dinners or selected nights of a rotation. Preserve dish-specific rules and overrides. Editing Wednesday in this week's copy leaves the next ordinary week intact. Compare total effort with reusing the family's existing template.

**P02 · Pair dinners across the pack**  
**Household or isolated preview** · B08 · S14 S15  
Enumerate approved unscheduled candidate dinners and confirmed leftovers; solve whole-pack and time constraints, reprice entire basket and compare the same mouths and lunches. Explain which pack changed. **Acceptance:** Pair familiar meals using unreserved food. Include all other ingredients, packs, fees, accepted portions and prep time. The three-pepper example must cover lunches in both alternatives before reporting a checkout change.

**P03 · Adjust people and plans**  
**Household automation, free manual edits** · B08 · S16 S17 S25  
Apply guest/away/plate deltas to the occurrence and serving groups. Recalculate all dependent packs/fees. Show isolated preview, give free manual editing an equivalent path. **Acceptance:** Adjust guests, nights away, vegetarian plates, lunches or sides. Preview the smallest change and cost. Moving from eight to nine needed wraps triggers a second eight-pack for review and preserves the lunches.

**P04 · Recover tonight's dinner**  
**Household suggestions, free manual repair** · B08 · S08 S09  
Evaluate only confirmed household-accepted fallbacks against actual yield, exclusions, prep time and reservations. Show one feasible repair and smallest top-up; ask before an extra trip. **Acceptance:** Filter the family's accepted meals against actual fill, confirmed yield, time, exclusions and protected portions. With an unavailable ingredient, show a feasible top-up or leave the need open. Compare time to using the household's usual fallback.

**P05 · Prepare the next trip**  
**Household assisted review, free open deferrals** · B08 · S01 S12  
Use prior reviewed needs, purpose, store and disposition to suggest next-trip work. Reprice only after user selection. Another person buying an item can close its obligation. **Acceptance:** Recall previously approved staples by purpose and store, then ask what is needed this trip. A month-old checked market item stays checked until reopened. Count re-entry time alongside prompts and duplicate purchases.

**P06 · Show what changed since sending**  
**Household automated comparison, free dated copies** · B08 · S06 S10 S17  
Compute additions/removals/unresolved against last intentional send for that shop and helper. Report acknowledgment separately; send a full instruction if destination is uncertain. **Acceptance:** Compare adds, removals and unresolved items against the last intentional handoff to this recipient. A stale edit requires review. If a prior message may have gone elsewhere, the correction includes the full current instruction.

**P07 · Family decision history**  
**Household history tools, free access to saved records** · B08 · S12 S14 S20  
Query completed decisions by dish, product and occasion. Show actual/unknown and temporary/permanent separately. Promote a one-shop preference only on explicit action. **Acceptance:** Find past dish-specific approvals, exclusions and what actually happened. Missing outcomes stay unconfirmed. Retaining an emergency substitute as a lasting preference requires the household's explicit choice.

**P08 · One household offer**  
**One Household entitlement for two named adults on supported iPhones** · B08 · S18 S19  
Map verified product to one household and up to two named adult seats. Provide restore, manage, transfer/revoke seat and entitlement status. Preserve free data access on lapse. **Acceptance:** Show the actual localized annual StoreKit price and renewal terms, Apple confirmation, manage and restore. The US $49.99 figure is a test assumption only. Verify second-seat access and recovery. Pending purchases do not activate tools. After expiry, records open and export and one dinner remains reusable. A seat grants no automatic shop access. Renewal or restoration cannot create a third active seat; a child cannot occupy either seat.

### Import, access and connections

**E01 · Bring a recipe library**  
**Free manual entry and staged file import; assisted multi-dinner reuse requires Household** · B05 · S02 S14 S20  
Implement versioned RecipeImport adapter with a documented Recipe JSON-LD file profile (Recipe objects and graphs). Stage title, yield, note, ingredient strings and source; report unsupported shapes; support one-batch rollback. **Acceptance:** Import one documented recipe-library file format with title, servings, source, notes and linked needs. Preview matches, duplicates and skipped rows, then undo the entire batch. A malformed file must preserve existing meals.

**E02 · Photo and scan**  
**Free optional capture with supported camera, photo picker or local recognition** · B09 · S02 S04 S08 S14  
Opt-in camera/photo picker plus on-device OCR/barcode parsing. Stage source image/reference, uncertain fields and receipt lines. Unknown barcode requires manual match. Review cannot auto-certify a price, receipt or safe ingredient. **Acceptance:** Attach a package reference photo. Offer reviewed recipe OCR, barcode identification and receipt-line capture. Preserve original text/image for comparison, flag unreadable quantities and allow typing. A low-light bilingual capture can be corrected without confirming a price or marking an item received.

**E03 · Current shared view**  
**Free scoped online shared view, separate contributor and shopper grants** · B06–B07 · S10 S20 S21  
Offer authenticated one-shop read projection and separate editor grant. Scope each field/record, expire/revoke online, show as-of on cached/exported copies. Submit proposed edits for shopper approval. **Acceptance:** Share a revocable, expiring current view for one shop on iPhone or Android/browser. A separately authorized editor reviews conflicting stale changes. Keep one active shopper. A contributor sees only their own requests. Revoking a link blocks fresh reads and edits. Label offline copies with their save time.

**E04 · Spanish handoff and interface**  
**Human-reviewed US English and US Spanish strings, help and purchase copy** · B01–B10 · S01 S10 S18 S22  
Ship reviewed en-US and US Spanish across help, purchase, voice, errors, validation and handoffs in both directions. Preserve original text, units and store quantities on every locale change. **Acceptance:** Support handoffs in both language directions and the full core and subscription flows in US Spanish. Preserve original item text and allow edits. Check pack count, local date, exclusion and amount due with speakers of both languages, including after a locale change.

**E05 · Confirmed retailer connection**  
**Deferred integration, outside the first release** · Later · S06  
Isolate the retailer adapter and capability ledger. Launch ships copy/share and user-open only. Before an official cart-write rollout, prove scopes, permissions, local price/fill limitations, idempotent add and response verification. **Acceptance:** Keep the historical ID to preserve the decision trail. The shipped handoff is copy or share of shopper-reviewed household lines and user-directed checkout. No provider credential, integration or live retailer access is a release prerequisite.

**E06 · Pantry and freezer carryover**  
**Free manual entries; assisted pairing requires Household. Optional household-entered storage and batch details** · B04 B08 · S04 S08 S12 S15  
Store household-entered pantry/freezer lots, confirmed yield, observation time, reservations and use-first preference. Carry over only what has been confirmed; never create leftover servings from a theoretical remainder. **Acceptance:** Record a dated pantry or freezer batch, usable quantity, reservations and a use-first hint. Confirm before carrying food into a dinner. Five portions cannot cover four dinners and two lunches. A correction updates dependent meals once.

**E07 · Faster shopping access**  
**Free supported iPhone surfaces, with privacy and accessibility checks** · B09 · S02 S06 S20 S22  
Store-scoped aisles, manual sort, dictation, locked-safe widget/App Intent, share extension inbox and print layout. Reuse domain actions. Extension cancellation must not create a confirmed line. **Acceptance:** Provide store labels, aisle grouping, keyboard dictation, a scoped widget, selected-text share extension and large-print list. Compare finding one item across long lists. The locked widget hides budget/private notes and a cancelled share import leaves the draft intact.

**E08 · Optional reminders**  
**Free, explicit notification permission** · B09 · S07 S12 S20  
Schedule local notices for explicit deadlines or deferrals. Store time zone, expiry and quiet hours; cancel/reschedule on edit or revocation. Open current state and re-evaluate expired offer. **Acceptance:** Choose a specific deferral or offer deadline, local time, quiet hours and expiry. A delayed notice after cutoff opens Await pickup. Turning reminders off leaves the ordinary shop usable.

**E09 · Price and budget history**  
**Household history and period planning, free current-shop budget preview** · B08 · S03 S05 S11 S20 S27  
Keep observed price history by pack/store/channel plus optional period envelopes and allocations. Reconcile pending vs posted; display remaining as conditional if shops are incomplete. **Acceptance:** Review household-entered prices by store and mode. Reserve future shops in an optional pay-period envelope. Distinguish warehouse from web, deferred spend from savings, and incomplete periods from verified balances. Restrict budget and payment information to authorized adults.

**E10 · Other surfaces and markets**  
**US launch coverage, mobile web on supported browsers, market-by-market release checks** · B07 B10 · S10 S21 S22  
Serve responsive contributor and one-shop cook views on supported iPhone/Android browsers. Do not expose a native adult account to helpers. Validate each market independently before enabling it. **Acceptance:** A helper on Android/browser can receive instructions and submit, inspect or withdraw their own request within shop rules. Gate specific chain, language, currency, unit and market claims on local checkout fixtures and support. Test the mixed-phone task without a native companion or adult account sharing.

### Gen 15 additions

**N01 · Family request inbox**  
**Free on participating phones, including invited kids with the appropriate guardian setup** · B07 · S21 S22 S23 S24  
Redeem a narrow invite, receive reviewed requests, clarify/link/add/defer/dismiss. Keep each author's receipt. Freeze current basket at checkout, route late writes by server state and require authority/revision checks. **Acceptance:** An invited author types or speaks, reviews and submits. Only the active shopper may merge, add, defer or dismiss. Show the shopper the full-budget preview first. Locking for checkout protects the basket. Placement routes new and undecided requests to Next shop. Deduplicate retries. Contributors receive only their own request status and no budget or payment fields.

**N02 · Structured speech entry**  
**Free request entry, optional speech with a typed equivalent** · B09 · S02 S22  
Optional on-device speech captures a bounded draft. Parse item/count/unit/pack/purpose/destination, distinguish negation and ambiguity, review material amounts, then send precisely once or cancel. **Acceptance:** Preview item, pack count, amount and destination. Correct one field. A contributor confirms a request only. For the shopper, selecting Apply can update the local planning draft. A retry affects the intended record exactly once.

**N03 · Dinner readback**  
**Free, optional on-device playback where supported** · B09 · S10  
Render a current dated instruction and request playback of that exact projection. Pause/stop/repeat, stop on route change, avoid overlapping VoiceOver, require user action to resume. **Acceptance:** Read the selected current cooking instruction with pause, stop and repeat. Use confirmed usable quantity and reservations, keep the dated text visible and omit private budget by default. VoiceOver and readback must not talk over one another.

**N04 · Product-name corrections**  
**Optional, device-local and editable** · B09 · S02 S20 S22  
Device-, profile- and locale-scoped correction records. Offer a spelling after an explicit correction; preview on future matches, delete or opt out. No rewriting old requests. **Acceptance:** After the user corrects a recognized product name, offer to remember that correction. Show it for review at the next matching entry, preserve original wording and let the user forget it without changing past records.

**N05 · Source on manual recipe**  
**Free manual recipe entry** · B05 · S14 S26  
Save a user-entered source URL and original recipe data independently. An optional URL is attribution, not a network fetch or license. A missing site never invalidates the dinner. **Acceptance:** Paste an optional source URL alongside the family's own meal title, servings and notes. A failed import or vanished page leaves the editable dinner and its weekly allocations intact.

**N06 · Recovery comparison**  
**Free record and backup recovery** · B05 · S20  
Compare source namespace, immutable revision, parent and projection. Preserve unrelated/newer records on Cancel or restore. Never use backup ownership as an authentication signal. **Acceptance:** Compare the selected backup's source, date, revision and affected records with newer local work. Preview which records match, conflict or are absent, then recover separately. Cancelling or importing a corrupt file makes no changes.

**N07 · Spoken guest preview**  
**Household guest automation or isolated preview, free manual guest edit** · B09 · S16 S17  
Route a guest utterance to an identified meal/count proposal. Use the identical planner as manual editing, expose pack and cap changes and check current authority before Apply. **Acceptance:** Say one more guest, confirm which meal and count, then review pack, protected lunch and checkout effects on screen. Cancel discards the preview. Apply once creates a draft revision, and any order amendment still needs retailer confirmation.

### Owner-approved additions

**A01 · Household meal-week calendar**  
**Free manual planning; Household assisted changes** · B10 · S25 S14 S16  
Build an adult-only seven-day view of meal occurrences, servings, away nights, guests, sides and protected lunches. Move or edit an occurrence as a proposal. Reuse the same guest and reprice operations as S16. **Acceptance:** Move Thursday's dinner across a local date boundary. Lunches and other meals remain intact; the original rotation is unchanged. A contributor cannot read the week.

**A02 · Editable dinner ideas**  
**Free suggestion and manual review; Household assisted pairing** · B10 · S26 S14 S15  
Produce an editable candidate using app-owned templates or household-approved variants. Show source, quantities, yield, time, assumed extras and exclusions. Accept into library, then separately schedule, then explicitly apply a shopper-approved change. **Acceptance:** An unknown yield prevents a coverage claim. Editing or discarding an idea makes zero basket changes. Reject an excluded ingredient; approving a corrected idea does not yet schedule it.

**A03 · Compare two entered store quotes**  
**Free manual comparison; adult with budget scope** · B10 · S27 S03 S05  
Branch two private quote scenarios from one commitment set. Record package/availability, quote freshness, fees and mode per store, incremental travel money and time. Label incomplete alternatives; choose one to preview adoption. Keep store price and trip money separate. **Acceptance:** A cheaper shelf basket becomes more expensive after its extra trip. Missing fee leaves the winner unknown. Adopting a quote invalidates stale offers and cannot change an already placed order.

### Product boundaries

**X01 · Grocery marketplace and delivery**  
**Excluded** · Boundary · S06  
Use retailer-directed checkout and truthful handoff states. No payment, fulfillment or marketplace service. **Acceptance:** The shopper completes payment, slot selection and ordering with the retailer. Copy and share never create an ordered or delivered state.

**X02 · Universal deals and store routing**  
**Excluded** · Boundary · S05 S27  
Keep universal discovery/routing out. The approved A03 only compares two shopper-provided, explicitly scoped alternatives. **Acceptance:** S05 compares same-shop checkouts. S27 may compare two explicit shopper-entered store quotes and incremental travel costs. The app never presents a universal deal, silently fetches stock, recommends an automatic route or places a second order.

**X03 · Medical or allergy decisions**  
**Excluded** · Boundary · S07 S09 S26  
Never infer medical suitability; enforce entered exclusions and send ambiguous ingredients for review. **Acceptance:** Respect household-entered hard exclusions and let the family decline any replacement. A scanned name or translation cannot certify allergen safety or suitability for a medical condition.

**X04 · Broad generated recipes and nutrition coaching**  
**Excluded** · Boundary · S14 S26  
Use A02 reviewed suggestions; keep free-form authoritative nutrition or medical guidance outside the product. **Acceptance:** Offer approved meals and manual entries. Leave a need open when none fit. No generic recipe generation, nutrition targets, diet coaching or calorie dashboard.

**X05 · Social feed and family calendar**  
**Excluded** · Boundary · S21 S25  
Use A01 for the private adult meal week. Do not build social, school or chore feeds. **Acceptance:** Record an away night or guest against the meal. A contributor request stays private to its authorized participants. No social feed, school schedule or full family calendar.

**X06 · Mandatory scanning and credential scraping**  
**Excluded** · Boundary · S02 S06 S08  
Provide optional camera and official external open, keep typing viable, never collect retailer login secrets. **Acceptance:** Complete a shop by typing and manual retailer review with camera access denied and no retailer password in the planner. Optional scan review and official shopper authorization remain distinct routes.

## Journeys and screens

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

## Appearance, behavior and language

**One person should be able to read the next decision while standing in a grocery aisle.** Lead with the item or meal, give the quantity and its consequence, then one primary action. On a $38 cap, the hero reads “Expected checkout $40.69 · $2.69 over $38.” Keep the fee basis and unknowns beside it. For a contributor the same event reads “Cereal · Saved for next shop.” Do not render the adult card underneath a privacy overlay.

## Color placement

theme.json is the token source. Generate named colors in the iOS asset catalog and CSS custom properties for web from the same file. A build check compares the generated values. Views reference roles such as `Theme.action` backed by `accent`. Raw hex values belong only in that generation step. Follow device appearance by default and offer System, Light or Dark in device settings.

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

## Who may see or change each fact

Keep prices, consent evidence and private meal constraints out of the contributor API by construction. Authenticate the session, select the current household and persona, check the actual object grant, then construct one of three response shapes: adult, own request, or scoped helper. A caller who knows a record ID gains no rights. Use the same rules on search, change feeds, exports, notifications, troubleshooting, stale-operation receipts and server-rendered previews.

## Authorization matrix

| Capability | Local guest | Invited contributor | Scoped helper / editor | Household adult | Active shopper |
|---|---|---|---|---|---|
| Private quick check, local meal/list and file | Own device | Own device outside household role | Own device outside grant | Own | Own |
| Submit/change/withdraw a pending request | Join to send | Own requests, current membership/consent | Only with a separate contributor invite | If enrolled | If enrolled |
| Read full household request inbox | — | Own requests only | — | — unless assigned shopper | Assigned shop only |
| Read private budget | Own local budget | — | — under a standard helper grant | Explicit adult budget grant for this shop | Assigned shop |
| Read current cook view | Dated copy | Separate view grant | One shop, selected fields, until revoked/expired | Explicit scope | Assigned shop |
| Propose a change to one shop | Own local plan | — | Editor can propose only within one grant | Explicit scope | Can review and apply to assigned shop |
| Read or plan the household meal week | Own local week | — | — | Adult planning access; paid tools also require seat | Requires adult planning access; shopper applies basket effects |
| Final basket add, deferred choice, checkout freeze, placed report or amendment review | Own private local workspace | — | — | Proposal only if someone else shops | Only current epoch holder for shared shop |
| Invite, revoke, change shopper | — | — | — | Organizer with current membership, transfer via server | Shopper role alone gives no admin power |
| Child consent, export or erasure | — | — | — | Verified guardian for their child and permitted scope | Shopper role alone gives no guardian power |
| Verify purchase / assign seats | — | — | — | Server verifies purchase, authorized account manages seats | Shopper role alone gives no billing power |

**Visibility examples.** Sam receives `{requestId, revision, originalItem, ownQuantity, authoredAt, receivedAt, route, status, ownActionAllowed}`. Optional shopper clarification uses a purpose-built message visible to Sam only; never expose another request or its author to explain a merge. A helper receives dated item/amount/action/basis and optionally authorized fields for this shop. Mia sees the private before/after preview, unknown facts and protected portions. Session refresh, role transfer and child revocation invalidate old projections and caches. When identity is unclear, show the least privileged sign-in or local option.

## Build architecture, storage and operations

Choose **SwiftUI for the iPhone**. The product needs Dynamic Type and VoiceOver in dense lists, offline recovery, local speech and OCR, StoreKit, widgets and a share extension. Native targets let the team exercise those paths directly. The existing Expo starter is not a dependency of the new app. Use iOS 17 as the proposed deployment floor for the first build; record the actual tested OS/device/locale matrix and current submission SDK before release. Gate optional OS/device capabilities at runtime and always keep typed entry. Build and sign on macOS/Xcode; Windows can validate the blueprint, fixtures and web/service logic.

Use a **modular monolith** for the service plus a responsive TypeScript web client. Suggested initial backend is TypeScript with a single HTTP process and PostgreSQL, backed by a worker from the same codebase for expiry, sync notification, deletion and StoreKit reconciliation. Use managed TLS, a secret manager and encrypted object storage for explicitly retained media. Choose the hosting vendor during environment setup. The service owns household authority and authorization; the phone owns its offline draft, UI preferences and unsubmitted private data. The web app is for invited contributors, one-shop helpers and authorized proposals. No public family directory.

Suggested repository layout when implementation begins:

```text
ios/RoomInTheCart.xcodeproj       app, widget and share-extension targets
ios/App/                         environment, session routing, tab shell, composition root
ios/Packages/CoreDomain/          value types, calculators, policies, use cases; no UI or I/O
ios/Packages/LocalStore/          SQLite migrations, transactions, files, recovery
ios/Packages/HouseholdClient/     authentication, typed service API, outbox, cursors
ios/Packages/DesignSystem/        semantic colors, typography, shared states and components
ios/Features/                    Shop, Dinners, Household, Records, Capture, Membership
ios/Extensions/                  small widget snapshot and explicit share-import staging
service/src/                     auth, households, shops, planner, sync, files, billing, jobs
web/src/                         invite, own requests, cook view, proposed change, device state
shared/contracts/                versioned DTOs, fixture vectors, tokens, locale keys
tests/                           contract, scenario, migration, UI, accessibility and load tests
```

**Dependency rule.** SwiftUI views send intents to a main-actor feature model. The model calls a typed use case and receives a renderable result or typed error. Domain code knows no SwiftUI, database, HTTP, StoreKit or system clock. Inject a clock, stable ID provider and repositories at the composition root. Keep one implementation per platform of each shared algorithm; both run identical cross-language vectors and use the server's authoritative recomputation when committing a shared decision. Do not put duplicate budget math in rows, previews or extensions.

**Port examples.** `QuoteEngine.compare(commitments, quotes)`, `AllocationPolicy.cover(confirmedLots, demands)`, `PlanRepository.commit(base, mutation)`, `ShareProjector.render(scope, revision)`, `CaptureEngine.preview(input, locale)`, `EntitlementProvider.status()`, `HouseholdGateway.execute(command)`. Return result variants for exact / bounded / unknown / not comparable, rather than a naked amount. Add unit, source, reason and missing facts at the domain boundary. Retain a small catalog of approved recipe-to-ingredient templates and preference filters; dinner ideas work without an external generation service.

**Navigation and state.** A session router chooses guest, contributor, scoped helper or authorized adult before constructing screens. Adult tabs own navigation stacks and restore non-sensitive routes by opaque ID. Switch persona by tearing down its view models, private cache, speech buffers and pending notification targets. Only a protected adult session can reopen private screens. Each modal owns one cancellable preview. Keep sync status and local save status distinct in per-feature models. Revalidate permission and existence when restoring a scene, deep link or widget URL.

## Persistence, private use and offline sync

1. First launch creates an installation-local workspace with random IDs, SQLite foreign keys enabled, versioned migrations, atomic writes and a serialized writer. No account prompt for an item check. Protect database, backups and selected media with appropriate iOS Data Protection; keep credential material in Keychain. Use separate workspace keys/paths per enrolled persona; never expose the adult database to the widget, extension or child web client.
2. Joining a household is explicit. Preview which local shops/records to retain privately or import. Create safe new membership linkage and merge by verified origin and revision. Never upload anonymous-shop contents merely because someone signs in. Losing membership ends household service access; let an adult keep or export properly owned personal records.
3. Transactionally persist the local change, immutable local revision/event and eligible outbox operation. A queued proposal cannot advance the shared basket locally as if committed. Resume with the same operation key after crash; check household membership again. Server commits the decision, derived records, audit receipt, projected change feed and cursor in one transaction. Push carries only a wake-up hint. On launch/foreground or manual retry, pull authorized changes from the cursor.
4. A client records cursor and applied events in one transaction. On a gap/expired cursor request a scoped re-bootstrap. Detect version/authority conflicts explicitly. Keep both draft and server result for review. No automatic last-write-wins for purchases, quantities, membership or consent. Retry transient failures with bounded exponential backoff and jitter. Honor Retry-After. Stop pending writes on logout, revocation, permanent validation errors and mismatched payloads.
5. Web stores only own minimal projection. First redemption and initial load need the network. Offer a local browser outbox only when durable storage is supported, an enrolled identity exists and consent allows it. Handle private browsing, quota exhaustion, stale cookies and shared devices. A failing write says “Not saved”; offer a user-controlled copy. Reauthenticate before sending queued work and purge scoped storage after revocation or logout.

**Device surfaces.** WidgetKit reads a separate minimal App Group projection written only after a successful commit. Locked state hides private text and all budget details. A widget/App Intent can open a named capture destination; require authentication and review before any protected mutation. The share extension stages explicit user-selected text/files in a bounded inbox, acknowledges only a successful write, and imports into the app for review. The receiving app never reads the clipboard on launch. Use Vision for local text/barcode proposals; a barcode is an identifier, not a trusted price/product label. Use speech only after a tap and permission check. Custom child recognition requires a verified on-device path for the actual locale/device; otherwise typed entry works. Keyboard Dictation follows OS settings. Use local speech synthesis for a current cook instruction without requesting a microphone.

## Service identity and privacy

Default to a managed standards-based adult login supporting a verified Apple identity or email/passkey flow. Validate issuer, audience, expiry and nonce; exchange into app sessions, rotate refresh tokens and support all-device revocation. Treat email and account identity as server-private. An opaque invite token is short lived, single use, hashed at rest and limited to a role, household and intended enrollment. A helper grant has its own opaque scope, expiry and revocation. Exchange a link at first contact, strip it from the URL, use secure HttpOnly cookies and CSRF protection on web, no external trackers on invitation pages, and `no-store` for sensitive responses. Do not use a household password shared with a child. Recover adult access through verified identity, never from an imported file or an alias.

**Child enrollment gate.** Before enabling a child's networked profile, identify the actual parent/guardian, present direct notice and use a reviewed verifiable parental consent method where required. Route guardians without in-app identity to an authenticated verification flow; use a provider reference and policy version, not a copy of an identity document in app records. Block all child network submission/audio until consent and membership are active. Provide parental access, correction, withdrawal and deletion. The contributor DTO excludes budget, receipts, other requests, private meal constraints and membership lists. Keep request attribution limited to household alias. Disable child advertising and behavioral analytics. Never retain raw speech; redact free text from crash logs and lock-screen notifications. Verify the final consent method and written retention policy with a qualified reviewer before enabling child enrollment. [FTC child privacy rule](https://www.ftc.gov/legal-library/browse/rules/childrens-online-privacy-protection-rule-coppa) · [FTC guidance](https://www.ftc.gov/business-guidance/resources/complying-coppa-frequently-asked-questions)

**Data lifecycle.** Collection is purpose-bound. Define numeric retention settings and named owners in the deployment policy before beta: expired invite hashes, pending reservations, ended child profiles, inactive media, stale outbox rows, dedup receipts, telemetry, audit evidence and rotational backups have separate lifetimes. No indefinite child records by default. Link a deletion job to field-level redaction, file removal, cache invalidation and tombstones; record completion without free text. A parent may remove child attribution while preserving a shopper-owned, de-identified basket line when appropriate. After restore, replay deletion tombstones before serving data. Expiry and purge of backups must be tested. Explain the lifetime of a static copy someone already sent. In-app account deletion is distinct from subscription management, leaving a household and deleting a local shop. [Apple account deletion](https://developer.apple.com/support/offering-account-deletion-in-your-app/)

**Billing.** Use StoreKit 2 product metadata, `Transaction.updates` plus current entitlements and verified signed transaction reconciliation. Submit the signature to the service; validate its Apple chain, bundle, environment, product, transaction and renewal status. Scope the verified purchase to the purchasing account and explicitly selected household. Store transaction IDs and support duplicate/out-of-order server notifications, renewals, expiration, revocation/refund and restore. Pending/cancelled checkout grants nothing. Turning off auto-renew retains access through paid expiry. Honor verified grace when applicable; never invent indefinite offline grace. A signed, expiring cached entitlement can unlock authorized local tools until its known expiry, while Free data access remains. Finish a purchase after durable delivery. Seat assignment cannot transfer the subscription or grant shop authority. Test restore on a second device and wrong-household restore. Display the real localized price and renewal terms, manage/restore affordances and links. Two adult app seats are an app entitlement decision distinct from Apple Family Sharing. [StoreKit entitlements](https://developer.apple.com/documentation/storekit/transaction/currententitlements) · [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)

## Expansion without a rewrite

Version commands and exports separately from schema migrations. Add optional fields first, dual-read old and new records, backfill with an idempotent job, deploy readers before writers, and retire a field only after supported old clients are accounted for. Use stable IDs, UTC instants plus named time zones, integer currency minor units and exact quantity fractions with a source basis. Use capability flags by environment, market, platform, language, integration and entitlement. Flags guard availability; the complete first release includes all 52 launch contracts.

Separate dev, staging and production bundle IDs, databases, push domains, secrets and StoreKit environments. Provision through repeatable reviewed migrations. Never expose production credentials in app binaries, sample data or support exports. Apply server-side household isolation to every read and write; use least-privilege service roles and an explicit authorization layer even when using database row-level protection. Quarantine attachments by verified type, size, decompressed size, file count and safe path. Never automatically fetch arbitrary source URLs in a privileged service.

Operate the service with content-free metrics: command latency/error code, sync age, queue depth, conflict/replay rates, deletion lag, checkout math errors and billing verification failures. Log request IDs and coarse outcome categories, never transcripts, invite URLs, private notes, receipts or exact products. Back up and restore staging under a measured recovery objective; monitor backup age. Rate-limit enrollment, token redemption and mutation per actor/household; cap batch size and paginate projections. On service failure preserve private local work; keep shared approvals pending. Roll back code by compatibility window; repair data forward or restore to an isolated branch before reconciliation.

Sources for device implementation: [SwiftUI](https://developer.apple.com/documentation/SwiftUI), [WidgetKit](https://developer.apple.com/documentation/widgetkit), [on-device speech](https://developer.apple.com/documentation/speech/sfspeechrecognitionrequest/requiresondevicerecognition). Confirm actual Xcode SDK availability on the selected device matrix during B00.

## Foundation 2 implementation decisions

Use an explicit household-level adult planning grant for the shared meal week and approved dinner library. Check it on reads, commands, preview, sync and export. A local private week works without an account. A paid seat unlocks assistance only in data the adult can already access. An assigned shopper controls the current basket; their role alone does not reveal other weeks. A service child needs an active membership plus a verified guardian relationship and active notice-specific consent; verify evidence outside SQL. Verify or renew on re-enrollment. Never persist raw child voice, including on errors.

Compare the trusted server clock with the latest verified Apple entitlement, including superseding refunds or expirations, both at seat assignment and use. Do not select an older active receipt just because it has a later date. Rebind the two existing household slots transactionally to the current verified entitlement after a renewal; do not mint new slots. Seat reassignment is delete/insert in one transaction with an audit event; failure restores the original assignment. Review a read-only or lapsed view with real accounts before shipping.

Implementation defaults where earlier research did not specify pricing: private manual work, staged file import, supported-device capture, scoped sharing, reminders and manual pantry/calendar/quote/idea tools use the Free path. The plan sells repeated/assisted planning. Free can store or read historical meal records and plan as many individual dinners as needed; one chosen usual is reusable from the library. Picking a different usual changes that slot without erasing the old meal or its scheduled copies. Paid previews are disposable, never silently activate billing or change a shared basket.

## Meals, quantities, money and files

**Common representations.** Use opaque random stable IDs (including client-created ones); namespace every operation by household and actor. Use date-only values for the meal day and local meal-slot zone; use instants plus IANA zones for deadlines, quote timestamps and events. Changing display locale never changes currency or a deadline. Preserve source text/locale, amount as rational numerator and positive denominator, unit dimension, original package label and conversion basis. Use checked integer/decimal arithmetic; prohibit negative food quantities, NaN, zero denominator, invalid currency, overflow and accidental float-based dollar comparisons. Signed financial adjustments are intentional. Version lookup tables for pack conversions. A unit change never overwrites the original observation.

**Visibility drives storage.** Service owns verified credential/consent, purchase proof, grants, operation receipts and authorization history. Adult devices may cache only included fields permitted for that member and grant. Contributor gets only addressed request records and its own statuses. Helpers get a precomputed redacted projection for a single shop; unauthorized keys must never reach the browser network response. Use separate encryption, storage lifetime and retention for identifiable payloads versus structural revision/event IDs; explicit erasure overrides byte-for-byte historical reconstruction of personal text.

## Calculation contract

1. **Normalize demand.** Track each accepted need, required servings, edible units and original label. Convert only within a known dimension or with an ingredient/pack-specific confirmed basis. Two cans each labeled 15 oz are two packs, not 30 cans. Dual printed units describe one demand. Distinguish a protected reservation that partitions an existing total from a separate additive need. Never consume the same lot twice.
2. **Buy enough in whole packages.** For compatible units: `to_buy = max(0, total_accepted_need − confirmed_uncommitted_supply)`; `packs = ceil(to_buy / confirmed_usable_units_per_pack)`. First subtract other households' or other dishes' reservations from available supply exactly once. Compare total spend to cover the need, remaining shortfall and surplus potential. Unconfirmed or variable yield produces a bound or question; it cannot establish dinner coverage. A material uncertainty remains visible if the family proceeds anyway.
3. **Choose viable changes.** Check hard exclusions and food/portion constraints before ranking. Compare matched store, slot, currency and commitments. Rank valid options by fewest accepted changes meeting the cap, then expected inclusive checkout; keep ties explicit. Never assume an undecided staple may wait. Ask the next question only if its answer changes feasibility or selected action; if the basket already works, offer to keep it. If no allowed scenario works, show the best known alternative with its shortfall and unresolved needs. Avoid combinatorial explosion: bound search to the shopper's active choices; return “more possibilities untested” on budget/time limit.
4. **Price the whole pickup.** Sum pack costs plus explicitly applicable discounts/taxes/fees/deposits using matched basis. Evaluate threshold against the eligible components, with named rounding and inclusion rules. Use an inclusive user-entered total as a separate basis; do not add fees twice. Exact totals require complete evidence; allow a documented lower/upper bound only when all uncertain components are bounded. A label “within cap” requires the upper bound at or below a comparable cap; a known lower bound above cap can establish an overage. Otherwise show “Need price/fee.” Do not infer that a lower checkout meets budget. An item-only or dinner-only cap never authorizes a full-checkout statement.
5. **Evaluate retailer changes.** Show the smaller of the line-specific ceiling and remaining whole-cart headroom after other committed lines and retained original quantities; re-evaluate fee changes. Solve whole-pack feasibility jointly for simultaneous offers. For a price per weight, report maximum affordable weight at the relevant rounding/billing increment or request the total weight. Preserve hard deadline separately from pickup time. Past cutoff routes to receipt review. Only verified amendment changes the confirmed order.
6. **Reconcile.** Received amount, usable amount, reserved amount, meal shortfall, actual outcome and posted money are six different facts. Reduce availability on a damaged count without reducing money paid. A duplicate receipt message never creates a second delivery; a second genuine partial delivery does. Do not retroactively reprice a minimum-order fee after a retailer-caused short fill. Leave untouched lines unverified. Report cash paid so far separately from expected final settlement or hypothetical savings.
7. **Plan the next trip.** A saved deferral carries its outstanding need, purpose, origin and optional deadline into review. Require a fresh package and quote. A past estimate is a dated reference; a past charge stays posted. A skip/away edit before purchase may remove a whole pack; after purchase calculate carryover possibilities only. Ask before repeating a dish, changing another family's preference or making an extra trip.

## The three new decisions

**A01 · Meal week.** A date belongs to a household meal-plan zone. A week is a view over dated slots, not a second copy of the recipe library. Save an occurrence with groups such as “three standard plates, one vegetarian entrée, two lunches”; each group has its own demand. Dragging must have a non-drag Move action. Preview impact on meals, lots, remaining servings and the active shop before commit. A proposal by the second adult can update their working version; the shopper must apply any change to a shared basket. Show an explicit new revision/correction for a previously sent cook instruction.

**A02 · Dinner idea.** Start from an app-owned dinner pattern, user-selected foods and available household templates; return structured candidates with named servings, ingredient lines, units, amounts, estimated prep time, source and assumptions. Explicitly mark availability and yield unknown rather than inventing them. Rule out hard exclusions and preserve original substitutions for review. Give an adult editable fields and an ordinary manual route if no candidate qualifies. Lifecycle: *idea draft → reviewed candidate → accepted dinner → scheduled occurrence → proposed shop change*. Each arrow is an intentional command, can be cancelled between steps and has independent revision identity. If a generator returns contradictory or disallowed content, block approval, retain the draft for correction, and never change pantry or basket. Free manual/suggested ideas; Household pairing works only with approved meals. No remote model, personal-text transfer or nutrition promises are required to ship a useful first version.

**A03 · Two store quotes.** Each alternative represents a complete plan for the **same household commitments**. The shopper supplies store/branch, mode/slot, all needed products or confirmed equivalents, quantity/stock status, currency, timestamp, prices and fees. Record incremental trip cash separately from the grocery checkout and travel time separately from cash; time is never monetized by default. Confirm whether each trip would already happen and whether pickup/delivery fees are included. Compare two named single-store alternatives for the same purchase. Either alternative can incur an extra stop relative to the household's existing travel. Enter that incremental cost once. Where other already-committed purchases are identical, show them as a common baseline. If a multi-store split would change fees or item coverage, flag the alternatives as incomparable and ask for two complete quotes. No route search or live stock feed. With insufficient data show partial totals by column and which fact would settle the comparison; do not crown a winner. Always show each checkout against its own applicable cap scope. Choosing an alternative starts a review on the current draft; keep the original quote proof and never mutate a placed order.

Worked example, fictional, same family needs and USD. Store A items $36 + pickup fee $2 = **$38 checkout**. Store B items $34 + fee $1 = **$35 checkout**. If B needs $4 additional travel and 18 minutes while A is on the normal route, the trip-inclusive costs are **$38 versus $39**, so B's checkout is $3 lower while the overall cash outlay is $1 higher. An unknown B fee or an unavailable required pack yields no confirmed advantage. Leave each number, basis and time visible for the shopper to decide. Do not classify an unpurchased counterfactual as a saving.

## File and import protocol

Use separate mimetypes/file kinds for a recovery archive, a redacted shop file, a plain/print cook instruction and a recipe import. A v1 envelope carries format major/minor, document kind, origin namespace, shop ID if applicable, source revision ID and parent, projection ID, producer build, exported time, last saved time, canonical payload digest and optional media manifest. Digest the canonical data bytes, not a localized serialization; a digest detects corruption, never authority. Retain app-owned versioned migration fixtures, also when scaling template formats later.

* **Recipe library v1.** Accept a documented UTF-8 Recipe JSON-LD file containing one Recipe, an array, or an @graph with Recipe nodes. Allow title, yield text, ingredient strings, source URL, user notes and plain-text steps. Preserve unknown quantities and original units. Report unsupported rows/fields and duplicate candidates, block unsupported major versions and malicious/oversized input. No remote context fetches, script execution, link traversal or blind parsing of a website. Stage results, preview, confirm one batch, then allow undo. Manual entry and source URL work independently.
* **Helper file.** Allowlist shop label, origin identity necessary for revision comparison, selected item label, original amount/unit/language, purpose, action, food status, as-of time and version. Include private fields only on a separate explicit adult disclosure for that recipient; default them off on the next share. Deny membership, invites, buyer/seat IDs, other helpers, consent, billing, raw receipts, private exclusions, device prefs and server secrets. Missing fields in a projection are unknown; importing them must not blank private local data.
* **Personal backup.** Show selected shops, media size and disclosure before export. Include authorized revision ancestry, quantities, lot/receipt/ledger history and owned meal preferences as selected. Do not export credentials, consent evidence, active grants, entitlement or raw voice. Encrypt sensitive backups with a user-held key or passphrase using reviewed platform cryptography and explicit key-loss UX. Always offer readable redacted export separately. Redact child attribution as required. Explicitly show what can and cannot be recovered.
* **Restore.** Stage decrypt/parse, check media sizes/types/digests and envelope. Match origin + shop + revision + projection + digest. Identical content reopens once; same revision/projection with different digest is quarantined. Two children of the same parent are branches, even with identical display numbers. Keep newer local and unrelated work. Present match/conflict/absent, allow independent recovery and optional explicit reviewed merge. Unsupported/corrupt/cancel leaves current data intact. Reapply known erasure markers, exclude expired authority and purge unwanted staged files. For household reattachment, reauthorize and recheck server deletion state first.

## Concrete acceptance vectors

| Input | Must return |
|---|---|
| $37.20 pickup + one $3.49 box against $38 | $40.69 and $2.69 over. Linking one existing box to two requests yields $0 added cost without losing either author. |
| $34.80 goods + $4.95 fee; cereal changes goods to $38.29 and removes fee | $39.75 → $38.29, lower by $1.46 and still $0.29 over $38. Missing fee → conditional, never “under.” |
| Six usable wraps in an eight-pack; two lunch reservations, six tacos and four quesadillas needed | Allocate two lunches and four taco wraps. Tacos short two, quesadillas short four. Delivery, usable observation and allocation each remain inspectable. |
| Eight needed wraps → nine needed; available packs of eight | Two packs required, with original lunches intact. Reverting a guest edit restores the old demand. |
| $37.20 charge with a pending $2.40 credit; or $34.80 net with credit already included | Paid so far $37.20 in the first case and $34.80 in the second. Do not post a pending credit or subtract an included adjustment twice. |
| A partial retained original consumes headroom, two substitutions look viable in isolation | Test inherited line ceiling $1.01 → $0.61 and joint overage $0.65. Undo both restores headroom and known shortage. See G4 UI cases. |
| Redacted revision and full backup arrive in either order; equal displayed revision but different parents/content | Preserve each authorized branch/projection. Never clear missing private fields, mint permission or overwrite the latest shop. |

## Evidence and recovery invariants

Order lines are the entries captured at placement, not a live join for their quantities or labels. Display them from the immutable placed revision and confirmed quantity. Later retailer response or corrected report appends an attributed event and, when needed, its own revision; no rewrite of the submitted order. A reported cancellation preserves the original report and opens a distinct draft. A posted cash error is corrected with evidence and a compensating signed movement of the appropriate kind, never by editing a net charge. Only posted charges, posted credits and posted top-ups enter paid cash; an included credit explains a matching net charge, and a hold never enters the sum.

Use a stable projection identity: hash a versioned description of the file kind, recipient scope and field allowlist, **not the serialized content**. The content digest independently covers canonical payload bytes. Claim the origin, record, revision and projection inside the import transaction. On a uniqueness conflict reread: identical content is an idempotent match, different content is a quarantined attempt. Never change a prior imported digest to make a conflict disappear. An explicitly reviewed merge gets a new revision. A file never confers a live grant.


## Placement corrections

A selected shop occurrence can have an unknown night. A reusable template, an accepted candidate, an unscheduled occurrence and a scheduled occurrence have distinct meanings. Assigning a date preserves the occurrence ID and every need already linked to it. Until a specific time is supplied, a cook handoff can carry its preparation date and explicitly unresolved meal deadline.

Preserve the original ingredient name for each manual stock lot. Match it to a need only after review of identity, unit and dish constraints. A derived usable amount cannot exceed received supply on a comparable physical basis. One 20 oz pack is about 567 g and cannot yield 4,176 g of same-form leftover. When units or food form differ, require a confirmed conversion/yield basis or keep carryover unresolved. A correction revisits dependent allocations. Store optional required elapsed lead time separately from hands-on prep time and ask which steps are already complete. A known unfinished 120-minute marinade cannot fit 45 remaining minutes.

The private cash-hold check uses two separate comparisons. Expected $78 versus an $80 whole-shop cap leaves $2 of headroom. A shopper-reported $86 authorization requirement versus $82 available leaves a $4 gap for that payment method. Label both bases. Releasing a hold contributes zero savings. Never store available funds in a share, account, price history or period envelope.

**Seal the original order.** The placement service acquires the household/shop lock, checks the operation identity, actor, current authority and frozen revision, and validates exact equality of source lines, quantities and immutable terms against the frozen snapshot. In a single transaction stage its order lines, insert the placed order header last, then commit. The deferred parent relationship prevents an orphan line from committing. The header seals the line set. Reject a second placement for the same placement intent even if the caller supplies fresh local IDs. Later retailer-confirmed amendments append independent evidence. SQL protects insert-after-seal, update and deletion. Semantic equality to the snapshot and command uniqueness remain service gates.

**Application record details.** Record reviewed preparation lead time and interrupted/completed steps in versioned recipe rules and occurrence data. Record the maker and time of a handled/reopened transition in the corresponding revision or event. A local urgent shortage can use a private draft shop and a meal need with optional date, plus a manually named stock lot and reviewed usable observation. Keep zero as an observed quantity when the shopper explicitly reports none. Create a reviewed food-to-need match before allocation. When upgrading a legacy store, backfill list state from its check flag, preserve known import sequence, and leave unavailable ordering or food identity explicitly unresolved for manual review. Never fabricate a meal date, store rank or pantry match.

## Network commands and synchronization

## HTTP surface, v1

Apply the field rules before rendering any S14–S17 or S25/S26 planning preview. An adult with planning access but no private budget scope may see authorized portions and propose a meal change. Omit prices, caps, cost deltas, budget-based rankings, and fields that indirectly reveal them. The assigned shopper completes the financial review. This rule also covers speech, logs, change feeds, export and assistive labels.

Use HTTPS, versioned JSON DTOs and fixed allowlists for query and mutation types. Keep optional extension fields backwards compatible and reject unknown mutation types. Serve consistent machine-readable errors with a correlation ID and a user's recovery action. Advertise maximum batch sizes, media bounds, locale/version support and cursor expiry. All commands below have a typed request validator, an authorization policy, a handler and a response projector.

| Endpoint family | Contract and transaction boundary |
|---|---|
| `POST /v1/invites/redeem`, `/households/{h}/invites`, `/revocations` | Verify identity, intent, expiry, unused token, role, guardian status and household; consume token and create/revoke grant in one transaction. Concurrent redemption succeeds once. Rejoining requires a fresh grant. |
| `GET /v1/me/workspaces`, `/households/{h}/bootstrap`, `/changes?cursor=…` | Return only permitted projections and opaque cursors. Rebuild when retention, schema epoch or access boundary changes. Authorize each event's current scope; no enumeration by guessable IDs. |
| `GET /v1/households/{h}/requests/mine`, `/shops/{s}/inbox` | First endpoint filters by authenticated author; second requires shop authority/private access. Page by server order; timestamps on a child's phone do not decide eligibility. |
| `POST /v1/households/{h}/commands` | One bounded intent per envelope below. May batch transport, but preserve per-command transaction and ordered dependencies. Shopper approvals are committed online; private guest work stays local. |
| `POST /v1/households/{h}/shops/{s}/previews` | Require adult scope. Compute approved pack, commitments digest and inclusive totals; return a short-lived identifier and input fingerprint. No purchase or basket mutation. A second adult's preview is a proposal. |
| `POST /v1/households/{h}/views`, `GET /v1/views/{grant}/current` | Create/redeem narrowly scoped share with expiry and explicit fields. Re-evaluate membership, version and revocation at read. Editor may propose a change, never apply solely through a view link. |
| `POST /v1/billing/verify`, `POST /v1/apple/notifications`, `GET /v1/me/entitlements` | Validate Apple evidence and environment; bind transactions globally to the correct purchase/household; handle replay and out-of-order notifications. Return current product access, not new data rights. |
| `POST /v1/privacy/deletions`, `GET /v1/privacy/jobs/{id}` | Require reauthentication plus owner/guardian scope. Create a durable erasure job, immediately revoke affected live grants; publish only safe completion status and support reference. |

### Example shopper decision

```json
{
  "v": 1,
  "replayWindow": "opaque-server-issued-window",
  "clientKey": "4cfe1cd5-27c3-45e8-8adc-8a52d5c57ed0",
  "kind": "request.apply",
  "shopId": "shop-thu",
  "base": {"shopRevision": "r12", "requestRevision": 2, "authorityEpoch": 3},
  "body": {"requestId": "req-7", "choice": "defer", "previewId": "preview-r12-cereal"}
}
```

An adult sees a receipt with operation ID, committed shop/request revision, actual disposition and an authorized sync cursor. Sam sees only his status “Saved for next shop.” Omit server-owned household role, calculated totals, caller-supplied child status and trusted author from the inbound body. Derive actor/device from the session. Device-generated times are evidence, never the causal clock.

**Commit sequence.** Authenticate and canonicalize versioned input. Derive the namespace `household + verified actor + clientKey`, bind kind, target, base and canonical payload digest. Open a transaction and lock the shop/membership and affected request in a deterministic order or use equivalent conditional updates. Recheck present authorization. If the key has an authorized stored receipt and digest matches, return the safe receipt without reapplying, even if the base is now old. For a reused key with different payload return `409 key_reused`. For a fresh action verify phase, authority epoch, request revision, shop head, preview fingerprint, entitlement if needed, consent, inventory and quote freshness. Atomically update line/allocation/route/revision and record operation/event; commit, then notify. Losing a response only retries the original key. Generate a fresh key after user review of a changed intent. Require a server-issued replay window bound to the enrolled household/actor/device (authenticate the presenting device). It carries an issued-at/expiry, random generation and revocation state signed or stored by the service. A queued command retains the original window and client key through retry; the window is part of its canonical envelope. Reject expired/retired windows with refresh-required before any mutation, using server time. Within a live window an authorized duplicate returns its safe receipt, or refresh-required if only the used-key marker remains. Retain markers until all windows that could present their keys expire; never rewrap an old outbox command into a new window automatically. After expiry or loss of membership, bootstrap current facts and require fresh intent. On erasure close the enrollment/windows before purging dedup markers; no grocery text survives in them.

**Errors with recovery.** `401 session_needed` → keep private draft and authenticate. `403 access_ended` → stop, clear protected cache, do not expose a prior success to a revoked user. `404 unavailable` can conceal out-of-scope resources. `409 stale_base/authority_changed` → return permitted current context and require review. `409 checkout_locked` → offer next shop, never silently alter frozen order. `422 unknown_unit/invalid_candidate` → keep fields and identify the missing fact. `429` or transport failure → retain queue, back off. A storage failure must visibly fail the local save; the system cannot say “saved on this phone” until the write succeeds.

## Command dictionary

**Receipt lifecycle.** In one commit insert the durable `operation` identity and the disposable `operation_response` row, plus the change, its event and any proposal application. Both evidence records point to the durable identity. A privileged compaction deletes just the response; its trigger retains the used key. A missing/retired response for a known operation returns refresh-required, with no original private payload and no action even on changed-body replay. Never re-create the response by executing the command. Keep referentially required identities until separately authorized erasure can remove their dependent records; close related replay windows before purging markers.

| Intent(s) | Required guards and durable effect |
|---|---|
| `request.send/edit/withdraw/clarify` | Verify author, active membership and child consent where applicable. Pending author updates increment request version. After acceptance, a correction becomes a linked follow-up; no automatic quantity removal. The author may answer a scoped clarification. Only the assigned shopper may ask it, and only about a request in their assigned inbox. |
| `request.apply` (link existing/add/defer/dismiss/handled) | Shopper + current epoch, reviewed request/preview/head, open shop for basket effects. Existing box can satisfy several requests after review; adding a genuine second box must be explicit. On defer keep obligation, no charge. |
| `shop.patch/undo/freeze/reopen/reportPlaced/reconcileReport` | Patch exact base with a new revision; reverse via a compensating revision. Freeze exact dated snapshot. Reopen a distinct revision, preserving sent/order evidence. After placed, never amend retailer truth through a draft edit. |
| `shop.transferAuthority` | Organizer-authorized transfer is online and atomic; verify old epoch, current shop and new adult's active eligibility. Increment epoch, preserve frozen basket. Stale shopper cannot close the new shopper’s revision. |
| `meal.saveTemplate/schedule/move/guest/away`, `proposal.apply` | Authorized adult or private device; captures template version and dates. Household meal planning checks the adult planning grant; scoped editors use a distinct shop proposal without calendar access. A seat controls assisted tools, not early read/write into the basket. Shopper checks base when applying a basket effect. |
| `idea.create/edit/approve/discard` | Validate sources, portions, ingredients and exclusions per current idea revision. Durable candidate approval is independent from scheduling and list application. |
| `quote.record/compare/adopt` | Private local or shop-budget-authorized adult quotes only. Quotes can be incomplete; forbid a comparable-winner claim with missing facts. Adoption requires current shopper, same commitments and an open draft. Preserve quote snapshot after adoption. |
| `offer.record/decide/expire`, `amendment.recordResponse` | Record deadline/offer evidence, pending choice and provider response separately. A late local preference cannot resurrect a retailer opportunity. Explicit confirmation or manual evidence determines status. |
| `fill.record/correctUsable`, `stock.confirm/reserve`, `ledger.append` | Verify source identity, dimension, same shop/lot and prior observations. Keep partial/split delivery history; reject over-allocation; correction creates a new record. No financial effect from a meal repair. |
| `handoff.prepare/recordAction/acknowledge` | Explicit destination/projection. Cancel does not move the intentional-send baseline. Record actual observed destination only when known. Acknowledgment never means an order was placed. |
| `grant.create/revoke`, `consent.record/revoke`, `seat.assign/release` | Authority specific to action; consent proof and billing verification are server-only. A revoked child cannot replay a queued submission. Never expose a guardian proof to the shopper. |
| `import.stage/commit/undo`, `backup.recoverBranch` | Local or permitted owner-scope operations. Validate full batch and projection; compare revisions; commit once and preserve existing private fields. Files cannot grant membership or activate payment. |

## State transitions worth testing before UI polish

| Trigger | Shared basket / order | Request and client result |
|---|---|---|
| Incoming request in open shop | Basket unchanged | Pending current shop; authored and received times independent. |
| Freeze to prepare handoff | Freeze current revision, preserve undecided items outside the frozen plan | New arrivals route next. Existing undecided remain visible to shopper. Copying a list alone never records placement. |
| Explicit reopen after cancelled checkout | New open draft with traceable parent | Next-shop items stay there until intentionally promoted after review. |
| Shopper reports placement | Pin frozen or reconciled revision; source “shopper reported” | Route new and still-undecided requests next. A pending contributor draft can sync later with accurate server route. |
| Offline placement during authority transfer | Keep local cutoff; accept separately attributed external report for reconciliation if old authority lost | New shopper decides whether it applies to the frozen basket. Stale device cannot close, reroute or modify the newer order. |
| Later provider change / order cancellation | Keep order and amendment history; record response separately. Reopen or start another distinct draft if cancelled. | Never silently delete other households' contributions, add a duplicate box, or infer that the family received the item. |
| Confirm actual arrival | Record observed/usable quantity once; allocation can change suggestions | “Bought” requires an explicit applicable confirmation. A refund does not imply the food was missing and vice versa. |

## Development order and release evidence

Build vertical slices the family can actually use. Connect each slice through the real route, durable store, domain policy and state projection before adding another screen. A static mockup, a green fixture, a compiled entitlement view or a disabled feature flag is not completion. The tickets are development order, not a proposal to cut launch scope.

| Ticket and prerequisites | Deliverable Codex should implement | Exit evidence |
|---|---|---|
| **B00 · Workspace and CI** · none | Confirm deployment floor and record Xcode/Swift/tool versions. Create `ios/` app, core package, tests and previews; web/service manifests with reproducible locks; debug/staging/prod configuration. Generate design tokens; install a fake clock, fictional fixtures and one redacted log sink. Do not overwrite the old Expo workspace or commit signing secrets. | Clean clone builds on macOS/Xcode; iPhone simulator opens Shop with correct name. Swift domain, web and service tests run in CI. Dark/large type renders recorded. Verify fixture/license provenance. |
| **B01 · Local pack check** · B00 | First-run Shop → compare two packs → item-level answer, save, kill and resume. Add rational quantity and money types, known/unknown result model, SQLite v1, migration runner, local guest workspace, en/es catalogs and accessibility labels. | Exercise D01/D05/D14/F01/F06. Unknown weight yields a threshold/question. One $30 item cap cannot turn into a whole-household budget. Confirm offline use with VoiceOver and network disabled. |
| **B02 · Full list and meal ledger** · B01 | Explicit paste/type import with deduplicated contributions. Store branch, mode, dated slot, cap and protected demands. Reusable meal definition and weekly copy independent. Search, visible notes, independent inspect/check, Recently checked, undo and local save. | A second paste prompts for merge. Removing tacos keeps lunches and manual staples. Restart after checking and restore the line. Store/date changes invalidate the old quote. |
| **B03 · Whole checkout and handoff** · B02 | Implement matched-basis full-shop quote, bounded fee/pack alternatives, protected/deferrable lines and durable deferred needs. Preview, commit, freeze, recoverable copy/share/external open. Store source and recipient baseline. | Pass $37.20/$40.69, 29¢ over after fee reversal, unknown-fee and simultaneous substitution cases. Cancel share, return from empty retailer page and record explicit placement. |
| **B04 · Pickup through next shop** · B03 | Offer/cutoff, discrepancy-only receipt, partial/wrong/split/late fill, usable observation, pantry/freezer reservations, manual dinner repair, self-contained cook handoff, pending/posted/refund ledger and next-trip review. | Walk S07–S12 offline and after restart. Six wraps protect two lunches. Late delivery records once without duplicating a replacement meal or charge. Separate posted and included credits. |
| **B05 · Control of records** · B02/B04 | Typed helper and owner projections, explicit export, recipe import, manual source link, immutable branch identity, media limits, atomic staging, rollback, deletion and redacted support. Implement prior-version migrations before beta data exists. | Corrupt/truncated/oversized file leaves local store unchanged. Same export in a different envelope reopens the same data. Recover old backup alongside later draft; helper omits private context. |
| **B06 · Household trust and sync** · B02–B05 | Auth, member/guardian enrollment, single-use invites, scoped view grant, household database isolation, event cursors and operation receipts. Web session, revocation and consent. Explicit opt-in from local-only work; secure return to protected adult persona. | Exercise two real devices, wrong tenant with known IDs, invalid link, withdrawn consent, backup replay after deletion, stale cursor, app background privacy and reinstall. Zero private fields in unprivileged payload/cache/log. |
| **B07 · Requests and one shopper** · B03/B06 | Contributor mobile web and native entry, own-status view, household inbox, clarification, duplicate linking, over-cap approval/deferral, frozen intake and shopper transfer. Retry-safe online commits and local offline queue. | Run all 20 Gen 15 routing scenarios against the API, plus offline/reconnect on iPhone and Android. Same key/different body fails; exact retry preserves the original result. Concurrent old shopper cannot commit. |
| **B08 · Assisted planning and billing** · B04–B07 | One reusable dinner free, multi-night rotation, whole-pack pairing, protected lunches, guest proposals, accepted fallback, history, recipient diff, funding envelope, isolated nonbilling preview. StoreKit product, two named adult seats, manage and restore. | Reproduce Gen 12 pasta/fajita A/B and guest reprice, compare identical commitments. Duplicate Apply creates one revision. Exercise sandbox purchases including Ask to Buy/pending, cancelled, grace, expired, refunded, restore and wrong household. |
| **B09 · Capture and accessible surfaces** · B02/B04/B06/B07/B08 | Structured on-device speech, corrections, spoken guest preview, optional readback, barcode/OCR/photo/receipt review, share extension, widget shortcut, aisle/store sort, printable list and local reminders. | Deny each permission separately. No raw audio retained and no child network fallback. VoiceOver and readback never collide. Repeat a recognition callback and retry the same operation. Stale deadline notice opens Await pickup. Locked widget and screen do not leak private data. |
| **B10 · Calendar, ideas and two quotes** · B03/B04/B06/B08 | Finish S25–S27 and A01–A03 with the shared meal/stock/quote engines. Free manual paths; permission checks; adult approval before the basket changes. Complete bilingual parity across app/web/help/billing. | Run the three-feature vectors plus dirty offline edits. A cheaper sticker basket can cost more after travel. Unapproved dinner ideas produce zero changes. Editing this week preserves rotation and placed lines. |
| **B11 · Release candidate** · B00–B10 | End-to-end deployment, privacy/retention, support, StoreKit reconciliation, field instrumentation, migration/restore drills, accessibility, localization and staged rollout. Ship the dated retailer handoff. | Feature-by-feature evidence for D/F/P/E/N/A, all 27 routes, six boundary checks, all planned devices. Any open hard block stops release or the affected assurance. |

## Test harness requirements

* **Fast domain tests** on every change. Shared JSON vectors evaluated independently by Swift and server implementation: exact rational/decimal math, package rounding, mixed units, insufficient confirmed yield, duplicate/manual/meal provenance, fee thresholds, dated rebates, guest portions, equivalent commitments, travel cash and time. Include randomized conservation checks (no lot over-allocation, no double count, null never becomes a zero price) and overnight/DST cutoffs. Fix the expected behavior before optimizing.
* **Database and API contract tests** use real SQLite/Postgres and migrations, separate credentialed test clients and deterministic interleavings. Test cross-tenant object access for every read/command/export, duplicate events, changed-body replay, stale epochs, row count on conditional write, device re-enrollment, closed shops and out-of-order notifications. Fail after each mutation boundary to prove rollback and restart consistency. Run a migration from each supported file/schema version and interrupt/retry it. Verify restore and deleted identities in a fresh environment.
* **UI tests** cover onboarding without an account; empty first-time urgent repair; list import → budget compare → handoff → actual fill → repair → cook message → close → next shop; family request from offline draft → shopper review → deferral → later trip; paid second-adult proposal → approval → lapse; all three additions and denied camera/mic/notification access. Capture before/after database assertions, not just a screenshot of a success toast.
* **Human device tests** on minimum supported and current iPhone OS, small/large screens, light/dark/increased contrast, large accessibility type, VoiceOver, Switch Control/keyboard and Reduce Motion. Test iOS Safari and Android Chrome web invite/own requests/helper scope on a fresh and primed browser, storage eviction/denial, external links, background/restart and sign out. Exercise regional units, English/Spanish flows and readback in a noisy kitchen. Record OS, build, locale, device and exact fixture used.
* **Operational rehearsals** on staging: lost device and authority transfer mid-checkout, account deletion while offline, stale cached projections, duplicate Apple transaction callbacks, expired provider keys, restore-from-backup plus tombstones, write failure and media upload interruption. Set an initial measured performance budget on a named lowest-supported device: e.g., a 500-line list remains responsive to checking/search, and saving a draft never blocks typing. Measure P95 on realistic fixtures; retain baseline before adding more features.

## Field and release checklist

For each requirement track ID, owning screen/command, commit, fixture, automated result, device evidence, owner, date and unresolved risk. The feature catalogue is a specification; fill a separate implementation tracker from real test artifacts. Hard blocks include a false “under budget” or “dinners covered”, a private value in a child/helper response, duplicate purchase line after retry, stale mutation of a placed order, inability to recover local records, or entitlement restore granting another household's authority.

Prepare a human-reviewed English/Spanish product page, support/privacy URLs, privacy disclosures, App Store age-rating responses, purchase terms/manage/restore, in-app account deletion, App Review walkthrough and a demo household with fictional data. Obtain a real signing team, bundle and services IDs, domain, notification environment, product configuration, child-consent process and operating owner. Verify review requirements and current SDK on submission day. Reviewers must be able to evaluate the free journey, two seats, contributor web invite, guardian controls and manual handoff without real children, retailer accounts or production family data. [Apple review requirements](https://developer.apple.com/app-store/review/guidelines/)

The historical pilot measures commercial and household value separately from software correctness. Compare ten households across two real pickups with their best normal workflow, including a quiet week and another adult's effort. Two verified incremental decisions in different households advance the next study. Keep the 100-order incidence and 30-exception comparison separate. In the eight-week study use at least 90% verified success and a 15-point lift over the preselected baseline, or the preregistered five-minute gate when baseline exceeds 85% with no more than five points coverage loss. Treat missing verification as missing or failed per protocol. A saved fee in an unpurchased alternative is hypothetical. Optional feedback/analytics starts off.

Keep the proposed $49.99 offer separate: cap research at 400 qualified offers or $280 fully loaded acquisition spend, seek 20 retained buyers at $14 or less acquisition cost, then 12/20 using three of their last four eligible shops by week eight. Log refunds and later renewal distinctly. These are inherited business experiments, not claims of success, automatic commitments to spend, or a reason to omit launch features. Pilot protocol

**Release handoff.** On macOS produce signed TestFlight builds, run the fixture-linked suites, archive screenshots and result bundles by build, then publish with staged monitoring only after owner authorization for distribution. Rollback plan: turn off a failing network path, retain local records and typed/manual alternatives, block misleading assurances, and reconcile queued writes before resuming. No direct retailer adapter ships in this release.

**Gen 2 regression gates.** At B05 import a conflicting digest concurrently and exercise export-after-erasure. At B06 enforce an actual guardian relationship, irrevocable consent withdrawal, scoped meal-week access, replay windows and both pre- and post-compaction retries. At B07 race a shopper transfer with external placement; preserve both reports and require reconciliation. At B08 test a third adult and a child across renewals, verified time, superseding refund, and reassign/restore rollback. At B11 open the signed build and execute every promise in the keyword handoff before recording listing fields. Record the build, locale, device, tester, result and next action. Exclude an unverified claim from the listing even if it ranks well.


**Placement regressions to implement.** B02 selects a meal without a date, restarts and assigns it once. Check, handle and trash three identically named rows, change stores, restore original order and reopen only the intended row. B03 tests separate spend and hold gaps with known and unknown holds. B04 starts from an empty offline install, makes an urgent meal need and cook note without manufacturing a delivery. Copy a replacement ceiling at S07 without changing offer status. Reject impossible leftover yield. B05 stages a failed recipe OCR review without touching a saved meal. B06/B07 exercise static text, read-only link, proposed edit, revoked link, contributor denial and stale proposal. B08 verifies per-recipient paid diff versus manual resend after lapse, updates the baseline of a second what-if, and prevents a period total from leaking a hidden shop. B09 uses the B08 guest/entitlement port for spoken preview. B10 moves an undated meal into the week with the same needs. B11 records mobile testing evidence for every feature and the comparative usability study.

B08 and B11 use the Apple subscription setup. B00 and B11 use the screen placement and interaction audit to check route presentation, visual hierarchy and motion.

## Launch keywords and listing instructions

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

**Included evidence:** editable keyword planner · machine-readable Draft A · original evidence archive. The workbook retains the 383-phrase reviewed English bank, historical and Spanish evidence, exclusions and alternative branded drafts B/C. Its original 19 intent categories are research classifications; three extra Feature guide rows connect A01–A03 to the current release. The archive is historical, including prior names and scopes. For building or publishing, use this foundation's decisions.

## Foundation 2 audit and limits

Foundation 2 revises the implementation blueprint for **Room in the Cart**. “Gen 15” is the product research generation; it is not the blueprint version. The release still contains 52 affirmative requirements: 16 D, 9 F, 8 P, 9 E, 7 N and 3 A. E05 is deferred. Six X entries describe lasting boundaries and the narrower alternatives the app does support. Together these make 59 decisions and 27 screens. There is no shipped app or measured household outcome in this package.

| Before: a reproducible ambiguity or invalid state | Gen 2 decision and how to verify it |
|---|---|
| A child row could be its own guardian or an organizer; revocation could be erased on the same consent row. | Separate verified adult–child relationship from notice-specific consent. Require both at the server; SQL checks the distinct roles, one-way revocation and evidence. Losing membership/relationship ends the grant. Reconsent is a new record. Never expose proof to the shopper. |
| A seat limit applied per Apple transaction, so a renewal could create seats three and four. | Unique slot 1/2 and member per household. Assignment/reassignment requires eligible verified entitlement and an active adult. A renewal updates the effective purchase period, not capacity; expiration does not delete the person's recipes or records. |
| A one-shop editor and a paid seat could be mistaken for household meal-week access. | An explicit adult household planning grant covers S25/S26, even for Free manual planning. A scoped helper can only propose within their shop. Budget scope, paid seat, shopper and organizer remain separate. Local private planning needs no service grant. |
| Placed orders and order lines could be edited in place after outside checkout. | Freeze the revision and its order facts. Append subsequent amendment, cancellation or corrected report evidence; do not point the existing order at a new revision. A stale reporter cannot close another shopper's basket. |
| An included credit could link to itself; a hold could look posted; a posted charge could be overwritten. | Link an included credit to a separate posted charge in the same shop/currency. Holds are never posted spending. Keep pending and included entries out of the paid sum; append independently sourced adjustments to settled facts. |
| Removing an operation receipt made its actor/key available for another effect; deleting an operation that had evidence attached broke its foreign keys. | Separate durable operation identity from the disposable response. Compaction deletes only the response, leaving a used-key marker, event and applied proposal. Exact authorized replay before compaction returns a safe receipt; afterward either payload receives refresh-required without a new effect. The server rejects expired windows even after marker retention ends. |
| A backup with identical origin/revision/projection but different bytes could also be marked imported. | Allow one accepted digest per identity, protect its metadata from rewrite, and quarantine collisions. Retry of identical bytes reopens the prior result; sibling revisions and narrower projections retain their independent identity. |
| The keyword workbook used unbranded working titles and lacked the three approved additions. | All three listing drafts use Room in the Cart. Draft A has explicit title/subtitle/token counts, six test phrases and a screen proof for each. Spanish and exclusions remain separate. The three new proof rows do not fabricate fresh search traffic. |
| Build instructions and marketing were scattered; several acceptance criteria could be mistaken for accomplished work. | One standalone master includes the release, screen behavior, design, architecture, tests, ticket order and keyword handoff. The build begins at B00/B01. Local executable examples test the foundation only. |

**Division of enforcement.** SQL checks persistent structural invariants. A trusted service must enforce object rights, guardian verification, consent validity, server time, effective subscription, permitted transitions, deletion policy and field projections transactionally. Local SQLite is a reference, never the contributor API or a substitute for PostgreSQL authorization. Deny destructive SQL/REPLACE and schema changes to ordinary writers for immutable evidence; give scoped migration and erasure code a separate privilege boundary. The reference verifier exercises representative runtime denial and privileged payload compaction. Full account erasure and backup purge remain service acceptance gates.

**What still requires a real build.** Sign and run on macOS/Xcode. Prove behavior on iPhone and mobile web, with two actual clients and a real service; check migrations, revocation, lock-screen content, VoiceOver and large type. Get human US Spanish review, a reviewed guardian verification and retention process, valid domain/signing/StoreKit configuration, storefront name clearance and release authorization. Pilot evidence and real willingness to pay are separate from technical acceptance. The audit of this package is not a substitute for any of these gates.

## Screen placement and interaction audit

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

**Inspected evidence.** The interactive request study runs offline in a browser. Captured states show the inbox, request decision, deferred result and overage confirmation. The study exercises review, cancel, defer, accept and the reduced-motion control with fictional data. Its local page state resets when reloaded. It is one interaction sample. The build still needs real storage, service authorization, iPhone frame measurements, VoiceOver and the complete set of 27 route checks.

## Competitive comparison and release gate

| Baseline from the publisher | What the family should be able to do here |
|---|---|
| AnyList offers shared lists, quantity notes, recipe import, price entry and grocery lists from a meal calendar. [AnyList feature list](https://www.anylist.com/features) | On an ordinary shop, add and check an item as quickly as the family normally would. Surface the extra decision only when an item affects the whole pickup or a protected meal. |
| OurGroceries describes household list updates, item photos and aisle grouping across devices. [OurGroceries overview](https://www.ourgroceries.com/overview) | An invited person can ask from a mixed-phone household in one scoped destination. Measure the author's effort and the shopper's effort separately. |
| Paprika combines similar ingredients, builds aisle lists and supports reusable menus. [Paprika features](https://www.paprikaapp.com/) | Show what six usable wraps can actually cover after two lunches are reserved, then hand the cook a correction. Measure whether both people can explain what is still missing. |

The potential advantage is the point where a shared-list change affects both the full checkout and a meal already promised. Publisher descriptions establish baseline capabilities. They do not establish comparative speed, ease or preference.

**Proposed formative test.** Counterbalance app order with at least eight target shoppers, including mixed-phone households, and use the same device, quantities, prices and time limits per paired task. Record comparator version, tier, starting state and any manual workaround. Test ordinary list entry, a capped request, a short-fill with protected lunches and a corrected cook handoff. Log unassisted completion, elapsed time, backtracking, wrong financial/food conclusions, who did the work and blind-rated clarity of the final instruction. Ask separately which they prefer and why. For this small study, advance if at least seven of eight finish each critical task unassisted, nobody mistakes a financially wrong or under-covered plan for a good one, median ordinary entry time is within 10% of their normal workflow, and at least six of eight prefer this app for the exception workflow. If a gate misses, revise the failing path and retest. This is a design decision gate, separate from the longer household pilot.

**On-device sign-off.** Test on the oldest supported iPhone class and a current device, with the production navigation stack, largest Dynamic Type, both appearances, English/Spanish, VoiceOver, Reduce Motion, keyboard open and interrupted sync. Record a repeated 30-interaction run on device with Instruments, investigate visible hitches or repeated missed frame deadlines against the device's refresh cadence, and record permission denial, double tap and navigation interruption. Confirm every result remains legible and correct without animation. A judge can accept these specifications before any of these device or household results exist.

## Apple subscription setup

Household is an annual digital subscription for up to two named adult planners. Use **StoreKit 2** on iPhone. S18 owns the subscription offer, Restore Purchases and Manage Subscription. S19 manages the app's seats. Keep the Free route visible. The retailer collects payment for groceries. The shopper may record that charge later at S11. Apple Pay merchant checkout, grocery-card capture and payment processing for groceries are outside this build.

| Stage and owner | Action | Completion evidence |
|---|---|---|
| 1. Account Holder and finance | Use the correct Apple Developer team and App Store Connect organization. In Business, have the Account Holder accept the current Paid Apps Agreement. Complete Apple's applicable tax and banking requirements through the account. Keep account and payout details outside the repository. | Agreement and required financial information are active for selling. [Apple agreements](https://developer.apple.com/help/app-store-connect/manage-agreements/sign-and-update-agreements) |
| 2. Release owner | Register the app's final bundle ID and select it for the App Store Connect app. Enable In-App Purchase for the iOS target. Under Monetization → Subscriptions, create one group for Household and one annual auto-renewable product. Choose a permanent product ID, set one year, storefront availability and the approved price. The US $49.99 annual figure is the research hypothesis. Supply the group and product localizations, review screenshot and review notes. Leave Family Sharing off for this two-seat account model. | Exact product ID and bundle match environment configuration in client and server. No production SKU or price is assumed from a fixture. [Subscription properties](https://developer.apple.com/help/app-store-connect/reference/app-information/required-localizable-and-editable-properties) |
| 3. iOS owner, B08 | Request the configured product, display its localized price and term, renewal disclosure, privacy policy, terms, Restore and Manage actions. Ask the adult to identify the purchasing account and household. Subscribe through StoreKit. Handle success, pending, cancellation, unverified transaction and unavailable product explicitly. Observe transaction updates and reconcile current entitlements at startup. Finish after durable delivery. | A missing product leaves a retry and an accessible Free path. A user-initiated restore reconciles the existing purchase. Pending, cancellation and verification failure grant zero paid seats. |
| 4. Service owner, B08 | Deploy a signed-transaction verification and reconciliation handler. Configure distinct sandbox and production HTTPS endpoints for App Store Server Notifications V2 under App Information. Validate Apple signatures, bundle, product and environment before changing access. Deduplicate events and reconcile subscription state on late, missing or out-of-order delivery. Keep App Store Server API keys in a server-side secret manager. Bind the verified original purchase identity once to its purchaser and selected household. | Send a test notification. Exercise renewal, expiry, refund and restoration. A replay and a restore to the wrong household cannot duplicate access. A refund or expiry retains the family's permitted Free data. [Apple server-notification settings](https://developer.apple.com/help/app-store-connect/configure-in-app-purchase-settings/enter-server-urls-for-app-store-server-notifications/) |
| 5. QA and release owner, B08/B11 | First test with a local StoreKit configuration in Xcode. Then fetch the actual product through sandbox/TestFlight and test purchase, interrupted delivery, reinstall and restore on a second device, renewal, billing retry, grace if enabled, expiration and refund. Check both app locales and the real storefront price. Include the first subscription, group and new app version in the review submission and supply the reviewer's test path. | Attach sandbox transaction and reconciliation results using redacted IDs, a screenshot of S18, restore and seat-limit evidence, review status, an operating owner for billing support and reconciliation alerts. [Apple submission workflow](https://developer.apple.com/help/app-store-connect/manage-submissions-to-app-review/submit-an-in-app-purchase/) |

**Current status.** The reference schema and fixtures cover purchase binding, adult seats and replay. The app record, financial agreements, product, keys, endpoints, signed build and real sandbox purchase require the owner's Apple team and the eventual running application. This foundation supplies instructions and acceptance criteria.

**Live-view lifecycle.** S10 issues a view after checking the creator's current authority to share every selected field. S21 manages and revokes it. S20 links to the scoped management panel. The recipient uses the helper branch of S10, identified by a grant for exactly one shop. A contribution link alone cannot open it. An editor can submit allowed fields as a proposal. The assigned shopper opens S17 and applies against the current base or requests a new review. Preserve the ordinary S10 dated text path after cancellation, expiry and membership lapse.

**Period query.** Authorize every participating shop before aggregating money for S20 or an export. Use the same currency for period and shop reservations. If the caller has incomplete scope, return only information independently derivable from the permitted rows, with no hidden subtotal, remaining balance, count, ranking or hint. Deny access before generating cached responses, readback or a file.
