# Feature implementation contracts

Read each row as one independently demonstrable behavior. B tickets refer to the [build sequence](08-build.md), S numbers to the [screen contracts](03-screens.md). The original oracle is retained for each legacy ID. X rows describe boundaries; A01–A03 carry the owner's explicit scoped changes.

## Day-to-day shop

### D01 · Start without setup

**Free** · B01 · S01 S04

Offer quantity and two pack quotes to a pure PackComparison; store locally on Save. Return item-only headroom if the basket scope is incomplete.

**Accept when.** Open a quick check without an account, store, subscription or weekly menu. Two pack offers and the amount needed produce an item-level answer.

### D02 · Bring the list

**Free** · B02 · S02 S04

Parse typed, explicit paste, selected text and voice into staged source contributions. Confirm duplicate vs additional amount; commit a reversible batch. Search excludes deleted lines.

**Accept when.** Type, paste or share selected text. Keep the original, preview lines, search and undo. Pasting 12 wraps twice asks whether to merge or add. Linking six to tacos within the 12 leaves 12 on the list.

### D03 · Describe this shop

**Free** · B02 · S03 S05

Capture scope, currency, optional fixed reserves, fees, slot/zone and mode on ShopBasis. Edits invalidate dependent quote/guest previews. Keep a receipt/hold out of planned spend.

**Accept when.** Set the cap's scope, currency, store, mode and slot when relevant. Enter an inclusive preview or just the facts available. A $35 dinner limit stays labeled dinner-only even if the other groceries are unknown.

### D04 · Name meals and needs

**Free** · B02 · S03 S04 S14 S25

Create a meal occurrence, serving groups, ingredient demands and protected allocations separately from shopping lines. Hiding or moving a meal does not remove staples or lunch reservations.

**Accept when.** Record the meal, optional night, servings and purpose of each need alongside staples and nonfood. Hiding lunches from view preserves their two wraps alongside six for tacos and four for quesadillas.

### D05 · Compare usable packages

**Free** · B01 · S01 S04 S07

Normalize using a confirmed rational unit basis. Subtract confirmed usable supply, round up whole packs, compare total cost, remaining need, unit ceiling and leftovers. Return a question on unknown conversion.

**Accept when.** Compare whole packs by usable amount, price to buy enough and remainder after protected portions. A shopper can leave a weight or volume conversion unknown when its ingredient-specific basis is missing.

### D06 · Compare current checkouts

**Free basic budget preview** · B03 · S03 S05 S24

Reprice complete equivalent alternatives in expected minor units. Re-evaluate eligible subtotal, fees, discounts and cap scope. Unknown costs propagate. An A03 cross-store scenario uses a separate comparison.

**Accept when.** Compare two same-store, same-slot checkout previews with time, source, included fees and commitments. A $34.80 subtotal plus a $4.95 fee shows $39.75 against $38. An uncertain fee produces a conditional result.

### D07 · Protect or defer a purchase

**Free** · B03 · S05 S12 S24

Record need priority independently of line inclusion. Search only approved removals; persist a deferred need with source, destination and review status. A confirmed handled need is never revived automatically.

**Accept when.** Mark a line required, flexible or undecided. Offer keep, defer and leave unresolved. When the shopper defers filters, lunches keep their allocation and the filters reappear for review next shop.

### D08 · Explain a change

**Free** · B03 · S05 S16 S17

A proposed patch records parent revision and affected contributions. Show delta and unpriced items; Apply once on matching base, Undo as a compensating revision. Post-placement edits require amendment.

**Accept when.** Preview changed lines, meals, packs and checkout before applying. Skip one dinner and check that its portion alone disappears. Undo restores the draft, including unrelated staples.

### D09 · Save a recoverable handoff

**Free** · B03 · S06 S10

Freeze the exact revision before invoking copy/share/open. Record attempted, prepared, intentionally sent, manually reported placed and provider-confirmed as different evidence.

