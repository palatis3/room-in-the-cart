# Current unfiltered audit:41 exact reports reconciled

Native65 / strict1 remains the result of the **first actual fresh native audit attempt**. The earlier runtime setup attempt stopped before testing because it selected the first of two same-identifier runtime records (23C52). R3 bound the already booted runtime by SIMULATOR_ROOT and SystemVersion: iOS26.2/23C54. Explicit settings were English/light/standardLarge/increased-contrast disabled; original increased-contrast parity is unknown. Source and original result remain unchanged after this collection (independent file hashes verified).

## Bounded collection and correlation

Only `xcresulttool export attachments --filter '*.txt'` was run, with the exact single test ID and **inspection/native.xcresult COPY** as input. Export contains84 text attachments (41 custom issue reports,41 automatic descriptions,2 teardown diagnostics) plus manifest: approximately123KB including initial logs,87files, below20MiB/200files. No screenshot/video or unfiltered export occurred. All seven reports without an element remain unattributed; collection did not broaden to guess their targets.

`findings.json` and `findings.csv` contain all41 issues with full issue-time target Attributes, original text-file hashes, category and rawlog line. Timestamped custom attachments correlate with exactly one attachment event before each error; timestamp-minus-consoleelapsed offsets differ by only0.01s. Automatic Complete Issue Description entries lack timestamps; their description multiset agrees, but no invented one-to-one automatic-description mapping is used. `original36-crosswalk.csv` preserves each prior finding separately, matching category + type + full label + parent identity for duplicate quantities/scopes. No ordinal-only match.

## What changed—and what did not

- **27** named target/category pairs recur.
- **2** known targets appear in a different category: old#2 After this decision now contrast issue3; old#22 preview Add packs to this shop now contrast issue2. Their old DynamicType findings are not observed in this run, but the target still has a finding.
- **5** named finding records concern the two bottom actions: Apply reviewed decision contrast/unsupportedDynamicType/clipping (#4/#6/#40), Cancel preview unsupportedDynamicType/clipping (#20/#39). These same action/category combinations were already present in the earlier pre-grouping baseline audit; they are not five established product regressions.
- **7** new reports lack a public target (#1,#8,#11,#13,#15,#22,#41):1contrast,3partialDynamicType,2unsupportedDynamicType,1clipping. Do not match them to the old four unnamed reports by generic wording alone.
- Old#27 Review before applying DynamicType and old#34/#35 review button/heading contrast are **not observed in this run**, not declared fixed. Old four unnamed findings remain unmatchable. No acceptance gate is waived.

The current total is4contrast +29partialDynamicType +4unsupportedDynamicType +4clipping. A41−36 count delta is not a regression count. Previously captured correct growth/complete labels coexist with recurring audit findings; neither evidence source is discarded.

## Next actionable target: Cancel preview, paired with Apply

The exact current source places these as **separate normal Form Button rows**, HouseholdInboxView.swift227–229. No local HStack, fixed font or fixed height explains a defect. Apply is intentionally disabled by `!model.canApply` pending overage consent; all three issue-time Apply reports explicitly say **Disabled**. Cancel preview has no Disabled marker, but this collection did not separately sample `isEnabled`.

Retained issue-time geometry is stable across categories: Apply[16,692.7,370,52], Cancel preview[16,744.7,370,52], each in its own same-size Cell and within CollectionView[0,62,402,812]/Window[0,0,402,874]. These normal/Large frames do not show present frame clipping and do not establish behavior at a larger category. The current same-audit navigation report30 records Review request bar[0,78,402,54]; it is not a simultaneous ancestor/pixel capture for earlier findings. Add-preview contrast frame[16,30,370,52] and After-heading[32,97,144.3,20.3] raise a chrome/occlusion attribution concern; no issue-time screenshot was exported or viewed, so no color defect is inferred. The original audit-boundary screenshot is recorded before the first callback, but its pixels were not accessed here.

For disabled Apply, root verified the primary [W3C SC1.4.3 inactive-component explanation](https://www.w3.org/WAI/WCAG22/Understanding/contrast-minimum.html#inactive-user-interface-components): inactive controls are exempt from minimum contrast. That informs this exact observed Disabled state; it does not exempt DynamicType/clipping, establish an enabled-state result, or change XCTest's failed outcome. No contrast tweak or audit suppression is justified from finding4 alone.

The smallest next decision is **target proof for Cancel preview DynamicType/clipping (#20/#39), with Apply #6/#40 alongside in its intended disabled state**. First compare the already retained AX5 action screenshot/ordinary largest-type test against these exact current rows. If that cannot resolve their rendered behavior, root can review a separately bounded target-only visibility/size probe in the same synthetic cancel/no-write journey. Do not consent, Apply, add retries or alter typography before evidence demonstrates a defect. No new screenshots or reruns were performed or automatically scheduled here. The nil-element reports require separately reviewed issue-time attribution if they remain necessary; they are not reasons for a blanket artifact export.

See `action-targets.json` for exact ancestor lines, source hash/line, state observations, geometry limits and the narrow standards disposition; `receipt.json` binds runtime/setup/collection/preservation receipts. The original failed audit and all earlier failures remain intact.


Public copy scope: this folder retains the bounded ledger, raw failure categories and verification receipts. The complete84 text attachments and original completed result remain private under `.build/RequestDecisionAccessibilityNov08/current-unfiltered-r2/run-r3/`; their source hashes are retained in the ledgers. No screenshot or video export was needed for this reconciliation.
