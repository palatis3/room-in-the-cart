# Clarification contrast fix and regression

Household clarification now uses the app's secondary text color and native working
text field. Original guidance and empty Question measured3.111655:1 and1.723392:1;
the unchanged4.5:1 threshold rejected both in the retained negative control.
The corrected targets measure7.083026:1 in light mode and8.295239:1 in dark mode,
at both Large and accessibilityXXXL. Multiline editing and cancellation remain intact.

The regression checks exact text, complete target visibility, palette, contrast,
draft editing and zero command attempts after Cancel. A deliberately rejected send
must increment attempts to1 while applied decisions and saved lines remain0.
This catches a previous fixture blind spot where a rejected write still looked like
no write. Callbacks execute outside the fixture lock; updates remain monotonic.
Dismissal does not claim to cancel that intentionally pending operation.

Nine compiler-warning sites in eight fixture files are corrected: seven redundant
protocol Sendable declarations, verbatim diagnostic interpolation and an encode-only
record's conformance. These are not a general concurrency-safety certification.

## Same-source qualification

Source manifest: `2f880895b40c37e3662f83ffedae2ae0d0f45169857f9669cdcd0f8f7a63b84f`.
Xcode27.1, iPhone17, iOS27.0/runtime24A434. Contributor build and bundle check pass;
no Swift compiler warnings. All positive cases use on-failure diagnostics.

| Case | Native / strict exit | Whole-run seconds |
| --- | --- | --- |
| light-large | 0 / 0 | 66.490 |
| dark-large | 0 / 0 | 68.450 |
| light-ax5 | 0 / 0 | 98.699 |
| dark-ax5 | 0 / 0 | 95.660 |
| cancel-original | 0 / 0 | 143.894 |

Independent full-image reviews confirm complete wording, actual larger glyphs,
wrapping and no target clipping. AX5 guidance and Question use separate scroll
positions. Compiled inventory contains68contributor cases; the new selector appears
exactly once in existing contributor-balanced-03. Together with5Dinner cases, the
planner expects73fixture cases. No additional CI job was introduced.

## Integration and boundaries

Ten reviewed source files were installed byte-for-byte, plus the planner assertion.
The separately verified CoreDomain deletion-history fix was preserved, not replaced
with its older isolated-source version. Final combined native input manifest:
`f9d4f7717b3b19967be7f24466b36c2c31973ba14361e47f4b4c37d4ceb80ba6`.
All409offline checks and17queue-node checks pass after integration.

These are focused English checks with explicit app appearance selection. They do
not qualify automatic system appearance propagation, all S24 states, VoiceOver,
Spanish, minimumOS or full combined release CI. CI's new selector defaults to
English/light/Large; the four-trait results above are scoped local qualification.

## Retained evidence

Original negative control: `.build/ClarificationContrastNov09/baseline-r4/`.
Final originals, one-time inspections, compiled inventory, visual review and
installation receipt: `.build/ClarificationContrastNov09/positive-r5/`.
Complete561-source/376-product archive and executable modes are verified under
`.build/NativeQualificationArchivesNov09/2f880895b40c37e3662f83ffedae2ae0d0f45169857f9669cdcd0f8f7a63b84f/`.
Prior navigation failures remain preserved. The failed layout probe and its passed
successor used non-acceptance local layout mode; neither replaced positive checks.

| Receipt | SHA-256 |
| --- | --- |
| Final archive custody | `d3cb2ca7901e04b416a770ba6fb6b9517e5314e77b2bae637bf76ff993cb4c4c` |
| Four-trait visual review | `8360bd822eb642841636c0ac7fdd7c48d181f912956ee432dcbbe2d08395fc5c` |
| Installation | `c43f61844fa4a1cdcdb077b58ae764b06686eed4d6f4af4b28257852b9c69133` |
| Final offline/workflow validation | `461839627a4d4a73a7f9272a5ae19b3a7fd51d9b216520244ead25a0b226ca4b` |

Raw originals remain local; this compact report is not a remote backup.