**Accept when.** Save a dated readable snapshot before copy, share or retailer open. Track each action separately from shopper-confirmed submission and retailer-confirmed amendment. Cancelling or opening an empty cart leaves the snapshot intact and the order unconfirmed.

### D10 · Resolve a changed item

**Free** · B04 · S07 S08

Evaluate the offer against per-dish rules, remaining original charge, pack yield, joint headroom and local cutoff. Save a private decision and concise retailer note. Expire to await pickup even offline.

**Accept when.** Record an offer's affected lines, remaining original quantity, known price and local deadline. Check per-dish alternatives. At cutoff show Await pickup with the date/time and keep fill unknown until the bag arrives.

### D11 · Record what came home

**Free** · B04 · S08 S09 S11

Append receipt fragments keyed by source event, original order line, branch and segment. Supersede usable counts separately; allocate protected portions first. Resolve shortfalls per dish independently of money.

**Accept when.** Record no-fill, partial, wrong, late or split items. Separate received, usable and reserved amounts, meal repair and refunds. A delivered eight-pack with six usable and two reserved supplies four to dinner. Retrying the same delivery adds nothing.

### D12 · Tell the cook

**Free** · B04 · S09 S10

Project a complete cook instruction with date, revision, required action and usable portions. Reset optional private fields off per share. Use recipient-specific comparison only on known send history.

**Accept when.** Preview the complete dated instruction and revision in plain text before sharing. An Android caregiver can act without installing the app. Budget defaults private. Marking a version sent does not record acknowledgment.

### D13 · Reopen next shop

**Free** · B04 · S01 S12

Create a new shop ID and draft from selected recurring inputs. Ask about open deferrals and one reusable dinner. Clear stale quotes, store offers and old checkout status.

**Accept when.** Reopen the last shop, reuse one familiar dinner and review outstanding staples in a new draft. If someone bought the coffee already, mark it handled and verify the new list has no coffee charge.

### D14 · Read and recover offline

**Free** · B01–B04 · S01 S08 S20

Write data and local revision in one durable transaction. Replay after process death with local/remote timestamps; keep a recent working version, dated handoff and accessible retry.

**Accept when.** Restart in airplane mode and open the latest local save and last sent snapshot. At large type and with VoiceOver, read the item, quantity, dinner and status without relying on color or a swipe.

### D15 · Keep control of family data

**Free, including after membership ends** · B05 · S19 S20

Separate helper projection from owner backup. Stage, validate and diff imports before a transaction. Provide correction, scoped deletion, restore and redacted support export on Free.

**Accept when.** Preview a scoped shared copy separately from a personal recovery file. Correct, undo, export readable and structured records, recover and delete with scope shown. Importing a backup beside newer records preserves them and offers help.

### D16 · Learn from the first result

**Free, consent optional** · B11 · S11 S20

At end of shop offer optional coded outcome; tie to eligible shop and baseline with no grocery text. Suppress prompts during active planning and on consent decline.

**Accept when.** Let a shopper distinguish acted, unchanged, too late, unknown, already knew and wrong. Declining feedback leaves the trip usable. Measurement omits grocery text and assigns zero incremental benefit to an observed tie.

## Shared implementation contracts

### F01 · Quantities and money

**All quantities and calculations** · B01 · S03 S04 S05

Use typed Money, Quantity and UnitBasis value objects. Keep original literal, normalized rational, confirmed conversion, currency and explicit rounding policy; null means unknown.

**Accept when.** Keep distinct IDs for lines, meal demands and packages, original text, decimal amount, unit, conversion basis, currency and rounding. Two 15 oz cans stay two packs. Dual printed measures describe one demand.

### F02 · Sources and allocations

**All list and meal edits** · B02 · S02 S04 S14

Store contribution IDs and allocation edges. Merge only compatible units/products and confirmed duplicate semantics. Remove one source in isolation. Enforce exclusion rules before candidate ranking.

