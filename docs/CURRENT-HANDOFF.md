# Room in the Cart current handoff

Updated November 9, 2026. Active goal: finish the complete first version—Foundation
2.1's 52 requirements, 27 screen contracts and B11. Not complete or paused.
Read [APP-BASELINE](product/APP-BASELINE.md), then the Foundation 2.1 master and
[MASTER-GENERATION](product/MASTER-GENERATION.md). The detailed prior checkpoint
and all earlier native preservation paths remain at
[immutable 21f69b5f](https://github.com/palatis3/room-in-the-cart/blob/21f69b5f7f81dc2ab11767c8de83d7c42d1c746b/docs/CURRENT-HANDOFF.md).

## Workspace and execution ownership

Canonical checkout: `/Users/palatis/Room in the Cart`, local branch
`codex/parallel-ios-ci`. Publish to `codex/combined-candidate-20261109`; its verified
head before this evidence update was dc343f3e. Recheck current Git/run state before dispatch.
The ambient `spanish-done-diagnostic` worktree is stale. Draft PR1 is an older
candidate. No full combined qualification or merge has passed.

No Dot/Lumpy. Astra High helpers and Sol6.1 Extra High monitoring are authorized.
Root owns integration and dispatch. One owner per cause, one local native process,
no source/product mutation during execution. All local and hosted attempts below are terminal;
no native process or debugger remains. Disk last reported approximately 15 GiB free;
keep 8 GiB reserve and avoid downloads/duplicate raw archives.

## Implemented workflow

[CI-VALIDATION](CI-VALIDATION.md) governs the feedback loop: diagnose before
repeating, preserve the first failure, reuse compatible build products, and freeze
one revision before full regression. Baseline compatibility is checked before Mac
fan-out; full-release dispatch rejects mismatched candidate/event/checkout SHAs.
Five shared native slots remain. Reports separate measured pre-start waits from
execution, and compact evidence binds hashes to retained originals. Merge and App
Store gates remain separate in [RELEASE-EXECUTION](RELEASE-EXECUTION.md).

New: copy only changed source bytes/modes when assembling successors, preserving
unchanged modification times. The performance simulator producer now explicitly
builds arm64 only, removing unused Intel compilation from that lane. Generated
Release defaults, device archives, consumers and strict gates are unchanged.
433 offline checks and all 17 workflow queue definitions pass. The optimized hosted producer, actual arm64 products and original native scroll
now pass. Required hosted scroll duration remains missing; the 451-versus-618-second
build observation is not a controlled speed comparison.

Primary CI: Xcode 27.1/27A9275, arm64 `xcode-27`, iPhone 17 / iOS 27.0/24A434. Swift
CodeQL retains its required macOS15/Xcode 26.3 exception. Minimum iOS remains 17.0.
The only approved performance profile is 26.3/17C529 with iOS 26.2/23C54; 27.1 remains
unapproved. Do not dispatch full release expecting this mismatch to pass.

## New verified changes

1. **Shared exclusion matches:** original HTTP negative controls reproduced two
   incorrect 200 responses. Pantry/delivery now reject explicit conflicts with 409
   `match_exclusion_conflict`, including effective recovery restrictions. Local
   focused PostgreSQL/HTTP: 38 pass; broad integration: 250 pass / 3 browser skips; fast
   service: 450 pass / 1 database skip. Native localized feedback no longer reports a
   terminal rejection as saved, while retaining durable review cleanup and uncertain
   waiting retries. Debug build and all 19 SharedShopFlowTests pass native/strict.
   No migration or hosted deployment occurred.
   [Exact proof](evidence/native/shared-match-exclusions-20261109/README.md).
2. **Performance loaded-image observer:** reviewed same-file helper and explicit
   collector pin installed; original 3 selectors/measurements/assertions preserved.
   20 synthetic parser controls pass; Release build/bundle/inventory pass. Full local
   scroll passes native/strict and required metrics: 5 durations, median 2.581955166 s;
   memory complete, hitches unavailable. Saved 500 rows / 500 contributions / 0 checkoffs / rev 3.
   Post-measure runner observes MTC UUID E40A186A-8D7D-3029-B5CD-D42C967992C0 once;
   RPAC has no match. The hosted runner now reports the same post-measure identity.
   No during-measure loading/activity or metric-cause inference.
   [Exact proof and inspection caveat](evidence/native/performance-loaded-images-20261109/README.md).

All 561 canonical native inputs match source manifest
`a357a09918cf6dc15093dccb8dc992dc16e5baaff789b8eb490fddb5f9708791`.
Execution workspace `.build/Xcode27WarningReviewNov09/execution-r1/{source,dd}` now
contains this successor; old executors are historical. Current receipts/scripts are
under `.build/PerformanceLoadedImagesNov09/execution-r1/`.
Debug products manifest f51f027c66f299c08f8c719076bd956a8af631d025bcf283bbf432f7f954ff55
is archived with source under `.build/NativeQualificationArchivesNov09/<source-SHA>/shared-match-debug-products-f51f027c66f299c0/`.
Release products manifest 3de01fde66170f6ffdbcf9b3fe7d7fa2bdd477e3a0a44e220e4fb6c5d58138a8
is also archived under the same source-SHA directory in
`performance-observer-release-products-3de01fde66170f6f/products`, with a preservation
receipt referencing the already-verified Debug source archive. Do not overwrite it. Both source and
products stayed unchanged during their test executions.

The initial scroll setup failed before XCTest because an old Release test app was
installed. Its complete app/data were verified and preserved before uninstalling
only that owned installation. Successful attempt is `run_scroll_r2.py`; inspect once
with `inspect_scroll_r2.py` (already completed). Its original custody check returned 1
because a new `database.sqlite3` appeared in the result during inspection. Separate
`inspection-observer-r2/custody-review.json` proves all original members unchanged,
no removals, stable added Xcode results database and successful SQLite check. Do not
rewrite the first receipt or rerun native work for that addition. Local Release used
the prior dual-architecture command, so it does not qualify the optimized producer.

## Remaining diagnostic work

- Latest hosted 42639339096 attempt 1 at dc343f3e is terminal failure: arm64-only
  producer, immutable plan/products, native 1/1 and cleanup pass; required scroll
  duration is absent, with only 3 memory series × 5. Selected-runtime bytes match
  producer. Crucially, the post-measure runner attachment matches local exactly
  except PID: MTC UUID E40A186A-8D7D-3029-B5CD-D42C967992C0 present, RPAC no match,
  1,130 callbacks / 5,263,912 bytes / complete. The declared producer path is still absent
  pre/post setup, but it does not establish absent runner loading.
  [Final report and retained hashes](evidence/native/hosted-arm64-observer-20261109/README.md).
  Coordinator independently verified all 3 GitHub ZIP digests and read actual Mach-O
  headers for app/tests/extensions and all 5 static package objects: arm64-only.
  Monitor originals: `.build/HostedLoadedImagesNov09/monitor/`; product original and
  architecture proof: `.build/HostedLoadedImagesNov09/products/`.
- The post-measure runner-image question is closed. Do not repeat filesystem/image
  probes, rewrite plans or disable checkers. Before another expensive run, identify
  one discriminator for measured-window collection/transport or relevant application
  environment. Screenshots already prove rendering; Simulator.app visibility and
  during-measure/AUT states remain unmeasured, not established causes. A post-hoc
  query found zero matching events but cannot distinguish emission from transport.
- Capability-only 42625593343 and earlier 42620394385 remain preserved historical
  results. No baseline or full combined acceptance follows from these diagnostics.
- Original Spanish iOS 17.0 journey still fails. Direct LLDB capture confirms null
  x0/strcmp → XCTest runtime_issue_os_log_fault_callback → libtrace quarantine
  during accessibility query. Null origin remains unknown. One exact-PID resume
  completed verified detach cleanup. Debugger timing is diagnostic-only.
  The later direct-label query experiment also failed and is not installed; its
  source/products are archived. No unchanged query/resource/checker-suppression retry.
  [First-fault proof](evidence/native/minimum-os-first-fault-20261109/README.md).
- Private Apple report approval remains pending. Nothing sent. Exact package:
  `.build/MinimumOSXCTestReproducerNov09/apple-report-draft/reviewed-first-fault-package/`
  with REPORT.md, 10 KB capture and manifest only. Do not resend the question or submit
  without the user's answer.

Then finish remaining fixes, freeze one final commit, run full combined regression,
review required checks and merge only when its gates pass. Focused results from
other revisions cannot be assembled into full acceptance.

## App release still separate

Current accepted local work includes ordinary F02 removal/Cancel/Apply/restart and
SQLite proof, clarification contrast/AX5 coverage, fixture isolation and corrected
SDK provenance; see the immutable prior checkpoint and CURRENT-ACCEPTANCE.
Authenticated mixed-device F02 and other B11/provider/physical-device/human review
gates remain incomplete. Staging approval extends through 041; 042 and subsequent
service rollout need their own reviewed scope. Paid Apple membership/signing, SMTP
and KWS activation are owner deferred; do not repeatedly request them. Operator:
Venture House Group LLC. Support: hello@roominthecart.com.
