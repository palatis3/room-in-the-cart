# S01–S27 Check acceptance ledger — bounded traceability draft

All **27 verbatim Check paragraphs** are accounted for as **123 explicit acceptance clauses** under the documented conservative splitting rules in `ledger.json`. This is a complete mapping of those paragraphs, **not a complete acceptance audit or UI-state count**. The 27 contracts overlap the earlier 20 supporting destination types; they are not 47 distinct screens. No defensible total of every reachable UI state follows from either count.

The classification is deliberately bounded:

- **15 proven-in-scoped-run:** inspected outcome assertions tied to exact per-selector passes and frozen test-source hashes. Some are model/synthetic proofs, not physical UI or provider acceptance.
- **1 contradicted-current:** S06 cancelled system share has an ordinary pass but a retained 804 Reduce Motion failure before Close completed. This is a failed acceptance variant, not proof that the frozen basket mutated or proof of a wrong-button cause.
- **103 indirect-or-unmapped:** **75 partial retained mappings** and **28 source-only mappings** awaiting exact execution/assertion binding. No clause in this group is wholly without a named related selector. This is not 103 missing features, 103 broken outcomes, or 103 outcomes without existing acceptance evidence.
- **4 owner-or-human-external:** empty-retailer-cart return, Android human cook task, physical VoiceOver/audio ordering, and actual second-device reinstall/restore. Other clauses also retain external scope limits; four is not the total number of release gates.

## What is pinned

The ledger contains full source quotes and sentence indexes, actual implementation entry paths/lines and hashes, exact named selectors and source lines, per-selector retained results where bound, limitations, and current route-map references. The native result binding uses core run **42272379454 attempt 1**, exact **804030e68473d022e72b464940061c01c611a0bd**, iPhone 17 arm64 simulator / iOS 26.2 (23C54) / Xcode 26.3 (17C529). Current production source hashes and older frozen test hashes remain distinct.

The retained terminal audit also records **389 package passes and 3 declared native-wire skips**, including **171 CoreDomain passes**, for ordinary packages and each address/thread sanitizer run. This draft does **not** bind those package cases or shared JSON vectors, real PostgreSQL service runs, dedicated fixture/billing runs, and older accepted runs to every clause. S03–S17 in particular have substantial math/stock/domain coverage outside the 601 app model cases. This is an explicit mapping limitation. Binding that evidence should precede proposing new tests or implementation.

Current web/service selectors are source-only here. Existing Android synthetic evidence remains related and scoped; neither it nor DOM tests establish actual SMTP/KWS activation, human comprehension, or live mixed-phone acceptance. Owner-deferred Apple/SMTP/KWS and physical/human release gates remain unchanged.

## Per-contract mapping

P = scoped proof; C = retained contradiction; I = partial/source-only; E = external.

|Contract|Clauses|P|C|I|E|
|---|---:|---:|---:|---:|---:|
|S01 Start or resume|3|0|0|3|0|
|S02 Bring the list|4|0|0|4|0|
|S03 Describe this pickup|3|1|0|2|0|
|S04 Inspect an ingredient|4|0|0|4|0|
|S05 Compare checkout choices|4|1|0|3|0|
|S06 Prepare the retailer handoff|5|2|1|1|1|
|S07 Review a store offer|4|1|0|3|0|
|S08 Record what came home|5|0|0|5|0|
|S09 Repair the meal|3|0|0|3|0|
|S10 Tell the cook|5|1|0|2|2|
|S11 Close the pickup|3|0|0|3|0|
|S12 Start the next shop|5|0|0|5|0|
|S13 Choose a way to plan|3|0|0|3|0|
|S14 Choose familiar dinners|3|0|0|3|0|
|S15 Pair dinners across a pack|3|0|0|3|0|
|S16 Add a guest|5|0|0|5|0|
|S17 Apply and explain a revision|3|1|0|2|0|
|S18 Decide on Household|4|1|0|3|0|
|S19 Manage the two seats|6|1|0|4|1|
|S20 Find records and recover files|6|0|0|6|0|
|S21 Invite and manage household contributors|6|0|0|6|0|
|S22 Ask the shopper|5|0|0|5|0|
|S23 Review family requests|4|1|0|3|0|
|S24 Choose this pickup or the next|8|1|0|7|0|
|S25 Plan the household meal week|8|1|0|7|0|
|S26 Review a dinner idea|6|0|0|6|0|
|S27 Compare two entered store quotes|5|3|0|2|0|