**Accept when.** Retain each manual, meal or reservation contribution when merging compatible lines. Remove one recipe and verify that other meals, lunches and a manual staple survive. An excluded ingredient cannot become an accepted match.

### F03 · Draft and sent versions

**All shops, snapshots and retailer actions** · B02–B04 · S06 S08 S17

Give templates, occurrences, drafts, immutable revisions, submitted lines, proposals and fill events independent IDs. Every external-action receipt identifies its actual base.

**Accept when.** Version usual meal, weekly draft, sent copy, confirmed order and actual fill independently. Apply against the reviewed base once. An edit to a submitted order remains a proposed amendment until confirmed by the retailer.

### F04 · Price evidence

**All money figures** · B03 · S03 S05 S07 S11

Attach store/mode/slot/time/eligibility source and charge basis to observations. Separate expected, hold, pending, posted, included credit and top-up; never add a net credit twice.

**Accept when.** Attach source, store, time, mode, slot, eligibility and included charges. Keep estimates, holds, posted charges, credits and top-ups distinct. $37.20 posted with a $2.40 pending credit still shows $37.20 paid. A net charge retains an included credit once.

### F05 · Offline and sharing rights

**All sharing and offline writes** · B06 · S19 S21 S23 S24

Keep auth principal, household membership, role epoch, one-shop grant, planning seat and retailer authority distinct. Recheck them server-side on every read or mutation.

**Accept when.** Separate membership, link scope, editing and retailer action. Limit each shop to one active shopper. An authorized handover transfers that role. A forwarded note conveys information only. Retries deduplicate by operation while distinct real purchases survive.

### F06 · Language and access

**All languages and assistive access** · B01–B10 · S02 S10 S20 S22

Use string catalogs and web locale catalogs, formatters and layout direction. UI language, original text/units, recipient language and transaction currency have separate scopes.

**Accept when.** Separate interface and recipient language from original food wording, units, currency and store region. Exercise long text, RTL layout, plurals and spoken labels. A US Spanish message preserves no-salt, pack size and USD.

### F07 · Storage and recovery

**All local records and exports** · B05 · S10 S20

Identify files by origin, revision, projection, format and canonical digest. Use bounded decoding, staging and transactions. Keep conflicting revisions as siblings; identical retry reopens the earlier copy.

**Accept when.** Version and migrate structured files with stable identities. Preview selected media and recovery scope. Reopening an identical source and revision finds its existing copy. A malformed file leaves local records intact and support needs no full receipt.

### F08 · Connections and operations

**Offline baseline and online household service** · B06–B07 · S06 S21 S24

Queue client operations with stable actor-scoped keys and synchronize authoritative revisions. Show local save, waiting, conflict, server received and retailer report as distinct states.

**Accept when.** Distinguish copying a list, syncing a request, saving a family decision and reporting an order placed. A failed sync retains a retryable local draft. A copied list never confirms an order.

### F09 · Purchase and measurement

**All billing and measurement** · B08 B11 · S18 S19

Verify Apple transactions on the server for shared service, dedup notifications, reconcile restore and seats separately. Never restore authority or consent from a receipt or file.

**Accept when.** Keep consent, eligible weeks, comparison baseline, membership and Apple billing separate. Exercise pending, restore, grace, cancellation, expiry and refund. A second device or refunded sale cannot count as a second willing household.

## Household planning

### P01 · Usual dinners and rotations

**Household, with one reusable dinner free** · B08 · S13 S14 S25

Clone chosen nights of approved versioned templates into weekly occurrences. Modify only this week unless an authorized adult explicitly changes the template. Support pins and rotations.

**Accept when.** Select multiple familiar dinners or selected nights of a rotation. Preserve dish-specific rules and overrides. Editing Wednesday in this week's copy leaves the next ordinary week intact. Compare total effort with reusing the family's existing template.

