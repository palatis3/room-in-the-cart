# Room in the Cart

**Master generation · Consolidated product and research specification · US iPhone**

Room in the Cart helps a family decide whether a change to its grocery pickup still fits the whole-trip budget and feeds the people it promised to feed. A shopper can compare two packs on a first visit, plan an entire pickup, or rescue tonight's dinner without a previous order. The same quantities, meal commitments and dated evidence follow the family from that first decision through pickup and the next shop.

This edition reconciles the fifteen product generations by subject. The latest decision on each subject governs. The chosen name, three owner-approved additions and the accepted Foundation 2.1 corrections postdate Gen 15 and are included. The release has **52 requirements across 27 screen contracts**. Retailer cart integration is a later project. Research findings below retain their original samples, dates and assumptions. A prototype result, publisher claim, modeled checkout or proposed pilot has its own evidentiary status.

**Minimum iPhone operating system.** The proposed native deployment target is **iOS 17.0**. An iPhone XS on iOS 17 meets this OS minimum. Devices running only iOS 16 are outside the planned native range. B00 must set the deployment target, and B01 must exercise the first offline shopping task on the minimum OS as well as a current device. Runtime-check features such as on-device speech and keep typed entry available. Compatibility is a build and device-test gate. [Apple’s iOS 17 availability announcement](https://www.apple.com/newsroom/2023/06/ios-17-makes-iphone-more-personal-and-intuitive/)

**At handoff.** The repository contains research prototypes, reference data and verification scripts. The native iPhone app, production service, signed purchase flow and household trials are still to be built or run. For implementation, begin with B00–B01 and the real Shop → Compare packs path. For a product or business question, start in the corresponding section below.

[The family and the offer](#family) · [Release register](#register) · [Screens](#routes) · [Design](#design) · [Data and service](#engineering) · [Worked cases](#cases) · [Field evidence](#people) · [Competition](#market) · [Retailer access](#retailers) · [Economics](#economics) · [Tests and decision thresholds](#studies) · [Build and billing](#build) · [Launch and keyword bank](#launch) · [Source index](#sources)

<a id="family"></a>

## The family and the offer

The starting household already shops for groceries. One adult may plan five familiar dinners for four people, keep two lunch portions aside, and have a firm limit for the entire order. A useful comparison includes what else the family must buy, how much usable food comes in each pack, the pickup fee, and any top-up trip. A single-item question deserves a single-item answer. Ask for more information only when the answer depends on it.

**An ordinary week.** Mia has a $38 pickup cap. Deferring $2.10 of filters from a $39.30 checkout leaves $37.20. Sam wants a $3.49 box of cereal. His request reaches Mia's inbox. If the rest of the checkout stays the same, one extra box brings it to $40.69, $2.69 over. Mia can link a box she already planned, clarify the request, explicitly accept the overage or save it for the next trip. Sam sees what happened to his request. Mia's budget stays private.

**A changed week.** Six wraps are for tacos, four for quesadillas and two for lunch. Two eight-packs cover the original plan. If only six usable wraps arrive, reserving lunch leaves four for tacos and the other dinner still needs four. Mia can use confirmed freezer stock, change an accepted meal, authorize a top-up, or leave the shortage open. Alex gets a dated instruction with the quantities and what still needs attention. A helper on Android can read the instruction or use the invited web view.

**Free and Household.** Free covers an ordinary pickup from list through handoff, actual arrival, manual repair and the next trip. It includes the family inbox, one reusable dinner, manual meal-week planning, reviewed dinner ideas, and two shopper-entered store quotes. Household offers up to two named adult planning seats for rotations, pack pairings, guest scenarios, suggested recovery, history and automated comparisons. Test the annual offer at $49.99 in the US and show Apple's localized StoreKit price. Retailers collect grocery payments. Access to a subscription, permission to read a budget and authority to change a shared basket are separate decisions.

**Where people work.** Shop handles the current pickup and family requests. Dinners handles the meal week, candidate ideas and familiar meals. Records handles earlier pickups, files, history and recovery. The current shopper alone commits a shared basket change. An authorized second adult can propose. A guardian-managed contributor sees their own requests. A cook receives only what the sender selected for that shop.

**Launch boundaries.** The adult meal calendar, editable dinner ideas and opt-in comparison of two entered store quotes have first-release owners. A general household calendar, unrestricted recipe or nutrition generation, market-wide deal routing, a grocery marketplace, medical suitability judgments and mandatory scanning or credential collection fall outside the agreed scope. A dated copy, a report of placing an order, a confirmed retailer amendment, an actual delivery and a posted charge have different meanings throughout this document.

<a id="register"></a>

## Release register

### Day-to-day shop

#### D01 · Start without setup

**Free** · B01 · S01 S04

Offer quantity and two pack quotes to a pure PackComparison; store locally on Save. Return item-only headroom if the basket scope is incomplete.

**Accept when.** Open a quick check without an account, store, subscription or weekly menu. Two pack offers and the amount needed produce an item-level answer.

#### D02 · Bring the list

**Free** · B02 · S02 S04

Parse typed, explicit paste, selected text and voice into staged source contributions. Confirm duplicate vs additional amount; commit a reversible batch. Search excludes deleted lines.

**Accept when.** Type, paste or share selected text. Keep the original, preview lines, search and undo. Pasting 12 wraps twice asks whether to merge or add. Linking six to tacos within the 12 leaves 12 on the list.

#### D03 · Describe this shop

**Free** · B02 · S03 S05

Capture scope, currency, optional fixed reserves, fees, slot/zone and mode on ShopBasis. Edits invalidate dependent quote/guest previews. Keep a receipt/hold out of planned spend.

**Accept when.** Set the cap's scope, currency, store, mode and slot when relevant. Enter an inclusive preview or just the facts available. A $35 dinner limit stays labeled dinner-only even if the other groceries are unknown.

#### D04 · Name meals and needs

**Free** · B02 · S03 S04 S14 S25

Create a meal occurrence, serving groups, ingredient demands and protected allocations separately from shopping lines. Hiding or moving a meal does not remove staples or lunch reservations.

**Accept when.** Record the meal, optional night, servings and purpose of each need alongside staples and nonfood. Hiding lunches from view preserves their two wraps alongside six for tacos and four for quesadillas.

#### D05 · Compare usable packages

**Free** · B01 · S01 S04 S07

Normalize using a confirmed rational unit basis. Subtract confirmed usable supply, round up whole packs, compare total cost, remaining need, unit ceiling and leftovers. Return a question on unknown conversion.

**Accept when.** Compare whole packs by usable amount, price to buy enough and remainder after protected portions. A shopper can leave a weight or volume conversion unknown when its ingredient-specific basis is missing.

#### D06 · Compare current checkouts

**Free basic budget preview** · B03 · S03 S05 S24

Reprice complete equivalent alternatives in expected minor units. Re-evaluate eligible subtotal, fees, discounts and cap scope. Unknown costs propagate. An A03 cross-store scenario uses a separate comparison.

**Accept when.** Compare two same-store, same-slot checkout previews with time, source, included fees and commitments. A $34.80 subtotal plus a $4.95 fee shows $39.75 against $38. An uncertain fee produces a conditional result.

#### D07 · Protect or defer a purchase

**Free** · B03 · S05 S12 S24

Record need priority independently of line inclusion. Search only approved removals; persist a deferred need with source, destination and review status. A confirmed handled need is never revived automatically.

**Accept when.** Mark a line required, flexible or undecided. Offer keep, defer and leave unresolved. When the shopper defers filters, lunches keep their allocation and the filters reappear for review next shop.

#### D08 · Explain a change

**Free** · B03 · S05 S16 S17

A proposed patch records parent revision and affected contributions. Show delta and unpriced items; Apply once on matching base, Undo as a compensating revision. Post-placement edits require amendment.

**Accept when.** Preview changed lines, meals, packs and checkout before applying. Skip one dinner and check that its portion alone disappears. Undo restores the draft, including unrelated staples.

#### D09 · Save a recoverable handoff

**Free** · B03 · S06 S10

Freeze the exact revision before invoking copy/share/open. Record attempted, prepared, intentionally sent, manually reported placed and provider-confirmed as different evidence.

**Accept when.** Save a dated readable snapshot before copy, share or retailer open. Track each action separately from shopper-confirmed submission and retailer-confirmed amendment. Cancelling or opening an empty cart leaves the snapshot intact and the order unconfirmed.

#### D10 · Resolve a changed item

**Free** · B04 · S07 S08

Evaluate the offer against per-dish rules, remaining original charge, pack yield, joint headroom and local cutoff. Save a private decision and concise retailer note. Expire to await pickup even offline.

**Accept when.** Record an offer's affected lines, remaining original quantity, known price and local deadline. Check per-dish alternatives. At cutoff show Await pickup with the date/time and keep fill unknown until the bag arrives.

#### D11 · Record what came home

**Free** · B04 · S08 S09 S11

Append receipt fragments keyed by source event, original order line, branch and segment. Supersede usable counts separately; allocate protected portions first. Resolve shortfalls per dish independently of money.

**Accept when.** Record no-fill, partial, wrong, late or split items. Separate received, usable and reserved amounts, meal repair and refunds. A delivered eight-pack with six usable and two reserved supplies four to dinner. Retrying the same delivery adds nothing.

#### D12 · Tell the cook

**Free** · B04 · S09 S10

Project a complete cook instruction with date, revision, required action and usable portions. Reset optional private fields off per share. Use recipient-specific comparison only on known send history.

**Accept when.** Preview the complete dated instruction and revision in plain text before sharing. An Android caregiver can act without installing the app. Budget defaults private. Marking a version sent does not record acknowledgment.

#### D13 · Reopen next shop

**Free** · B04 · S01 S12

Create a new shop ID and draft from selected recurring inputs. Ask about open deferrals and one reusable dinner. Clear stale quotes, store offers and old checkout status.

**Accept when.** Reopen the last shop, reuse one familiar dinner and review outstanding staples in a new draft. If someone bought the coffee already, mark it handled and verify the new list has no coffee charge.

#### D14 · Read and recover offline

**Free** · B01–B04 · S01 S08 S20

Write data and local revision in one durable transaction. Replay after process death with local/remote timestamps; keep a recent working version, dated handoff and accessible retry.

**Accept when.** Restart in airplane mode and open the latest local save and last sent snapshot. At large type and with VoiceOver, read the item, quantity, dinner and status without relying on color or a swipe.

#### D15 · Keep control of family data

**Free, including after membership ends** · B05 · S19 S20

Separate helper projection from owner backup. Stage, validate and diff imports before a transaction. Provide correction, scoped deletion, restore and redacted support export on Free.

**Accept when.** Preview a scoped shared copy separately from a personal recovery file. Correct, undo, export readable and structured records, recover and delete with scope shown. Importing a backup beside newer records preserves them and offers help.

#### D16 · Learn from the first result

**Free, consent optional** · B11 · S11 S20

At end of shop offer optional coded outcome; tie to eligible shop and baseline with no grocery text. Suppress prompts during active planning and on consent decline.

**Accept when.** Let a shopper distinguish acted, unchanged, too late, unknown, already knew and wrong. Declining feedback leaves the trip usable. Measurement omits grocery text and assigns zero incremental benefit to an observed tie.

### Shared implementation contracts

#### F01 · Quantities and money

**All quantities and calculations** · B01 · S03 S04 S05

Use typed Money, Quantity and UnitBasis value objects. Keep original literal, normalized rational, confirmed conversion, currency and explicit rounding policy; null means unknown.

**Accept when.** Keep distinct IDs for lines, meal demands and packages, original text, decimal amount, unit, conversion basis, currency and rounding. Two 15 oz cans stay two packs. Dual printed measures describe one demand.

#### F02 · Sources and allocations

**All list and meal edits** · B02 · S02 S04 S14

Store contribution IDs and allocation edges. Merge only compatible units/products and confirmed duplicate semantics. Remove one source in isolation. Enforce exclusion rules before candidate ranking.

**Accept when.** Retain each manual, meal or reservation contribution when merging compatible lines. Remove one recipe and verify that other meals, lunches and a manual staple survive. An excluded ingredient cannot become an accepted match.

#### F03 · Draft and sent versions

**All shops, snapshots and retailer actions** · B02–B04 · S06 S08 S17

Give templates, occurrences, drafts, immutable revisions, submitted lines, proposals and fill events independent IDs. Every external-action receipt identifies its actual base.

**Accept when.** Version usual meal, weekly draft, sent copy, confirmed order and actual fill independently. Apply against the reviewed base once. An edit to a submitted order remains a proposed amendment until confirmed by the retailer.

#### F04 · Price evidence

**All money figures** · B03 · S03 S05 S07 S11

Attach store/mode/slot/time/eligibility source and charge basis to observations. Separate expected, hold, pending, posted, included credit and top-up; never add a net credit twice.

**Accept when.** Attach source, store, time, mode, slot, eligibility and included charges. Keep estimates, holds, posted charges, credits and top-ups distinct. $37.20 posted with a $2.40 pending credit still shows $37.20 paid. A net charge retains an included credit once.

#### F05 · Offline and sharing rights

**All sharing and offline writes** · B06 · S19 S21 S23 S24

Keep auth principal, household membership, role epoch, one-shop grant, planning seat and retailer authority distinct. Recheck them server-side on every read or mutation.

**Accept when.** Separate membership, link scope, editing and retailer action. Limit each shop to one active shopper. An authorized handover transfers that role. A forwarded note conveys information only. Retries deduplicate by operation while distinct real purchases survive.

#### F06 · Language and access

**All languages and assistive access** · B01–B10 · S02 S10 S20 S22

Use string catalogs and web locale catalogs, formatters and layout direction. UI language, original text/units, recipient language and transaction currency have separate scopes.

**Accept when.** Separate interface and recipient language from original food wording, units, currency and store region. Exercise long text, RTL layout, plurals and spoken labels. A US Spanish message preserves no-salt, pack size and USD.

#### F07 · Storage and recovery

**All local records and exports** · B05 · S10 S20

Identify files by origin, revision, projection, format and canonical digest. Use bounded decoding, staging and transactions. Keep conflicting revisions as siblings; identical retry reopens the earlier copy.

**Accept when.** Version and migrate structured files with stable identities. Preview selected media and recovery scope. Reopening an identical source and revision finds its existing copy. A malformed file leaves local records intact and support needs no full receipt.

#### F08 · Connections and operations

**Offline baseline and online household service** · B06–B07 · S06 S21 S24

Queue client operations with stable actor-scoped keys and synchronize authoritative revisions. Show local save, waiting, conflict, server received and retailer report as distinct states.

**Accept when.** Distinguish copying a list, syncing a request, saving a family decision and reporting an order placed. A failed sync retains a retryable local draft. A copied list never confirms an order.

#### F09 · Purchase and measurement

**All billing and measurement** · B08 B11 · S18 S19

Verify Apple transactions on the server for shared service, dedup notifications, reconcile restore and seats separately. Never restore authority or consent from a receipt or file.

**Accept when.** Keep consent, eligible weeks, comparison baseline, membership and Apple billing separate. Exercise pending, restore, grace, cancellation, expiry and refund. A second device or refunded sale cannot count as a second willing household.

### Household planning

#### P01 · Usual dinners and rotations

**Household, with one reusable dinner free** · B08 · S13 S14 S25

Clone chosen nights of approved versioned templates into weekly occurrences. Modify only this week unless an authorized adult explicitly changes the template. Support pins and rotations.

**Accept when.** Select multiple familiar dinners or selected nights of a rotation. Preserve dish-specific rules and overrides. Editing Wednesday in this week's copy leaves the next ordinary week intact. Compare total effort with reusing the family's existing template.

#### P02 · Pair dinners across the pack

**Household or isolated preview** · B08 · S14 S15

Enumerate approved unscheduled candidate dinners and confirmed leftovers; solve whole-pack and time constraints, reprice entire basket and compare the same mouths and lunches. Explain which pack changed.

**Accept when.** Pair familiar meals using unreserved food. Include all other ingredients, packs, fees, accepted portions and prep time. The three-pepper example must cover lunches in both alternatives before reporting a checkout change.

#### P03 · Adjust people and plans

**Household automation, free manual edits** · B08 · S16 S17 S25

Apply guest/away/plate deltas to the occurrence and serving groups. Recalculate all dependent packs/fees. Show isolated preview, give free manual editing an equivalent path.

**Accept when.** Adjust guests, nights away, vegetarian plates, lunches or sides. Preview the smallest change and cost. Moving from eight to nine needed wraps triggers a second eight-pack for review and preserves the lunches.

#### P04 · Recover tonight's dinner

**Household suggestions, free manual repair** · B08 · S08 S09

Evaluate only confirmed household-accepted fallbacks against actual yield, exclusions, prep time and reservations. Show one feasible repair and smallest top-up; ask before an extra trip.

**Accept when.** Filter the family's accepted meals against actual fill, confirmed yield, time, exclusions and protected portions. With an unavailable ingredient, show a feasible top-up or leave the need open. Compare time to using the household's usual fallback.

#### P05 · Prepare the next trip

**Household assisted review, free open deferrals** · B08 · S01 S12

Use prior reviewed needs, purpose, store and disposition to suggest next-trip work. Reprice only after user selection. Another person buying an item can close its obligation.

**Accept when.** Recall previously approved staples by purpose and store, then ask what is needed this trip. A month-old checked market item stays checked until reopened. Count re-entry time alongside prompts and duplicate purchases.

#### P06 · Show what changed since sending

**Household automated comparison, free dated copies** · B08 · S06 S10 S17

Compute additions/removals/unresolved against last intentional send for that shop and helper. Report acknowledgment separately; send a full instruction if destination is uncertain.

**Accept when.** Compare adds, removals and unresolved items against the last intentional handoff to this recipient. A stale edit requires review. If a prior message may have gone elsewhere, the correction includes the full current instruction.

#### P07 · Family decision history

**Household history tools, free access to saved records** · B08 · S12 S14 S20

Query completed decisions by dish, product and occasion. Show actual/unknown and temporary/permanent separately. Promote a one-shop preference only on explicit action.

**Accept when.** Find past dish-specific approvals, exclusions and what actually happened. Missing outcomes stay unconfirmed. Retaining an emergency substitute as a lasting preference requires the household's explicit choice.

#### P08 · One household offer

**One Household entitlement for two named adults on supported iPhones** · B08 · S18 S19

Map verified product to one household and up to two named adult seats. Provide restore, manage, transfer/revoke seat and entitlement status. Preserve free data access on lapse.

**Accept when.** Show the actual localized annual StoreKit price and renewal terms, Apple confirmation, manage and restore. The US $49.99 figure is a test assumption only. Verify second-seat access and recovery. Pending purchases do not activate tools. After expiry, records open and export and one dinner remains reusable. A seat grants no automatic shop access. Renewal or restoration cannot create a third active seat; a child cannot occupy either seat.

### Import, access and connections

#### E01 · Bring a recipe library

**Free manual entry and staged file import; assisted multi-dinner reuse requires Household** · B05 · S02 S14 S20

Implement versioned RecipeImport adapter with a documented Recipe JSON-LD file profile (Recipe objects and graphs). Stage title, yield, note, ingredient strings and source; report unsupported shapes; support one-batch rollback.

**Accept when.** Import one documented recipe-library file format with title, servings, source, notes and linked needs. Preview matches, duplicates and skipped rows, then undo the entire batch. A malformed file must preserve existing meals.

#### E02 · Photo and scan

**Free optional capture with supported camera, photo picker or local recognition** · B09 · S02 S04 S08 S14

Opt-in camera/photo picker plus on-device OCR/barcode parsing. Stage source image/reference, uncertain fields and receipt lines. Unknown barcode requires manual match. Review cannot auto-certify a price, receipt or safe ingredient.

**Accept when.** Attach a package reference photo. Offer reviewed recipe OCR, barcode identification and receipt-line capture. Preserve original text/image for comparison, flag unreadable quantities and allow typing. A low-light bilingual capture can be corrected without confirming a price or marking an item received.

#### E03 · Current shared view

**Free scoped online shared view, separate contributor and shopper grants** · B06–B07 · S10 S20 S21

Offer authenticated one-shop read projection and separate editor grant. Scope each field/record, expire/revoke online, show as-of on cached/exported copies. Submit proposed edits for shopper approval.

**Accept when.** Share a revocable, expiring current view for one shop on iPhone or Android/browser. A separately authorized editor reviews conflicting stale changes. Keep one active shopper. A contributor sees only their own requests. Revoking a link blocks fresh reads and edits. Label offline copies with their save time.

#### E04 · Spanish handoff and interface

**Human-reviewed US English and US Spanish strings, help and purchase copy** · B01–B10 · S01 S10 S18 S22

Ship reviewed en-US and US Spanish across help, purchase, voice, errors, validation and handoffs in both directions. Preserve original text, units and store quantities on every locale change.

**Accept when.** Support handoffs in both language directions and the full core and subscription flows in US Spanish. Preserve original item text and allow edits. Check pack count, local date, exclusion and amount due with speakers of both languages, including after a locale change.

#### E05 · Confirmed retailer connection

**Deferred integration, outside the first release** · Later · S06

Isolate the retailer adapter and capability ledger. Launch ships copy/share and user-open only. Before an official cart-write rollout, prove scopes, permissions, local price/fill limitations, idempotent add and response verification.

**Accept when.** Keep the historical ID to preserve the decision trail. The shipped handoff is copy or share of shopper-reviewed household lines and user-directed checkout. No provider credential, integration or live retailer access is a release prerequisite.

#### E06 · Pantry and freezer carryover

**Free manual entries; assisted pairing requires Household. Optional household-entered storage and batch details** · B04 B08 · S04 S08 S12 S15

Store household-entered pantry/freezer lots, confirmed yield, observation time, reservations and use-first preference. Carry over only what has been confirmed; never create leftover servings from a theoretical remainder.

**Accept when.** Record a dated pantry or freezer batch, usable quantity, reservations and a use-first hint. Confirm before carrying food into a dinner. Five portions cannot cover four dinners and two lunches. A correction updates dependent meals once.

#### E07 · Faster shopping access

**Free supported iPhone surfaces, with privacy and accessibility checks** · B09 · S02 S06 S20 S22

Store-scoped aisles, manual sort, dictation, locked-safe widget/App Intent, share extension inbox and print layout. Reuse domain actions. Extension cancellation must not create a confirmed line.

**Accept when.** Provide store labels, aisle grouping, keyboard dictation, a scoped widget, selected-text share extension and large-print list. Compare finding one item across long lists. The locked widget hides budget/private notes and a cancelled share import leaves the draft intact.

#### E08 · Optional reminders

**Free, explicit notification permission** · B09 · S07 S12 S20

Schedule local notices for explicit deadlines or deferrals. Store time zone, expiry and quiet hours; cancel/reschedule on edit or revocation. Open current state and re-evaluate expired offer.

**Accept when.** Choose a specific deferral or offer deadline, local time, quiet hours and expiry. A delayed notice after cutoff opens Await pickup. Turning reminders off leaves the ordinary shop usable.

#### E09 · Price and budget history

**Household history and period planning, free current-shop budget preview** · B08 · S03 S05 S11 S20 S27

Keep observed price history by pack/store/channel plus optional period envelopes and allocations. Reconcile pending vs posted; display remaining as conditional if shops are incomplete.

**Accept when.** Review household-entered prices by store and mode. Reserve future shops in an optional pay-period envelope. Distinguish warehouse from web, deferred spend from savings, and incomplete periods from verified balances. Restrict budget and payment information to authorized adults.

#### E10 · Other surfaces and markets

**US launch coverage, mobile web on supported browsers, market-by-market release checks** · B07 B10 · S10 S21 S22

Serve responsive contributor and one-shop cook views on supported iPhone/Android browsers. Do not expose a native adult account to helpers. Validate each market independently before enabling it.

**Accept when.** A helper on Android/browser can receive instructions and submit, inspect or withdraw their own request within shop rules. Gate specific chain, language, currency, unit and market claims on local checkout fixtures and support. Test the mixed-phone task without a native companion or adult account sharing.

### Requests, voice and recovery

#### N01 · Family request inbox

**Free on participating phones, including invited kids with the appropriate guardian setup** · B07 · S21 S22 S23 S24

Redeem a narrow invite, receive reviewed requests, clarify/link/add/defer/dismiss. Keep each author's receipt. Freeze current basket at checkout, route late writes by server state and require authority/revision checks.

**Accept when.** An invited author types or speaks, reviews and submits. Only the active shopper may merge, add, defer or dismiss. Show the shopper the full-budget preview first. Locking for checkout protects the basket. Placement routes new and undecided requests to Next shop. Deduplicate retries. Contributors receive only their own request status and no budget or payment fields.

#### N02 · Structured speech entry

**Free request entry, optional speech with a typed equivalent** · B09 · S02 S22

Optional on-device speech captures a bounded draft. Parse item/count/unit/pack/purpose/destination, distinguish negation and ambiguity, review material amounts, then send precisely once or cancel.

**Accept when.** Preview item, pack count, amount and destination. Correct one field. A contributor confirms a request only. For the shopper, selecting Apply can update the local planning draft. A retry affects the intended record exactly once.

#### N03 · Dinner readback

**Free, optional on-device playback where supported** · B09 · S10

Render a current dated instruction and request playback of that exact projection. Pause/stop/repeat, stop on route change, avoid overlapping VoiceOver, require user action to resume.

**Accept when.** Read the selected current cooking instruction with pause, stop and repeat. Use confirmed usable quantity and reservations, keep the dated text visible and omit private budget by default. VoiceOver and readback must not talk over one another.

#### N04 · Product-name corrections

**Optional, device-local and editable** · B09 · S02 S20 S22

Device-, profile- and locale-scoped correction records. Offer a spelling after an explicit correction; preview on future matches, delete or opt out. No rewriting old requests.

**Accept when.** After the user corrects a recognized product name, offer to remember that correction. Show it for review at the next matching entry, preserve original wording and let the user forget it without changing past records.

#### N05 · Source on manual recipe

**Free manual recipe entry** · B05 · S14 S26

Save a user-entered source URL and original recipe data independently. An optional URL is attribution, not a network fetch or license. A missing site never invalidates the dinner.

**Accept when.** Paste an optional source URL alongside the family's own meal title, servings and notes. A failed import or vanished page leaves the editable dinner and its weekly allocations intact.

#### N06 · Recovery comparison

**Free record and backup recovery** · B05 · S20

Compare source namespace, immutable revision, parent and projection. Preserve unrelated/newer records on Cancel or restore. Never use backup ownership as an authentication signal.

**Accept when.** Compare the selected backup's source, date, revision and affected records with newer local work. Preview which records match, conflict or are absent, then recover separately. Cancelling or importing a corrupt file makes no changes.

#### N07 · Spoken guest preview

**Household guest automation or isolated preview, free manual guest edit** · B09 · S16 S17

Route a guest utterance to an identified meal/count proposal. Use the identical planner as manual editing, expose pack and cap changes and check current authority before Apply.

**Accept when.** Say one more guest, confirm which meal and count, then review pack, protected lunch and checkout effects on screen. Cancel discards the preview. Apply once creates a draft revision, and any order amendment still needs retailer confirmation.

### Meal week, dinner ideas and store quotes

#### A01 · Household meal-week calendar

**Free manual planning; Household assisted changes** · B10 · S25 S14 S16

Build an adult-only seven-day view of meal occurrences, servings, away nights, guests, sides and protected lunches. Move or edit an occurrence as a proposal. Reuse the same guest and reprice operations as S16.

**Accept when.** Move Thursday's dinner across a local date boundary. Lunches and other meals remain intact; the original rotation is unchanged. A contributor cannot read the week.

#### A02 · Editable dinner ideas

**Free suggestion and manual review; Household assisted pairing** · B10 · S26 S14 S15

Produce an editable candidate using app-owned templates or household-approved variants. Show source, quantities, yield, time, assumed extras and exclusions. Accept into library, then separately schedule, then explicitly apply a shopper-approved change.

**Accept when.** An unknown yield prevents a coverage claim. Editing or discarding an idea makes zero basket changes. Reject an excluded ingredient; approving a corrected idea does not yet schedule it.

#### A03 · Compare two entered store quotes

**Free manual comparison; adult with budget scope** · B10 · S27 S03 S05

Branch two private quote scenarios from one commitment set. Record package/availability, quote freshness, fees and mode per store, incremental travel money and time. Label incomplete alternatives; choose one to preview adoption. Keep store price and trip money separate.

**Accept when.** A cheaper shelf basket becomes more expensive after its extra trip. Missing fee leaves the winner unknown. Adopting a quote invalidates stale offers and cannot change an already placed order.

### Product boundaries

#### X01 · Grocery marketplace and delivery

**Excluded** · Boundary · S06

Use retailer-directed checkout and truthful handoff states. No payment, fulfillment or marketplace service.

**Accept when.** The shopper completes payment, slot selection and ordering with the retailer. Copy and share never create an ordered or delivered state.

#### X02 · Universal deals and store routing

**Excluded** · Boundary · S05 S27

Keep universal discovery/routing out. The approved A03 only compares two shopper-provided, explicitly scoped alternatives.

**Accept when.** S05 compares same-shop checkouts. S27 may compare two explicit shopper-entered store quotes and incremental travel costs. The app never presents a universal deal, silently fetches stock, recommends an automatic route or places a second order.

#### X03 · Medical or allergy decisions

**Excluded** · Boundary · S07 S09 S26

Never infer medical suitability; enforce entered exclusions and send ambiguous ingredients for review.

**Accept when.** Respect household-entered hard exclusions and let the family decline any replacement. A scanned name or translation cannot certify allergen safety or suitability for a medical condition.

#### X04 · Broad generated recipes and nutrition coaching

**Excluded** · Boundary · S14 S26

Use A02 reviewed suggestions; keep free-form authoritative nutrition or medical guidance outside the product.

**Accept when.** Offer approved meals and manual entries. Leave a need open when none fit. No generic recipe generation, nutrition targets, diet coaching or calorie dashboard.

#### X05 · Social feed and family calendar

**Excluded** · Boundary · S21 S25

Use A01 for the private adult meal week. Do not build social, school or chore feeds.

**Accept when.** Record an away night or guest against the meal. A contributor request stays private to its authorized participants. No social feed, school schedule or full family calendar.

#### X06 · Mandatory scanning and credential scraping

**Excluded** · Boundary · S02 S06 S08

Provide optional camera and official external open, keep typing viable, never collect retailer login secrets.

**Accept when.** Complete a shop by typing and manual retailer review with camera access denied and no retailer password in the planner. Optional scan review and official shopper authorization remain distinct routes.

<a id="routes"></a>

## Screens, entry points and recovery

### Where people enter

On iPhone, use three SwiftUI tabs with independent navigation stacks. **Shop** opens the current pickup (S01). **Dinners** opens planning choices (S13) or the meal the shopper last viewed. **Records** opens saved pickups and files (S20). A gear on each root opens durable settings. Returning from a detail restores the originating tab, query, scroll position and selected shop. A sheet carries a proposed change. Dismissing it discards edits unless the screen explicitly saves a draft. Identify a restored destination by household, shop and stable record ID. Recheck access on resume.

On a shared phone, an invited contributor enters their own S22 space. Returning to adult tabs requires unlocking the adult session. On mobile web, an invite opens redemption then S22. A separate current-view link opens a narrow, dated shop view with its own grant. A cook can read the complete plain-text instruction in their usual messaging app. Only a separately authorized editor may propose edits to a shared view. Identify the shop, last update and expiry before showing content. On revocation or expiry, end online access and offer a path to request a fresh link. Prior exported messages remain readable.

**First free pickup.** From S01 choose **Start pickup**, paste a list at S02, then enter a $38 whole-pickup cap at S03. At S04 link the twelve wraps already listed to two dinners and lunch. S05 shows the actual packages and whether deferring a flexible line keeps the order under $38. At S06 the shopper first freezes the reviewed basket, then explicitly copies or shares the list. Copy alone never places or freezes an order. The shopper checks out with the retailer and returns to confirm placement. At pickup, S08 records discrepancies. S09 repairs a dinner if necessary, S10 sends the cook instructions and S11 closes the shop. S12 starts a new draft from one familiar dinner and reviewed carryovers. Each short route also works independently. A shopper comparing two packages can go directly from S01 to S04 and leave with an answer. Accounts, household invitations and subscription previews enter only when the shopper selects those features.

### Shop and pickup

#### S01 · Start or resume
**Entry and action.** Shop root for a local or authorized household shopper. Show the dated pickup, next available action, last local save and last household sync. Offer Start pickup (S02), Compare packs (S04), Check one change (S05), Something is missing (S08) and the household inbox (S23) when authorized. Starting a pickup creates a local draft. Opening an existing shop reads its saved state.

**Check.** On first launch in airplane mode, two pack offers yield a usable comparison without setup. On restart after an offer expires, resume at Await pickup with the local deadline. Switching to a contributor clears adult navigation and previews.

#### S02 · Bring the list
**Entry and action.** Shopper from S01, selected-text extension or a saved draft. Type, dictate, paste or share selected text into an editable import preview. Show original wording, parsed units and unresolved lines together. Confirm once to add or link contributions. Explicitly distinguish checking a line from opening its detail. Keep notes, aisle/store grouping, search, recently checked, undo and the large-print list accessible. Keep entry and search pinned. Open detail by tapping the label and check using the separate control. Ordinary search excludes trash. Preserve original import order independently of a shop-specific sort. Recently checked, Handled and Trash expose Restore or Reopen by stable ID, including after restart. Handling a need records who took care of it. Checking a line records list progress. Deleting a line previews effects on active needs.

**Check.** Paste “12 wraps” twice. Prompt for merge or add, and let the shopper link six to tacos within the existing twelve. Cancel a share import, then return from detail on a long filtered list. Preserve existing lines, search and position.

#### S03 · Describe this pickup
**Entry and action.** Shopper from list or checkout comparison. Ask only for facts needed by the decision. Capture cap amount, scope, currency and firmness, branch, fulfillment mode, slot, and retailer preview with its source, time and included charges. Mark essentials and genuinely flexible lines. Saving a changed branch, slot or mode invalidates affected quotes. Show old and new full dates, times and fees before applying. Only when an authorization hold is binding, the shopper may enter the retailer-displayed hold and optionally compare it with funds available for that payment method. Keep available funds session-local and private. S05 presents the hold gap separately from the spending cap. An unknown hold stays unknown.

**Check.** A $35 dinner limit with unknown household goods remains dinner-only. Cancelling a slot change restores the previous basis. A fee of unknown applicability leaves a conditional total.

#### S04 · Inspect an ingredient
**Entry and action.** Shopper from a line, meal or stand-alone pack check. Read the original need, linked requests, manually added quantity, meal shares, reservations, available stock and package offers. Show buyable packs, cost for enough usable food, unit basis and remainder. Edit one contribution, link within existing quantity or explicitly add demand. Return to the source or compare at S05. Show ingredient use and whole packs bought on separate lines. Bound derived carryover by confirmed physical stock on a comparable basis. Package photo or barcode capture opens a manual match here.

**Check.** Six taco wraps, four quesadilla wraps and two lunches need two eight-packs with no stock. Hiding lunches changes presentation only. A lower price per pound still requires checking actual pack weight. Leave mass-to-volume unknown without an ingredient-specific basis.

#### S05 · Compare checkout choices
**Entry and action.** Shopper from Shop, item detail or a request review. Compare like-for-like pickup previews, including remaining original quantities, protected portions, applicable promotions, fees, taxes and other commitments. Name the affected dinners, line ceiling, overall cap and unresolved terms. Ask the fewest preference questions needed to identify a sufficient option. Save a reviewed choice or leave the draft intact.

**Check.** With $34.80 protected, $4.60 coffee, $1.50 salsa and an applicable $4.95 fee below $35, deferring coffee alone produces $36.30. Deferring both produces $39.75. Two simultaneous changes share one allowance. When exact weight is missing, show the maximum weight that fits if calculable.

#### S06 · Prepare the retailer handoff
**Entry and action.** Active shopper from the reviewed list. Save an immutable, readable dated snapshot, protect that basket for checkout and route incoming requests to Next shop. Copy or share the household-authored lines. Track those actions separately. On return offer I placed this order, Still checking out and Reopen draft. Placement records who reported it, when and against which frozen revision. A later amendment requires independent retailer confirmation.

**Check.** Cancel share, open an empty retailer cart or lose connectivity. The frozen list remains available and placement is unconfirmed. An authorized local placement report queues for sync. If authority changed meanwhile, preserve the separately attributed report for the current shopper to reconcile.

#### S07 · Review a store offer
**Entry and action.** Shopper from an order line or optional deadline reminder. Enter the replacement, quantity of original still expected, offered pack, price, local cutoff and impacted meals. Read dish-specific acceptance and maximum price. Show combined cost and uncovered portions. Record the household preference and retailer response separately. Offer a deadline reminder only on request. Offer Preview retailer note and Copy from this offer. Include the required usable quantity, authorized offer-specific price or weight ceiling, cutoff and the fallback if short. Omit household budget, available funds and family details. Both copy and cancel preserve the pending decision.

**Check.** A replacement can fit the basket but exceed a saved line ceiling. Ask before accepting. Reopen an unresolved offer after restart. Once its cutoff passes, display Await pickup with time and keep the fill unknown. Never assign a new placement fee just because the retailer later shorts the order.

#### S08 · Record what came home
**Entry and action.** Shopper from the order or missing-item shortcut. Allow discrepancy-only review. For each original or substitute record no-fill, partial, wrong, late or split fulfillment, actual arrival, usable amount and protected portions. Link evidence and corrections to the same delivery. Show an unchecked line as unverified. Keep later deliveries pending until confirmed in time. When opened from Something is missing without a prior order, ask what food is short, what meal needs it, how much is available, and by when. Create a private local planning need and a reviewed stock observation, then open S09. A due time may remain unknown. Reopening offline restores this need. This branch creates zero orders, fills or charges. Receipt-line capture belongs to the order branch.

**Check.** One delivered eight-pack with six usable and two reserved supplies four to tacos. Correcting usable to seven supplies five. Replaying the same save adds no new pack. Two separately confirmed deliveries survive. A credit alone leaves the dish short.

#### S09 · Repair the meal
**Entry and action.** Shopper from S08 or an affected dinner. Show required vs available quantities, named reservations, timing and exclusions. Enter a free manual fix, confirm freezer stock, choose a top-up, deliberately repeat or change a dinner, or leave it open. Household assistance ranks accepted feasible dishes. Obtain explicit agreement before introducing another trip or repeating a meal. Before labeling a fallback feasible, compare remaining elapsed preparation time with the meal deadline. If a recipe needs two hours of marinating and dinner is in 45 minutes, ask whether that step is already complete or suggest another reviewed meal. Unknown timing stays conditional.

**Check.** Replacing Wednesday’s dinner leaves Tuesday’s shortage visible. A frozen batch of five portions cannot serve four plates and two protected lunches. If every approved option misses a requirement, preserve the open need and its due date.

#### S10 · Tell the cook
**Entry and action.** Shopper or authorized adult from a meal or revision. Preview a complete dated plain-text instruction with portions, what to set aside, unresolved needs and revision. Select recipient language, edit wording and explicitly choose any private fields for this copy. Read aloud on demand with pause, stop and repeat. Share through the system sheet. Explicitly marking a recipient and version sent establishes that recipient’s comparison baseline. Offer Send dated copy and Share current view as distinct choices. For a live link, select one shop, fields, read or propose access, expiry and recipient, then explicitly issue. A scoped helper opens the current permitted fields with the revision and as-of time shown. An editor may propose a change to S17 for the shopper. Link management opens S21 for an authorized administrator. The cook can still use a static message after a link expires.

**Check.** An Android cook can act from the message alone. A US Spanish handoff preserves original product constraints, quantities and local date. Cancelling share leaves the baseline intact. A sent version proves neither receipt nor acknowledgment. Stop readback before VoiceOver speaks.

#### S11 · Close the pickup
**Entry and action.** Shopper from actual fill or order history. Record posted charges, holds, credits, additional trips and top-ups with evidence. Keep paid-to-date, unresolved money and dinner outcomes separate. Confirm bought status for the relevant family request if known. Offer optional feedback including already knew, unchanged, wrong, too late and unknown.

**Check.** A pending $2.40 credit leaves $37.20 posted as $37.20 paid. Posting a credit already reflected in a net charge cannot subtract it twice. Declining feedback permits closure and preserves unresolved items for later correction.

#### S12 · Start the next shop
**Entry and action.** Shopper from Shop or a closed pickup. Start blank or reuse one familiar dinner free. Present individual deferrals, needs with deadlines and household requests saved for next shop. Mark already handled, keep deferred, dismiss or explicitly price and accept for this trip. Household assistance recalls approved staples by purpose and store. Write a fresh draft without changing prior history.

**Check.** Coffee bought elsewhere adds $0. A checked market line remains checked until reopened. Previous offer prices are cleared, a stale reminder expires, and the shopper can recheck a carried item without duplicating the old purchase.

### Dinners, membership and records

#### S13 · Choose a way to plan
**Entry and action.** Dinners root for a local shopper or authorized adult planner. Offer manual meal entry, one free reusable dinner, usual rotations and an isolated Household preview. Continue to S14, S15 or S16. A preview copies the source references and records the base revision. Leaving the preview discards its changes. Show This week (S25) and Dinner ideas (S26) within Dinners, alongside the manual S14 route. The adult planning grant applies to the shared week and ideas.

**Check.** A free shopper tries a pairing and returns to the original list unchanged. A second adult can prepare a proposal for the active shopper. Only the active shopper can apply it to the pickup.

#### S14 · Choose familiar dinners
**Entry and action.** Adult from Dinners. Record title, servings, source URL, notes, meal-specific approvals, hard exclusions, named portions and linked ingredients. Select one meal or permitted rotation nights. Import the supported library file through a batch preview showing matches, duplicates, skipped fields and original source. Recipe photo/OCR opens the same editable review. Save this week separately from the usual dinner. Separate Accept as a candidate from Choose for this shop. A chosen dinner may have no assigned night. Its occurrence and grocery demand exist once. Assign a date at S25 by updating that same occurrence. Offering or declining a candidate creates no shop need. Offer optional known elapsed lead time and already-completed steps for the timing warning at S09/S10.

**Check.** A broken recipe link leaves servings and allocations editable. Undoing a library import removes that batch’s changes without deleting unrelated records. A one-week substitute becomes a usual preference only by explicit choice.

#### S15 · Pair dinners across a pack
**Entry and action.** Authorized adult from Dinners, or isolated preview. Compare accepted meal pairs using confirmed unreserved food. Show each complete alternative’s diners, ingredient and pack changes, protected portions, prep time, fees and total cash. Select a proposal for S17. Return to manual planning if no viable pair fits. Compare a proposed pairing with the actual current schedule. If both dinners are already chosen, report no new pairing. After Apply the next preview starts from the accepted revision. Cancel leaves the old revision active.

**Check.** Three peppers cannot be allocated twice. Cover lunches and all ingredients in both alternatives before displaying a saving. Missing price or usable yield produces a conditional comparison with the unresolved input visible.

#### S16 · Add a guest
**Entry and action.** Adult from a meal or Shop. Enter or speak a temporary change. Confirm meal, guest count, individual plates and sides, then preview pack and checkout effects. Include nights away and reduced servings. Free shoppers edit manually. Household assistance prepares a review for S17. A voice utterance never applies a change directly.

**Check.** Eight to nine needed wraps crosses an eight-pack boundary. Twelve to four still buys one twelve-pack. After pickup, skipping dinner opens a carryover check. Confirm remaining usable food before assigning it. Cancelling restores the base and named lunches.

#### S17 · Apply and explain a revision
**Entry and action.** Adult from a meal change or a proposal. Compare the reviewed base with the current shop revision. Show the commitments affected by this proposed change. Active shopper applies once, then optionally prepares a corrected instruction. A changed base requires fresh review. For a placed order, retain the change as a proposed amendment. Free shows the previous dated copy and a manually editable full correction for this recipient. Only authorized Household assistance computes a recipient-specific difference. After lapse, keep both dated copies and manual resend available. A cook with an editor link submits only an allowed proposal. The shopper alone commits basket changes.

**Check.** Two adults review the same pickup. The second stale proposal cannot overwrite the first. A replay of the same apply creates one revision. If the prior destination is unknown, provide a full current message instead of a differences-only correction.

#### S18 · Decide on Household
**Entry and action.** Adult from Settings or an intentionally selected planning feature. Show the annual offer, two named planning seats, renewal, current storefront terms, free route, Restore and Manage. Present the proposed US $49.99 annual price only when consistent with the actual storefront offer. Purchase through StoreKit and read verified entitlement state. Keep marketing experiments and purchase records separate.

**Check.** Pending purchase leaves paid tools inactive. On cancellation, honor the verified access period. On expiry retain free manual work, family requests, one reusable dinner, saved records and exports. A child cannot reach purchase controls.

#### S19 · Manage the two seats
**Entry and action.** Authorized adult from Settings. Read entitlement and named seat assignments. Invite, redeem, remove or recover a second planner through the appropriate verified account. Show who organizes the household, who has paid tools and who shops this trip separately. Transfer the shop role only through an explicit authorized handover.

**Check.** Redeeming a seat grants no automatic shop or budget access. Reinstalling and restoring a purchase does not add a third seat. Removal, refund, grace period and entitlement expiry update the appropriate capability without erasing personal records.

#### S20 · Find records and recover files
**Entry and action.** Records root for authorized adults. Find saved pickups, sent notes, past approvals, actual fills and unresolved outcomes. Display local save, household sync and exported backup times separately. Preview a minimally scoped helper copy or a personal readable/structured export. Compare backup source, stable identities, date, revision and conflicts before recovery. Show correction, support, deletion scope and undo where possible. Place price history and period planning under Records. Reveal a period aggregate only when the adult has current budget access to every contributing shop in that period. With partial access, return an explicitly scoped subtotal of permitted entries or withhold the summary. Suppress hidden-shop count, implied remainder and derived financial signals. Offer Manage shared views leading to the authorized S21 panel.

**Check.** An older backup opens beside newer work for review. Reimport recognizes the same source revision. Malformed input or cancellation leaves records intact. Apply deletion history before reconnecting a restored device. Imported records cannot restore revoked access, guardian consent or paid membership.

### Household requests

#### S21 · Invite and manage household contributors
**Entry and action.** Organizer or guardian from Settings. Show household, invite scope, alias, devices and revoke controls. Offer an adult contributor invitation or guardian-managed child setup. Complete required guardian notice and verification before enabling child network participation. Issue an expiring single-use invite of the requested scope. Allow reissue and revocation. S19 owns paid seats. List active one-shop view grants separately from contributor invites and paid seats. Permit the authorized grant manager to inspect selected fields, expiry and scope and revoke the link. At the next access a revoked link ends the live session. A previously exported dated copy remains labeled with its as-of time.

**Check.** A used, expired or revoked token cannot activate a device. A forwarded invite cannot broaden its grant. A child without completed guardian setup cannot submit online. Revocation prevents new server reads and writes, including queued actions on an old device.

#### S22 · Ask the shopper
**Entry and action.** Invited contributor via iPhone or mobile web. Show household before entry. Type or speak item, amount, pack count and intended trip. Review original wording and parsed fields, correct one field, then send. List only this author’s own requests and statuses. Permit edit/withdraw while pending. Later corrections become follow-ups. Show waiting to sync locally and server confirmation separately.

**Check.** Retry a cereal request after disconnect without duplicating it. Show next-shop routing when protected or placed. An unknown quantity stays unresolved. Changing households clears the prior form or prompts to keep it with its original destination. Server payload and browser history expose no budget, other requests or private notes.

#### S23 · Review family requests
**Entry and action.** Active shopper from Shop. Read submitted requests with alias, amount, server-received time, destination and revision. Show potential duplicates together while preserving each author and intended use. Ask for clarification, mark handled or dismiss with a scoped outcome. Select the package and quantity for S24. Keep completed decisions inspectable.

**Check.** Two authors request cereal. Ask whether one box covers both or a second is needed. Keeping separate sources lets each author receive their own outcome. If a request changes while open, refresh before acting. A former shopper cannot submit a decision.

#### S24 · Choose this pickup or the next
**Entry and action.** Active shopper from S23. Read the request, shop revision, matched quantity, cheapest sufficient available pack on known terms, price basis, meals and inclusive before/after total. Offer Add to this pickup, Save for next shop and Cancel. Unknown price keeps the effect unknown. An overage requires explicit shopper acceptance. Commit basket change, decision and author-visible outcome together once.

**Check.** $37.20 plus $3.49 gives $40.69, or $2.69 over a $38 cap. One confirmed matching box already in the draft can cover a request at $0 incremental cost. Cancel leaves it pending. A revised quantity, changed authority or checkout lock invalidates the preview. Do not silently add it after placement. A contributor receives only their status.

### Meal week, dinner ideas and a two-store comparison

The financial portion of any preview requires the current shop's budget scope. When a planning adult has only meal access, render the authorized food effects without prices, cap, monetary delta or implied budget outcome. Route their proposal to the assigned shopper for the private review.

#### S25 · Plan the household meal week
**Entry and action.** Authorized adult from Dinners or the guest sheet. Offer a week grid and an equivalent chronological list grouped by full local date. Select a meal, add a guest, mark an away night or reserve lunch portions. Use the same meal and reservation identities as S14–S16 so edits from either surface agree. Preview affected portions, packages, cost and previously sent instructions at S17. Only the active shopper applies changes to a pickup. Other authorized adults may propose changes. Show chosen dinners without dates in an Unscheduled section. Scheduling moves the same occurrence from this section to its date. Require a real date for a dated reminder. Accepting an idea alone does not put it here.

**Check.** Move one dinner across the week boundary while preserving a lunch reservation on its original day. Ask before moving a linked commitment. An away-night edit after purchase leaves the charge intact and offers dated carryover. An already submitted order requires a confirmed amendment. Show a stale edit for review and keep the ordinary rotation unchanged. Contributors and expired one-shop links cannot open the household week.

#### S26 · Review a dinner idea
**Entry and action.** Adult with meal-planning access from Dinners or an open meal slot at S25. Create an editable idea draft, show suggested servings and ingredient quantities with units, flag missing information and household exclusions, and let the adult replace or remove an ingredient. Preview stock, usable yield, named reservations, whole packs and unresolved prices. Obtain explicit household adult approval of the meal and quantities before offering to link it to this week. Applying list changes still requires active-shopper review at S17. Saving an idea, approving a new usual dinner and committing a shopping change are separate actions.

**Check.** Generate an idea containing a household-excluded ingredient and an ambiguous package. Keep the proposal outside the list and accepted library. Let the adult correct both fields, inspect the remaining quantity after lunch reservations, then approve. Cancel or retry during generation without generating duplicate lines. An unavailable generator leaves manual meal entry available. A contributor cannot generate or approve on an adult’s behalf.

#### S27 · Compare two entered store quotes
**Entry and action.** The local shopper or a household adult with private budget scope (including the assigned shopper for that shop) opts in from S05. A non-shopper can save a comparison or propose a change. Only the current shopper may adopt it after reviewing an open draft. Enter both stores’ comparable packages or baskets with branch, source, date, slot, currency, eligibility, quantity, fees and availability. Identify whether the second option needs an extra trip. Allow explicit travel/parking costs, other known charges and optional time with its own unit. Show item-price difference, total checkout and total including incremental trip expense separately. Mark unmatched quantities or missing terms. Offer save comparison or explicitly revise the draft at the chosen store. Store choice invalidates old store-specific quotes and requires review.

**Check.** A second store’s basket is $3 cheaper but its extra trip costs $4. Show that it costs $1 more overall. Unknown trip cost shows a $3 break-even point if all other terms are comparable. Missing prices or availability leave the comparison conditional. No location tracking, fetched price, second trip, route or order follows from entering either quote. Invited contributors cannot access private price comparisons.

### Shared controls and secondary views

- **Input and capture.** Request permission when the person selects the microphone, camera or photo picker. Every capture has a typed equivalent and an original-versus-interpreted preview. Barcode identifies a candidate product. Receipt OCR proposes lines. Neither confirms price, purchase or fill. Offer a device-local spelling correction only after an explicit edit. Let the user inspect or forget learned names without rewriting prior records.
- **Food storage.** Open pantry and freezer batches from a need or Dinners. Edit storage date, usable amount, reservations and use-first hints. Confirm carryover before a meal consumes it. If a correction affects several meals, preview each effect and commit the change once.
- **Price records and period budgets.** Authorized adults open these from Records. Filter household-entered prices by branch, mode and evidence date. Separate web and warehouse prices. A pay-period view distinguishes planned future holds, posted charges, expected credits and unpriced shops. Deferment moves an expected expense. It cannot establish savings or a verified period balance.
- **Settings and privacy.** Put appearance (system by default), accessibility, readback, editable speech corrections, interface language, optional measurement, help, membership, privacy, export and household membership under the gear. Keep recipient language, list sorting, store label and reminders at their point of use. Ask notification permission for a selected need or cutoff with local time, quiet hours and expiry. Lock-screen widgets use a narrow read model and hide private notes and money. Avoid putting secrets, budget text or member names in deep-link parameters.
- **Appearance and access.** Follow Gen 13’s linen/white/ink/spruce light palette and dark canvas/raised surface/light ink/mint palette. Show affected item, dinner, dollars and action together. Use explicit words for uncertainty, pending sync, over cap and shortage. Support Dynamic Type and web text zoom with stacked comparisons, semantic group headings, native form labels and accessible checkbox actions. Check VoiceOver, mobile screen-reader and hardware-keyboard reading order with full dates, money and units. Support high contrast, light/dark and Reduce Motion. Keep numbers stationary, announce one committed result and return focus to the changed row. Every swipe action has a labeled button.
- **Language.** Ship human-reviewed US English and US Spanish across entry, shop, help, billing and exports. Set interface and recipient language independently. Preserve original names, exclusions and currency. Exercise long strings, plural forms, RTL resilience, interrupted speech and locale switches during a draft.
- **Operational boundaries.** Default handoff is the shopper-reviewed dated list. Direct retailer integration is deferred. The adult meal-week view, reviewed dinner ideas and two entered store quotes ship in the first release. Their scope excludes a general family calendar, unreviewed recipe-to-cart changes, universal deals and automatic multi-store routing. The planner does not provide a delivery marketplace, medical/allergy judgments, nutrition coaching, social feeds or mandatory scanning.

### Presentation on iPhone

A shopper comparing two packs needs Shop → Inspect an ingredient. A contributor needs one place to ask and check their own result. Making either person pass through all the pickup stages would defeat both uses. The following is the recommended compact-width presentation. Retain a contract ID when the same task adapts to a larger display.

| Presentation | Contracts | Reason |
|---|---|---|
| 3 tab roots | S01 Shop, S13 Dinners, S20 Records | Resume the current trip, work on meals, or find earlier evidence. Each preserves its own navigation state. |
| 15 pushed destinations | S02 list, S04 ingredient, S05 checkout comparison, S06 retailer handoff, S08 arrivals or private shortage entry, S09 meal repair, S10 cook handoff, S11 closeout, S14 familiar dinners, S19 seats, S21 grants, S23 inbox, S25 meal week, S26 dinner idea, S27 store quotes | These tasks can have long content, history or several edits. Give them Back and a stable return location. S19/S21 enter through settings or a contextual management link. S10 additionally has a grant-limited web rendering. |
| 8 contextual sheets | S03 pickup facts, S07 replacement offer, S12 next-shop selection, S15 pairing, S16 guest, S17 apply revision, S18 Household offer, S24 request decision | Each answers a decision in its parent. Use a scrollable full-height sheet at large type. Move from one review step to the next within the same presentation. Cancel returns to the origin with focus restored. |
| 1 scoped contributor destination | S22 request and own status | Native scoped session or invite on mobile web. The contributor sees no adult tab bar, checkout total, or other author's requests. |

Settings, system permission prompts, confirmation alerts, empty states and helper renderings appear where their task needs them. Count these separately for implementation estimates. Promote a sheet to a pushed view if testing shows people routinely need navigation history or lose work on dismissal. Add a tab only if repeated cross-task navigation shows an independent, frequent destination.

<a id="design"></a>

## Visual design, language and interaction

**One person should be able to read the next decision while standing in a grocery aisle.** Lead with the item or meal, give the quantity and its consequence, then one primary action. On a $38 cap, the hero reads “Expected checkout $40.69 · $2.69 over $38.” Keep the fee basis and unknowns beside it. For a contributor the same event reads “Cereal · Saved for next shop.” Do not render the adult card underneath a privacy overlay.

The retained visual studies show [light and dark checkout](foundation-gen2.1/references/grocery28/Recommended%20appearance.png), [shop and arrival screens](foundation-gen2.1/references/grocery28/Working%20screens.png), [household requests](foundation-gen2.1/references/grocery30/Family%20inbox%20study.png), [text hierarchy](foundation-gen2.1/references/grocery29/Typography%20study.png) and [motion](foundation-gen2.1/references/grocery28/motion-study.gif). They illustrate behavior. Register, permission and state contracts govern any older labels in the images.

### Color placement

[theme.json](foundation-gen2.1/contracts/theme.json) is the token source. Generate named colors in the iOS asset catalog and CSS custom properties for web from the same file. A build check compares the generated values. Views reference roles such as `Theme.action` backed by `accent`. Raw hex values belong only in that generation step. Follow device appearance by default and offer System, Light or Dark in device settings.

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

### Type, layout and interaction

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

### Interaction walkthroughs

| Job | Path and return behavior | Evidence required on the native build |
|---|---|---|
| Pick a pack now | S01 → S04. Return to Shop at the same scroll position. | New, offline installation. Compare equivalent usable quantities. Leave an unknown yield unresolved. No account or setup questions. |
| Decide on Sam's cereal | S01 → S23 → S24 → same S23 row. | Sam asks once. Mia sees current and proposed checkout, two protected lunches and the $2.69 overage together. Deferral keeps $37.20. Accepting the overage produces $40.69 once. Only Sam's outcome returns to his view. |
| Rescue tonight without an order | S01 → S08 private shortage → S09 → S10. | Reopen the local need after a restart. Confirm available food and timing, retain lunch reservations and prepare a dated cook message. Zero order, delivery or financial records. |
| Choose dinners before choosing nights | S13 → S14 → S25, optional S16 → S17. | Accept as candidate creates no demand. Choose for this shop creates one occurrence. Assigning Tuesday moves the same occurrence. A cancelled guest preview restores the week and current basket. |

### What the shopper sees and feels

In Shop, give the active pickup, its next action and any pending requests priority. Keep quick pack comparison and urgent repair within one selection from the root. Put frequent list entry and search above the scrolling list. Use short food names and fixed-position, tabular amounts. At large type, stack the amount directly beneath its label. In Dinners, photographs can help identify saved meals. In a checkout decision, use the same space for the affected dinner, amount and next action.

In the request decision, the shopper sees the projected total first, the overage in words next, and the two numbers that explain it beneath. Give the affordable next-shop choice the filled spruce action in this worked example. Keep the over-cap choice available and ask for explicit acceptance. After a decision, return to its original row and focus the durable outcome label. A repeated tap cannot create a second effect. When the server has not accepted an offline request, label the local and shared states separately.

Use the system navigation and sheet transitions. For custom feedback cap press emphasis at 100 ms, selection at 160 ms, detail disclosure at 180 ms and a confirmed local change at 120 ms. Do not animate currency counting, reorder rows under the finger or play a success haptic for an uncommitted preview. On dismissal, interruption or Reduce Motion, show the final state immediately. With VoiceOver, move focus to one concise result and avoid a duplicate announcement. Large type, Reduce Motion and dark appearance each need their own fixture.

**Inspected evidence.** The [interactive request study](foundation-gen2.1/experience/Motion%20study.html) runs offline in a browser. Captured states show the [inbox](foundation-gen2.1/experience/01-inbox.png), [request decision](foundation-gen2.1/experience/02-decision.png), [deferred result](foundation-gen2.1/experience/03-outcome.png) and [overage confirmation](foundation-gen2.1/experience/04-overage.png). The study exercises review, cancel, defer, accept and the reduced-motion control with fictional data. Its local page state resets when reloaded. It is one interaction sample. The build still needs real storage, service authorization, iPhone frame measurements, VoiceOver and the complete set of 27 route checks.

<a id="engineering"></a>

## Architecture and operating responsibilities

### Native product with one shared contract

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

### Persistence, private use and offline sync

1. First launch creates an installation-local workspace with random IDs, SQLite foreign keys enabled, versioned migrations, atomic writes and a serialized writer. No account prompt for an item check. Protect database, backups and selected media with appropriate iOS Data Protection; keep credential material in Keychain. Use separate workspace keys/paths per enrolled persona; never expose the adult database to the widget, extension or child web client.
2. Joining a household is explicit. Preview which local shops/records to retain privately or import. Create safe new membership linkage and merge by verified origin and revision. Never upload anonymous-shop contents merely because someone signs in. Losing membership ends household service access; let an adult keep or export properly owned personal records.
3. Transactionally persist the local change, immutable local revision/event and eligible outbox operation. A queued proposal cannot advance the shared basket locally as if committed. Resume with the same operation key after crash; check household membership again. Server commits the decision, derived records, audit receipt, projected change feed and cursor in one transaction. Push carries only a wake-up hint. On launch/foreground or manual retry, pull authorized changes from the cursor.
4. A client records cursor and applied events in one transaction. On a gap/expired cursor request a scoped re-bootstrap. Detect version/authority conflicts explicitly. Keep both draft and server result for review. No automatic last-write-wins for purchases, quantities, membership or consent. Retry transient failures with bounded exponential backoff and jitter. Honor Retry-After. Stop pending writes on logout, revocation, permanent validation errors and mismatched payloads.
5. Web stores only own minimal projection. First redemption and initial load need the network. Offer a local browser outbox only when durable storage is supported, an enrolled identity exists and consent allows it. Handle private browsing, quota exhaustion, stale cookies and shared devices. A failing write says “Not saved”; offer a user-controlled copy. Reauthenticate before sending queued work and purge scoped storage after revocation or logout.

**Device surfaces.** WidgetKit reads a separate minimal App Group projection written only after a successful commit. Locked state hides private text and all budget details. A widget/App Intent can open a named capture destination; require authentication and review before any protected mutation. The share extension stages explicit user-selected text/files in a bounded inbox, acknowledges only a successful write, and imports into the app for review. The receiving app never reads the clipboard on launch. Use Vision for local text/barcode proposals; a barcode is an identifier, not a trusted price/product label. Use speech only after a tap and permission check. Custom child recognition requires a verified on-device path for the actual locale/device; otherwise typed entry works. Keyboard Dictation follows OS settings. Use local speech synthesis for a current cook instruction without requesting a microphone.

### Service identity and privacy

Default to a managed standards-based adult login supporting a verified Apple identity or email/passkey flow. Validate issuer, audience, expiry and nonce; exchange into app sessions, rotate refresh tokens and support all-device revocation. Treat email and account identity as server-private. An opaque invite token is short lived, single use, hashed at rest and limited to a role, household and intended enrollment. A helper grant has its own opaque scope, expiry and revocation. Exchange a link at first contact, strip it from the URL, use secure HttpOnly cookies and CSRF protection on web, no external trackers on invitation pages, and `no-store` for sensitive responses. Do not use a household password shared with a child. Recover adult access through verified identity, never from an imported file or an alias.

**Child enrollment gate.** Before enabling a child's networked profile, identify the actual parent/guardian, present direct notice and use a reviewed verifiable parental consent method where required. Route guardians without in-app identity to an authenticated verification flow; use a provider reference and policy version, not a copy of an identity document in app records. Block all child network submission/audio until consent and membership are active. Provide parental access, correction, withdrawal and deletion. The contributor DTO excludes budget, receipts, other requests, private meal constraints and membership lists. Keep request attribution limited to household alias. Disable child advertising and behavioral analytics. Never retain raw speech; redact free text from crash logs and lock-screen notifications. Verify the final consent method and written retention policy with a qualified reviewer before enabling child enrollment. [FTC child privacy rule](https://www.ftc.gov/legal-library/browse/rules/childrens-online-privacy-protection-rule-coppa) · [FTC guidance](https://www.ftc.gov/business-guidance/resources/complying-coppa-frequently-asked-questions)

**Data lifecycle.** Collection is purpose-bound. Define numeric retention settings and named owners in the deployment policy before beta: expired invite hashes, pending reservations, ended child profiles, inactive media, stale outbox rows, dedup receipts, telemetry, audit evidence and rotational backups have separate lifetimes. No indefinite child records by default. Link a deletion job to field-level redaction, file removal, cache invalidation and tombstones; record completion without free text. A parent may remove child attribution while preserving a shopper-owned, de-identified basket line when appropriate. After restore, replay deletion tombstones before serving data. Expiry and purge of backups must be tested. Explain the lifetime of a static copy someone already sent. In-app account deletion is distinct from subscription management, leaving a household and deleting a local shop. [Apple account deletion](https://developer.apple.com/support/offering-account-deletion-in-your-app/)

**Billing.** Use StoreKit 2 product metadata, `Transaction.updates` plus current entitlements and verified signed transaction reconciliation. Submit the signature to the service; validate its Apple chain, bundle, environment, product, transaction and renewal status. Scope the verified purchase to the purchasing account and explicitly selected household. Store transaction IDs and support duplicate/out-of-order server notifications, renewals, expiration, revocation/refund and restore. Pending/cancelled checkout grants nothing. Turning off auto-renew retains access through paid expiry. Honor verified grace when applicable; never invent indefinite offline grace. A signed, expiring cached entitlement can unlock authorized local tools until its known expiry, while Free data access remains. Finish a purchase after durable delivery. Seat assignment cannot transfer the subscription or grant shop authority. Test restore on a second device and wrong-household restore. Display the real localized price and renewal terms, manage/restore affordances and links. Two adult app seats are an app entitlement decision distinct from Apple Family Sharing. [StoreKit entitlements](https://developer.apple.com/documentation/storekit/transaction/currententitlements) · [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)

### Expansion without a rewrite

Version commands and exports separately from schema migrations. Add optional fields first, dual-read old and new records, backfill with an idempotent job, deploy readers before writers, and retire a field only after supported old clients are accounted for. Use stable IDs, UTC instants plus named time zones, integer currency minor units and exact quantity fractions with a source basis. Use capability flags by environment, market, platform, language, integration and entitlement. Flags guard availability; the complete first release includes all 52 launch contracts.

Separate dev, staging and production bundle IDs, databases, push domains, secrets and StoreKit environments. Provision through repeatable reviewed migrations. Never expose production credentials in app binaries, sample data or support exports. Apply server-side household isolation to every read and write; use least-privilege service roles and an explicit authorization layer even when using database row-level protection. Quarantine attachments by verified type, size, decompressed size, file count and safe path. Never automatically fetch arbitrary source URLs in a privileged service.

Operate the service with content-free metrics: command latency/error code, sync age, queue depth, conflict/replay rates, deletion lag, checkout math errors and billing verification failures. Log request IDs and coarse outcome categories, never transcripts, invite URLs, private notes, receipts or exact products. Back up and restore staging under a measured recovery objective; monitor backup age. Rate-limit enrollment, token redemption and mutation per actor/household; cap batch size and paginate projections. On service failure preserve private local work; keep shared approvals pending. Roll back code by compatibility window; repair data forward or restore to an isolated branch before reconciliation.

Sources for device implementation: [SwiftUI](https://developer.apple.com/documentation/SwiftUI), [WidgetKit](https://developer.apple.com/documentation/widgetkit), [on-device speech](https://developer.apple.com/documentation/speech/sfspeechrecognitionrequest/requiresondevicerecognition). Confirm actual Xcode SDK availability on the selected device matrix during B00.

### Foundation 2 implementation decisions

Use an explicit household-level adult planning grant for the shared meal week and approved dinner library. Check it on reads, commands, preview, sync and export. A local private week works without an account. A paid seat unlocks assistance only in data the adult can already access. An assigned shopper controls the current basket; their role alone does not reveal other weeks. A service child needs an active membership plus a verified guardian relationship and active notice-specific consent; verify evidence outside SQL. Verify or renew on re-enrollment. Never persist raw child voice, including on errors.

Compare the trusted server clock with the latest verified Apple entitlement, including superseding refunds or expirations, both at seat assignment and use. Do not select an older active receipt just because it has a later date. Rebind the two existing household slots transactionally to the current verified entitlement after a renewal; do not mint new slots. Seat reassignment is delete/insert in one transaction with an audit event; failure restores the original assignment. Review a read-only or lapsed view with real accounts before shipping.

Implementation defaults where earlier research did not specify pricing: private manual work, staged file import, supported-device capture, scoped sharing, reminders and manual pantry/calendar/quote/idea tools use the Free path. The plan sells repeated/assisted planning. Free can store or read historical meal records and plan as many individual dinners as needed; one chosen usual is reusable from the library. Picking a different usual changes that slot without erasing the old meal or its scheduled copies. Paid previews are disposable, never silently activate billing or change a shared basket.

## Records, calculations, imports and recovery

[model.sql](foundation-gen2.1/contracts/model.sql) is the executable relational reference. Use it to name records, identify their owners and rehearse integrity cases. The production server uses PostgreSQL migrations with equivalent tenant-safe keys, domain checks, unique constraints and transactions. iOS owns SQLite migrations for the subset the current persona may possess. Never copy a server database to a contributor's phone. The source [Gen 13 contract](foundation-gen2.1/references/grocery28/schema-contract.json) supplies revision and handoff examples and the [Gen 15 cases](foundation-gen2.1/references/grocery30/inbox-scenarios.json) supply the household concurrency examples.

### Model the actual things people can change

| Aggregate | Owner and lifetime | Durable relationships and invariants |
|---|---|---|
| Identity, membership, consent, invite, seat, grant | Verified service principals; household organizer administers membership, actual guardian controls consent | Many members per household. At most two active paid adult seats; exactly one active shopper per shared shop. Revoking a one-shop link does not revoke the whole household. A child or file import cannot confer authority. |
| Shop, store/branch, slot and immutable revision | Workspace owns draft. Shopper authorizes a shared basket. | One shop has many revisions and one active head. Each revision identifies its parent or branch, frozen content digest, author and time. Human-readable revision numbers can collide across branches. Reserve stable IDs before offline entry. |
| Source contribution, shopping line, purpose and meal demand | Household author/user or accepted request | Pasting, manual staples, recipe needs and requests have independent IDs. A line can satisfy several distinct needs. A “two for lunches” allocation inside a typed total is a reservation, not two additional wraps. Confirm an ambiguous merge. |
| Meal template, version, occurrence, plate group, week and proposal | Adult planner / guest owns local work | A usual dinner is distinct from a candidate and from Wednesday's instance. Keep accepted substitutions/exclusions by dish; a one-time guest or fallback never silently changes the template. Preserve lunch reservations when a dinner moves. |
| Pantry/freezer lot, receipt fragment and allocation | Shopper confirms arrival; household confirms usable yield | Relate every received fragment to its order line, branch, segment and source key. Usable counts may supersede an observation. Allocate remaining stock by purpose, carry over only confirmed lots, keep shortages open until covered. |
| Package, price observation, quote and envelope | Adult private finance scope | Include amount, pack/unit basis, currency, origin, timestamp, channel, eligibility and store. Keep missing/uncertain facts separate from zero. Immutable snapshots reference the observations they used. An envelope allocation is a plan, not a posted expense. |
| Quote pair and options (A03) | Adult with budget grant | Exactly two alternatives reference one set of commitments and measurement scope. Preserve each store's distinct pack, fees, trip cash, availability and travel minutes. An unchosen comparison has no effect on the active shop. |
| Order, substitution offer, amendment and fill | Shopper reports; retailer evidence typed separately | Frozen revision identifies what the shopper intended. Manual placement, provider acknowledgment, accepted replacement, actual receipt and final settlement have separate identities and timestamps. An expired offer does not prove a fill or refund. |
| Expected cost, hold, posted charge, pending credit, included credit and top-up | Adult only | Distinct sources and evidence keys. Record currency/rounding and any linkage to an already-net charge. A second real purchase is valid even at the same amount. Do not deduplicate money by value or timestamp. |
| Household request, author status, decision, role epoch, operation receipt | Author owns submission; current shopper decides; service owns routing | Source request identifies author and household even when linked to an existing line. A stale offline report can exist without closing an order. Receipts return the result of the original intent on exact authorized replay. |
| Handoff, share projection, backup, import, redaction | Creator chooses disclosure each time | Immutable revision and recipient/destination determine corrections. Store share/cancel/open, reported sent, actual known destination and acknowledgment separately. Never infer the receiving person from a system share-sheet dismissal. |
| Device preferences, media, notifications and alias | Device or explicitly designated private profile | System accessibility wins. Optional OCR images and original text need consent and a retention bound. Product aliases, speech settings and credentials never travel in ordinary family exports. Store aisle order is store scoped; a week's override is shop scoped. |

**Common representations.** Use opaque random stable IDs (including client-created ones); namespace every operation by household and actor. Use date-only values for the meal day and local meal-slot zone; use instants plus IANA zones for deadlines, quote timestamps and events. Changing display locale never changes currency or a deadline. Preserve source text/locale, amount as rational numerator and positive denominator, unit dimension, original package label and conversion basis. Use checked integer/decimal arithmetic; prohibit negative food quantities, NaN, zero denominator, invalid currency, overflow and accidental float-based dollar comparisons. Signed financial adjustments are intentional. Version lookup tables for pack conversions. A unit change never overwrites the original observation.

**Visibility drives storage.** Service owns verified credential/consent, purchase proof, grants, operation receipts and authorization history. Adult devices may cache only included fields permitted for that member and grant. Contributor gets only addressed request records and its own statuses. Helpers get a precomputed redacted projection for a single shop; unauthorized keys must never reach the browser network response. Use separate encryption, storage lifetime and retention for identifiable payloads versus structural revision/event IDs; explicit erasure overrides byte-for-byte historical reconstruction of personal text.

### Calculation contract

1. **Normalize demand.** Track each accepted need, required servings, edible units and original label. Convert only within a known dimension or with an ingredient/pack-specific confirmed basis. Two cans each labeled 15 oz are two packs, not 30 cans. Dual printed units describe one demand. Distinguish a protected reservation that partitions an existing total from a separate additive need. Never consume the same lot twice.
2. **Buy enough in whole packages.** For compatible units: `to_buy = max(0, total_accepted_need − confirmed_uncommitted_supply)`; `packs = ceil(to_buy / confirmed_usable_units_per_pack)`. First subtract other households' or other dishes' reservations from available supply exactly once. Compare total spend to cover the need, remaining shortfall and surplus potential. Unconfirmed or variable yield produces a bound or question; it cannot establish dinner coverage. A material uncertainty remains visible if the family proceeds anyway.
3. **Choose viable changes.** Check hard exclusions and food/portion constraints before ranking. Compare matched store, slot, currency and commitments. Rank valid options by fewest accepted changes meeting the cap, then expected inclusive checkout; keep ties explicit. Never assume an undecided staple may wait. Ask the next question only if its answer changes feasibility or selected action; if the basket already works, offer to keep it. If no allowed scenario works, show the best known alternative with its shortfall and unresolved needs. Avoid combinatorial explosion: bound search to the shopper's active choices; return “more possibilities untested” on budget/time limit.
4. **Price the whole pickup.** Sum pack costs plus explicitly applicable discounts/taxes/fees/deposits using matched basis. Evaluate threshold against the eligible components, with named rounding and inclusion rules. Use an inclusive user-entered total as a separate basis; do not add fees twice. Exact totals require complete evidence; allow a documented lower/upper bound only when all uncertain components are bounded. A label “within cap” requires the upper bound at or below a comparable cap; a known lower bound above cap can establish an overage. Otherwise show “Need price/fee.” Do not infer that a lower checkout meets budget. An item-only or dinner-only cap never authorizes a full-checkout statement.
5. **Evaluate retailer changes.** Show the smaller of the line-specific ceiling and remaining whole-cart headroom after other committed lines and retained original quantities; re-evaluate fee changes. Solve whole-pack feasibility jointly for simultaneous offers. For a price per weight, report maximum affordable weight at the relevant rounding/billing increment or request the total weight. Preserve hard deadline separately from pickup time. Past cutoff routes to receipt review. Only verified amendment changes the confirmed order.
6. **Reconcile.** Received amount, usable amount, reserved amount, meal shortfall, actual outcome and posted money are six different facts. Reduce availability on a damaged count without reducing money paid. A duplicate receipt message never creates a second delivery; a second genuine partial delivery does. Do not retroactively reprice a minimum-order fee after a retailer-caused short fill. Leave untouched lines unverified. Report cash paid so far separately from expected final settlement or hypothetical savings.
7. **Plan the next trip.** A saved deferral carries its outstanding need, purpose, origin and optional deadline into review. Require a fresh package and quote. A past estimate is a dated reference; a past charge stays posted. A skip/away edit before purchase may remove a whole pack; after purchase calculate carryover possibilities only. Ask before repeating a dish, changing another family's preference or making an extra trip.

### The three new decisions

**A01 · Meal week.** A date belongs to a household meal-plan zone. A week is a view over dated slots, not a second copy of the recipe library. Save an occurrence with groups such as “three standard plates, one vegetarian entrée, two lunches”; each group has its own demand. Dragging must have a non-drag Move action. Preview impact on meals, lots, remaining servings and the active shop before commit. A proposal by the second adult can update their working version; the shopper must apply any change to a shared basket. Show an explicit new revision/correction for a previously sent cook instruction.

**A02 · Dinner idea.** Start from an app-owned dinner pattern, user-selected foods and available household templates; return structured candidates with named servings, ingredient lines, units, amounts, estimated prep time, source and assumptions. Explicitly mark availability and yield unknown rather than inventing them. Rule out hard exclusions and preserve original substitutions for review. Give an adult editable fields and an ordinary manual route if no candidate qualifies. Lifecycle: *idea draft → reviewed candidate → accepted dinner → scheduled occurrence → proposed shop change*. Each arrow is an intentional command, can be cancelled between steps and has independent revision identity. If a generator returns contradictory or disallowed content, block approval, retain the draft for correction, and never change pantry or basket. Free manual/suggested ideas; Household pairing works only with approved meals. No remote model, personal-text transfer or nutrition promises are required to ship a useful first version.

**A03 · Two store quotes.** Each alternative represents a complete plan for the **same household commitments**. The shopper supplies store/branch, mode/slot, all needed products or confirmed equivalents, quantity/stock status, currency, timestamp, prices and fees. Record incremental trip cash separately from the grocery checkout and travel time separately from cash; time is never monetized by default. Confirm whether each trip would already happen and whether pickup/delivery fees are included. Compare two named single-store alternatives for the same purchase. Either alternative can incur an extra stop relative to the household's existing travel. Enter that incremental cost once. Where other already-committed purchases are identical, show them as a common baseline. If a multi-store split would change fees or item coverage, flag the alternatives as incomparable and ask for two complete quotes. No route search or live stock feed. With insufficient data show partial totals by column and which fact would settle the comparison; do not crown a winner. Always show each checkout against its own applicable cap scope. Choosing an alternative starts a review on the current draft; keep the original quote proof and never mutate a placed order.

Worked example, fictional, same family needs and USD. Store A items $36 + pickup fee $2 = **$38 checkout**. Store B items $34 + fee $1 = **$35 checkout**. If B needs $4 additional travel and 18 minutes while A is on the normal route, the trip-inclusive costs are **$38 versus $39**, so B's checkout is $3 lower while the overall cash outlay is $1 higher. An unknown B fee or an unavailable required pack yields no confirmed advantage. Leave each number, basis and time visible for the shopper to decide. Do not classify an unpurchased counterfactual as a saving.

### File and import protocol

Use separate mimetypes/file kinds for a recovery archive, a redacted shop file, a plain/print cook instruction and a recipe import. A v1 envelope carries format major/minor, document kind, origin namespace, shop ID if applicable, source revision ID and parent, projection ID, producer build, exported time, last saved time, canonical payload digest and optional media manifest. Digest the canonical data bytes, not a localized serialization; a digest detects corruption, never authority. Retain app-owned versioned migration fixtures, also when scaling template formats later.

* **Recipe library v1.** Accept a documented UTF-8 Recipe JSON-LD file containing one Recipe, an array, or an @graph with Recipe nodes. Allow title, yield text, ingredient strings, source URL, user notes and plain-text steps. Preserve unknown quantities and original units. Report unsupported rows/fields and duplicate candidates, block unsupported major versions and malicious/oversized input. No remote context fetches, script execution, link traversal or blind parsing of a website. Stage results, preview, confirm one batch, then allow undo. Manual entry and source URL work independently.
* **Helper file.** Allowlist shop label, origin identity necessary for revision comparison, selected item label, original amount/unit/language, purpose, action, food status, as-of time and version. Include private fields only on a separate explicit adult disclosure for that recipient; default them off on the next share. Deny membership, invites, buyer/seat IDs, other helpers, consent, billing, raw receipts, private exclusions, device prefs and server secrets. Missing fields in a projection are unknown; importing them must not blank private local data.
* **Personal backup.** Show selected shops, media size and disclosure before export. Include authorized revision ancestry, quantities, lot/receipt/ledger history and owned meal preferences as selected. Do not export credentials, consent evidence, active grants, entitlement or raw voice. Encrypt sensitive backups with a user-held key or passphrase using reviewed platform cryptography and explicit key-loss UX. Always offer readable redacted export separately. Redact child attribution as required. Explicitly show what can and cannot be recovered.
* **Restore.** Stage decrypt/parse, check media sizes/types/digests and envelope. Match origin + shop + revision + projection + digest. Identical content reopens once; same revision/projection with different digest is quarantined. Two children of the same parent are branches, even with identical display numbers. Keep newer local and unrelated work. Present match/conflict/absent, allow independent recovery and optional explicit reviewed merge. Unsupported/corrupt/cancel leaves current data intact. Reapply known erasure markers, exclude expired authority and purge unwanted staged files. For household reattachment, reauthorize and recheck server deletion state first.

### Concrete acceptance vectors

| Input | Must return |
|---|---|
| $37.20 pickup + one $3.49 box against $38 | $40.69 and $2.69 over. Linking one existing box to two requests yields $0 added cost without losing either author. |
| $34.80 goods + $4.95 fee; cereal changes goods to $38.29 and removes fee | $39.75 → $38.29, lower by $1.46 and still $0.29 over $38. Missing fee → conditional, never “under.” |
| Six usable wraps in an eight-pack; two lunch reservations, six tacos and four quesadillas needed | Allocate two lunches and four taco wraps. Tacos short two, quesadillas short four. Delivery, usable observation and allocation each remain inspectable. |
| Eight needed wraps → nine needed; available packs of eight | Two packs required, with original lunches intact. Reverting a guest edit restores the old demand. |
| $37.20 charge with a pending $2.40 credit; or $34.80 net with credit already included | Paid so far $37.20 in the first case and $34.80 in the second. Do not post a pending credit or subtract an included adjustment twice. |
| A partial retained original consumes headroom, two substitutions look viable in isolation | Test inherited line ceiling $1.01 → $0.61 and joint overage $0.65. Undo both restores headroom and known shortage. See [G4 UI cases](foundation-gen2.1/references/grocery19/ui-cases.json). |
| Redacted revision and full backup arrive in either order; equal displayed revision but different parents/content | Preserve each authorized branch/projection. Never clear missing private fields, mint permission or overwrite the latest shop. |

### Evidence and recovery invariants

Order lines are the entries captured at placement, not a live join for their quantities or labels. Display them from the immutable placed revision and confirmed quantity. Later retailer response or corrected report appends an attributed event and, when needed, its own revision; no rewrite of the submitted order. A reported cancellation preserves the original report and opens a distinct draft. A posted cash error is corrected with evidence and a compensating signed movement of the appropriate kind, never by editing a net charge. Only posted charges, posted credits and posted top-ups enter paid cash; an included credit explains a matching net charge, and a hold never enters the sum.

Use a stable projection identity: hash a versioned description of the file kind, recipient scope and field allowlist, **not the serialized content**. The content digest independently covers canonical payload bytes. Claim the origin, record, revision and projection inside the import transaction. On a uniqueness conflict reread: identical content is an idempotent match, different content is a quarantined attempt. Never change a prior imported digest to make a conflict disappear. An explicitly reviewed merge gets a new revision. A file never confers a live grant.


### Placement corrections

A selected shop occurrence can have an unknown night. A reusable template, an accepted candidate, an unscheduled occurrence and a scheduled occurrence have distinct meanings. Assigning a date preserves the occurrence ID and every need already linked to it. Until a specific time is supplied, a cook handoff can carry its preparation date and explicitly unresolved meal deadline.

Preserve the original ingredient name for each manual stock lot. Match it to a need only after review of identity, unit and dish constraints. A derived usable amount cannot exceed received supply on a comparable physical basis. One 20 oz pack is about 567 g and cannot yield 4,176 g of same-form leftover. When units or food form differ, require a confirmed conversion/yield basis or keep carryover unresolved. A correction revisits dependent allocations. Store optional required elapsed lead time separately from hands-on prep time and ask which steps are already complete. A known unfinished 120-minute marinade cannot fit 45 remaining minutes.

The private cash-hold check uses two separate comparisons. Expected $78 versus an $80 whole-shop cap leaves $2 of headroom. A shopper-reported $86 authorization requirement versus $82 available leaves a $4 gap for that payment method. Label both bases. Releasing a hold contributes zero savings. Never store available funds in a share, account, price history or period envelope.

**Seal the original order.** The placement service acquires the household/shop lock, checks the operation identity, actor, current authority and frozen revision, and validates exact equality of source lines, quantities and immutable terms against the frozen snapshot. In a single transaction stage its order lines, insert the placed order header last, then commit. The deferred parent relationship prevents an orphan line from committing. The header seals the line set. Reject a second placement for the same placement intent even if the caller supplies fresh local IDs. Later retailer-confirmed amendments append independent evidence. SQL protects insert-after-seal, update and deletion. Semantic equality to the snapshot and command uniqueness remain service gates.

**Application record details.** Record reviewed preparation lead time and interrupted/completed steps in versioned recipe rules and occurrence data. Record the maker and time of a handled/reopened transition in the corresponding revision or event. A local urgent shortage can use a private draft shop and a meal need with optional date, plus a manually named stock lot and reviewed usable observation. Keep zero as an observed quantity when the shopper explicitly reports none. Create a reviewed food-to-need match before allocation. When upgrading a legacy store, backfill list state from its check flag, preserve known import sequence, and leave unavailable ordering or food identity explicitly unresolved for manual review. Never fabricate a meal date, store rank or pantry match.

## Permissions, commands and synchronization

Keep prices, consent evidence and private meal constraints out of the contributor API by construction. Authenticate the session, select the current household and persona, check the actual object grant, then construct one of three response shapes: adult, own request, or scoped helper. A caller who knows a record ID gains no rights. Use the same rules on search, change feeds, exports, notifications, troubleshooting, stale-operation receipts and server-rendered previews.

### Authorization matrix

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

### HTTP surface, v1

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

#### Example shopper decision

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

### Command dictionary

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

### State transitions worth testing before UI polish

| Trigger | Shared basket / order | Request and client result |
|---|---|---|
| Incoming request in open shop | Basket unchanged | Pending current shop; authored and received times independent. |
| Freeze to prepare handoff | Freeze current revision, preserve undecided items outside the frozen plan | New arrivals route next. Existing undecided remain visible to shopper. Copying a list alone never records placement. |
| Explicit reopen after cancelled checkout | New open draft with traceable parent | Next-shop items stay there until intentionally promoted after review. |
| Shopper reports placement | Pin frozen or reconciled revision; source “shopper reported” | Route new and still-undecided requests next. A pending contributor draft can sync later with accurate server route. |
| Offline placement during authority transfer | Keep local cutoff; accept separately attributed external report for reconciliation if old authority lost | New shopper decides whether it applies to the frozen basket. Stale device cannot close, reroute or modify the newer order. |
| Later provider change / order cancellation | Keep order and amendment history; record response separately. Reopen or start another distinct draft if cancelled. | Never silently delete other households' contributions, add a duplicate box, or infer that the family received the item. |
| Confirm actual arrival | Record observed/usable quantity once; allocation can change suggestions | “Bought” requires an explicit applicable confirmation. A refund does not imply the food was missing and vice versa. |

The 20 routing and replay traces in [inbox-scenarios.json](foundation-gen2.1/references/grocery30/inbox-scenarios.json) exercise these distinctions with fictional names. Run each trace against the real API and two actual synchronized clients during B07. Test packet loss before commit, after commit/before reply, process death, clock skew, stale views, simultaneous edits and a revoked identity replaying an old success.


**Live-view lifecycle.** S10 issues a view after checking the creator's current authority to share every selected field. S21 manages and revokes it. S20 links to the scoped management panel. The recipient uses the helper branch of S10, identified by a grant for exactly one shop. A contribution link alone cannot open it. An editor can submit allowed fields as a proposal. The assigned shopper opens S17 and applies against the current base or requests a new review. Preserve the ordinary S10 dated text path after cancellation, expiry and membership lapse.

**Period query.** Authorize every participating shop before aggregating money for S20 or an export. Use the same currency for period and shop reservations. If the caller has incomplete scope, return only information independently derivable from the permitted rows, with no hidden subtotal, remaining balance, count, ranking or hint. Deny access before generating cached responses, readback or a file.

<a id="cases"></a>

## Worked decisions from the research

These cases preserve situations where two reasonable-looking answers produce different meals or different bills. Each has its own store, unit, price basis and stage of the order. Amounts from different cases must never be combined.

### How much meat does this price actually buy?

G1 found advertised Appomattox pickup prices of $19.79 for a three-pound roll and $7.29 for a one-pound roll of 80/20 beef. Using a fictional $80 cap and $60 of other purchases gives four distinct outcomes. Stock and final checkout were unknown.

| Decision | Cash result | Dinner result |
| --- | --- | --- |
| Original 3 lb pack | $60 + $19.79 = $79.79. $0.21 remains. | Covers the 3 lb allocated across two dinners. |
| Buy three small packs | $60 + $21.87 = $81.87. $1.87 over. | Enough food, but $2.08 more than the original. |
| Accept one small pack | $60 + $7.29 = $67.29. $12.71 remains. | Short by 2 lb. Flag the affected dinners. |
| Confirm 1 lb in freezer first | Two small packs cost $14.58. Basket $74.58. | The confirmed 1 lb plus 2 lb purchased covers the need. Recheck that the freezer pack is unallocated. |

### A full week can still have four missing lunches

G2 replayed five Cincinnati recipes for four people, with 15 product lines, 17 packs and $37.29 of historical shelf prices. The published recipes claimed 30 servings. The replay removed every possible single line and pair of lines, then tried different household permissions. The denominator is simulated combinations.

| Household permission | One missing line · 15 cases | Two missing lines · 105 cases |
| --- | --- | --- |
| Keep each of the five original recipes once | 0 / 15 | 0 / 105 |
| Permit one repeat of each available dish | 12 / 15 | 25 / 105 |
| Allow repeats and protect four enchilada lunch portions | 7 / 15 | 5 / 105 |

One pinto can was for chili and two for enchiladas. With one can delivered, repeating dinners could fill the calendar while losing four promised lunches. Keeping two cans for enchiladas can work if the household approves an alternate chili. Moving a dinner is useful only when the newly empty night is accounted for. In a separate audit of the five menu cards and 21 related cards, 23 comparable pages yielded 56 observations and 37 distinct tuples. A 20 oz pack appeared to yield 4,176 g of same-form leftovers. Suppress that carryover and revisit every meal that depended on it.

### One shared dinner with different plates

G3 modeled a ¾-cup bean entrée, three ¼-cup sides and a reserved ¾-cup lunch. Other purchases cost $78.75. The shopper confirms a 1½-cup usable yield per $1 can. A different side is an explicit meal choice. Confirming a smaller yield changes coverage even when the price looks favorable.

| Plan for the same table | What the shopper sees |
| --- | --- |
| Tonight only | 1½ cups require one can. Checkout is $79.75. |
| Keep all sides and reserve lunch | 2¼ cups require two cans. The $80 trip is 75 cents over. |
| Keep the entrée and lunch. Three diners approve a different side already covered in the basket. | 1½ cups require one can. All four still have an accepted dinner and lunch stays reserved. Checkout is $79.75. |
| The actual can yields only one cup | Even with the alternate side, the entrée and lunch need 1½ cups. One can falls short. Check an allowed source or show the missed commitment. |

A known two-hour marinade also changes feasibility. With 45 minutes before dinner, ask how much of the step has already been completed. Carry the result into the cook's instruction.

### One price ceiling shared by two substitutions

G4 took three itemized Hannaford lines totaling $15.47 and imposed an illustrative combined limit of $27.97. The customer had not reported such a cap. After apples changed to $4.99, eggs and apples used $7.98. The beef ceiling became $19.99. At $6.49/lb, 3.08 lb is the largest hundredth-pound pack within the ceiling under the fixture's rounding. The invoiced 3.18 lb cost $20.64. That weight was reportedly unavailable at approval time. A proposal at that point needs either a weight bound or a question. Copying the scoped note must leave the offer pending.

| Choice in the working basket | Three-line total | Decision under the example limit |
| --- | --- | --- |
| Requested beef, eggs and apples | $15.47 | Starts with $12.50 of room. |
| Change only the apples | $16.47 | Uses $1.00 of room. |
| Change only the beef | $27.62 | Fits by 35¢ if the apple price stays unchanged. |
| Accept both changes | $28.62 | Exceeds the combined limit by 65¢. |

### What a family can safely reuse

G5 exercised a saved three-dinner rotation with requirements and substitute choices attached to each dish. Store this week's known stock and offer separately from those saved choices. These are observed prototype outcomes.

| Change presented | Observed prototype behavior |
| --- | --- |
| Two cans at $1.21 each | Rejects the offer above the $1.20 ceiling and marks the replacement unresolved. The warning survives reopening. |
| Only one substitute can at $1.10 | With numeric stock entered, reports a one-can shortage. With zero original cans and a keep-original soup rule, it flags the missing soup can. |
| Exactly $1.20 and enough stock | Accepts the taco alternative after confirmation. Reopening the active shop retains the choice. Finishing and starting a new shop clears this week’s price and restores the original list. |
| Undo after recording one original can | The usual list returns to three pinto cans and shows a two-can shortfall against the known stock. Undo cannot make those cans appear. |
| Two dinners explicitly allow the same alternative | A staged change flags the remaining shortfall. With three black cans available and separate approvals for both dinners, the final list pools the three cans without double counting. |
| Only one dinner repeats this week | Selecting tacos alone lists two pinto cans and eight tortillas. The next usual shop still contains all three dinners. |

G6 carried this into the urgent repair path. A whole basket of $83.42 can be affordable and still contain two $1.21 cans above the family's $1.20 per-can ceiling. One original pinto for soup and one black can for tacos can cost $82.10 while tacos are still one can short. If removing taco night reduces demand from twelve tortillas to four, one twelve-pack is still required. A plan that reduces demand from sixteen to eight saves one pack before checkout. After pickup, inspect remaining usable food before offering it to another meal.

### Ask only the questions that could change the decision

G7 enumerated eight possible pantry states at four dinner caps for the $37.29 basket. Garlic powder, corn and beans could replace bought packs worth $2.49, $1 and $1 only when the family confirmed amount, availability and dish suitability. Each state was equally weighted for the exercise.

| Dinner cap | States that can meet it | Questions on average / most | What the shopper learns |
| --- | --- | --- | --- |
| $37.29 | 8 of 8 | 0 / 0 | Already inside the cap. Do not ask about pantry alternatives unless the family asks to spend less. |
| $35.00 | 4 of 8 | 1 / 1 | Ask about the garlic powder. Yes: $34.80. No: even removing the other two packs gives $35.29. |
| $33.00 | 1 of 8 | 1.75 / 3 | All three changes are needed. Stop on the first no. If all three are yes, $32.80 fits. |
| $32.00 | 0 of 8 | 0 / 0 | Even the best of these three combinations is $32.80. Say the plan needs a different change. Do not claim the family has the ingredients. |

A fixed ordering with an early stop matched the best branching tree on these cases. A shopper explicitly seeking the cheapest attainable basket needs all three answers. An unanswered question stays unknown.

### When a smaller basket costs more

G8 used the same groceries with a modeled pre-checkout pickup fee of $4.95 below $35 in eligible goods. The illustrative amounts assume all unchanged goods qualify and every other charge is known.

| Available change in the same five dinners | Groceries | Modeled pickup fee | Estimated checkout |
| --- | --- | --- | --- |
| Keep the original basket | $37.29 | $0 | $37.29 |
| Use garlic powder from home | $34.80 | $4.95 | $39.75 |
| Use corn and beans from home, keep the garlic | $35.29 | $0 | $35.29 |
| Use all three from home | $32.80 | $4.95 | $37.75 |

At a $35 whole-order cap, none of the eight pantry states can fit under these terms with no other items. A merchandise-only comparison falsely passed four. With an already-needed eligible 20¢ item, $34.80 becomes exactly $35.00 without a fee. With a 19¢ item it becomes $39.94 including the fee. The full replay has 192 conditions across two fee settings, four other-item amounts, three caps and eight pantry states. Preserve the order-time fee basis when a retailer short-fills after submission.

### Deferring one chosen item

G9 modeled $34.80 of protected groceries, $4.60 coffee and $1.50 salsa against a $38 whole-pickup cap. The family said either extra could wait. The example uses the same $35 fee threshold.

| Shopper’s choice | Groceries | Pickup fee | Expected checkout | Against $38 |
| --- | --- | --- | --- | --- |
| Keep both extras | $40.90 | $0 | $40.90 | $2.90 over |
| Put off salsa | $39.40 | $0 | $39.40 | $1.40 over |
| Put off coffee | $36.30 | $0 | $36.30 | $1.70 left |
| Put off both | $34.80 | $4.95 | $39.75 | $1.75 over |

The coffee remains an outstanding need. Keep its original wording and purpose, ask before adding it next time, and price it afresh. Deferral shifts when money may be spent.

### Pairing two dinners and adding one guest

The G11–G12 return visit asks whether pasta and fajitas can share the third pepper in a three-pack. Compare complete baskets with the same dinner and lunch commitments. Known ingredients already on hand have a confirmed use. These are alternatives within one worked example.

| Version of the same shop | Groceries and fee | What Mia should see |
| --- | --- | --- |
| A · Pasta draft plus staples and $1 water. Wednesday has four confirmed freezer portions. Two lunches use bread and filling already at home. | $33.40 + $4.95 = $38.35 | 35¢ over. Four Wednesday dinners and two packed lunches are covered by the family’s accepted fallback. |
| B · Add fajitas and one eight-wrap pack | $35.80 + $0 = $35.80 | Six wraps for Wednesday, two for the same lunches with Mia’s agreement. The freezer meal remains at home. Groceries rise $2.40 and expected checkout falls $2.55. |
| C · Add a guest to B | $38.20 + $0 = $38.20 | Ten wraps required, hence two eight-packs. 20¢ over. Six wrap units could remain if 16 actually arrive and ten are used. |
| D · Defer water in C | $37.20 + $0 = $37.20 | 80¢ left. The correction relative to B is one extra wrap pack, deferred water and $1.40 more expected at checkout. |

If both versions already needed the wrap pack for lunch, each is $35.80 and the incremental checkout is $0. If A's pickup fee was waived instead, B adds $2.40. An uncovered $1.10 bean can makes B $36.90. An unknown bean price leaves that comparison unresolved. After Apply, the next preview starts from the accepted revision.

### Four different answers to the same cereal request

| What Mia knows | Proposed screen | Decision |
| --- | --- | --- |
| One new $3.49 box, all other terms unchanged | $37.20 before → $40.69 with cereal. $2.69 above a $38 cap. Show price basis, store, mode and time. | Save for next shop, adjust another flexible item, or explicitly accept this over-budget plan. Reviewing a suggestion never purchases anything. |
| An identical box is already planned | Ask whether the existing box covers Sam’s request or whether the family needs a second box. If one covers both, the added checkout cost is $0. | Link both purposes to the one line. Preserve individual requester attribution. Two people typing “cereal” does not establish quantity two. |
| Adding the box removes a pickup fee | Separate example. $34.80 of goods plus $4.95 fee is $39.75. With cereal, $38.29 of goods and no fee is $38.29. Checkout falls $1.46 and is still 29¢ over the cap. | Show the lower total and the remaining overage together. Recheck the same store and slot when the counterfactual is uncertain. |
| The price, package, fee or full basket is unknown | Show “Price needed to check the $38 limit,” or an explicitly bounded estimate with the missing fact. | Mia may enter the missing fact, keep it pending, save it for later, or accept a clearly unpriced planning line. Never label it under budget. |

An authorized shopper's acceptance affects the planned basket. Receipt by the server, acceptance into a draft, reported placement and confirmed purchase are separately recorded outcomes. One helper or child cannot infer a budget gap from a hidden field or a status message.

<a id="people"></a>

## What the shopper evidence actually showed

The studies used public reviews, public order accounts, competitor documentation, instrumented prototypes and simulations. The family examples use fictional people. A repeated review ID, a second comment in the same order or another run of the same script is not another household. No round established paid demand, household preference or a causal reduction in spending.

| Evidence collection | What survived into the product |
|---|---|
| G1 screened 1,301 distinct US-store written reviews and 28 videos from 24 channels with 134 comments. A contextual search found 24 replacement mentions among 1,000 Kroger/Walmart reviews, including two about higher cost and two about quantity. | Compare the decision before the shopper's deadline with the capable native retailer workflow. Review frequency cannot establish order incidence. |
| G2–G3 checked recipe cards, historical baskets, multiple plate needs and prior approvals. | Preserve the source line, physical yield, repeat permission, dish-specific constraints and protected lunches. Retain actual ordered quantities separately. |
| G4 reconstructed four public shopping accounts and matched portions of those accounts against working tools. | Preserve what was known when a decision was made. A later receipt does not reveal what the shopper could have chosen earlier. |
| G5 compared two successive food diaries. Only one of the prior week's dinners appeared among six documented evenings the following week, on a different day. One later dish repeated within its own week. Friday was undocumented. | Let people choose familiar dinners individually and assign dates later. Do not assume weekly rotation from one repeated dish. |
| G6 read five groups of 50 reviews. At least seven Mise reviewers disputed prices, 13 AnyList reviewers described sharing favorably, and nine Cooklist reviewers reported sync or connection problems. One shopper reported a $9 estimate becoming $28.57. Another stayed within a $115 budget at $98. | Uneventful, successful incumbent workflows belong in the comparison. Seek the item's source and time before displaying a precise budget result. |
| G7 examined 50 recent US written reviews each for OurGroceries, Paprika and Jow. A partner could identify an item from a photo, a quantity parser misread a food name, and a retailer sign-in interrupted a dinner plan. | Preserve selection and raw text, return to the same meal after app switching, offer a typed correction, and let a cook use an ordinary message. |
| G8 screened 500 retailer reviews and replayed checkout conditions. Families reported items disappearing from carts. A cropped or incomplete view cannot establish why an item vanished. | Keep the intended need, mark a discrepancy and ask whether it has already been handled. Show unverified when the evidence ends. |
| G9 reviewed 1,180 Google Play records and 478 top-level comments across 21 videos, selecting 19 reviews and ten comments. | Real families use Notes, retailer carts, messaging and mixed phones. Show branch, mode and deadline. Preserve user spelling and recipient language. Ask before creating an extra trip. |
| G10 examined 700 distinct review IDs across 11 apps, of which 594 were absent from the prior index. In 96 previously unindexed eMeals reviews, 22 mentioned Walmart. Twelve valued its integration, six described problems, three disliked prompts and one preferred separate ordering. | Bind a handoff to its source and destination. Preserve the dated dinner list through retailer switching, and make recovery and export usable after lapse. |
| G11 developed 20 screen contracts for the first shop and return visit. G12 checked 305 distinct shopper review IDs and corrected the comparison cases. | Source, branch, slot, whole packs, meal commitments and recipient-specific versions have to agree before comparing a revision. |
| G13 collected 450 distinct review IDs, 350 absent from the prior scan, and selected 22 cases. It also checked 68 opaque foreground/background color pairings. | Keep search anchored and checking distinct from inspection. Restore recently checked rows after Undo expires. The chosen light/dark buttons measured 8.30:1 and 9.48:1 in the token calculation. Rendered focus, overlays and Dynamic Type need device tests. |
| G14 selected 14 previously unindexed cases across seven apps. People described forcing a brand name through dictation, repeating Siri entry, small type and an unscrollable options window. | Keep the raw words beside the interpretation, correction by product, scrollable sheets, silent reading, accessible type and a backup comparison that preserves the newer revision. |
| G15 tested four checkout examples and 20 household routing scenarios against a reference model. | Exercise attribution, guardian scope, one-shopper authority, stale edits, duplicate requests, checkout cutoff, revocation and replay against real clients before release. |

### Four public order accounts

| Order and evidence | Observed result | What remains unknown |
| --- | --- | --- |
| Walmart dinner shop May 2026. Seventeen item prices, three planned dinners and a $30 dinner target. | The lines sum to $29.66. The shopper reports $30.26 after switching from canned to regular carrots. She describes making the meals and treats the 26¢ overrun as acceptable. | Final itemized receipt, individual price of replacement carrots, complete household grocery budget and specific pickup or delivery mode. |
| Hannaford January 2026. Customer account and itemized substitution rows. | Requested 1.25 lb at $6.79/lb. A 3.18 lb pack billed at $6.49/lb was $20.64. A dozen eggs stayed $2.99. A $3.99 apple bag became $4.99. | Beef package weight at approval was reportedly hidden. No declared cap, minimum beef weight, final whole order, refund or dinner outcome. |
| Instacart at Walmart January 2024. Customer messages and order summary. | The cook asked for 2 lb of stew meat and requested two small packs. The summary lists one replacement at about 1.16 lb. Estimated shortfall is 0.84 lb. | Actual billed weight, charge, rest of the basket and whether the stew was changed. The customer had already noticed the problem. |
| Walmart curbside July 2018. First-person pickup and acceptance account. | One 24 oz pickle jar became two 16 oz jars. The shopper welcomed the extra 8 oz at the same reported price. They accepted a change in chips as well. | Whole order, dinner requirements and receipt. Historical price handling is specific to this account. |

### What the existing tools could already do

| Free workflow | What we entered and observed | Result against Gen 4 |
| --- | --- | --- |
| FusionCore grocery calculator | Entered all 17 planned Walmart lines and $30 cap. It showed $29.66 and 34¢ left. Zeroing the carrot line showed $1.01 left. A $1.27 candidate produced $30.26, 26¢ over. | Tie on cash. $1.27 is inferred if other charges stayed fixed. Gen 4 labels the maximum directly and preserves the original line. No shopper was timed. |
| CartCraft live demo | Used sample Walmart, five diners and three nights. Its budget control bottomed out at $40. Generated screen showed $45 and a $79.06 menu. Swapping shrimp for the offered cold peanut noodles yielded $61.38. | Free wins at menu generation. Its list showed pack sizes, usage, surplus and shared ingredients. The two menus, stores and price dates differ. The $17.68 demo reduction is not savings on the historical order. |
| BudgetRaid web estimator | Set five people, three days, one meal, $30 and the lower-cost strategy. Some staples yielded $39–$50. Well stocked yielded $34–$45. Both flagged a tight budget. | Useful range. Its tool explicitly calls this an estimate. Gen 4 can price the exact pasted list. We did not test the native iPhone planner or infer an error from the difference. |
| CentsPerServing | Submitted the real stew requirement of 2 lb with the benchmark ZIP 45202. It matched one 2 lb Kroger beef-for-stew pack at $20. | Free wins at finding a pack. Different retailer, location and date from the Instacart order. Gen 4 checks an already-offered quantity and has no live catalog. |

### The cost of setup and return use

In G5, four workflows each performed two scenarios three times. All 24 instrumented runs reached the intended list. These counts are actions on the tested paths. Reading, composing the prepared note and deciding what to type were outside the automated timer.

| Tool | First-shop prep actions | Ordinary second shop | Changed second shop |
| --- | --- | --- | --- |
| Gen 5 | 22 | 1 action   /   0.33 s | 3 actions   /   0.61 s |
| LoschaZ | 31 | 1 action   /   3.77 s | 5 actions   /   4.85 s |
| UsefulVerse | 16 | 2 actions   /   0.71 s | 7 actions   /   1.31 s |
| Prepared free notes | 6 | 1 action   /   0.44 s | 1 action   /   0.43 s |

The technical result makes the human comparison more demanding. Time the work of both adults including initial setup, corrections and handoff. Keep a family that already succeeds with a prepared note in the study.

### Recurring problems to reproduce

The selected observations below connect specific accounts to a product decision. Counts across generations can overlap. Preserve the historical test condition and use the release register above for the current scope.

**G9 observations.**

| What someone actually reported | Planning consequence |
| --- | --- |
| A Bring reviewer said the app renamed an entry and the person doing the shopping bought the wrong product. An OurGroceries reviewer said a photo tells another person exactly what to buy and reported paying for ad removal after three years of free use. | Keep original wording visible. Offer one optional reference photo for a consequential match. Record whether it actually prevented a correction. P01, P13. |
| A Bring user initially thought “last chance to add” and “shopping complete” messages had disappeared, then updated the review after finding them. An AnyList reviewer valued adding an item while their spouse was at the store. | Make the latest action and whether additions are still useful easy to find. Test one person-initiated alert. The retailer owns the real cutoff. P04, P15. |
| One YouTube commenter’s household already manages well with a shared Notes checklist. Another said their mixed-device family had relied on AnyList for years. A third shared a list with their husband and had trouble sharing its tags. | Use the family’s best existing list as the comparison. Put the essential instruction in the message body so it survives a missing tag or app. Y01, Y03, Y04. |
| A curbside shopper once drove to the wrong branch. Another commenter valued curbside because walking was difficult. A Walmart reviewer encountered one cart split between pickup and delivery. | Show branch, fulfillment method and deadline where they affect the decision. Ask before proposing another trip. A store label can be more useful than a map. Y05, Y06, P17. |
| One Kroger reviewer described stockouts as minor. A Walmart reviewer liked the service and recommended turning substitutes off. In an older YouTube account, dairy-free creamer failed the shopper’s intended use for cheese. | A missing item earns attention when it matters to this meal or cash cap. Let native controls win where they suffice. A similarly named product can perform a different job in a recipe. P19, P16, Y08. |

**G10 observations.**

| Observed behavior | What it adds to the plan |
| --- | --- |
| An eMeals shopper saw an empty Walmart cart and could no longer see the list in eMeals. A Samsung Food shopper exports a list to Safeway and can identify which recipe needs each item. A10–11. | Freeze the sent list; keep the original, destination and affected meals. Give the family a way to compare and retry. If their current handoff works, ours must save another step or prevent a specific mistake. |
| A saved eMeals recipe appeared twice and later disappeared between shopping and cooking. A Crouton user said scaling a recipe with flour expressed in cups and grams changed only one quantity. A12–13. | Distinguish a second deliberate meal from a duplicate import, and preserve the copy used for this order. A second unit printed for the same ingredient is not a second demand. |
| Three Listonic users share a staples list and a separate list for a distant market. They reopen items when they run out. Another user keeps warehouse subtotals because online prices can differ. A14, A20. | A checked staple stays available without being automatically bought again. Store and shopping mode belong with the price. A distant-store list need not become a multi-store optimization feature. |
| A caregiver benefits from a typed shared list. A longtime Out of Milk shopper wanted darker, larger text and search. A couple compared screenshots when shared lists disagreed. A15–16, A19. | A searchable, readable, dated list that reopens offline is day-one functionality. Show when it was current. Do not require the helper to install anything or buy access. |
| A former eMeals payer wanted varied meals that share ingredients. A Samsung Food subscriber had trouble finding pantry-matched meals; a free SuperCook user already reported avoiding trips. A08–09, A18. | Offer one different familiar dinner for the unreserved remainder, with all additional purchases visible. Compare this directly with the family's usual backup. Recipe suggestions alone have a strong free substitute. |

**G12 observations.**

| Shopper account | Product decision |
| --- | --- |
| A Paprika reviewer described regularly texting recipe files to friends and building a week’s meals and shopping list. A Jow parent described selecting dinners, preserving leftovers for lunches and printing the recipes. | A helper should be able to act from an ordinary message or file. Keep “what to cook” and portions in the handoff even if they never join the household account. |
| A Sidekick subscriber liked the shared list and guided cooking but reported that canned lentils used as a shortcut were hard to get locally. Another described previously letting ingredients go unused and finding coordinated shopping easier. | Check that every additional ingredient and the promised prep time work for this household. An unfamiliar extra trip can wipe out the benefit of a pack pairing. |
| A MealPrepPro user described getting the week ready through meal selection and a shopping list. Another reported disliking the measurements and an unwanted annual charge after forgetting to cancel. | Reuse preparations the family trusts. Offer an explicitly nonbilling preview before asking to buy. Count an affirmative, kept purchase separately from an unwanted charge. |
| A Quickle reviewer valued an expected grocery price alongside a list and cooking instructions. A MealPot reviewer valued the menus when deciding what to cook felt like work. | Put the dinner name, effort and expected extra checkout on one card. A known family favorite stays a valid choice even when a suggested dinner costs slightly less. |

**G13 observations.**

| What shoppers reported | Change to the planner | Acceptance check |
| --- | --- | --- |
| Two Bring! 4.58.0 reviewers described different moments in the same problem. One described extra trips after accidental touches. Another liked finding removed items immediately below the list. | Put check and inspect on distinct targets. Keep Recently checked on the same list. | Restore once, even after leaving and reopening the app. |
| OurGroceries users missed hidden notes, saw checked and trashed duplicates, or had to chase search as lists changed length. Another valued seeing a spouse’s live checks. | Anchor search, show a note marker and keep checked, handled and deleted distinct. Label a local copy with its revision. | A query returns each active line once. A helper can tell the age of a copy. |
| A Bring! shopper liked the large icons. Another found the artwork hard to identify. A third wanted categories that fit their store. | Keep item names beside icons. Test a store-specific aisle order from the list as a later addition. | A shopper can find a named item with images disabled and recover their sort on return. |
| A Listonic reviewer reported repeated tracking requests. Another described accidental taps on a promoted banner. An OurGroceries reviewer objected to a rating interruption. | Keep active shopping, cooking and repair free of promotional prompts. Put optional feedback in Records or Settings. | Decline optional telemetry, reopen the shop and complete it without another request. |

**G14 observations.**

| Shopper experience | Product decision and verification |
| --- | --- |
| An AnyList shopper liked adding an item by Alexa while cooking. Another described losing the usefulness of that routine. A third reported that the V8 brand repeatedly became “v eight.” An OurGroceries user reported repeating Siri requests. | Keep the ordinary field available. Show destination and parsed fields together. Correct one name and preserve the other items. Test a second attempt and a wrong-list correction. |
| A Recipe Keeper user found built-in voice-to-text adequate for manual entry without paying. A Crouton reviewer valued both hands-free features and seeing ingredients at the current step. | Compare against free keyboard Dictation. Test one spoken household instruction with its available quantity. Include a nonvoice large-type card as a competitor to speech. |
| An Out of Milk user who added items almost daily found the font too small. A Crouton user reported an options window that would not scroll. | Test the longest labels, money and actions together at larger accessibility sizes. Complete the flow from the bottom of an oversized sheet. |
| A Pestle buyer reported duplicate and missing recipes after setting up family access. A longtime AnyList subscriber described losing access on a new phone. | Import the same family file twice and recover an older archive beside a newer shop. Show recovery source and ownership before any write. |
| A Pestle reviewer wanted to keep the recipe URL after an import failed. A Crouton user wanted a list in the family’s shared note. | Let a manual dinner retain its source link. Let Alex copy an app-free, dated note with the amount reserved and the current revision. |

<a id="market"></a>

## Competitive landscape and market evidence

Use the household's strongest available workflow as the comparison. A regular user of AnyList plus their retailer may finish a routine shop quickly. Paprika and Plan to Eat already let cooks scale meals and turn recipes into lists. OurGroceries and Apple Reminders serve mixed household routines, and a message can often settle a shortage. Test the specific point where a budget change affects a promised meal. Keep participants' existing subscriptions, saved lists and native substitution preferences available during comparison.

**Market observations.** The following are historical US iPhone estimates and publisher observations from the research captures. The reported revenue covers the competitor's whole offering. A modeled zero can reflect the platform's resolution. No row measures operating profit, all-channel sales, retention or a purchase of Room in the Cart.

| App and US iPhone ID | September downloads / revenue | What the planner must address |
| --- | --- | --- |
| AnyList · 522167641 | 13.9k / $30.3k | An incumbent offers family lists, recipe storage and meal planning. Its listed $14.99 household option sets a lower price benchmark for family organization. |
| Our Groceries · 325851015 | 0 / $3.85k | Its publisher emphasizes a shared list that updates across devices. Test whether a dated cook instruction is sufficient for the handoff job. |
| Plan to Eat · 1215348056 | 0 / $15.6k | A planned week produces a grocery list with scaling and leftovers. The observed iPhone one-year product was $54.99. Compare equivalent family tasks and distinguish website and store offers. |
| TapCook · 6769601354 | 94k / $134k | The nearest budget-meal comparator advertises $29.99 annually and explains that its estimated prices can differ at checkout. Put the whole retailer-matched checkout comparison in the pilot. |

In the G9 selected-period view, Cozi showed $458k estimated revenue across its family organizer and SuperCook showed $0 estimated revenue with 1.47k estimated downloads. Earlier work also recorded approximately $134k each for Mise and TapCook in the selected monthly view. Treat an uncertain match or a missing estimate as unknown. Subscription pricing and availability in these comparisons were observed at the time of the study.

### Speech and cooking specialists

| Competitor and historical evidence | Product or search observation | Implication for our test |
| --- | --- | --- |
| Voice Grocery List · 6783177978 · 279 reported terms | Historical #1 for “voice grocery list,” volume 5. Its publisher describes speaking a full list, recognizing quantities, sorting by aisle and sharing through a QR code. | Plain spoken entry and automatic grouping already exist. Compare preservation of the exact pack, lunch reservation and intended shop. |
| BuyVoice · 6505125372 · 33 terms | Historical #1 for “voice shopping list,” volume 5. Live Search used the title “Voice Shopping List” for the same ID. | Key the archive by Apple ID. Search captions and current profile titles can differ. |
| Two SHOPPPY listings · 1167480485 and 1482525447 | The reports contained 193 and 30 rows respectively. The first had historical #1 for “grocery list by voice.” The second had #2 for “voice grocery list.” | Keep separate listings even when the product names look alike. Test ordinary user phrasing without using an incumbent’s brand. |
| RecipeSky · 6802664516 and StepChef · 6757906313 | RecipeSky had three historical rows, including “hands free cooking” at #1. StepChef had 28, including the same term at #3. RecipeSky advertises narrated steps, timers and spoken navigation. | Prototype the short quantity instruction before a complete cooking assistant. A household can already get recipe narration elsewhere. |
| Nod Chef · 6799914033 · one term | Historical #2 for “hands free cooking,” volume 5. The publisher describes advancing by turning the head. | A busy cook may value avoiding touch without wanting to speak. Include a large silent card in the comparison. |

### Planner, retailer and household comparisons

The G12 atlas distinguished 87 evaluated products or workflows and eight additional research or identity checks. The 87 comprise 35 direct planners, 25 specialists, 13 retailer or marketplace workflows, seven household workarounds and seven adjacent or review-only comparisons. The entries below retain the observed behavior and source boundary of all 95. An app appearing in search only is weaker evidence than a tested workflow. Relevant screen numbers refer to this app's corresponding task.

#### Direct meal planners

| Comparison | Historical observation | Related screens | Evidence limits and source |
| --- | --- | --- | --- |
| AnyList / AnyList Complete | previously documented. Shared shopping supports household edits. Complete offers reusable templates and leftover planning. Help identifies recipe contributions and combining similar ingredients. | S04, S06, S12, S17, S19 | Historical listing or documentation. Current availability and outcomes at the selected store need testing. [Source 1](https://help.anylist.com/articles/add-recipe-ingredients-to-list/) |
| BudgetRaid iPhone planner | previously documented. Advertises whole-pack, pantry-aware plans and shared shopping lists. | S04, S06, S14 | Native app was not transaction-tested. [Source 1](https://apps.apple.com/us/app/id6799982107) · [Source 2](https://budgetraid.com/) |
| Bunlo | previously documented. Free offer describes seven dinners, household portions and additional breakfasts and lunches if money remains. | S03, S04, S14 | Historical listing or documentation. Current availability and outcomes at the selected store need testing. [Source 1](https://apps.apple.com/us/app/id6800858599) |
| CartCraft | previously exercised in a public web workflow. The sample demo swapped a dinner and showed a lower modeled basket plus package usage, surplus and shared ingredients. The documented planner deducts pantry and pools recipe demand. | S05, S14, S15 | Sample prices. The return visit and saved-week entitlement were not exercised. [Source 1](https://web.cartcraft.app/?demo) · [Source 2](https://www.cartcraft.app/how-prices-work) |
| Checked Out | previously documented. Vendor web/Google Play offer. Per-plate dinners, recurring alternates, variable servings and combined exact-quantity list. Used as accessible alternative; native iPhone availability unverified. | S04, S14, S16 | Listing or vendor scope. Actual acceptance by each diner and local cart cost were untested. [Source 1](https://www.checkedoutapp.com/) |
| Cooklist | previously documented. Connects loyalty purchases, pantry, cookable meals and missing-only lists. Historical reviews report both useful setup and connection failures. | S02, S04, S08, S09 | Historical listing or documentation. Current availability and outcomes at the selected store need testing. [Source 1](https://cooklist.com/cooklist-app) |
| Cozi Family Organizer | previously documented. Places meals on the family calendar and sends ingredients to a list. | S06, S14, S16 | Historical listing or documentation. Current availability and outcomes at the selected store need testing. [Source 1](https://www.cozi.com/meals-and-recipe-box/) |
| DinnerDrop | previously documented. The free plan advertises weekly dinners, a combined list, dinner swaps, favorites and history, pantry scanning, and handoff to Instacart or Walmart. Family adds voting and list additions by text, individual food preferences and a direct Kroger cart. The public example prices five four-serving dinners at an estimated $49. The publisher says its example uses typical US recipe costs. Final store prices and package sizes can differ. A separate store comparison feature is described on the home page. | S06, S12, S14, S19 | The published example is dinner groceries. It cannot verify whole-order cash after charges or what was in a particular pickup. The customer checks out with the store. [Source 1](https://www.dinnerdrop.app/) · [Source 2](https://www.dinnerdrop.app/help) · [Source 3](https://www.dinnerdrop.app/dinners/family-dinners-under-100) |
| dinnerkind | previously documented. Each paid family or two-adult plan includes a specifically named rescue dinner using the existing grocery list. The sample shows tomato and white bean Parmesan toasts. $9.99/mo or $79/yr after trial. | S09, S14 | Prescribed weekly plan. No public workflow shown to select the backup based on the exact missing SKU, available packs or remaining servings. [Source 1](https://dinnerkind.com/) |
| eMeals | historical shopper account. A family renewed for recipes and Walmart+ integration. Other shoppers reported failed transfer, duplicate saved recipes or losing access after lapse. | S02, S06, S17, S18, S20 | The account describes one workflow. Reproduce it on the household’s device before generalizing. [Source 1](https://apps.apple.com/us/app/id575756462) |
| Everyday Eats | previously documented. Advertises free Kroger-family availability, store prices, portion-covering pack sizes and one-tap substitutions based on recipe role before checkout. | S05, S07 | Publisher claims only. Both mobile platform download badges resolved to the landing page. Shipped mobile availability and data accuracy unverified. No example for a short-filled existing order affecting multiple dinners. [Source 1](https://everydayeats.app/) |
| Forks in Common | previously documented. US iPhone. Per-family-member diets, automatic bean/beef substitution, shared aisle list, pantry. No ratings overview displayed. | S04, S14, S16 | Listing or vendor scope. Actual acceptance by each diner and local cart cost were untested. [Source 1](https://apps.apple.com/us/app/forks-in-common-family-meals/id6752518389) |
| Grocery Fresh Chef | previously documented. Advertises local Kroger-family deals, meal swaps, itemized summary and cart transfer. | S05, S06, S14 | Historical listing or documentation. Current availability and outcomes at the selected store need testing. [Source 1](https://www.groceryfreshchef.com/) |
| Guarda | previously documented. Advertises store prices, swaps and recording actual spend. | S05, S08, S11 | Historical listing or documentation. Current availability and outcomes at the selected store need testing. [Source 1](https://apps.apple.com/us/app/id6787326288) · [Source 2](https://guardabudget.com/) |
| Jow | previously documented. Personalized, inventory-aware recipes and products flow into the linked grocer's cart; also shops personal recipes at needed quantities. A Gen 7 reviewer praised H-E-B pickup; another reported sign-in friction. | S06, S17 | Forward planning to checkout. Does not document a post-pick actual-package repair across committed meals. [Source 1](https://jow.com/pages/legal-information/how-does-it-work) · [Source 2](https://jow.com/help?question=how-do-i-order-my-personal-recipes) · [Source 3](https://jow.com/pages/lp/ditch-meal-kits) |
| LoschaZ Meal Planner | previously exercised in a public web workflow. Saved recipes, household size and a separate taco variant. Reopening the working template took one action for the normal list or five for the changed list. | S12, S14, S16 | The fast path reused the previous week. Creating a new dated week was a different trial. [Source 1](https://loschazgames.com/tools/meal-planner/) |
| MealBoard | previously documented. Aggregates meal-plan lists; users transfer purchased grocery items to the pantry after shopping. | S08, S12 | No demonstrated actual quantity-to-multiple-meal repair on cited page. [Source 1](https://mealboard.com/features.html) |
| MealHuddle | previously documented. November 2026 release notes specifically document moving a missed meal onto another day and pushing subsequent meals and leftovers forward, with undo. | S12, S14 | Move then choose push. The published behavior is date movement; the page does not demonstrate reallocating a shortage to protected dinners. [Source 1](https://mealhuddle.com/whats-new) |
| Mealime (historical standalone) | historical product and shopper account. A household used its week of dinners and grocery list after meal kits exceeded budget. Handoff and portability mattered to other reviewers. | S06, S10, S14, S20 | Historical listing or documentation. Current availability and outcomes at the selected store need testing. [Source 1](https://www.mealime.com/closing) |
| Mealpository | previously documented. Documents a Used in view for ingredients and keeps manual items when meals change. | S02, S04, S17 | Historical listing or documentation. Current availability and outcomes at the selected store need testing. [Source 1](https://mealpository.com/help/grocery-lists) |
| MealPrepPro | previously documented. Caters for different portions and planned lunches. | S04, S14, S16 | Historical listing or documentation. Current availability and outcomes at the selected store need testing. [Source 1](https://www.mealpreppro.com/) |
| Mise | previously documented. Plans personalized meals around a budget. Some sampled users met their cap while others disputed the estimated cost. | S03, S05, S14 | Historical listing or documentation. Current availability and outcomes at the selected store need testing. [Source 1](https://apps.apple.com/us/app/id6777471316) |
| Misu | previously documented. Describes retail-pack rounding, leftovers and first-shop staples versus later weeks. | S03, S12, S15 | Historical listing or documentation. Current availability and outcomes at the selected store need testing. [Source 1](https://apps.apple.com/us/app/id6809705188) |
| NeatEat | previously documented. Combines store and budget planning with fridge scanning. One reviewed household disputed an infeasible-budget result. | S03, S05, S09 | Historical listing or documentation. Current availability and outcomes at the selected store need testing. [Source 1](https://apps.apple.com/us/app/id6783742855) |
| NourishFix | previously documented. Describes planning with leftovers, pantry swaps and a plan a recipient can open without an account. | S09, S10, S15 | Historical listing or documentation. Current availability and outcomes at the selected store need testing. [Source 1](https://nourishfix.com/planner/help/) |
| Placeset | advertised or prelaunch. The US iPhone listing describes planning dinners against a grocery budget. Earlier web materials described menu rechecks and receipt true-up. | S03, S08, S11 | The former “coming soon” website is no longer sufficient evidence of availability. US listing verified, native performance untested. AppTweak returned no suggestions. [Source 1](https://apps.apple.com/us/app/placeset/id6795260019) · [Source 2](https://www.placeset.app/) |
| Plan to Eat | previously documented. Bulk reschedule and serving adjustment recalculate lists; moved meals preserve checked-off shopping items. Gen 10 also reports a paid shopper importing a Paprika library and documents recipe export after lapse. | S12, S14, S16, S20 | User selects recipes and new dates. No receipt reconciliation or bidirectional treatment of pack shortfalls shown. [Source 1](https://learn.plantoeat.com/help/bulk-edit-your-meal-plan-app) · [Source 2](https://www.plantoeat.com/pricing/) · [Source 3](https://learn.plantoeat.com/help/account-basics-faq) |
| Quickle | previously documented. The listing describes importing a recipe, matching ingredients to products at Walmart, Kroger, Target, H-E-B, Meijer or Food Lion, aggregating packs across meals, and updating the week’s total when a dinner changes. Recent release notes describe choosing cook nights, skipping foods the household excludes, scaling a repeated dinner for every scheduled day, and counting the prior night’s dinner as lunch. Other stores receive a shopping list. The developer lists Pro as necessary to unlock the week. | S04, S14, S15, S16 | The documented repricing follows a user-selected meal change before shopping. The accuracy of a local pack match and the result of an actual partial fill are untested. [Source 1](https://apps.apple.com/us/app/quickle-meal-plan-groceries/id6804241110) |
| RecipeSage | previously documented. Advertises shared plans, migration, offline access and recurring meals. A Copy Me That user reported switching to it. | S02, S12, S18, S20 | Historical listing or documentation. Current availability and outcomes at the selected store need testing. [Source 1](https://recipesage.com/) |
| Samsung Food | historical shopper account and public sign-in screen exercised. A shopper described changing meals, downloading a recipe-linked list, then uploading it at Safeway for pickup. A public web probe reached sign-in when starting a plan. | S02, S06, S14, S17 | Historical listing or documentation. Current availability and outcomes at the selected store need testing. [Source 1](https://samsungfood.com/meal-planner/) |
| Samsung Food+ | previously documented. Paid offer advertises prioritizing ingredients approaching expiry. A subscriber reported difficulty surfacing pantry matches. | S09, S15, S18 | Historical listing or documentation. Current availability and outcomes at the selected store need testing. [Source 1](https://samsungfood.com/food-plus/) |
| Sidekick | previously documented. Bundles three recipes sharing ingredients under one shopping list, offers ingredient search and scheduling. | S14, S15 | Recipes jointly planned for ingredient use. No exact shortage-to-servings evidence on the official page. [Source 1](https://help.sortedfood.com/hc/en-gb/articles/4638394094482-What-do-I-get-from-Sidekick) |
| Snack'd | previously documented. US iPhone. One base meal with multiple variations, texture and no-touch preferences, pantry and consolidated aisle shopping. Three ratings on listing. | S04, S14, S16 | Listing or vendor scope. Actual acceptance by each diner and local cart cost were untested. [Source 1](https://apps.apple.com/us/app/snackd-family-meal-planner/id6756082783) |
| TapCook | previously documented. Estimates a budget menu and combined grocery list using ingredient prices adjusted for region and chain. | S03, S05, S14 | Historical listing or documentation. Current availability and outcomes at the selected store need testing. [Source 1](https://apps.apple.com/us/app/id6769601354) |
| UsefulVerse Weekly Meal Planner | previously exercised in a public web workflow. Saved a week with a dish-specific rule and rebuilt a list. Ordinary and changed repeat visits took two and seven scripted actions. | S12, S14, S17 | Automation counts exclude human reading and composition. [Source 1](https://usefulverse.com/tools/weekly-meal-planner/) |

#### Shopping and cooking specialists

| Comparison | Historical observation | Related screens | Evidence limits and source |
| --- | --- | --- | --- |
| Bring! | historical shopper account. Shoppers described photo and urgency cues, shopping-started and shopping-finished messages, and trips shared across stores. | S10, S17 | The account describes one workflow. Reproduce it on the household’s device before generalizing. [Source 1](https://apps.apple.com/us/app/id580669177) |
| Brokie | previously documented. Budget countdown, planned grocery rebalancing when adding extras, and dropping meals. Product description, not independently measured price accuracy. | S03, S05, S14 | Historical listing claim only. [Source 1](https://apps.apple.com/us/app/brokie-budget-meal-planner/id6822410452) |
| BudgetRaid web estimator | previously exercised in a public web workflow. In Gen 4 the same household and budget produced different ranges for some staples versus a well-stocked pantry. Both flagged a tight budget. | S03, S05 | Scripted public web inputs, no completed order. [Source 1](https://budgetraid.com/meal-budget-calculator) |
| CartCue | previously documented. Whole and remaining cart estimates; no-install link sharing. Publisher explicitly distinguishes estimates from a checkout affected by fees, tax, promotions and stock. | S03, S05, S12 | Historical listing claim only. [Source 1](https://apps.apple.com/us/app/cartcue-grocery-list-estimate/id6789986522) |
| CartSorted | previously documented. Australian tool matches pooled quantities from multiple recipes to supermarket products and prices the week per shop by unit. | S05, S15 | US Apple listing verified. Earlier Australian supermarket evidence does not establish comparable prices or store support in a US pickup. [Source 1](https://apps.apple.com/us/app/meal-planner-by-cartsorted/id6776264828) · [Source 2](https://au.cartsorted.com/meal-planner) |
| CentsPerServing | previously exercised in a public web workflow. Matched a specified amount and ZIP to a pack. Its public weekly menu and recipe cards exposed pack, usage and remainder figures. | S04, S05, S15 | Published data are historical. One physically implausible remainder does not estimate the overall error rate. [Source 1](https://centsperserving.com/price) · [Source 2](https://centsperserving.com/r/usda-2-step-chicken) |
| Copy Me That | historical shopper account. One free user upgraded for recipe collecting, another moved to RecipeSage, and a third printed a collection after seeing limits. | S02, S18, S20 | The account describes one workflow. Reproduce it on the household’s device before generalizing. [Source 1](https://apps.apple.com/us/app/id956800243) |
| Crouton | historical shopper account. A shopper said scaling a flour quantity updated cups but left grams unchanged. | S02, S04, S16 | The account describes one workflow. Reproduce it on the household’s device before generalizing. [Source 1](https://apps.apple.com/us/app/id1461650987) |
| FreshFolio | previously documented. Receipt review can connect a bought product to the different one the shopper wanted. It stores the bought product with its own units and price. A later matching receipt asks the shopper to confirm a previously recorded pair. An already recorded replacement can clear the original checked item without adding stock again. The help describes a manual quantity check when receipt weight conflicts with the line price or when only package counts are available for stock tracked by weight. It documents recipe-specific product links and a stock check for an individual recipe, with distinct indications for insufficient or uncertain amounts. | S07, S08, S09 | This documented workflow starts with a receipt or bought item. An item confirmation records a purchase. Whether the family accepts that product in a particular dish, whether it suffices across several meals at once and what can still be changed before pickup require a separate test. [Source 1](https://freshfolio.illyriasolutions.com/help.html) |
| FusionCore Grocery Calculator | previously exercised in a public web workflow. Reproduced the published Walmart basket, remaining allowance and overage under edited carrot prices. | S03, S05, S07 | Public web arithmetic. No household was timed. [Source 1](https://www.fusioncoreapps.com/tools/grocery-calculator) |
| Grocery AI | previously documented. US App Store listing describes receipt import, inventory quantities, pantry-grounded recipes and meal cards showing availability. The post-pickup inventory idea by itself already exists. | S04, S08, S09 | Prior announcement or listing. No completed order was tested. [Source 1](https://apps.apple.com/us/app/grocery-ai/id1544118181) |
| GroceryBudget | previously documented. Budget alerts and moving items between carts. Premium lists recurring shopping and Family Sharing. | S03, S05, S12, S19 | Historical listing or documentation. Current availability and outcomes at the selected store need testing. [Source 1](https://apps.apple.com/us/app/id6749287517) · [Source 2](https://grocerybudget.app/pricing) |
| KitchenPal | previously documented. Allows adding all or only missing recipe ingredients from the meal planner to the shopping list. | S04, S09, S15 | Evidence is missing ingredients, not identifying how a short-filled item changes possible servings and spend across a submitted order. [Source 1](https://kitchenpalapp.com/en/faqs/planner.html) |
| Listonic | historical shopper account. Families reported recurring store-specific lists, archived lists with subtotals, and typed lists used by a caregiver. | S05, S10, S12 | The account describes one workflow. Reproduce it on the household’s device before generalizing. [Source 1](https://apps.apple.com/us/app/id331302745) |
| Mealisa | previously documented. Public worksheet-style guide covers actual order differences, affected meals, preserve/adapt/swap/postpone, portion calculations, final spend and refunds. | S07, S08, S09 | Manual substitute for the whole workflow. No automated solver shown on the cited page; the guide is not consumer demand or willingness-to-pay evidence. [Source 1](https://mealisa.com/meal-plans/repair-meal-plan-after-grocery-delivery-substitutions) |
| OurGroceries | historical shopper account. A household reported rapid iPhone/Android list sync. Another paid to remove ads after long free use and valued item photos. | S06, S10, S19 | The account describes one workflow. Reproduce it on the household’s device before generalizing. [Source 1](https://apps.apple.com/us/app/id325851015) |
| Out of Milk | historical shopper account. One shopper wanted more legible text. A couple compared screenshots when their lists disagreed. | S06, S10, S17 | The account describes one workflow. Reproduce it on the household’s device before generalizing. [Source 1](https://apps.apple.com/us/app/id564974992) |
| Pantry Snapper | previously documented. September and October iOS version history documents reservations across named meals, shortage warnings and one-tap shortage-to-shopping-list. US store showed $2.99 on public page. | S04, S09, S15 | The developer explicitly restricts inventory to user-entered unit counts, excluding grams and recipe servings. No published actual substitution price or order reconciliation. [Source 1](https://apps.apple.com/us/app/pantry-snapper-meal-planner/id6762132200) |
| Paprika Recipe Manager 3 | previously documented. Supports recipe export. One household brought a Paprika library into Plan to Eat and subscribed. | S02, S14, S20 | Historical listing or documentation. Current availability and outcomes at the selected store need testing. [Source 1](https://www.paprikaapp.com/help/ios) |
| Pestle | historical shopper account. A lifetime buyer reported receiving a refund after the recipe import they wanted failed. | S02, S18, S20 | The account describes one workflow. Reproduce it on the household’s device before generalizing. [Source 1](https://apps.apple.com/us/app/id1574776971) |
| Recipe Keeper | previously documented. Offers printable PDF cookbooks. | S02, S20 | Historical listing or documentation. Current availability and outcomes at the selected store need testing. [Source 1](https://www.recipekeeperonline.com/) |
| spuun | advertised or prelaunch. Early-access page described whole-basket swap savings, undo and household needs. | S05, S07, S17 | Historical listing or documentation. Current availability and outcomes at the selected store need testing. [Source 1](https://spuun.app/) |
| SuperCook | previously documented. Finds recipes from available ingredients. One user reported avoiding trips without quantifying the savings. | S04, S09, S15 | Historical listing or documentation. Current availability and outcomes at the selected store need testing. [Source 1](https://apps.apple.com/us/app/id1477747816) |
| The Pantry | previously documented. Paste confirmation text or upload a receipt and match purchased items to general ingredients so recipes still match. | S02, S08 | Removing receipt retyping is existing functionality. Confirmation describes what was ordered, not necessarily what was delivered; cross-plan constrained repair not demonstrated. [Source 1](https://thepantry.app/support) |
| Total Plus | historical shopper account. Reviewers valued a running total and tax visibility. A shopper requested a countdown starting from a fixed cap. | S03, S05 | The account describes one workflow. Reproduce it on the household’s device before generalizing. [Source 1](https://apps.apple.com/us/app/id914553629) |

#### Retailer and marketplace workflows

| Comparison | Historical observation | Related screens | Evidence limits and source |
| --- | --- | --- | --- |
| Albertsons Companies Meals Hub | previously documented. The Mealime closure notice directs users to its former recipes in Meals Hub in participating banner apps. | S02, S06, S14, S20 | Historical listing or documentation. Current availability and outcomes at the selected store need testing. [Source 1](https://www.mealime.com/closing) |
| Hannaford To Go | previously documented. 2025 relaunch announcement confirms selecting substitutes while shopping. Approve/decline through app or website before pickup or delivery. | S05, S07, S08 | Earlier help describes checkout notes but predates platform replacement. Current per-item note availability, replacement quantity controls, offer weight, exact decision deadline, handling of silence and refund timing not established from this announcement. [Source 1](https://www.linkedin.com/posts/hannafordsupermarkets_allforgood-activity-7389658170773897216-3Dsj) |
| Instacart | previously documented. Cart total/quantity adjustments; add item instructions and choose up to three backup items, best match or refund. Replacement preference carries to future orders; editing preference can clear a previous shopper note. Can track changes and communicate with shopper while shopping. Notifications signal replacements/refunds when enabled; shopper can still suggest an item if refund was requested. No universal minute deadline established. | S05, S07, S08 | A customer can put a calculated range in a shopper note, but the reviewed customer instructions do not describe enforcing it, computing a meal floor, or showing actual weight on every offer. [Source 1](https://www.instacart.com/help/section/360007902831/360039162252/995469%40) · [Source 2](https://www.instacart.com/help/section/odpar8/360039163432) · [Source 3](https://www.instacart.com/help/section/360007902851/360039571331) · [Source 4](https://www.instacart.com/terms?locale=en_US) · [Source 5](https://www.instacart.com/help/section/3252458959) · [Source 6](https://www.instacart.com/help/section/2893565984/2072641700) · [Source 7](https://www.instacart.com/help/section/3600079028331/360039162252) · [Source 8](https://docs.instacart.com/storefront/releases/2026/R08/2026_08_0_release_notes) |
| Instacart family cart | previously documented. Instacart Marketplace help describes shared pickup/delivery carts, all members receiving updates, and replacement/edit/chat control by the person who checked out. Separately, Storefront docs updated October 14, 2026 describe an opt-in control that lets other household members change items, approve replacements, chat, and view order status/receipt while payment details stay private. Do not generalize one surface's permissions to all retailers. | S02, S06, S17 | Check specific account, storefront and permissions before relying on handoff or sharing. [Source 1](https://www.instacart.com/help/section/4179348463) · [Source 2](https://docs.instacart.com/storefront/accounts/family_accounts/) · [Source 3](https://www.target.com/help/articles/delivery-options/drive-up-order-pickup) |
| Kroger AI Shopping Assistant | previously documented. Available across Kroger family apps/sites as of July 28. Creates a week of meals and a cart around dietary needs and budget. Existing retailer order controls and purchase history make native Kroger the primary comparison. | S03, S05, S06 | Prior announcement or listing. No completed order was tested. [Source 1](https://ir.kroger.com/news/news-details/2026/Kroger-Helps-Families-Simplify-Back-to-Routine-Season-with-Fresh-Convenient-Meals-and-a-Smarter-Way-to-Shop/default.aspx) |
| Kroger pickup | previously documented. Accepted replacements billed at substituted price. Fees, taxes, coupons, variable weights and weekly price changes may change the actual bill. Partial original quantities can arrive with replacement products. May refuse the substitute at curb before loading. Next-day order edits until prior midnight, same-day edits lock at submission per FAQ; cancel/reorder can lose slot. | S05, S07, S08, S11 | Historical listing or documentation. Current availability and outcomes at the selected store need testing. [Source 1](https://www.kroger.com/i/terms/pickup-and-delivery) · [Source 2](https://www.kroger.com/hc/help/faqs/ways-to-shop/pickup) |
| Meijer list and cart | historical shopper account. Reviewers distinguished the former list from purchase history and the cart. One missed custom notes and reported that unavailable items could not stay in their cart. | S01, S02, S06, S12 | The accounts described an app update. Current support and an end-to-end pickup were not verified. [Source 1](https://apps.apple.com/us/app/id583093664?see-all=reviews&platform=iphone&reviewId=14714555984) |
| Safeway / Albertsons list import | previously documented. Safeway's own guide offers matching against a typed or uploaded grocery list on the web. Albertsons' launch describes typed lists or images of written lists across banner websites. Keep the shopper in their normal account to review matches and checkout. | S02, S06, S17 | Check specific account, storefront and permissions before relying on handoff or sharing. [Source 1](https://www.safeway.com/shopping-guides/services-and-information/safeway/ai-shopping-assistant-now-available-in-safeway-app-mt2fp3) · [Source 2](https://www.albertsonsmediacollective.com/pr-details/2025/Albertsons-Companies-Accelerates-Digital-Transformation-with-the-Albertsons-AI-Shopping-Assistant-Redefining-the-Grocery-Shopping-Experience/default.aspx) |
| Sam's Club curbside pickup | previously documented. For certain weighted items, members select quantity and see a maximum authorized item price. Retailer promises the final item price will not exceed it. Actual quantity/weight determines final charge. | S05, S07, S08 | Retailer-generated upper bound for ordered item. No evidence here for customer-configured maximum, substitution-specific band, or a meal-derived minimum. [Source 1](https://help.samsclub.com/app/answers/detail/a_id/4075/kw/club) |
| Target Drive Up / Order Pickup | previously documented. Offers preferred replacements and review before pickup. Gen 6 found that the preference can carry forward on reorder. | S07, S08, S12 | Historical listing or documentation. Current availability and outcomes at the selected store need testing. [Source 1](https://www.target.com/help/articles/delivery-options/drive-up-order-pickup) |
| Target Lists | previously documented. A separate list records needed and purchased quantities. Target documents that an unavailable item can disappear from the cart before checkout. | S01, S02, S04, S06 | Historical listing or documentation. Current availability and outcomes at the selected store need testing. [Source 1](https://www.target.com/help/articles/registries-lists/targetlists) · [Source 2](https://www.target.com/help/articles/product-support-services/product-availability) |
| Walmart pickup | previously documented. Select a preferred substitute or prevent substitution per item at checkout. Email offers a limited accept/refuse period; silence permits substitution. Customer can decline with associate at pickup, or return through purchase history. | S05, S07, S08 | No universal minute limit, actual pack weight shown on every offer, structured household price/weight ceiling or explicit free-text per-item note in cited substitution help. [Source 1](https://www.walmart.com/help/article/Substitutions-for-Store-Pickup-and-Delivery-Items/c8dd3973509b42488da66a362af4666d) · [Source 2](https://www.walmart.com/help/article/pickup-and-delivery-changes-and-exceptions/97461ebd27b04ab78cfa1ca3de480a83) |
| Walmart Sparky | previously documented. October 30 US release demonstrates menu planning for 15 on $125 with two vegetarians and healthier cart/recipe replacements. No explicit rule in this material combining substitute quantity coverage and a total basket ceiling during fulfillment. | S03, S14, S16 | Prior announcement or listing. No completed order was tested. [Source 1](https://corporate.walmart.com/news/2026/10/sparky-shopping-assistant-expansion) |

#### Household workarounds

| Comparison | Historical observation | Related screens | Evidence limits and source |
| --- | --- | --- | --- |
| Apple Notes shared checklist | historical shopper account. A household reported a shared Notes checklist grouped by section, with prompts underneath. | S06, S10, S17 | Single account or proposed household baseline. No matched outcome against the planner. [Source 1](https://www.youtube.com/watch?v=Z9Jd1-vmo_I&lc=UgwOQqxl5E796rIOx6V4AaABAg) |
| Apple Reminders grocery list | previously documented. Supports grocery categorization and shared lists. Gen 9 noted multilingual categorization. | S02, S06, S10 | Historical listing or documentation. Current availability and outcomes at the selected store need testing. [Source 1](https://support.apple.com/guide/iphone/share-and-collaborate-iph2a8f9121e/ios) · [Source 2](https://support.apple.com/en-us/120616) |
| Paper list or text plus native checkout | proposed comparator. Prior plans used the family’s ordinary list or text plus the retailer preview as the free comparison. | S03, S05, S06, S07, S10 | Single account or proposed household baseline. No matched outcome against the planner. [Source 1](https://www.kroger.com/hc/help/faqs/ways-to-shop/pickup) |
| Prepared conditional lists in DO101 Notes | previously exercised in a public web workflow. Two prewritten complete lists let the operator use the regular or changed list in one action after reopening. | S10, S12, S17 | Browser-script timing excluded composing the notes and deciding which version was appropriate. [Source 1](https://www.do101.online/tools/notes) |
| Printed recipe collection | historical shopper account. A Copy Me That user reported printing about 200 recipes after a notice about limits. | S14, S20 | Single account or proposed household baseline. No matched outcome against the planner. [Source 1](https://itunes.apple.com/us/rss/customerreviews/page=1/id=956800243/sortby=mostrecent/json) |
| Screenshots shared between shoppers | historical shopper account. An Out of Milk household compared screenshots when list states differed. | S10, S17 | Single account or proposed household baseline. No matched outcome against the planner. [Source 1](https://itunes.apple.com/us/rss/customerreviews/page=1/id=564974992/sortby=mostrecent/json) |
| Usual pantry or freezer backup dinner | proposed comparator. A family may already know an acceptable fallback without opening a planner. Gen 9 proposes its fastest usual backup as the comparison. | S04, S09, S15 | Single account or proposed household baseline. No matched outcome against the planner. [Source 1](https://www.epa.gov/recycle/preventing-wasted-food-home) |

#### Adjacent and review-only comparisons

| Comparison | Historical observation | Related screens | Evidence limits and source |
| --- | --- | --- | --- |
| 2 Week Meal Rotation | listing linked; ranking observed. Gen 10 linked this named specialist when assessing search intent for meal rotation. A saved-week or shopping transaction was not exercised. | S12, S13, S14 | Evidence here is limited to a named specialist and its search context. [Source 1](https://apps.apple.com/us/app/2-week-meal-rotation/id6757933969) |
| A Better Meal | historical review only. A selected reviewer credited it with making meals easier with picky toddlers. | S04, S14 | No documented end-to-end pickup or matched product test in this source. [Source 1](https://apps.apple.com/us/app/id6443470543) |
| BLW Meals | historical review only. Named by a Kids Meals reviewer as the app used when the child was younger. | S04, S14 | No documented end-to-end pickup or matched product test in this source. [Source 1](https://itunes.apple.com/us/rss/customerreviews/page=1/id=1613090960/sortby=mostrecent/json) |
| Kids Meals | historical review only. A reviewer described using the recipes after their child outgrew the BLW Meals stage. | S04, S14 | No documented end-to-end pickup or matched product test in this source. [Source 1](https://apps.apple.com/us/app/id1613090960) |
| Meal-kit subscription (unnamed) | historical shopper account. One former meal-kit household described using Mealime for dinners and a list after the kit exceeded its budget. | S03, S13, S14 | The selected account does not identify the service or quantify savings. Archived Play feed record P10. Its individual storefront link returned 404 in Gen 9. [Source 1](https://play.google.com/store/apps/details?id=com.mealime&reviewId=e0998e06-3926-4010-acb3-b52f3caba539&hl=en&gl=US) |
| My Fussy Eater | screened only. The mixed-household research queried its review feed. No selected case or evaluated feature for this title. | S04, S14 | No documented end-to-end pickup or matched product test in this source. [Source 1](https://apps.apple.com/us/app/id1340469417) |
| Unit Price Comparison | screened only. Returned for unit-price intent. The archived adjacent-review check returned no entries. | S03, S05 | No documented end-to-end pickup or matched product test in this source. [Source 1](https://apps.apple.com/us/app/id1221859915) |

#### Additional research and identity checks

| Comparison | Historical observation | Related screens | Evidence limits and source |
| --- | --- | --- | --- |
| MealPot | Public web control exercised. The recipe page scales displayed grocery quantities. Its public planning guide distinguishes a physical pack from amounts reserved for another meal. | S04, S06, S16 | On the tested page the Walmart summary still described two servings after switching to four and six. Actual cart contents were not inspected. [Source 1](https://getmealpot.com/guides/reduce-food-waste-pack-sizes/) |
| Mittsy | Publisher documentation. The publisher describes locking selected nights, changing the rest and giving each line an estimated pack price. | S03, S04, S16 | Store-specific estimates and pantry photos require confirmation before a cash or coverage claim. [Source 1](https://mittsy.app/) |
| FeedMyBudget | Public catalogue exercised; development feature documented. Australian public search returned pack-specific results. The publisher separately describes an alpha ranking by estimated extra checkout cost accounting for committed ingredients. | S05, S13, S15 | Australian catalogue exercise only. The marginal-ranking feature is described as a development build. [Source 1](https://spuddles.dev/) |
| Kitchen Playbook | Publisher documentation. The current site, including the former misemade.com redirect, offers imports, Kroger cart building and household price rules. | S06, S07, S12 | Keep this identity separate from the TEGS Labs Mise iPhone listing. Cart acceptance and successful fulfillment were not tested. [Source 1](https://kitchenplaybook.app/) |
| Noms at hellonoms.com | Discovery lead. The indexed publisher description presents a family dinner plan with a grocery budget and priced shopping list. | S01, S03 | The direct page could not be independently reopened in this pass. No verified matching US binary. The Nano AI listing is a separate record. [Source 1](https://hellonoms.com/) |
| ReciMe | US listing verified. Its developer describes saving recipes from multiple sources and using them in meal plans and grocery lists. | S02, S14 | Import breadth does not establish correct pack pricing, fulfillment or a paid reason for this planner. [Source 1](https://apps.apple.com/us/app/recime-recipes-meal-planner/id1593779280) |
| Dinnerkind iPhone app by Knightmile | US listing verified. The developer describes matching groceries across different dinners, including reuse of opened ingredients within a planned interval. | S14, S15 | Different identity from the dinnerkind.com cook-four-times program. Retention and actual food waste are unknown. [Source 1](https://apps.apple.com/us/app/dinnerkind-meal-planner/id6821738955) |
| noms iPhone app by Nano AI | US listing verified. The developer describes generating a cookable recipe and list from available ingredients and preferences. | S09, S15 | Different identity from the hellonoms.com candidate. Generated portions and costs remain unverified. [Source 1](https://apps.apple.com/us/app/noms-ai-recipe-meal-plan/id6748933312) |

<a id="retailers"></a>

## Retailer access and the dated handoff

The launch route freezes a dated basket, lets the shopper copy or share it, and lets the shopper report placement after checking out with the retailer. A household-entered price remains available for the family's own records. Before using any provider's data, establish its permitted storage, comparison and retention terms independently. A retailer's own shopper tool, a publisher recipe widget and an authorized third-party cart API grant different rights.

The Gen 15 feasibility review was dated November 2, 2026. It checked published programs and documentation. No authenticated end-to-end cart or order was executed. Kroger offered the most specific single-store contract for a potential later trial, Safeway supplied a strong existing list-import comparison, and Walmart grocery access required a separate partner check. The evidence and trial criteria below describe the dated research.

### Which retailers qualify?

NRF's **2026 list ranks 2025 US retail sales across categories**. Walmart, Amazon, Costco, Kroger and Home Depot ranked first through fifth. Target ranked eighth, Albertsons tenth and Publix twelfth. That places Home Depot inside the research set even though dinner grocery shopping gives families little reason to connect it. [NRF 2026 Top 100](https://nrf.com/research-insights/top-retailers/top-100-retailers-2026-list)

Numerator's **share of US grocery food and beverage spending** over the 12 months ending September 30, 2026 gives a different top five. Walmart had 20.3%, Costco 8.4%, Kroger 8.2%, Albertsons 4.5% and Publix 4.1%. Amazon + Whole Foods had 3.9% and Target 2.1%. Numerator reports Sam's Club separately from Walmart. These percentages measure shopper spending and cannot be read as the share of households reachable through an API. [Numerator methodology and tracker](https://www.numerator.com/retail-market-share-tracking/) · [Underlying chart data](https://datawrapper.dwcdn.net/h2S2G/1/dataset.csv)

### What a family could actually do

| Retailer | Documented route and shopper benefit | Access boundary and practical fallback |
| --- | --- | --- |
| **Walmart** | The Online Pickup & Delivery partner flow can match grocery products for the shopper's store, return local price and availability, and send selected items to a Walmart cart for review. This could save search and re-entry for repeat purchases. | Requires an Impact account, access request and private partner-fit review. An affiliate product link carries fewer rights. Marketplace authorizes a seller's business data, and GoLocal delivers a business client's existing order. None of those grants household receipt or substitution access. Use a household list and open Walmart while partner rights remain unverified. [Grocery onboarding](https://www.walmart.io/docs/opd/stores-recipe/grocery-introduction) · [I/O terms](https://walmart.io/termsandcondition) · [Marketplace authorization](https://developer.walmart.com/us-marketplace/docs/authentication-authorization) · [GoLocal workflow](https://www.walmartgolocal.com/content/go-local/go-local-home/who-we-are/how-it-works.html) |
| **Amazon / Whole Foods** | Creators API offers affiliate product search, item details and variations. This could help a shopper identify a package and open its listing. Its listed operations provide no household grocery cart, checkout or receipt read. | Requires Associates eligibility, registration and credentials. Amazon specifies 10 qualifying sales in the preceding 30 days for the documented advertising API access. A mobile app requires approval, free access to Amazon links and compliance with its price-tracking restriction. Get Amazon's written agreement on a planner offering price history before combining those functions. Use a shopper-authored list and let the shopper choose their Amazon grocery destination. [Creators API](https://affiliate-program.amazon.com/creatorsapi/docs/en-us/introduction) · [Mobile policy](https://affiliate-program.amazon.com/help/node/topic/GHBY6W8UPTEFD3ZX) · [Operating policies](https://affiliate-program.amazon.com/help/operating/policies) |
| **Costco** | Members in eligible ZIP codes can shop Costco Same-Day, fulfilled by Instacart. This gives a family an actual delivery price for its selected grocery order. | Same-Day has its own cart and checkout, a $35 minimum and prices above warehouse prices. Nonmembers may shop Costco through Instacart on different terms. Ask which channel the family uses. A recipe vendor listing Costco via Instacart cannot establish transfer to a member's Costco Same-Day cart or warehouse stock. [Costco Same-Day FAQ](https://customerservice.costco.com/app/answers/answer_view/a_id/8150) · [Recipe vendor's supported channels](https://support.destini.co/hc/en-us/articles/16989446995351-Shoppable-Recipes-Add-to-Cart-Functionality-FAQs) |
| **Kroger** | Public Locations and Products can find a store and its product offers, including store-specific price and optional stock level. An authenticated shopper can explicitly add reviewed UPCs and quantities with `PUT /v1/cart/add`. This is the most specific public contract for a basket test. | Catalog reads use app credentials. Cart requires shopper OAuth and production testing. Daily caps are 10,000 for Products, 5,000 for Cart and 1,600 per Locations endpoint. Public Cart has only the add operation. Keep checkout and fill unconfirmed. Stop after an ambiguous timeout for shopper review. Use rules prohibit cross-retailer price comparison and storing search/add-derived history. Preserve household-authored lines separately. [Public endpoints](https://www.postman.com/kroger/the-kroger-co-s-public-workspace/documentation/ki6utqb/kroger-public-apis) · [Environment rules](https://developer.kroger.com/documentation/public/getting-started/apis) · [Acceptable use](https://developer.kroger.com/documentation/public/getting-started/acceptable-use) · [Official portal index and rate limits](https://developer.kroger.com/api/v1/developer/content/search.json) |
| **Home Depot** | Approved affiliate websites receive links and a daily feed for home-improvement purchases. Home Depot also offers business procurement integrations. | Pro Xtra integrations cover business purchasing, accounting and receipts. Neither route documents consumer grocery cart access. A family can carry an occasional household supply as a separate list line and buy it through its normal channel. No dedicated connection is justified by the retail-sales ranking alone. [Affiliate FAQ](https://www.homedepot.com/c/SF_MS_Affiliate_Program_FAQs) · [Pro integrations](https://www.homedepot.com/c/pro-integrations) |
| **Target** | Target Partners offers approved websites affiliate links through Impact. Target separately documents shopping in ChatGPT, Google and Microsoft experiences. Its ChatGPT app can build multi-item fresh-food baskets with Drive Up or Order Pickup. Destini documents a third-party recipe widget that attempts to send matched products to Target. | Named partnerships establish those surfaces' capabilities only. Destini requires a configured recipe and automated retailer feed. Non-shippable groceries may go to **Saved for later** until the shopper selects pickup or same-day and adds them. Confirm private-list eligibility, mobile use and actual chilled-item behavior before valuing a basket transfer. Otherwise copy the list and open Target for review. [Target Partners](https://partners.target.com/faqs) · [Target's named AI experiences](https://corporate.target.com/press/fact-sheet/2026/06/conversational-ai) · [Destini retailer behavior](https://support.destini.co/hc/en-us/articles/16989446995351-Shoppable-Recipes-Add-to-Cart-Functionality-FAQs) · [Widget deployment](https://support.destini.co/hc/en-us/articles/10550286436247-Going-live-with-Shoppable-Recipe-Widgets) |
| **Albertsons / Safeway** | A signed-in shopper can type or upload a list in Safeway's web assistant and review matches. Albertsons also supports user-initiated import of a web recipe. Chicory announced a direct shoppable-recipe integration with Albertsons and 15 banners. | Native recipe and list import provide a useful baseline immediately. Chicory's publisher network is commercial and recipe-focused. Confirm named banners, private dynamic-list rights and allowed mobile use before relying on it. Retain unmatched household needs for review. [Safeway list matching](https://www.safeway.com/shopping-guides/services-and-information/safeway/ai-shopping-assistant-now-available-in-safeway-app-mt2fp3) · [Albertsons recipe book](https://www.albertsons.com/personal-digital-shoppable-recipe-book.html) · [Chicory direct integration](https://chicory.co/blog-feed/chicory-builds-direct-integration-with-albertsons-to-enhance-online-shopping-experience-for-the-retailer) |
| **Publix** | The in-store list supports basic entry and printing without a Club Publix account. Publix separately offers delivery and curbside pickup powered by Instacart. Destini identifies Publix as a supported Instacart sub-banner for configured recipes. | An Instacart handoff can save product matching when the store is available. Confirm the destination and its prices. A Club Publix shopping list, a branded delivery cart and a Marketplace recipe link can represent different work. Retain the family's list and ask about dinner-critical exceptions at pickup. [Publix list FAQ](https://www.publix.com/faq/shopping-list) · [Publix delivery and pickup FAQ](https://www.publix.com/faq/instacart) · [Vendor route](https://support.destini.co/hc/en-us/articles/16989446995351-Shoppable-Recipes-Add-to-Cart-Functionality-FAQs) |

### Intermediaries and deeper access

- **Instacart Developer Platform.** An approved app creates a hosted recipe or shopping-list URL. The shopper reviews the available matches and checks out on Instacart. A recipe may suggest an available retailer with the appropriate nearby-retailer key. The US intake page currently says new applications are closed without a waitlist. Public links do not return verified prices, filled items, substitutions or receipts to the planner. IDP terms restrict cross-retailer priced displays and basket transfers. Connect fulfillment serves contracted retailer storefronts. A separate OAuth MCP shopping interface needs representative-provisioned access. [US intake and FAQ](https://company.instacart.com/business/developers) · [Shopping-list endpoint](https://docs.instacart.com/developer_platform_api/api/products/create_shopping_list_page) · [Preferred-retailer tutorial](https://docs.instacart.com/developer_platform_api/get_started/recipe) · [Developer terms](https://docs.instacart.com/developer_platform_api/guide/terms_and_policies/developer_terms/) · [Connect](https://docs.instacart.com/connect/) · [MCP access](https://docs.instacart.com/mcp_servers/get-started/use-instacarts-mcp-server)
- **Uber Eats.** Consumer Delivery documents merchant/item discovery, pricing, cart changes, order submission, tracking and past orders. This could support a shopper-authorized top-up where grocery coverage exists. Access and test credentials are granted case by case in early access. Verify store, mode, exact item, price, checkout and post-order fields under the proposed agreement. Merchant APIs and Uber Direct serve merchants and their deliveries. [Consumer Delivery](https://developer.uber.com/docs/consumer-delivery/introduction) · [Uber Eats merchant platform](https://developer.uber.com/docs/eats/introduction) · [Uber Direct](https://developer.uber.com/docs/deliveries/overview)
- **DoorDash.** Corporate MCP documentation includes grocery discovery, cart, checkout, status and receipts, but its private beta explicitly excludes consumer-facing integrations. DoorDash's shopping experience in ChatGPT is an existing named deployment. Marketplace and Drive serve merchants. A consumer planner can send the shopper to DoorDash for a separate order. Reconsider embedded functionality only if DoorDash offers production rights for this use case. [MCP eligibility](https://developer.doordash.com/en-US/docs/mcp/overview/about_mcp/) · [MCP operations](https://developer.doordash.com/en-US/docs/mcp/reference/available_tools/) · [ChatGPT partnership](https://about.doordash.com/en-us/news/openai) · [Marketplace access](https://developer.doordash.com/en-US/docs/marketplace/overview/getting_started/requesting_access/)

### What evidence would justify a connection?

1. **Without a commercial agreement**, observe the household's fastest existing route. Time a saved list or retailer-native import through correct products in the actual cart. Include store selection, quantities, produce weights, pack sizes and missing products. Copying or opening measures a handoff only.
2. **With documented production rights**, compare the new route against that same household's baseline at one store and mode. Measure both adults' active time, wrong packs, duplicates and dinner-critical misses. Exercise denial, expiry, stale prices, ambiguous writes and the shopper's ability to recover the original list. For Target, inspect the active pickup cart and Saved for later separately.
3. **Require independent evidence for every downstream claim.** A cart write, a placed order, an accepted substitution, a posted charge and a usable amount in the bag are different events. Stop the trial if production rights or required data uses cannot be confirmed, or if a safe retry or manual fallback fails. Ranking or partner marketing alone cannot establish a household benefit.

**Verification boundary.** Public first-party documentation, published program status and ranking data were reviewed. No accounts were created, credentials requested, retailers contacted, carts tested or purchases placed. The described benefits are hypotheses for a consented trial.

For any later trial, compare 12 households over two shops at the same store and mode. On the first trip, counterbalance matched baskets against each household's fastest existing method. Seek at least eight households saving 60 active seconds and zero silent duplicates or wrong critical items. On the second trip, seek six unprompted reuses. Count setup, corrections and partner time. A failed or ambiguous write must preserve the original list and offer a safe manual path. To import a list in release one, accept the text or content the shopper explicitly shares. A URL alone grants no access to a private cart.

<a id="economics"></a>

## Why a family might pay and what the business would require

The repeat purchase hypothesis is that one household can plan its ordinary week, preserve the right portions, and handle an occasional disruption with less combined work. Price testing must include the household that simply uses a saved note and retailer cart. Paying for another product and returning after a lapse are evidence about that competitor's bundle. Intent to pay, a trial start, an automatic charge, a kept purchase and an annual renewal are separate outcomes.

**Price and household value.** At a hypothetical $15 per household hour, $49.99 equals about 200 net minutes saved per year. That is 3.85 minutes per use at 52 eligible shops, 7.69 at 26, 8.33 at 24 or 15.38 at 13. If the family actually replaces a $14.99 subscription, the $35 difference requires 140 minutes. Replacing a $29.99 subscription requires 80 minutes for the $20 difference. Include setup and both adults' effort. Record extra trips, cash and meal coverage separately.

| Planning assumption | Implication under those assumptions |
|---|---|
| $49.99 billed annually, 15% platform fee, 3% refunds | About $41.22 expected proceeds per gross start. Keep a separate ledger for kept buyers so refunds are deducted once. |
| $6 annual variable service, $14 to acquire a replacement buyer, 35% renewal | At a mature steady population, 65% annual replacement gives roughly $26.12 contribution per active annual household after modeled replacement acquisition. This is a scenario, independent of the actual Apple agreement and costs. |
| $6,000 monthly fixed costs including $4,000 owner pay | Approximately 7,352 active annual households for $10,000 monthly operating profit after owner pay and before tax, or 11,947 for $20,000. At modeled renewal this needs about 398 or 647 replacement buyers every month. |
| Stress scenario of 28% renewal, $10 service and $22 acquisition | The same targets require about 12,487 or 20,291 active annual households. These figures describe sensitivity to inputs, not a sales forecast. |
| $30 per hour of staff time | $6 pays for 12 minutes a year before infrastructure. One minute of human help per week would cost $26 annually. Count support, consent, speech, sync and free-household load when measuring actual costs. |
| 886 modeled monthly impressions at continuous first position for “grocery budget” in the historical panel | Replacing 398–647 buyers from that one term alone would require roughly 45–73% of those hypothetical impressions to become buyers. The term is a positioning test, insufficient evidence for the acquisition plan. |

**Offer tests.** The approved product has one annual Household offer. Historical lower-price, one-shop and acquisition experiments are research designs. On equally costly qualified traffic, 20 kept $49.99 buyers produce about $729.83 before acquisition assuming a 15% fee and $6 annual service per kept buyer. Matching it takes 27 at $39.99 or 38 at $29.99. Compare contribution per qualified visitor, not conversion alone. The earlier $4.99 single-shop service was a contingency for infrequent use and has no launch SKU.

**Distribution experiments.** Compare a rights-cleared creator's menu with the same menu plus one locally priced pack check. A hypothetical $100 placement would need eight kept buyers to clear a $14 acquisition ceiling. Seven cost $14.29 each. No creator agreement was established. On identical traffic, randomize a completed sample against one personalized dinner check at the same price. At $0.70 per qualified visit and 200 visitors per arm, ten kept buyers on $140 would meet the target. Count everyone assigned, including people who leave before setup, and replicate the better arm with at least 20 kept buyers. Separate research recruitment, creator traffic, paid exact-match traffic and unattributable organic demand.

**Research score.** The latest carried business evidence rating was 6.6/10, with pilot priority 8/10. Inputs were buyer problem 9, comparable entrant sales 9, discovery 7, paid acquisition 5, competitive gap 3 and delivery/economics 5, weighted 20%, 20%, 15%, 15%, 15% and 15%. These were research judgments. The agreed build scope and the evidence needed for a viable business answer different questions.

<a id="studies"></a>

## Field tests, release checks and decision thresholds

Use separate populations and denominators for initial observation, exception handling, causal outcomes and purchases. Record both adults' active time plus contributor effort. A second phone opening the app cannot establish that a dinner was served or another household converted.

| Study | Enrollment and test | Decision rule |
|---|---|---|
| Consecutive pickup observation | Ten unrelated weekly-pickup households, one retailer and area, two consecutive planned shops per household. Include quiet weeks, mixed phones, a guardian-managed contributor and a cook using large text or readback where applicable. | At least two verified incremental decisions in different households justify a larger study. If the benefit appears only after pickup, test recovery as the primary job. Include failed, missing and same-as-usual outcomes. |
| Incidence and handling | Record 100 consecutive eligible orders after existing retailer preferences. Separately replay at least 30 actionable exceptions with only information available before the cutoff. | Fewer than ten actionable unresolved exceptions among the 100 disqualifies live repair as the lead promise. The enriched set of 30 measures how well a known exception is handled. |
| Household outcomes | Randomize 20 households at the household level, ten immediate and ten delayed for eight concurrent weeks, after locking the strongest applicable comparator. Keep normal shops in the denominator. | Seek at least 90% verified successful intervention weeks and a 15-percentage-point lift over comparison. Count missing verification as a miss. If baseline exceeds 85%, preregister a five-net-minute saving per weekly shop with no more than five points of coverage loss. Replicate before relying on the result. |
| Cold paid offer | In a separate cohort, offer a deliverable year at $49.99. Stop at 20 kept buyers, 400 qualified offers or $280 in fully loaded acquisition spend, whichever comes first. Include labor at replacement cost and channel costs. | Seek acquisition cost at or below $14 and at least 12 of the first 20 voluntarily using the product on three of their last four eligible shops by week eight. Observe refunds, service expense and eventual annual renewal. |
| Voice and readback | Twelve target shoppers, each trying two three-item scenarios. Rotate typed entry, keyboard Dictation, reviewed push-to-talk and the household's own voice list when used. Test background noise, bilingual names, large type, VoiceOver and silent cards. | Across 24 matched scenario pairs, require zero unreviewed writes, wrong-shop commits, silent unit changes or duplicates. Target at least 20% lower median time through a correct saved result than the person's faster typing/Dictation baseline, and at least baseline completion. Record failures, fallbacks and later voluntary use. |
| Screen and motion comparison | Counterbalance with at least eight target shoppers on ordinary entry, a capped request, a short-fill and a corrected cook handoff. Fix version, tier, starting state and device for each pair. | Seek at least seven of eight completing each critical task unassisted, zero false positive financial or meal conclusions, median ordinary entry time within 10% of the normal workflow, and six of eight preferring the exception flow. Test native hitches, focus, text growth and Reduce Motion separately. |

**Design research.** The chosen palette is spruce and linen. The earlier visual study compared it with indigo/mist and plum/porcelain using the same checkout layout. Its proposed blind test assigns the six possible presentation orders twice across 12 shoppers. Ask for the expected checkout, overage and protected food before asking about preference and trust. Also test accidental check, damaged pack, expired amendment and uncertain share destination. A preferred appearance still has to preserve task accuracy.

### How to collect one interpretable order

1. Recruit before knowing whether a shop has an exception. Obtain consent for a redacted log, set a deletion date, and record refusals and attrition. A household that shops alone is eligible.
2. Freeze the household's cap and scope, meals, portions, named exclusions, lunch reservations, store, slot, acceptable trips, comparator and preexisting subscription before revealing an answer. Keep this research intake separate from the app's first-use flow.
3. Time-stamp the notice, deadline, visible facts and family's usual decision. Have the researcher or app use the same evidence independently. If there is no time to show an answer, record it as a shadow comparison. The shopper controls the actual purchase.
4. Record a missing line against the intended quantity, whether the view was complete, and any known resolution. For fee comparisons, preserve eligible subtotal, taxes, discounts, payment conditions, slot and full displayed totals for both versions whenever available. Record pending credits and final charges separately.
5. At pickup, record usable amounts, top-ups, actual charges, unresolved credits, extra trips, who did the work and what was served. Ask about the affected dinner. Keep “unknown” available. A fee avoided by the actual normal method cannot be claimed again by the planner.
6. Classify the stage, actual vs shadow outcome, better/same/worse/unknown, confirmed/contradicted/missing, harm and extra work. One ordered basket yields one observed household outcome. Count all twenty planned orders in the first study.

**Release-blocking failures.** A false “under cap” or “dinners covered” on held-out cases blocks that assurance. So do a private value in a child/helper payload, a stale device changing a placed order, a duplicate purchase line after replay, lost lunch reservations, or a failure to recover the household's data. Reproduce, correct and retest the relevant path. Simulator checks, scripted browser actions and synthetic fixtures answer narrower questions than native and field tests.

<a id="build"></a>

## Build sequence and release evidence

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
| **B10 · Calendar, ideas and two quotes** · B03/B04/B06/B08 | Finish S25–S27 and A01–A03 with the shared meal/stock/quote engines. Free manual paths; permission checks; adult approval before the basket changes. Complete bilingual parity across app/web/help/billing. | Run the [three-feature vectors](foundation-gen2.1/contracts/new-features.json) plus dirty offline edits. A cheaper sticker basket can cost more after travel. Unapproved dinner ideas produce zero changes. Editing this week preserves rotation and placed lines. |
| **B11 · Release candidate** · B00–B10 | End-to-end deployment, privacy/retention, support, StoreKit reconciliation, field instrumentation, migration/restore drills, accessibility, localization and staged rollout. Ship the dated retailer handoff. | Feature-by-feature evidence for D/F/P/E/N/A, all 27 routes, six boundary checks, all planned devices. Any open hard block stops release or the affected assurance. |

### Test harness requirements

* **Fast domain tests** on every change. Shared JSON vectors evaluated independently by Swift and server implementation: exact rational/decimal math, package rounding, mixed units, insufficient confirmed yield, duplicate/manual/meal provenance, fee thresholds, dated rebates, guest portions, equivalent commitments, travel cash and time. Include randomized conservation checks (no lot over-allocation, no double count, null never becomes a zero price) and overnight/DST cutoffs. Fix the expected behavior before optimizing.
* **Database and API contract tests** use real SQLite/Postgres and migrations, separate credentialed test clients and deterministic interleavings. Test cross-tenant object access for every read/command/export, duplicate events, changed-body replay, stale epochs, row count on conditional write, device re-enrollment, closed shops and out-of-order notifications. Fail after each mutation boundary to prove rollback and restart consistency. Run a migration from each supported file/schema version and interrupt/retry it. Verify restore and deleted identities in a fresh environment.
* **UI tests** cover onboarding without an account; empty first-time urgent repair; list import → budget compare → handoff → actual fill → repair → cook message → close → next shop; family request from offline draft → shopper review → deferral → later trip; paid second-adult proposal → approval → lapse; all three additions and denied camera/mic/notification access. Capture before/after database assertions, not just a screenshot of a success toast.
* **Human device tests** on minimum supported and current iPhone OS, small/large screens, light/dark/increased contrast, large accessibility type, VoiceOver, Switch Control/keyboard and Reduce Motion. Test iOS Safari and Android Chrome web invite/own requests/helper scope on a fresh and primed browser, storage eviction/denial, external links, background/restart and sign out. Exercise regional units, English/Spanish flows and readback in a noisy kitchen. Record OS, build, locale, device and exact fixture used.
* **Operational rehearsals** on staging: lost device and authority transfer mid-checkout, account deletion while offline, stale cached projections, duplicate Apple transaction callbacks, expired provider keys, restore-from-backup plus tombstones, write failure and media upload interruption. Set an initial measured performance budget on a named lowest-supported device: e.g., a 500-line list remains responsive to checking/search, and saving a draft never blocks typing. Measure P95 on realistic fixtures; retain baseline before adding more features.

### Field and release checklist

For each requirement track ID, owning screen/command, commit, fixture, automated result, device evidence, owner, date and unresolved risk. The feature catalogue is a specification; fill a separate implementation tracker from real test artifacts. Hard blocks include a false “under budget” or “dinners covered”, a private value in a child/helper response, duplicate purchase line after retry, stale mutation of a placed order, inability to recover local records, or entitlement restore granting another household's authority.

Prepare a human-reviewed English/Spanish product page, support/privacy URLs, privacy disclosures, App Store age-rating responses, purchase terms/manage/restore, in-app account deletion, App Review walkthrough and a demo household with fictional data. Obtain a real signing team, bundle and services IDs, domain, notification environment, product configuration, child-consent process and operating owner. Verify review requirements and current SDK on submission day. Reviewers must be able to evaluate the free journey, two seats, contributor web invite, guardian controls and manual handoff without real children, retailer accounts or production family data. [Apple review requirements](https://developer.apple.com/app-store/review/guidelines/)


Keep the proposed $49.99 offer separate: cap research at 400 qualified offers or $280 fully loaded acquisition spend, seek 20 retained buyers at $14 or less acquisition cost, then 12/20 using three of their last four eligible shops by week eight. Log refunds and later renewal distinctly. These are inherited business experiments, not claims of success, automatic commitments to spend, or a reason to omit launch features. [Pilot protocol](foundation-gen2.1/references/grocery23/pilot-protocol.md)

**Release handoff.** On macOS produce signed TestFlight builds, run the fixture-linked suites, archive screenshots and result bundles by build, then publish with staged monitoring only after owner authorization for distribution. Rollback plan: turn off a failing network path, retain local records and typed/manual alternatives, block misleading assurances, and reconcile queued writes before resuming. No direct retailer adapter ships in this release.

**Gen 2 regression gates.** At B05 import a conflicting digest concurrently and exercise export-after-erasure. At B06 enforce an actual guardian relationship, irrevocable consent withdrawal, scoped meal-week access, replay windows and both pre- and post-compaction retries. At B07 race a shopper transfer with external placement; preserve both reports and require reconciliation. At B08 test a third adult and a child across renewals, verified time, superseding refund, and reassign/restore rollback. At B11 open the signed build and execute every promise in [the keyword handoff](foundation-gen2.1/09-keywords.md) before recording listing fields. Record the build, locale, device, tester, result and next action. Exclude an unverified claim from the listing even if it ranks well.


**Placement regressions to implement.** B02 selects a meal without a date, restarts and assigns it once. Check, handle and trash three identically named rows, change stores, restore original order and reopen only the intended row. B03 tests separate spend and hold gaps with known and unknown holds. B04 starts from an empty offline install, makes an urgent meal need and cook note without manufacturing a delivery. Copy a replacement ceiling at S07 without changing offer status. Reject impossible leftover yield. B05 stages a failed recipe OCR review without touching a saved meal. B06/B07 exercise static text, read-only link, proposed edit, revoked link, contributor denial and stale proposal. B08 verifies per-recipient paid diff versus manual resend after lapse, updates the baseline of a second what-if, and prevents a period total from leaking a hidden shop. B09 uses the B08 guest/entitlement port for spoken preview. B10 moves an undated meal into the week with the same needs. B11 records mobile testing evidence for every feature and the comparative usability study.

## Apple subscription setup and verification

Household is an annual digital subscription for up to two named adult planners. Use **StoreKit 2** on iPhone. S18 owns the subscription offer, Restore Purchases and Manage Subscription. S19 manages the app's seats. Keep the Free route visible. The retailer collects payment for groceries. The shopper may record that charge later at S11. Apple Pay merchant checkout, grocery-card capture and payment processing for groceries are outside this build.

| Stage and owner | Action | Completion evidence |
|---|---|---|
| 1. Account Holder and finance | Use the correct Apple Developer team and App Store Connect organization. In Business, have the Account Holder accept the current Paid Apps Agreement. Complete Apple's applicable tax and banking requirements through the account. Keep account and payout details outside the repository. | Agreement and required financial information are active for selling. [Apple agreements](https://developer.apple.com/help/app-store-connect/manage-agreements/sign-and-update-agreements) |
| 2. Release owner | Register the app's final bundle ID and select it for the App Store Connect app. Enable In-App Purchase for the iOS target. Under Monetization → Subscriptions, create one group for Household and one annual auto-renewable product. Choose a permanent product ID, set one year, storefront availability and the approved price. The US $49.99 annual figure is the research hypothesis. Supply the group and product localizations, review screenshot and review notes. Leave Family Sharing off for this two-seat account model. | Exact product ID and bundle match environment configuration in client and server. No production SKU or price is assumed from a fixture. [Subscription properties](https://developer.apple.com/help/app-store-connect/reference/app-information/required-localizable-and-editable-properties) |
| 3. iOS owner, B08 | Request the configured product, display its localized price and term, renewal disclosure, privacy policy, terms, Restore and Manage actions. Ask the adult to identify the purchasing account and household. Subscribe through StoreKit. Handle success, pending, cancellation, unverified transaction and unavailable product explicitly. Observe transaction updates and reconcile current entitlements at startup. Finish after durable delivery. | A missing product leaves a retry and an accessible Free path. A user-initiated restore reconciles the existing purchase. Pending, cancellation and verification failure grant zero paid seats. |
| 4. Service owner, B08 | Deploy a signed-transaction verification and reconciliation handler. Configure distinct sandbox and production HTTPS endpoints for App Store Server Notifications V2 under App Information. Validate Apple signatures, bundle, product and environment before changing access. Deduplicate events and reconcile subscription state on late, missing or out-of-order delivery. Keep App Store Server API keys in a server-side secret manager. Bind the verified original purchase identity once to its purchaser and selected household. | Send a test notification. Exercise renewal, expiry, refund and restoration. A replay and a restore to the wrong household cannot duplicate access. A refund or expiry retains the family's permitted Free data. [Apple server-notification settings](https://developer.apple.com/help/app-store-connect/configure-in-app-purchase-settings/enter-server-urls-for-app-store-server-notifications/) |
| 5. QA and release owner, B08/B11 | First test with a local StoreKit configuration in Xcode. Then fetch the actual product through sandbox/TestFlight and test purchase, interrupted delivery, reinstall and restore on a second device, renewal, billing retry, grace if enabled, expiration and refund. Check both app locales and the real storefront price. Include the first subscription, group and new app version in the review submission and supply the reviewer's test path. | Attach sandbox transaction and reconciliation results using redacted IDs, a screenshot of S18, restore and seat-limit evidence, review status, an operating owner for billing support and reconciliation alerts. [Apple submission workflow](https://developer.apple.com/help/app-store-connect/manage-submissions-to-app-review/submit-an-in-app-purchase/) |

**Current status.** The reference schema and fixtures cover purchase binding, adult seats and replay. The app record, financial agreements, product, keys, endpoints, signed build and real sandbox purchase require the owner's Apple team and the eventual running application. This foundation supplies instructions and acceptance criteria.

<a id="launch"></a>

## App Store positioning and keyword plan

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

### What the research archive contains

The cumulative US iPhone library in G15 contains **185,847 historical ranking rows and 77,547 normalized terms** across 97 checked profiles, 96 with rows. The final collection added six profiles and 8,776 ranking rows to G14, including 1,788 previously unseen normalized terms. The release planner has 383 reviewed English phrases, 3,654 screened discovery leads, 27 current-search observations in that capture, 177 English panel entries and 195 Top Installs rows cumulatively. These counts describe different populations. A live organic search, a three-month historical rank, panel volume, estimated reach and Top Installs membership cannot be substituted for one another.

G14's voice experiments found 5/0 volume/difficulty for both “voice grocery list” and “voice shopping list”. All six leading slots across the two searches belonged to distinct specialists. “Siri shopping list” scored 11/0 and “Siri grocery list” 5/0. “Voice notes” at 48/0 and “family organizer” at 31/2 attracted different intentions. Test the relevant grocery action in the app, show it in a screenshot and use the selected brand consistently. An organic download alone cannot reveal the exact phrase that led to it.

**Storefront and language.** Separate US English and US Spanish queries. G9's Spanish panel returned 27/0 and 251 modeled monthly first-position impressions for “lista de compras”. Related variants and a small French-Canadian probe had different results. Four of eleven checked binaries declared Spanish in the historical Apple lookup. A translated listing alone cannot prove a localized app. Keep the shopper's original food wording, recipient language, locale, currency and retailer market separately. Test “frijoles negros sin sal añadida, 2 latas de 15 oz” from input through the cook's text and a spoken reading.

### Reviewed English keyword bank

Each row below comes from the current planner. The action is a research or listing decision. A dash in a numeric field means the workbook supplies no value. A measured zero remains zero. Keep excluded and exploratory phrases out of the default listing even if their market score is high.

| Phrase | Decision | Intent | Panel volume | Difficulty | Modeled monthly reach at #1 |
| --- | --- | --- | --- | --- | --- |
| meal planner grocery list | Test first | Meals to groceries | 48 | 4 | 2643 |
| shared grocery list | Test first | Shared lists | 31 | 0 | 98 |
| grocery budget | Test first | Checkout budget | 41 | 0 | 886 |
| budget meals | Test first | Budget meals | 38 | 13 | 631 |
| grocery list organizer | Test first | Everyday lists | 27 | 0 | 267 |
| dinner planner | Test first | Meals to groceries | 36 | 2 | 703 |
| grocery calculator | Secondary test | Checkout budget | 28 | 0 | 347 |
| meal planner family | Secondary test | Meals to groceries | 28 | 0 | 315 |
| grocery list with prices | Secondary test | Checkout budget | 5 | 0 | 0 |
| family grocery list | Secondary test | Shared lists | 5 | 0 | 0 |
| voice shopping list | Copy / proof | Voice capture | 5 | 0 | 0 |
| grocery shopping list | Secondary test | Everyday lists | 20 | 0 | 799 |
| collaborative grocery app | Secondary test | Shared lists | — | — | — |
| collaborative grocery list | Secondary test | Shared lists | 5 | 0 | 0 |
| couple grocery organizer | Secondary test | Shared lists | — | — | — |
| couples grocery list | Secondary test | Shared lists | — | — | — |
| family groceries | Secondary test | Shared lists | — | — | — |
| family grocery organizer | Secondary test | Shared lists | — | — | — |
| family grocery planner | Secondary test | Shared lists | — | — | — |
| family grocery shopping list | Secondary test | Shared lists | — | — | — |
| family shared list | Secondary test | Shared lists | — | — | — |
| family shopping list | Secondary test | Shared lists | 5 | 2 | 0 |
| grocery list for couples | Unmeasured idea | Shared lists | — | — | — |
| grocery list for family | Unmeasured idea | Shared lists | — | — | — |
| grocery list sharing | Secondary test | Shared lists | — | — | — |
| grocery sharing app | Secondary test | Shared lists | — | — | — |
| group grocery list | Unmeasured idea | Shared lists | — | — | — |
| household grocery list | Secondary test | Shared lists | 5 | 0 | 0 |
| household shopping list | Secondary test | Shared lists | — | — | — |
| share groceries | Secondary test | Shared lists | — | — | — |
| share grocery list | Secondary test | Shared lists | — | — | — |
| shareable grocery list | Secondary test | Shared lists | — | — | — |
| shared family list | Secondary test | Shared lists | 5 | 0 | 0 |
| shared groceries | Secondary test | Shared lists | — | — | — |
| shared grocery list for couples | Unmeasured idea | Shared lists | — | — | — |
| shared grocery list for family | Secondary test | Shared lists | 5 | 0 | 0 |
| shared household shopping list | Unmeasured idea | Shared lists | — | — | — |
| shared list for groceries | Unmeasured idea | Shared lists | — | — | — |
| shared shopping list | Secondary test | Shared lists | 5 | 0 | 0 |
| shared shopping list for family | Unmeasured idea | Shared lists | — | — | — |
| shopping list for couples | Secondary test | Shared lists | 5 | 0 | 0 |
| shopping planner for families | Secondary test | Shared lists | — | — | — |
| simple shared grocery list | Secondary test | Shared lists | — | — | — |
| add groceries for next trip | Unmeasured idea | Family requests | — | — | — |
| ask for groceries | Unmeasured idea | Family requests | — | — | — |
| family grocery inbox | Unmeasured idea | Family requests | — | — | — |
| family grocery reminders | Unmeasured idea | Family requests | — | — | — |
| family grocery requests | Unmeasured idea | Family requests | — | — | — |
| family shopping inbox | Unmeasured idea | Family requests | — | — | — |
| family shopping requests | Unmeasured idea | Family requests | — | — | — |
| groceries for next time | Unmeasured idea | Family requests | — | — | — |
| grocery request list | Unmeasured idea | Family requests | — | — | — |
| grocery requests for family | Unmeasured idea | Family requests | — | — | — |
| household shopping requests | Unmeasured idea | Family requests | — | — | — |
| request groceries | Unmeasured idea | Family requests | — | — | — |
| save for next shop | Unmeasured idea | Family requests | — | — | — |
| shopping request list | Unmeasured idea | Family requests | — | — | — |
| checklist for groceries | Secondary test | Everyday lists | — | — | — |
| easy grocery list | Secondary test | Everyday lists | — | — | — |
| easy grocery lists | Secondary test | Everyday lists | — | — | — |
| food list for groceries | Secondary test | Everyday lists | — | — | — |
| food shopping list | Secondary test | Everyday lists | 20 | 0 | 22 |
| groceries checklist | Unmeasured idea | Everyday lists | — | — | — |
| groceries list | Secondary test | Everyday lists | — | — | — |
| grocery checklist | Secondary test | Everyday lists | 5 | 0 | 0 |
| grocery list | Secondary test | Everyday lists | 53 | 0 | 15539 |
| grocery list app | Secondary test | Everyday lists | 26 | 0 | 58 |
| grocery list by store | Secondary test | Everyday lists | — | — | — |
| grocery list maker | Secondary test | Everyday lists | 33 | 0 | 189 |
| grocery list manager | Secondary test | Everyday lists | — | — | — |
| grocery list planner | Secondary test | Everyday lists | — | — | — |
| grocery organizer | Secondary test | Everyday lists | — | — | — |
| grocery planning | Secondary test | Everyday lists | — | — | — |
| grocery shopping lists | Secondary test | Everyday lists | — | — | — |
| grocery shopping planner | Secondary test | Everyday lists | — | — | — |
| grocery store list | Secondary test | Everyday lists | 18 | 0 | 40 |
| list for groceries | Secondary test | Everyday lists | — | — | — |
| make a grocery list | Secondary test | Everyday lists | — | — | — |
| my grocery list | Secondary test | Everyday lists | 27 | 0 | 66 |
| organize grocery list | Secondary test | Everyday lists | — | — | — |
| organize my shopping list | Secondary test | Everyday lists | — | — | — |
| shopping checklist | Secondary test | Everyday lists | — | — | — |
| shopping list | Secondary test | Everyday lists | 48 | 2 | 6621 |
| shopping list maker | Secondary test | Everyday lists | — | — | — |
| shopping list organizer | Secondary test | Everyday lists | — | — | — |
| shopping lists for groceries | Unmeasured idea | Everyday lists | — | — | — |
| shopping planner | Secondary test | Everyday lists | — | — | — |
| simple grocery list | Secondary test | Everyday lists | — | — | — |
| weekly grocery list | Secondary test | Everyday lists | 5 | 0 | 0 |
| weekly shopping list | Secondary test | Everyday lists | — | — | — |
| dinner menu planner | Secondary test | Meals to groceries | — | — | — |
| dinner planning | Secondary test | Meals to groceries | — | — | — |
| dinner rotation | Unmeasured idea | Meals to groceries | — | — | — |
| easy family meal organizer | Secondary test | Meals to groceries | — | — | — |
| family dinner ideas | Secondary test | Meals to groceries | 5 | 0 | 0 |
| family dinner planner | Secondary test | Meals to groceries | — | — | — |
| family meal plan | Secondary test | Meals to groceries | — | — | — |
| family meal planner | Secondary test | Meals to groceries | 5 | 0 | 107 |
| family meal planner app | Secondary test | Meals to groceries | — | — | — |
| family meal planners | Secondary test | Meals to groceries | — | — | — |
| family meal planning | Secondary test | Meals to groceries | 24 | 1 | 206 |
| family meal planning app | Secondary test | Meals to groceries | — | — | — |
| groceries and meals | Secondary test | Meals to groceries | — | — | — |
| grocery list from meal plan | Secondary test | Meals to groceries | — | — | — |
| grocery list from recipes | Secondary test | Meals to groceries | — | — | — |
| grocery lists for meal planning | Unmeasured idea | Meals to groceries | — | — | — |
| grocery meal planner | Secondary test | Meals to groceries | — | — | — |
| meal plan and shopping list | Secondary test | Meals to groceries | — | — | — |
| meal plan grocery list | Secondary test | Meals to groceries | — | — | — |
| meal plan shopping list | Secondary test | Meals to groceries | 5 | 0 | 0 |
| meal planner | Secondary test | Meals to groceries | 54 | 25 | 17067 |
| meal planner and grocery list | Secondary test | Meals to groceries | 5 | 1 | 0 |
| meal planner with grocery list | Secondary test | Meals to groceries | 5 | 4 | 0 |
| meal planner with shopping list | Secondary test | Meals to groceries | — | — | — |
| meal planning | Secondary test | Meals to groceries | 34 | 4 | 797 |
| meal planning and grocery list | Secondary test | Meals to groceries | 5 | 3 | 0 |
| meal planning and grocery list app | Secondary test | Meals to groceries | — | — | — |
| meal planning app for families | Secondary test | Meals to groceries | — | — | — |
| meal planning grocery list | Secondary test | Meals to groceries | — | — | — |
| meal rotation | Secondary test | Meals to groceries | 5 | 0 | 0 |
| meal rotation planner | Secondary test | Meals to groceries | — | — | — |
| meal shopping list | Secondary test | Meals to groceries | — | — | — |
| menu and shopping list | Unmeasured idea | Meals to groceries | — | — | — |
| menu planner | Secondary test | Meals to groceries | 32 | 0 | 871 |
| menu planning | Secondary test | Meals to groceries | — | — | — |
| plan dinners for the week | Unmeasured idea | Meals to groceries | — | — | — |
| recipe grocery list | Secondary test | Meals to groceries | — | — | — |
| recipe shopping list | Secondary test | Meals to groceries | — | — | — |
| weekly dinner planner | Secondary test | Meals to groceries | 24 | 0 | 51 |
| weekly meal plan | Secondary test | Meals to groceries | 5 | 1 | 0 |
| weekly meal planner | Secondary test | Meals to groceries | 24 | 0 | 617 |
| weekly menu | Secondary test | Meals to groceries | — | — | — |
| weekly menu planner | Secondary test | Meals to groceries | 22 | 0 | 51 |
| budget for groceries | Unmeasured idea | Checkout budget | — | — | — |
| budget grocery list | Secondary test | Checkout budget | — | — | — |
| budget shopping list | Secondary test | Checkout budget | — | — | — |
| estimate grocery total | Unmeasured idea | Checkout budget | — | — | — |
| family grocery budget | Secondary test | Checkout budget | 5 | 0 | 0 |
| food budget planner | Secondary test | Checkout budget | — | — | — |
| grocery bill estimator | Unmeasured idea | Checkout budget | — | — | — |
| grocery budget calculator | Secondary test | Checkout budget | — | — | — |
| grocery budget list | Secondary test | Checkout budget | — | — | — |
| grocery budget planner | Secondary test | Checkout budget | 5 | 0 | 0 |
| grocery cart calculator | Unmeasured idea | Checkout budget | — | — | — |
| grocery cost calculator | Secondary test | Checkout budget | 5 | 0 | 0 |
| grocery cost estimator | Unmeasured idea | Checkout budget | — | — | — |
| grocery list budget | Secondary test | Checkout budget | — | — | — |
| grocery list calculator | Secondary test | Checkout budget | — | — | — |
| grocery list with cost | Unmeasured idea | Checkout budget | — | — | — |
| grocery list with estimated prices | Unmeasured idea | Checkout budget | — | — | — |
| grocery list with total | Unmeasured idea | Checkout budget | — | — | — |
| grocery price calculator | Unmeasured idea | Checkout budget | — | — | — |
| grocery shopping budget | Secondary test | Checkout budget | — | — | — |
| grocery shopping calculator | Unmeasured idea | Checkout budget | — | — | — |
| grocery spending planner | Unmeasured idea | Checkout budget | — | — | — |
| grocery total calculator | Unmeasured idea | Checkout budget | — | — | — |
| plan grocery spending | Unmeasured idea | Checkout budget | — | — | — |
| shopping budget planner | Secondary test | Checkout budget | — | — | — |
| shopping list calculator | Secondary test | Checkout budget | — | — | — |
| shopping list with budget | Secondary test | Checkout budget | 5 | 0 | 0 |
| shopping list with prices | Secondary test | Checkout budget | 5 | 0 | 0 |
| weekly grocery budget | Secondary test | Checkout budget | 5 | 0 | 0 |
| affordable meal planning | Unmeasured idea | Budget meals | — | — | — |
| budget dinner planner | Unmeasured idea | Budget meals | — | — | — |
| budget dinners | Unmeasured idea | Budget meals | — | — | — |
| budget family meals | Unmeasured idea | Budget meals | — | — | — |
| budget friendly meal planner | Unmeasured idea | Budget meals | — | — | — |
| budget meal plan | Secondary test | Budget meals | — | — | — |
| budget meal planner | Secondary test | Budget meals | 5 | 12 | 0 |
| budget meal planning | Secondary test | Budget meals | — | — | — |
| cheap meal planner | Secondary test | Budget meals | — | — | — |
| family meals on a budget | Unmeasured idea | Budget meals | — | — | — |
| grocery budget meal planner | Unmeasured idea | Budget meals | — | — | — |
| meal budget planner | Secondary test | Budget meals | — | — | — |
| meal planning budget | Unmeasured idea | Budget meals | — | — | — |
| meal planning on a budget | Unmeasured idea | Budget meals | — | — | — |
| plan meals on a budget | Unmeasured idea | Budget meals | — | — | — |
| weekly meal planner on a budget | Unmeasured idea | Budget meals | — | — | — |
| curbside pickup list | Unmeasured idea | Pickup preparation | — | — | — |
| grocery handoff list | Unmeasured idea | Pickup preparation | — | — | — |
| grocery order checklist | Unmeasured idea | Pickup preparation | — | — | — |
| grocery pickup checklist | Unmeasured idea | Pickup preparation | — | — | — |
| grocery pickup list | Unmeasured idea | Pickup preparation | — | — | — |
| grocery pickup planning | Unmeasured idea | Pickup preparation | — | — | — |
| grocery trip planner | Copy / proof | Pickup preparation | — | — | — |
| pickup shopping list | Unmeasured idea | Pickup preparation | — | — | — |
| plan grocery pickup | Unmeasured idea | Pickup preparation | — | — | — |
| plan next grocery trip | Unmeasured idea | Pickup preparation | — | — | — |
| prepare grocery pickup | Unmeasured idea | Pickup preparation | — | — | — |
| shopping trip planner | Unmeasured idea | Pickup preparation | — | — | — |
| add to grocery list | Copy / proof | Voice capture | 5 | 0 | 0 |
| dictate grocery list | Copy / proof | Voice capture | 5 | 0 | 0 |
| dictation grocery list | Unmeasured idea | Voice capture | — | — | — |
| grocery list by voice | Copy / proof | Voice capture | 5 | 0 | 0 |
| grocery list dictation | Unmeasured idea | Voice capture | — | — | — |
| grocery list voice input | Unmeasured idea | Voice capture | — | — | — |
| grocery list with voice | Unmeasured idea | Voice capture | — | — | — |
| hands free grocery list | Unmeasured idea | Voice capture | — | — | — |
| shopping list by voice | Copy / proof | Voice capture | 5 | 0 | 0 |
| spoken grocery list | Unmeasured idea | Voice capture | — | — | — |
| voice activated grocery list | Unmeasured idea | Voice capture | — | — | — |
| voice grocery | Copy / proof | Voice capture | — | — | — |
| voice grocery list | Copy / proof | Voice capture | 5 | 0 | 0 |
| voice grocery shopping list | Unmeasured idea | Voice capture | — | — | — |
| voice input shopping list | Unmeasured idea | Voice capture | — | — | — |
| voice shopping | Copy / proof | Voice capture | 5 | 0 | 0 |
| food inventory list | Copy / proof | Pantry and freezer | — | — | — |
| freezer inventory | Copy / proof | Pantry and freezer | 5 | 0 | 0 |
| freezer inventory list | Copy / proof | Pantry and freezer | — | — | — |
| freezer list | Copy / proof | Pantry and freezer | — | — | — |
| leftover meal planner | Copy / proof | Pantry and freezer | 5 | 0 | 0 |
| pantry and freezer inventory | Unmeasured idea | Pantry and freezer | — | — | — |
| pantry checklist | Copy / proof | Pantry and freezer | — | — | — |
| pantry inventory | Copy / proof | Pantry and freezer | 36 | 0 | 1071 |
| pantry inventory list | Copy / proof | Pantry and freezer | — | — | — |
| pantry list | Copy / proof | Pantry and freezer | — | — | — |
| pantry meal planner | Copy / proof | Pantry and freezer | 5 | 0 | 0 |
| pantry meal planning | Unmeasured idea | Pantry and freezer | — | — | — |
| pantry planner | Copy / proof | Pantry and freezer | — | — | — |
| pantry shopping list | Copy / proof | Pantry and freezer | — | — | — |
| pantry staples list | Copy / proof | Pantry and freezer | — | — | — |
| pantry tracker | Copy / proof | Pantry and freezer | — | — | — |
| plan meals from pantry | Unmeasured idea | Pantry and freezer | — | — | — |
| use pantry ingredients | Unmeasured idea | Pantry and freezer | — | — | — |
| family recipe organizer | Copy / proof | Reusable recipes | — | — | — |
| import recipes | Unmeasured idea | Reusable recipes | — | — | — |
| organize family recipes | Unmeasured idea | Reusable recipes | — | — | — |
| recipe collection | Copy / proof | Reusable recipes | — | — | — |
| recipe import | Copy / proof | Reusable recipes | 22 | 0 | 42 |
| recipe importer | Copy / proof | Reusable recipes | — | — | — |
| recipe ingredient list | Copy / proof | Reusable recipes | — | — | — |
| recipe library | Unmeasured idea | Reusable recipes | — | — | — |
| recipe list organizer | Unmeasured idea | Reusable recipes | — | — | — |
| recipe meal planner | Copy / proof | Reusable recipes | — | — | — |
| recipe meal planning | Copy / proof | Reusable recipes | — | — | — |
| recipe organizer | Copy / proof | Reusable recipes | 38 | 23 | 1050 |
| recipe planner | Copy / proof | Reusable recipes | 23 | 2 | 56 |
| recipe to grocery list | Copy / proof | Reusable recipes | 5 | 2 | 0 |
| recipe to shopping list | Copy / proof | Reusable recipes | — | — | — |
| save family recipes | Copy / proof | Reusable recipes | — | — | — |
| batch cooking | Copy / proof | Packs and portions | 5 | 0 | 0 |
| batch cooking planner | Copy / proof | Packs and portions | — | — | — |
| batch meal planner | Unmeasured idea | Packs and portions | — | — | — |
| compare package sizes | Unmeasured idea | Packs and portions | — | — | — |
| dinner portion planner | Unmeasured idea | Packs and portions | — | — | — |
| grocery pack size | Unmeasured idea | Packs and portions | — | — | — |
| grocery quantity calculator | Unmeasured idea | Packs and portions | — | — | — |
| grocery unit price calculator | Unmeasured idea | Packs and portions | — | — | — |
| guest meal planner | Unmeasured idea | Packs and portions | — | — | — |
| lunch portion planning | Unmeasured idea | Packs and portions | — | — | — |
| meal portion planner | Unmeasured idea | Packs and portions | — | — | — |
| meal prep grocery list | Copy / proof | Packs and portions | — | — | — |
| meal prep shopping list | Copy / proof | Packs and portions | — | — | — |
| plan meals for guests | Unmeasured idea | Packs and portions | — | — | — |
| unit price calculator | Copy / proof | Packs and portions | 20 | 0 | 81 |
| unit price comparison | Copy / proof | Packs and portions | — | — | — |
| whole pack meal planning | Unmeasured idea | Packs and portions | — | — | — |
| bilingual grocery list | Unmeasured idea | Cooking handoff | — | — | — |
| family cooking instructions | Unmeasured idea | Cooking handoff | — | — | — |
| hands free cooking | Copy / proof | Cooking handoff | 5 | 0 | 0 |
| hands free recipe reader | Unmeasured idea | Cooking handoff | — | — | — |
| meal prep instructions | Unmeasured idea | Cooking handoff | — | — | — |
| read aloud recipe | Unmeasured idea | Cooking handoff | — | — | — |
| read recipes aloud | Copy / proof | Cooking handoff | 5 | 0 | 0 |
| recipe read aloud | Copy / proof | Cooking handoff | — | — | — |
| share dinner instructions | Unmeasured idea | Cooking handoff | — | — | — |
| share meal instructions | Unmeasured idea | Cooking handoff | — | — | — |
| spanish grocery list | Unmeasured idea | Cooking handoff | — | — | — |
| spoken cooking instructions | Unmeasured idea | Cooking handoff | — | — | — |
| talking recipe reader | Unmeasured idea | Cooking handoff | — | — | — |
| carry over grocery list | Unmeasured idea | Recovery and continuity | — | — | — |
| grocery backup list | Unmeasured idea | Recovery and continuity | — | — | — |
| grocery list offline | Unmeasured idea | Recovery and continuity | — | — | — |
| grocery list reminders | Unmeasured idea | Recovery and continuity | — | — | — |
| grocery shopping reminder | Unmeasured idea | Recovery and continuity | — | — | — |
| grocery substitutions | Unmeasured idea | Recovery and continuity | — | — | — |
| missing grocery item | Unmeasured idea | Recovery and continuity | — | — | — |
| next shopping trip | Unmeasured idea | Recovery and continuity | — | — | — |
| offline grocery list | Unmeasured idea | Recovery and continuity | — | — | — |
| offline shopping list | Unmeasured idea | Recovery and continuity | — | — | — |
| recurring grocery list | Copy / proof | Recovery and continuity | 5 | 0 | 0 |
| reorder grocery list | Unmeasured idea | Recovery and continuity | — | — | — |
| reusable grocery list | Unmeasured idea | Recovery and continuity | — | — | — |
| reusable shopping list | Unmeasured idea | Recovery and continuity | — | — | — |
| save grocery list | Unmeasured idea | Recovery and continuity | — | — | — |
| shopping list offline | Unmeasured idea | Recovery and continuity | — | — | — |
| shopping list reminder | Copy / proof | Recovery and continuity | — | — | — |
| weekly grocery checklist | Unmeasured idea | Recovery and continuity | — | — | — |
| food budget tracker | Copy / proof | History and planning | — | — | — |
| grocery budget history | Unmeasured idea | History and planning | — | — | — |
| grocery budget tracker | Copy / proof | History and planning | 5 | 0 | 0 |
| grocery expense history | Unmeasured idea | History and planning | — | — | — |
| grocery price history | Copy / proof | History and planning | 5 | 0 | 0 |
| grocery shopping history | Unmeasured idea | History and planning | — | — | — |
| grocery spending history | Unmeasured idea | History and planning | — | — | — |
| grocery spending tracker | Copy / proof | History and planning | — | — | — |
| track grocery spending | Copy / proof | History and planning | — | — | — |
| weekly grocery spending | Unmeasured idea | History and planning | — | — | — |
| ai recipe generator | Exclude | Wrong search intent | — | — | — |
| allergy checker | Exclude | Wrong search intent | — | — | — |
| automatic grocery ordering | Exclude | Wrong search intent | — | — | — |
| calorie counter | Exclude | Wrong search intent | — | — | — |
| cashback groceries | Exclude | Wrong search intent | — | — | — |
| cheapest grocery store | Exclude | Wrong search intent | — | — | — |
| family calendar | Exclude | Wrong search intent | — | — | — |
| family organizer | Exclude | Wrong search intent | 31 | 2 | 785 |
| grocery coupons | Exclude | Wrong search intent | 21 | 31 | 376 |
| grocery deals | Exclude | Wrong search intent | 25 | 28 | 70 |
| grocery delivery | Exclude | Wrong search intent | 32 | 88 | 6332 |
| grocery delivery app | Exclude | Wrong search intent | — | — | — |
| grocery delivery tracker | Exclude | Wrong search intent | — | — | — |
| grocery pickup planner | Exclude | Wrong search intent | 5 | 7 | 0 |
| grocery requests | Exclude | Wrong search intent | 5 | 7 | 0 |
| kitchen timer | Exclude | Wrong search intent | 25 | 0 | 79 |
| macro meal planner | Exclude | Wrong search intent | — | — | — |
| online grocery shopping | Exclude | Wrong search intent | — | — | — |
| order groceries online | Exclude | Wrong search intent | — | — | — |
| voice notes | Exclude | Wrong search intent | 48 | 0 | 3680 |
| barcode shopping list | Unmeasured idea | Capture and scanning | — | — | — |
| grocery barcode scanner | Copy / proof | Capture and scanning | 5 | 0 | 0 |
| grocery list barcode scanner | Unmeasured idea | Capture and scanning | — | — | — |
| grocery list from photo | Unmeasured idea | Capture and scanning | — | — | — |
| grocery list scanner | Copy / proof | Capture and scanning | 5 | 0 | 0 |
| grocery receipt scanner | Copy / proof | Capture and scanning | 5 | 4 | 0 |
| import grocery list | Copy / proof | Capture and scanning | — | — | — |
| import shopping list | Unmeasured idea | Capture and scanning | — | — | — |
| paste grocery list | Unmeasured idea | Capture and scanning | — | — | — |
| photo grocery list | Copy / proof | Capture and scanning | — | — | — |
| receipt to grocery list | Unmeasured idea | Capture and scanning | — | — | — |
| recipe ocr | Copy / proof | Capture and scanning | — | — | — |
| recipe photo to text | Unmeasured idea | Capture and scanning | — | — | — |
| recipe scanner | Copy / proof | Capture and scanning | 23 | 0 | 57 |
| scan groceries into list | Unmeasured idea | Capture and scanning | — | — | — |
| scan grocery list | Copy / proof | Capture and scanning | — | — | — |
| scan grocery receipt | Unmeasured idea | Capture and scanning | — | — | — |
| scan recipes | Unmeasured idea | Capture and scanning | — | — | — |
| scan shopping list | Unmeasured idea | Capture and scanning | — | — | — |
| shopping list barcode scanner | Unmeasured idea | Capture and scanning | — | — | — |
| accessible grocery list | Unmeasured idea | Aisles and access | — | — | — |
| category based shopping list | Copy / proof | Aisles and access | — | — | — |
| grocery aisle organizer | Unmeasured idea | Aisles and access | — | — | — |
| grocery list aisle categories | Unmeasured idea | Aisles and access | — | — | — |
| grocery list by aisle | Copy / proof | Aisles and access | 5 | 0 | 0 |
| grocery list by category | Unmeasured idea | Aisles and access | — | — | — |
| grocery list widget | Copy / proof | Aisles and access | 5 | 0 | 0 |
| grocery list with categories | Unmeasured idea | Aisles and access | — | — | — |
| grocery store checklist | Copy / proof | Aisles and access | — | — | — |
| large print grocery list | Unmeasured idea | Aisles and access | — | — | — |
| large print shopping list | Unmeasured idea | Aisles and access | — | — | — |
| organize groceries by aisle | Unmeasured idea | Aisles and access | — | — | — |
| shopping list by aisle | Copy / proof | Aisles and access | — | — | — |
| shopping list by category | Unmeasured idea | Aisles and access | — | — | — |
| shopping list widget | Copy / proof | Aisles and access | 5 | 2 | 0 |
| sort grocery list by aisle | Unmeasured idea | Aisles and access | — | — | — |
| adjust recipe servings | Unmeasured idea | Guest and meal recovery | — | — | — |
| backup dinner ideas | Unmeasured idea | Guest and meal recovery | — | — | — |
| dinner and lunch planner | Unmeasured idea | Guest and meal recovery | — | — | — |
| dinner backup plan | Unmeasured idea | Guest and meal recovery | — | — | — |
| extra dinner guest | Unmeasured idea | Guest and meal recovery | — | — | — |
| family lunch planning | Unmeasured idea | Guest and meal recovery | — | — | — |
| leftover meal planning | Unmeasured idea | Guest and meal recovery | — | — | — |
| meal planner for guests | Unmeasured idea | Guest and meal recovery | — | — | — |
| meal planning for leftovers | Unmeasured idea | Guest and meal recovery | — | — | — |
| plan dinner with leftovers | Unmeasured idea | Guest and meal recovery | — | — | — |
| recipe portion calculator | Copy / proof | Guest and meal recovery | — | — | — |
| recipe scaler | Copy / proof | Guest and meal recovery | 5 | 0 | 0 |
| recipe serving calculator | Copy / proof | Guest and meal recovery | — | — | — |
| scale recipe for guests | Unmeasured idea | Guest and meal recovery | — | — | — |
| bilingual shopping list | Unmeasured idea | Portable lists and language | — | — | — |
| copy grocery list | Unmeasured idea | Portable lists and language | — | — | — |
| english spanish grocery list | Unmeasured idea | Portable lists and language | — | — | — |
| export grocery list | Unmeasured idea | Portable lists and language | — | — | — |
| grocery list backup | Unmeasured idea | Portable lists and language | — | — | — |
| grocery list in spanish | Unmeasured idea | Portable lists and language | — | — | — |
| print grocery list | Unmeasured idea | Portable lists and language | — | — | — |
| printable grocery list | Copy / proof | Portable lists and language | 5 | 0 | 0 |
| printable shopping checklist | Unmeasured idea | Portable lists and language | — | — | — |
| restore grocery list | Unmeasured idea | Portable lists and language | — | — | — |
| share recipe instructions | Unmeasured idea | Portable lists and language | — | — | — |
| share shopping checklist | Unmeasured idea | Portable lists and language | — | — | — |
| share shopping list | Copy / proof | Portable lists and language | — | — | — |
| shopping list in spanish | Unmeasured idea | Portable lists and language | — | — | — |
| text grocery list | Unmeasured idea | Portable lists and language | — | — | — |

### US Spanish research phrases

| Phrase | Volume | Difficulty | Modeled monthly reach at #1 | Use to test |
| --- | --- | --- | --- | --- |
| lista de compras | 27 | 0 | 251 | Start with this list phrase. Show the shopper reviewing a family request. |
| lista del súper | 5 | 0 | 0 | Compare regional wording and returned apps before selection. |
| lista de la compra | 5 | 12 | 0 | Compare regional wording and returned apps before selection. |
| menú semanal | 5 | 0 | 0 | Test weekly dinner planning after native review. |
| menu semanal | 5 | 0 | 0 | Compare regional wording and returned apps before selection. |
| planificador de comidas | 5 | 0 | 0 | Test meal-planning language with a family dinner and its grocery list. |
| recetas con ingredientes | 5 | 0 | 0 | Compare regional wording and returned apps before selection. |
| presupuesto familiar | 5 | 0 | 0 | Broad household finance intent. Qualify the food budget in copy. |
| lista del super | 5 | 0 | 0 | Compare regional wording and returned apps before selection. |
| lista de supermercado | 5 | 0 | 0 | Compare regional wording and returned apps before selection. |
| recetas fáciles | 5 | 0 | 0 | Compare regional wording and returned apps before selection. |
| qué cocinar | 5 | 0 | 0 | Compare regional wording and returned apps before selection. |

<a id="sources"></a>

## Source index and authority

All fifteen primary briefs are indexed below. Each row identifies evidence or behavior retained in this edition. Where a concept, tier, product name, first-release decision or listing was revised, the operative wording appears in the relevant chapter above. The original records retain their dates for reproducibility.

| Gen | Primary brief | Contribution carried into this edition |
| --- | --- | --- |
| 1 | [Grocery pickup planner product brief.docx](../research/grocery16/Grocery%20pickup%20planner%20product%20brief.docx) | The first pack check, full-trip cash cap, five-dinner test, cash-hold distinction, acquisition and profit assumptions. |
| 2 | [Grocery pickup planner Gen 2.docx](../research/grocery17/Grocery%20pickup%20planner%20Gen%202.docx) | Meal shortages and repeat permission, protected lunches, usable-yield sanity checks, creator-menu comparison. |
| 3 | [Grocery pickup planner Gen 3.docx](../research/grocery18/Grocery%20pickup%20planner%20Gen%203.docx) | Mixed plates, whole packs, elapsed prep, separate serving and purchase facts, priced sample vs personal check. |
| 4 | [Grocery pickup planner Gen 4.docx](../research/grocery19/Grocery%20pickup%20planner%20Gen%204.docx) | Four public orders, native alternatives, pooled substitution ceilings, retailer note, price sensitivity. |
| 5 | [Grocery pickup planner Gen 5.docx](../research/grocery20/Grocery%20pickup%20planner%20Gen%205.docx) | Ordinary and changed repeat shops, prepared-note benchmark, per-dish reuse, reset and undo. |
| 6 | [Grocery pickup planner Gen 6.docx](../research/grocery21/Grocery%20pickup%20planner%20Gen%206.docx) | Three first-use paths, undated dinner selection, accountable fallbacks, incidence vs exception handling. |
| 7 | [Grocery pickup planner Gen 7.docx](../research/grocery22/Grocery%20pickup%20planner%20Gen%207.docx) | Question-stopping grid, matched commerce and outcome tests, import/handoff controls, evidence limits. |
| 8 | [Grocery pickup planner Gen 8.docx](../research/grocery23/Grocery%20pickup%20planner%20Gen%208.docx) | Fee reversals, vanishing cart lines, 192-condition replay, blinded comparison and field record. |
| 9 | [Grocery pickup planner Gen 9.docx](../research/grocery24/Grocery%20pickup%20planner%20Gen%209.docx) | Deferral, bilingual original wording, branch/mode, extra trips, observed incumbent successes. |
| 10 | [Grocery pickup planner Gen 10.docx](../research/grocery25/Grocery%20pickup%20planner%20Gen%2010.docx) | Product and access register, entire Free pickup, paid repeat planning, import/export after lapse. |
| 11 | [Grocery pickup planner Gen 11.docx](../research/grocery26/Grocery%20pickup%20planner%20Gen%2011.docx) | Two linked journeys across a first shop and return week, guest preview, recipient and membership handling. |
| 12 | [Grocery pickup planner Gen 12.docx](../research/grocery27/Grocery%20pickup%20planner%20Gen%2012.docx) | Equivalent meals across both baskets, per-recipient sent baseline, 95 comparison entries and keyword evidence. |
| 13 | [Grocery pickup planner Gen 13.docx](../research/grocery28/Grocery%20pickup%20planner%20Gen%2013.docx) | Spruce/linen design, list recovery, motion, scoped projections, immutable revisions and money history. |
| 14 | [Grocery pickup planner Gen 14.docx](../research/grocery29/Grocery%20pickup%20planner%20Gen%2014.docx) | Structured speech, readback, product spellings, type hierarchy, recovery comparison and voice market evidence. |
| 15 | [Grocery pickup planner Gen 15.docx](../research/grocery30/Grocery%20pickup%20planner%20Gen%2015.docx) | Family inbox, one-shopper approval, guardian-managed entry, frozen checkout, scoped retries, retailer feasibility and cumulative keyword library. |

**Later owner and foundation decisions.** Room in the Cart is the selected name. A01–A03 add the meal week, editable dinner ideas and two entered store quotes to the 49 launch requirements inherited from G15. One deferred integration and six boundaries bring the register to 59 decisions. The accepted foundation supplies the placement, service, integrity, Apple billing and build refinements in this edition. [Foundation 2.1 acceptance record](FOUNDATION-2.1-REVIEW.md)

**Evidence files.** This document includes the current product contracts and decision-relevant research. Original review records, native keyword exports, editable spreadsheets, working prototypes and executable fixtures retain their native formats in the source packs. [Historical G15 cumulative pack](../research/grocery30/Gen%2015%20complete%20research%20pack.zip) · [Current editable keyword planner](foundation-gen2.1/launch/Room%20in%20the%20Cart%20keyword%20planner.xlsx) · [Accepted build foundation and verifier](foundation-gen2.1/README.md)
