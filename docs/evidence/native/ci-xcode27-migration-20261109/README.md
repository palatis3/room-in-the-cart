# Primary Xcode 27.1 migration and focused core feedback

Commit `df49c37d6aa6e77cf4504890f3b2e840eea7b0e0` is published on
`codex/xcode27-ci-migration-20261109`. The existing integration PR has not yet
received this focused batch. The focused hosted core run now passes; full regression and release acceptance remain open.

Sixteen native job definitions move to exact Xcode 27.1 / 27A9275 on the official
arm64 `xcode-27` preview image. Required Swift CodeQL remains on Xcode 26.3 because
GitHub documents traced Swift 6.4 extraction as unsupported. The same five native
slot queues remain. A runtime/device pin selects iPhone 17 / iOS 27.0, avoiding an
unintended switch to the image's iPhone Duo / iOS 27.1. Old evidence identities and
the approved performance baseline remain unchanged.

The existing core workflow now accepts manual-only `ios_scope=dinner`. Full
compiled inventory is validated first and retained. Every ordinary app model test
and both original dinner UI journeys run through unchanged strict selectors,
counts and runtime-warning checks. Other core jobs remain required. Focused runs
have a distinct name, gate and concurrency group; PR and release runs stay full.
This replaces recurring temporary workflow aliases for this diagnostic.

Final offline verification: 286 Python tests pass, pinned workflow lint verifies
17 native queue nodes, and shell parsing, generation, localization and whitespace
checks pass. Independent root review caught and corrected a guard-before-checkout
ordering bug before dispatch; a regression check covers all migrated jobs.
The earlier isolated test-timing failure lacks a retained raw transcript and is
explicitly recorded as such, rather than claimed as a fixed production issue.

Hosted qualification status:
- [Focused core run 42561415704](https://github.com/palatis3/room-in-the-cart/actions/runs/42561415704)
  passed all 11 jobs, including 717 model tests and two original UI journeys.
- [Performance collection 42561773341](https://github.com/palatis3/room-in-the-cart/actions/runs/42561773341),
  `case=all`, `enforce_baselines=false`; scroll and launch passed XCTest but failed
  strict performance-evidence checks. Rendered strict evidence passed. No baseline is approved.

Both runs use the exact commit above. Missing metrics or native failures still
fail collection. PR/release performance enforcement remains enabled and cannot
pass without a measured, reviewed matching profile. Neither focused core success
nor calibration collection is full release acceptance. There is no promised
runtime improvement merely from upgrading Xcode; compare observed work and keep
compiler, runtime, device and source differences explicit.

Follow-up9f4dfa22 adds early configured and observed environment checks. 294 offline tests pass; calibration skips only baseline availability, not identity. This follow-up is now published; later diagnostics are recorded in the workflow follow-up report.

## Retained local verification originals

The files below remain on this Mac in this evidence directory. Only this compact
report is committed; the hashes identify retained originals, not independent
off-Mac archival. [Current workflow results](../ci-workflow-followup-20261109/README.md).

| File | SHA256 |
| --- | --- |
| `additional-checks.json` | `82f896a4cc73c31a7eeb7350d77f2636cb39957a57f5ea79ea92de512af70823` |
| `final-review.patch` | `34c638ff931f4b9c6075a18de2870a1d79e465987f90ea9b80d62b58199f9bf2` |
| `final-source-sha256.json` | `1b597ec48744d25cc2eeb5a22392de3d0934a0b966eb4687691569bc1d9a039b` |
| `focused-python-tests.log` | `7ba0950506d5eb538a62bcf8806540d566c0ec672534ece4969f2c20f2ad8fdd` |
| `focused-workflow-lint.json` | `9be7a770310b0b1852d58a59644e0a2a8886a494ce47ed1489391fb18acf4ac2` |
| `initial-test-failure-note.md` | `e45cd45e7582521a09b50e614e63cd48ae9537fc13d10fbdb2688133b62e49f5` |
| `validation-receipt.json` | `9bc4f36dcc169b150c3b016be600701dfaa98c9dfe917cbcc7cfe1c3116f466b` |