### P02 · Pair dinners across the pack

**Household or isolated preview** · B08 · S14 S15

Enumerate approved unscheduled candidate dinners and confirmed leftovers; solve whole-pack and time constraints, reprice entire basket and compare the same mouths and lunches. Explain which pack changed.

**Accept when.** Pair familiar meals using unreserved food. Include all other ingredients, packs, fees, accepted portions and prep time. The three-pepper example must cover lunches in both alternatives before reporting a checkout change.

### P03 · Adjust people and plans

**Household automation, free manual edits** · B08 · S16 S17 S25

Apply guest/away/plate deltas to the occurrence and serving groups. Recalculate all dependent packs/fees. Show isolated preview, give free manual editing an equivalent path.

**Accept when.** Adjust guests, nights away, vegetarian plates, lunches or sides. Preview the smallest change and cost. Moving from eight to nine needed wraps triggers a second eight-pack for review and preserves the lunches.

### P04 · Recover tonight's dinner

**Household suggestions, free manual repair** · B08 · S08 S09

Evaluate only confirmed household-accepted fallbacks against actual yield, exclusions, prep time and reservations. Show one feasible repair and smallest top-up; ask before an extra trip.

**Accept when.** Filter the family's accepted meals against actual fill, confirmed yield, time, exclusions and protected portions. With an unavailable ingredient, show a feasible top-up or leave the need open. Compare time to using the household's usual fallback.

### P05 · Prepare the next trip

**Household assisted review, free open deferrals** · B08 · S01 S12

Use prior reviewed needs, purpose, store and disposition to suggest next-trip work. Reprice only after user selection. Another person buying an item can close its obligation.

**Accept when.** Recall previously approved staples by purpose and store, then ask what is needed this trip. A month-old checked market item stays checked until reopened. Count re-entry time alongside prompts and duplicate purchases.

### P06 · Show what changed since sending

**Household automated comparison, free dated copies** · B08 · S06 S10 S17

Compute additions/removals/unresolved against last intentional send for that shop and helper. Report acknowledgment separately; send a full instruction if destination is uncertain.

**Accept when.** Compare adds, removals and unresolved items against the last intentional handoff to this recipient. A stale edit requires review. If a prior message may have gone elsewhere, the correction includes the full current instruction.

### P07 · Family decision history

**Household history tools, free access to saved records** · B08 · S12 S14 S20

Query completed decisions by dish, product and occasion. Show actual/unknown and temporary/permanent separately. Promote a one-shop preference only on explicit action.

**Accept when.** Find past dish-specific approvals, exclusions and what actually happened. Missing outcomes stay unconfirmed. Retaining an emergency substitute as a lasting preference requires the household's explicit choice.

### P08 · One household offer

**One Household entitlement for two named adults on supported iPhones** · B08 · S18 S19

Map verified product to one household and up to two named adult seats. Provide restore, manage, transfer/revoke seat and entitlement status. Preserve free data access on lapse.

**Accept when.** Show the actual localized annual StoreKit price and renewal terms, Apple confirmation, manage and restore. The US $49.99 figure is a test assumption only. Verify second-seat access and recovery. Pending purchases do not activate tools. After expiry, records open and export and one dinner remains reusable. A seat grants no automatic shop access. Renewal or restoration cannot create a third active seat; a child cannot occupy either seat.

## Import, access and connections

### E01 · Bring a recipe library

**Free manual entry and staged file import; assisted multi-dinner reuse requires Household** · B05 · S02 S14 S20

Implement versioned RecipeImport adapter with a documented Recipe JSON-LD file profile (Recipe objects and graphs). Stage title, yield, note, ingredient strings and source; report unsupported shapes; support one-batch rollback.

**Accept when.** Import one documented recipe-library file format with title, servings, source, notes and linked needs. Preview matches, duplicates and skipped rows, then undo the entire batch. A malformed file must preserve existing meals.

