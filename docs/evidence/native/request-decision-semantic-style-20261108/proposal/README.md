# S24 combined semantic style proposal — not installed

This scratch-only, two-file patch makes the decision Form use the existing WorkingForm and assigns HouseholdDecisionFact values explicit semantic roles. It does not alter fonts, layout modifiers, labels, state, bindings, actions, authority, consent, calculation or persistence. Root's current native source remains untouched. Installation waits for review after that frozen run.

## Requirement and implementation

APP-BASELINE's appearance contract requires the spruce/linen canvas, surfaces and text. Foundation2.1 `04-design.md:13–16` assigns list/sheet surfaces to surface, money/quantities/essential state to ink, and source/store/update metadata to secondary. Existing `Theme.swift:17–29,111–113` already implements those surface/text roles in WorkingForm.

1. `HouseholdRequestDecisionView`: replace only its root `Form` with `WorkingForm`; existing content and modifiers stay intact. This supplies Theme.surface rows, Theme.canvas background and Theme.ink foreground through the established component.
2. `HouseholdDecisionFact`: add nested `ValueRole` with essential/metadata and a computed semantic color. Its initializer defaults to essential→Theme.ink. Existing LabeledContent, combined accessibility, lineLimit and fixedSize remain identical.
3. Mark only Shop revision, Quote recorded, Quote expires and Preview expires with `valueRole: .metadata`, retaining Theme.secondary. The already-secondary meal-coverage guidance remains unchanged.

## All caller sites inspected

| Group | Calls | Role |
|---|---:|---|
| Main preview: expected total, over cap, scope, before total, cost change, cap and cap scope |7|essential ink|
| Included charges: retailer fee, fee threshold, fee below/above threshold, tax, deposits and discounts |7|essential ink|
| Nested before/after budget component: scope, expected total, over cap, remaining within cap |4|essential ink|
| Protected portions / Portions in meal facts |1|essential ink|
| Shop revision, Quote recorded, Quote expires, Preview expires |4|explicit metadata secondary|

`caller-map.json` lists every one of the23 call sites with original file, line and expression. The19 essential expressions remain byte-identical; only four metadata calls gain a parameter. The helper signature and foreground selection are the only changes inside the helper. No generic replacement of all secondary text is proposed.

## Bounded validation after root installation review

`existing-selectors.txt` names three unchanged cases:

- `testCerealCheckoutAndTwoProtectedLunchesAreVisibleTogetherAndCancelDoesNotWrite`: one-viewport37.20/40.69/2.69 and both named protected lunches; pixel-luminance assertions≥4.5:1 for40.69 and coverage guidance; Cancel/no-write and revoked-scope checks.
- `testShopperOpensCheckoutCalculationsAndIncludedChargesWithNoDecisionWrite`: disclosure reachability, exact revision/fee/tax/deposit/discount labels, disabled Apply without overage consent, Cancel and no writes.
- `testLargestTextShowsCompleteProtectedLunchNamesAndDates`: internal AX5 override, complete named lunch/date/portion wording, font-derived height checks, review-action capture and zero writes.

Initial proposal: these three cases on current owned iOS26.2 in light, then dark—six scoped executions, serial, existing limits/assertions. Standard cases use Large; AX5 case sets its own size. Preserve screenshots/AX and original failures. Review actual row/canvas colors and essential/metadata roles; the existing numerical contrast assertions do not cover every fact or metadata label.

Minimum-OS followup can use the cereal/readability and AX5 cases in both appearances—four executions. The existing calculation-details case sets `OS_ACTIVITY_MODE=disable` belowiOS18. Do not call its result warning-clean or silently treat it as unmuted; if separately selected there, label it functional-only. This proposal adds no suppression and prepares no new runners or audit variants.

Metadata date fields and the two original heading contrast targets are not guaranteed present in retained existing captures. Root must review available evidence and separately authorize bounded target captures if needed. Keep Apply disabled without consent; no new consent/write action is introduced merely to measure color. Check increased-contrast rendering separately if the existing evidence does not cover it.

## Limits and checks

The original41 audit findings remain tracked. The four contrast reports have no measured color pair/ratio: one is unattributed, two headings were reported near navigation chrome, and Apply was explicitly disabled. Neither this patch nor a passing existing journey proves those reports resolved. Essential/secondary token pairs already exceed4.5:1 against contract surfaces; this is a semantic-role correction, not a claim that every previous pixel pair failed.

`git apply --check semantic-style.patch` passes against the pinned canonical source. No Swift compilation, native run, new audit or product installation occurred. `preparation.json` retains base/candidate hashes and scope. The original one-line proposal remains unchanged alongside this combined proposal.
