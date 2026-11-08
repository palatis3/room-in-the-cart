# Request decision semantic styling · 2026-11-08

Three selected journeys pass native and strict **3/3 in light and 3/3 in dark on iOS 26.2**, using the exact two-file semantic-role correction. Six named PNGs per appearance (12 total) were exported and visually reviewed by root. Both examined XCTest exports record zero runtime warnings; the light 2,218-line and dark 2,003-line consoles record zero animation-idle messages and zero runner restarts. These are bounded observations, not proof of lossless logging. Dark qualification is completed below. The identical final source also passes unsigned arm64 iPhone Release compilation and bundle checks.

This change is **not closure of the 41 accessibility-audit findings**, a whole-app acceptance claim, physical VoiceOver verification, or new minimum-iOS17 styling qualification.

## Requirement and source scope

APP-BASELINE's “How the product should feel” and Foundation2.1 `04-design.md:13–16` require the spruce/linen semantic palette: canvas behind working surfaces, surface for sections/sheets, ink for money/quantities/essential state, and secondary for source/store/update metadata. Source hashes and exact reference paths are in `source/scope-verification.json`; the retained proposal contains the complete caller map.

- `HouseholdRequestDecisionView` replaces its root Form with the existing `WorkingForm`, supplying semantic row surfaces, canvas and ink. Existing content, actions, state, authority and surrounding modifiers remain.
- `HouseholdDecisionFact` adds an essential/metadata value role. Its 19 essential call sites default to `Theme.ink`; only Shop revision, Quote recorded, Quote expires and Preview expires explicitly use metadata/`Theme.secondary`.
- Existing LabeledContent layout, typography, combined accessibility, line limits, fixed sizing, consent gates and business calculations remain unchanged. This is not a blanket replacement of secondary text or a token redesign.

`source/change.patch` is the exact installed two-file diff. `source/fixed-source-manifest.json` pins all 556 iOS files; every file was checked against the frozen current source during publication. Both changed product-file hashes match the reviewed proposal candidates. The final manifest SHA-256 is `ad32a9a313a2f2763c9513adaa62513800d48ceaad1145d8cf66205ed9af6ff1`.

`proposal/` is copied verbatim, including its historical “not installed” status and proposed later checks. The completed light receipts establish subsequent installation and execution; future proposal checks are not treated as completed.

## Completed light checks

| Selected existing case | Result | Seconds |
|---|---|---:|
| Cereal checkout and two protected lunches visible together; Cancel does not write | Passed | 57.43 |
| Checkout calculations and included charges; no decision write | Passed | 69.13 |
| Largest text: complete protected lunch names and dates | Passed | 106.85 |

The first two use standard Large text; the largest-text case sets AX5 internally. Exact selectors, run command, runtime, source identity, preservation checks and strict outputs are under `light/`. The run summary is a bounded projection with the original private full-run SHA-256; its huge product inventory is omitted. No retries, suppression, assertions or test allowances were added by this styling change.

The six original PNGs and their export manifests retain UUID filenames under `light/captures/png-*`. `captures/receipt.json` maps exact names, case identities, timestamps, payload IDs and hashes. Its historical pending-review field is superseded by the later copied `captures/root-review.json`.

Root observed the standard review's $40.69 expected total, $2.69 overage, $37.20 before amount, $38 cap and both protected lunches together, with essential values in ink and preview time secondary on white/linen surfaces. The itemized capture shows revision/quote metadata secondary and charge/discount/before-after amounts in ink. AX5 captures separately show the complete Sam/Mia lunch names, dates and protected portion; adjacent offscreen content is not all visible in one image. Review actions wrap; disabled Apply remains dimmed. The access-ended fixture capture shows no private context and zero writes; fixture chrome is outside product-style qualification.

These images were displayed resized from 1206×2622 to 942×2048. They are visual evidence, not a new pixel-contrast audit. Existing case contrast assertions cover their defined samples, not every value, metadata field or original audit target. Disabled Apply is not being declared a contrast-audit pass. Physical VoiceOver, full-app appearance/accessibility and the original 41 findings remain unqualified.

## Qualification limits and preservation

Completed dark and Release receipts are included below; no active run was inspected by this publisher. No new minimum-OS styling run is included. The frozen proposal explicitly notes an existing below-iOS18 logging-suppression condition in the calculation-details test; its hypothetical minimum-OS result must not silently become warning-clean evidence.

`provenance.json` records byte-identical copies and original paths/hashes. `manifest.json` hashes every publication file except itself. No raw logs, full activity trees, result bundles, videos or huge product manifests are copied. Publication performs only local evidence reads/writes—no native/result-tool call, app/simulator/build action, source edit, parent-document edit or commit.

## Completed dark checks

`dark/` retains exact native/strict **3/3** on iOS 26.2 build 23C54, dark/Large with the AX5 case's internal size override. Cereal/no-write passed in 58.75 seconds, itemized calculations/no-write in 70.24 seconds and AX5 names/dates in 110.39 seconds. The source manifest is identical to the light run. The examined test export records zero runtime warnings; the supplied 2,003-line console records zero animation-idle messages and runner restarts. Original result/source preservation checks pass. No lossless-logging claim follows.

All six exact dark PNGs are byte-preserved with attachment manifests, export hashes and root's visual-review receipt. Root observed distinct dark canvas/surfaces, light essential ink, secondary metadata/guidance, the standard amounts and both protected lunches together, and individually complete AX5 names/dates/portions and wrapping actions. Disabled Apply is still disabled and is not declared an audit contrast pass. The no-access fixture contains no private context and zero writes; fixture chrome remains outside qualification. Images were displayed resized from 1206×2622 to 942×2048; offscreen adjacent content, physical VoiceOver and full-audit acceptance are not established.

## Remaining design gaps

Root/source review identifies three explicit gaps retained in `remaining-design-gaps.json`:

- Expected total still uses a body-sized fact row rather than the required large-title checkout hero. Tabular digits alone do not satisfy that hierarchy.
- Review and Apply remain standard Form buttons without the established `PrimaryAction` treatment.
- Fee basis and individually named missing facts remain inside collapsed calculation details, while the visible unresolved result uses generic wording.

These are outside this semantic-role correction. Passing these selected journeys and rendered color-role checks closes neither full S24 design acceptance nor the original 41 audit findings. New minimum-iOS17 styling qualification and physical VoiceOver remain unclaimed. No native, result-tool, app or simulator action was performed to append the completed dark evidence.

## Final unsigned Release check

`release/` records the identical frozen source passing **build exit 0 and bundle-check exit 0**, completed at 2026-11-08T13:24:41.261559Z. This is an unsigned arm64 generic-iPhone Release build, using the existing DerivedData path and serial jobs 2 recorded in the command. `check_built_app.py --configuration Release` verified the executable, assets, privacy, environment and embedded extensions. Source and preserved prior-product checks remained unchanged.

The bounded run summary retains the exact command/toolchain and original private full-run SHA-256; `bundle-check.txt` is byte-identical. No reinspection or build was performed to publish these receipts. This is compilation/bundle validation, not signed distribution, physical-device execution, a new minimum-OS styling pass or closure of the remaining design/audit gaps.