### E02 · Photo and scan

**Free optional capture with supported camera, photo picker or local recognition** · B09 · S02 S04 S08 S14

Opt-in camera/photo picker plus on-device OCR/barcode parsing. Stage source image/reference, uncertain fields and receipt lines. Unknown barcode requires manual match. Review cannot auto-certify a price, receipt or safe ingredient.

**Accept when.** Attach a package reference photo. Offer reviewed recipe OCR, barcode identification and receipt-line capture. Preserve original text/image for comparison, flag unreadable quantities and allow typing. A low-light bilingual capture can be corrected without confirming a price or marking an item received.

### E03 · Current shared view

**Free scoped online shared view, separate contributor and shopper grants** · B06–B07 · S10 S20 S21

Offer authenticated one-shop read projection and separate editor grant. Scope each field/record, expire/revoke online, show as-of on cached/exported copies. Submit proposed edits for shopper approval.

**Accept when.** Share a revocable, expiring current view for one shop on iPhone or Android/browser. A separately authorized editor reviews conflicting stale changes. Keep one active shopper. A contributor sees only their own requests. Revoking a link blocks fresh reads and edits. Label offline copies with their save time.

### E04 · Spanish handoff and interface

**Human-reviewed US English and US Spanish strings, help and purchase copy** · B01–B10 · S01 S10 S18 S22

Ship reviewed en-US and US Spanish across help, purchase, voice, errors, validation and handoffs in both directions. Preserve original text, units and store quantities on every locale change.

**Accept when.** Support handoffs in both language directions and the full core and subscription flows in US Spanish. Preserve original item text and allow edits. Check pack count, local date, exclusion and amount due with speakers of both languages, including after a locale change.

### E05 · Confirmed retailer connection

**Deferred integration, outside the first release** · Later · S06

Isolate the retailer adapter and capability ledger. Launch ships copy/share and user-open only. Before an official cart-write rollout, prove scopes, permissions, local price/fill limitations, idempotent add and response verification.

**Accept when.** Keep the historical ID to preserve the decision trail. The shipped handoff is copy or share of shopper-reviewed household lines and user-directed checkout. No provider credential, integration or live retailer access is a release prerequisite.

### E06 · Pantry and freezer carryover

**Free manual entries; assisted pairing requires Household. Optional household-entered storage and batch details** · B04 B08 · S04 S08 S12 S15

Store household-entered pantry/freezer lots, confirmed yield, observation time, reservations and use-first preference. Carry over only what has been confirmed; never create leftover servings from a theoretical remainder.

**Accept when.** Record a dated pantry or freezer batch, usable quantity, reservations and a use-first hint. Confirm before carrying food into a dinner. Five portions cannot cover four dinners and two lunches. A correction updates dependent meals once.

### E07 · Faster shopping access

**Free supported iPhone surfaces, with privacy and accessibility checks** · B09 · S02 S06 S20 S22

Store-scoped aisles, manual sort, dictation, locked-safe widget/App Intent, share extension inbox and print layout. Reuse domain actions. Extension cancellation must not create a confirmed line.

**Accept when.** Provide store labels, aisle grouping, keyboard dictation, a scoped widget, selected-text share extension and large-print list. Compare finding one item across long lists. The locked widget hides budget/private notes and a cancelled share import leaves the draft intact.

### E08 · Optional reminders

**Free, explicit notification permission** · B09 · S07 S12 S20

Schedule local notices for explicit deadlines or deferrals. Store time zone, expiry and quiet hours; cancel/reschedule on edit or revocation. Open current state and re-evaluate expired offer.

**Accept when.** Choose a specific deferral or offer deadline, local time, quiet hours and expiry. A delayed notice after cutoff opens Await pickup. Turning reminders off leaves the ordinary shop usable.

### E09 · Price and budget history

