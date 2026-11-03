# Frozen native Library, Privacy, History and civil-date acceptance

Selected results are green: **25 model cases and six UI cases**, with zero failures or skips in the final source-bound runs. This certifies the independently frozen QA bundles listed in [acceptance.json](acceptance.json), not the current full integration.

| Area | Cases | Frozen build | Result |
|---|---:|---:|---|
| HistoryFlow models |21|2|Passed|
| Civil-date models |4|2|Passed|
| Civil dates, English and Spanish |2|3|Passed|
| Free grant-only History, foreign reference and revocation |2|3|Passed|
| Recipe library Cancel, corrupt preservation, Apply and whole-batch Undo |1|4|Passed|
| Correction Settings, confirmed opt-out, Privacy/Support/Help |1|4|Passed|

The baseline is commit `ec1c243e7846892d9991620160e4365d8edf5ebb`, archived from Git objects. It intentionally predates concurrent Records capture work and later guardian integration. Four civil-date files were overlaid with supplied SHA verification. A single snapshot-only `@MainActor` annotation fixed a baseline Records compile error; the in-progress Records file was never copied. All live target files were compared again at completion. Source manifests, verified immutable source copies, cloned Products and exact per-run commands remain under the durable evidence root.

The native journeys found two production issues. The spelling opt-out popover exposed no explicit Cancel on iOS27; it now has an ordinary localized Cancel action that changes no saved data. The saved-period Form row combined its two buttons: tapping Review performed another raw read, while the paid-denial count stayed unchanged. A borderless style on only that row now gives the buttons separate actions. History model, scope and service guards remain unchanged. Later test failures were nested accessibility query ambiguity for Cancel and a premature existence wait for a lazy error row. The final tests use the observed Cancel identifier with the existing first-match helper and reveal the real error before asserting it.

The library test verifies two ready recipes, two duplicates, two skipped rows and unsupported nutrition, preserves the original recipe/current source on Cancel and corrupt input, saves two separate copies on explicit Apply, preserves original yield/ingredient/instruction/source strings, and undoes the whole batch. The Settings test verifies named and last-rule deletion, Cancel preservation, confirmed scoped English opt-out with Spanish retained, supplied operator/contact and metadata-only offline help without sending. History verifies Free raw reads despite absent shopper authority, paid analysis/write denial, zero writes, rejected foreign reference and fresh-read revocation clearing.

Civil UI asserts **64 exact production labels**: eight dates around both 2026 DST boundaries and November 3/5, four US zones, English and Spanish. Eight actual final-day screenshots show wire `2026-11-05` alongside localized November 5. The original S26 red date screenshot is retained; this focused component proof closes the display defect without claiming a fresh whole-S26 run.

The original interrupted six-UI result has no Info.plist and is unreadable by xcresulttool. Its log, raw data and nine directly recovered PNGs are preserved with that limitation. Final cases have complete, independently readable xcresults. No synthetic result metadata was created. The assigned 17e alone was used and shut down after acceptance; data was retained.

These are guarded fixture-app runs of production screens/components, with fictional data, substituted document-picker selection and `.invalid` transport. Real-service authority, the OS picker, current combined integration, human language review and physical VoiceOver remain separate evidence gates. Static localization passes 15 catalogs/3451 en-es entries/3309 literal keys, excluding 32 dynamic expressions and 106 runtime compositions. No remote, paid membership, SMTP or provider action occurred.

See [screenshots and hashes](screenshots.json), [exact run/source/binary identities](acceptance.json), and [the interrupted-attempt record](interrupted-ui-report.json).