## Useful next decisions

1. **Bind existing package/service evidence first.** The source-only exact arithmetic, allocation, replay and authorization cases should not be reinvented because this draft has not joined their run logs to assertions.
2. **Inspect narrowly unmapped compound outcomes:** S02 cancelled share-import plus filtered-list/position preservation; S04 hidden-lunch presentation invariance; S07 no new fee after short-fill; S14 successful library-import undo preserving unrelated records; S22 browser history privacy. Related tests cover pieces; the ledger states exactly which pieces do not yet establish the whole clause. None is a confirmed missing implementation.
3. **Keep current failures distinct.** S06 Reduce Motion is directly relevant to its Check. UI06 saved-offer reminder and UI07 Next-shop setup failures are recorded separately because their failed actions do not directly contradict S07/S12 Check outcomes. No pending diagnostic outcome or causal fix is inferred.
4. **Keep human/provider work explicit.** Do not promote model, simulator or synthetic Android evidence into physical assistive-access, human Spanish/Android handoff, real retailer return, actual Apple or live guardian/service acceptance.

## Integrity and reproduction

`validation.json` records passing offline ledger checks: all 27 IDs/full paragraphs, all source sentences assigned, quote/source correspondence, exact selector lines, unique retained result nodes, and source/evidence hashes. It checked **131 distinct mapped selectors and 96 hashed input files**. These are ledger integrity checks, not new product tests or semantic proof generated by a script. Assessment prose remains the reviewer’s judgment.

From the main repository, the scratch-only commands are `python3 .build/ScreenAcceptanceLedger20261106/build_ledger.py` then `python3 .build/ScreenAcceptanceLedger20261106/validate_ledger.py`. Regeneration repins current files and must be reviewed if inputs changed. `input-manifest.json` pins the inspected source/evidence; `manifest.json` pins this delivered package.

No tracked changes, Git, native/browser/network/hosted operations, test execution, or raw Records/media access occurred. Root review is required before any tracked publication or coverage claim.

## Root integrity review and snapshot limits

Root independently verified all six original package hashes and 96 input hashes, then replayed the verifier on copied inputs. The two inputs changed during follow-up work (`CURRENT-ACCEPTANCE.md` and `LedgerIngredientView.swift`) were restored in that copy from `6f1b4e4`, matching their original pinned hashes. Original evidence was unchanged. All 27 paragraphs, 123 clauses and 131 selectors passed those integrity checks. This is a historical mapping snapshot before the protected-need visibility fix, not current pass/fail coverage for every requirement. It remains a bounded traceability draft; the existing package/service proof needs further binding before using classifications to prioritize new tests.

## Subsequent evidence binding

The [S14 whole-batch undo addendum](s14-undo/README.md) binds existing exact-804 native assertions and a per-case pass to S14.02. Root reviewed its assertions and rehashed all 22 referenced inputs. With that scoped addendum, this snapshot has 16 scoped-proof clauses and 102 indirect/unmapped clauses; no new product test was required and no broad release acceptance is implied. The original ledger JSON remains unchanged for provenance.

The [S07 short-fill fee addendum](s07-short-fill-fees/REVIEW.md) binds four existing exact-804 model passes to retained-charge arithmetic, short-fill settlement, separate top-up costs and scoped trip consent. Root verified the retained result nodes, unchanged test method bodies and principal source hashes, and inspected the receipt/usable/settlement mutation paths. No new fee defect was found. This adds scoped evidence without promoting the entire clause or the original ledger totals to complete acceptance; exact before/after quote identity and real retailer billing remain outside those assertions.

The [S22 browser-history privacy addendum](s22-history-privacy/REVIEW.md) binds 17 existing passing web/service assertions and scoped Android observations to current source. Root rehashed 33 inputs and 11 source bindings. Own-request projection, actor changes, revocation and sign-out protections have scoped proof; actual Back/Forward/BFCache transitions after authority changes remain unverified. This adds existing evidence without closing S22.05 or asserting a newly discovered privacy bug.