**Household history and period planning, free current-shop budget preview** · B08 · S03 S05 S11 S20 S27

Keep observed price history by pack/store/channel plus optional period envelopes and allocations. Reconcile pending vs posted; display remaining as conditional if shops are incomplete.

**Accept when.** Review household-entered prices by store and mode. Reserve future shops in an optional pay-period envelope. Distinguish warehouse from web, deferred spend from savings, and incomplete periods from verified balances. Restrict budget and payment information to authorized adults.

### E10 · Other surfaces and markets

**US launch coverage, mobile web on supported browsers, market-by-market release checks** · B07 B10 · S10 S21 S22

Serve responsive contributor and one-shop cook views on supported iPhone/Android browsers. Do not expose a native adult account to helpers. Validate each market independently before enabling it.

**Accept when.** A helper on Android/browser can receive instructions and submit, inspect or withdraw their own request within shop rules. Gate specific chain, language, currency, unit and market claims on local checkout fixtures and support. Test the mixed-phone task without a native companion or adult account sharing.

## Gen 15 additions

### N01 · Family request inbox

**Free on participating phones, including invited kids with the appropriate guardian setup** · B07 · S21 S22 S23 S24

Redeem a narrow invite, receive reviewed requests, clarify/link/add/defer/dismiss. Keep each author's receipt. Freeze current basket at checkout, route late writes by server state and require authority/revision checks.

**Accept when.** An invited author types or speaks, reviews and submits. Only the active shopper may merge, add, defer or dismiss. Show the shopper the full-budget preview first. Locking for checkout protects the basket. Placement routes new and undecided requests to Next shop. Deduplicate retries. Contributors receive only their own request status and no budget or payment fields.

### N02 · Structured speech entry

**Free request entry, optional speech with a typed equivalent** · B09 · S02 S22

Optional on-device speech captures a bounded draft. Parse item/count/unit/pack/purpose/destination, distinguish negation and ambiguity, review material amounts, then send precisely once or cancel.

**Accept when.** Preview item, pack count, amount and destination. Correct one field. A contributor confirms a request only. For the shopper, selecting Apply can update the local planning draft. A retry affects the intended record exactly once.

### N03 · Dinner readback

**Free, optional on-device playback where supported** · B09 · S10

Render a current dated instruction and request playback of that exact projection. Pause/stop/repeat, stop on route change, avoid overlapping VoiceOver, require user action to resume.

**Accept when.** Read the selected current cooking instruction with pause, stop and repeat. Use confirmed usable quantity and reservations, keep the dated text visible and omit private budget by default. VoiceOver and readback must not talk over one another.

### N04 · Product-name corrections

**Optional, device-local and editable** · B09 · S02 S20 S22

Device-, profile- and locale-scoped correction records. Offer a spelling after an explicit correction; preview on future matches, delete or opt out. No rewriting old requests.

**Accept when.** After the user corrects a recognized product name, offer to remember that correction. Show it for review at the next matching entry, preserve original wording and let the user forget it without changing past records.

### N05 · Source on manual recipe

**Free manual recipe entry** · B05 · S14 S26

Save a user-entered source URL and original recipe data independently. An optional URL is attribution, not a network fetch or license. A missing site never invalidates the dinner.

**Accept when.** Paste an optional source URL alongside the family's own meal title, servings and notes. A failed import or vanished page leaves the editable dinner and its weekly allocations intact.

### N06 · Recovery comparison

**Free record and backup recovery** · B05 · S20

Compare source namespace, immutable revision, parent and projection. Preserve unrelated/newer records on Cancel or restore. Never use backup ownership as an authentication signal.

**Accept when.** Compare the selected backup's source, date, revision and affected records with newer local work. Preview which records match, conflict or are absent, then recover separately. Cancelling or importing a corrupt file makes no changes.

### N07 · Spoken guest preview

**Household guest automation or isolated preview, free manual guest edit** · B09 · S16 S17

Route a guest utterance to an identified meal/count proposal. Use the identical planner as manual editing, expose pack and cap changes and check current authority before Apply.

**Accept when.** Say one more guest, confirm which meal and count, then review pack, protected lunch and checkout effects on screen. Cancel discards the preview. Apply once creates a draft revision, and any order amendment still needs retailer confirmation.

## Owner-approved additions

### A01 · Household meal-week calendar

**Free manual planning; Household assisted changes** · B10 · S25 S14 S16

Build an adult-only seven-day view of meal occurrences, servings, away nights, guests, sides and protected lunches. Move or edit an occurrence as a proposal. Reuse the same guest and reprice operations as S16.

**Accept when.** Move Thursday's dinner across a local date boundary. Lunches and other meals remain intact; the original rotation is unchanged. A contributor cannot read the week.

### A02 · Editable dinner ideas

**Free suggestion and manual review; Household assisted pairing** · B10 · S26 S14 S15

Produce an editable candidate using app-owned templates or household-approved variants. Show source, quantities, yield, time, assumed extras and exclusions. Accept into library, then separately schedule, then explicitly apply a shopper-approved change.

**Accept when.** An unknown yield prevents a coverage claim. Editing or discarding an idea makes zero basket changes. Reject an excluded ingredient; approving a corrected idea does not yet schedule it.

### A03 · Compare two entered store quotes

**Free manual comparison; adult with budget scope** · B10 · S27 S03 S05

Branch two private quote scenarios from one commitment set. Record package/availability, quote freshness, fees and mode per store, incremental travel money and time. Label incomplete alternatives; choose one to preview adoption. Keep store price and trip money separate.

**Accept when.** A cheaper shelf basket becomes more expensive after its extra trip. Missing fee leaves the winner unknown. Adopting a quote invalidates stale offers and cannot change an already placed order.

## Product boundaries

### X01 · Grocery marketplace and delivery

**Excluded** · Boundary · S06

Use retailer-directed checkout and truthful handoff states. No payment, fulfillment or marketplace service.

**Accept when.** The shopper completes payment, slot selection and ordering with the retailer. Copy and share never create an ordered or delivered state.

### X02 · Universal deals and store routing

**Excluded** · Boundary · S05 S27

Keep universal discovery/routing out. The approved A03 only compares two shopper-provided, explicitly scoped alternatives.

**Accept when.** S05 compares same-shop checkouts. S27 may compare two explicit shopper-entered store quotes and incremental travel costs. The app never presents a universal deal, silently fetches stock, recommends an automatic route or places a second order.

### X03 · Medical or allergy decisions

**Excluded** · Boundary · S07 S09 S26

Never infer medical suitability; enforce entered exclusions and send ambiguous ingredients for review.

**Accept when.** Respect household-entered hard exclusions and let the family decline any replacement. A scanned name or translation cannot certify allergen safety or suitability for a medical condition.

### X04 · Broad generated recipes and nutrition coaching

**Excluded** · Boundary · S14 S26

Use A02 reviewed suggestions; keep free-form authoritative nutrition or medical guidance outside the product.

**Accept when.** Offer approved meals and manual entries. Leave a need open when none fit. No generic recipe generation, nutrition targets, diet coaching or calorie dashboard.

### X05 · Social feed and family calendar

**Excluded** · Boundary · S21 S25

Use A01 for the private adult meal week. Do not build social, school or chore feeds.

**Accept when.** Record an away night or guest against the meal. A contributor request stays private to its authorized participants. No social feed, school schedule or full family calendar.

### X06 · Mandatory scanning and credential scraping

**Excluded** · Boundary · S02 S06 S08

Provide optional camera and official external open, keep typing viable, never collect retailer login secrets.

**Accept when.** Complete a shop by typing and manual retailer review with camera access denied and no retailer password in the planner. Optional scan review and official shopper authorization remain distinct routes.
