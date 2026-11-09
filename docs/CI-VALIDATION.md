# Local CI validation

## Independent fixture pipelines and shared billing build

Contributor and dinner fixture tests now wait only for their own profile build.
The planner partitions the existing 17 rows without changing their test selectors,
order within each profile, or assigned macOS slots. Both pipelines retain the
same runner, timeouts, warning checks and Records privacy handling. A failed
profile does not block evidence from the other profile; the final `Fixture gate`
still fails unless every selected build and test job succeeds. Only a profile
explicitly excluded by a focused manual selection may be skipped.

Local StoreKit English and Spanish checks share one compiled test product. Their
runtime language/storefront configurations and all 15 scenarios per language
remain required. The shared build and the two consumers use the existing global
five-slot limit; a shared build failure cannot pass the final billing gate.

These changes remove a cross-profile wait and one duplicate StoreKit build.
They do not establish a new full-suite duration: artifact transfer, simulator
startup and actual job scheduling still need hosted measurement.

## Fast validation before macOS work

Core macOS entry jobs now wait for `source-checks`: Swift packages, Release
compilation, Swift CodeQL and the shared UI-test build. The measured source job
took 24 seconds in the November 8 batch. A generated-file, workflow or product
contract failure therefore stops these expensive jobs before they claim a macOS
slot. The final `CI gate` still rejects any failed or skipped required job.
Independent service/web checks continue in parallel. This trades a short startup
dependency on passing runs for less wasted work on invalid revisions.

The pre-release entry point now has its own Linux `source-preflight` before core,
deep checks, fixtures, native-wire, performance and installed staging-app work.
It checks generated files, localization, workflow syntax, Python checks and shell
syntax. These native paths start in parallel after preflight; they do not wait
for the whole core suite. Security and dependency audits remain independent.
The release gate requires preflight success, so a failure or skip cannot turn the
release green. Standalone workflow checks and the core validation remain intact.
This deliberately repeats inexpensive checks at the release boundary.

Performance planning and Python evidence-validator tests also run on Linux before
the optimized build. The compiled XCTest inventory is still verified on macOS.

## Focused hosted feedback

`iOS fixture checks` now accepts an optional manual `shard` input. Leave it blank
for all fixture groups. An exact shard selects that complete group and only its
required build profile; it preserves the same compiled-inventory validation,
selectors, runtime-warning checks, privacy handling, timeouts and five-slot limit.
The run title names the selected group. A targeted pass is diagnostic evidence,
not full PR or release acceptance.

List valid groups with `python3 scripts/plan_ios_fixture_tests.py matrix`. The
workflow is published on development branches; dispatch a focused run on a branch
containing the change without an open PR, for example:

```sh
gh workflow run ios-fixtures.yml --ref codex/my-reviewed-fix \
  -f shard=SharedStoreQuoteUITests-testKnownTripUnknownBreakEvenPrivateProposalAndExplicitShopperAdoption
```

Use a separate development branch for this feedback. Pushing to an open PR still
starts its full required checks. PR runs and reusable release calls expose no
shard selection and retain all fixture coverage. Unknown manual names fail in
the Linux planning job before allocating a macOS build. A failed required build
cannot be bypassed by the optional-profile skip condition.

Work in this order: reproduce and isolate the failure; keep the original journey
and assertions; run the focused local/hosted check; then publish a coherent set
of qualified fixes to the PR for a full regression batch. Reuse a stable local
DerivedData directory when the toolchain/profile is unchanged, preserving the
tested source revision/diff and results. Avoid a fresh source path and cold build
for every small experiment. Keep CI failure diagnostics enabled; collect heavier
local diagnostics when they answer the failure being investigated.

The first hosted focused fixture run passed in 28m27s, including its build,
simulator setup and one original quote journey. The unused dinner build was
skipped. This confirms the focused path works; it does not establish a faster
full-suite duration. [Verified hosted result](evidence/native/ci-focused-known-trip-20261108/README.md).

A branch-only core dinner diagnostic is available on
`codex/core-dinner-ui-diagnostic-20261108`, using the already registered
`ios-toggle-diagnostic.yml` path. It builds ordinary core Debug products once,
validates the complete compiled inventory, then runs exactly one original
English (`en`) or Spanish (`es`) dinner journey through the unchanged strict
shard runner. Build and test share one of the five macOS slots, so products do
not need an upload/download round trip. The distinct diagnostic check is not a
required PR or release check.

Dispatch requires an explicit language and the full commit SHA of that branch.
Use a candidate branch containing this workflow; do not create a PR just to
launch it. The workflow rejects a mismatched SHA or the default `choose` input.
Do not merge the diagnostic-path substitution into the integration branch.
Static validation passed; its first hosted execution is still pending.

The performance workflow likewise accepts a manual `case`: `all` (default),
`launch`, `rendered` or `scroll`. For example:

```sh
gh workflow run ios-performance.yml --ref codex/my-reviewed-fix \
  -f case=scroll -f enforce_baselines=true
```

The complete compiled performance inventory must match before selection. A
focused case retains its original selector, slot, execution deadline and evidence
validation. PRs run all three cases. The reusable release workflow exposes no
case selector and enforces all approved baselines. A focused result cannot stand
in for the full release gate. The baseline-enforcement input retains its existing
behavior; keep it `true` when checking an environment with approved limits.

Do not dispatch repeated copies while a diagnostic is queued or running. Record
the branch SHA and run URL, inspect one terminal result, and group the resulting
qualified fixes into the next full PR batch. A rerun uses the original revision;
changed source needs a new run. Preserve the first failure's evidence before
retrying. Full release acceptance remains tied to one exact revision.

The November 8 baseline took 150.70 minutes across 43 macOS jobs and 687.37 macOS
runner-minutes, about 91.22% of five-slot capacity. More static shards alone cannot
remove most of that work. Source compilation, simulator startup, slow UI
interactions and unnecessary full diagnostic batches are separate optimization
targets. [Measured timing evidence](evidence/native/ci-workflow-efficiency-20261108/README.md).

The pre-release workflow launches the Staging scheme on an iPhone simulator. It verifies the installed build’s anonymous service and authentication responses and opens Help and Support from native Settings into Safari. The release gate requires all three cases to run and pass its runtime-warning checks. This job uses one of the existing five macOS slots.

The Linux source check runs the Foundation 2.1 verifier with Python 3.13. It checks the 52 launch requirements, 27 screen contracts, source checksums, SQLite constraints and reference grocery scenarios. The PostgreSQL job separately executes all twenty grocery inbox scenarios against the service.

The workflow validator uses actionlint 1.7.12 plus the hash-pinned PyYAML requirements. Use an isolated environment; CI creates one before running the full Python suite. The lock currently covers CPython 3.12 on Linux x86_64 (Ubuntu 24.04) and CPython 3.9 on macOS arm64 (this Mac). Other interpreter/platform combinations require a reviewed wheel hash; source builds and unpinned fallback installs are disabled.

From the repository root:

```sh
python3 -m venv .build/ci-yaml
.build/ci-yaml/bin/python -m pip install --disable-pip-version-check --no-cache-dir --no-deps --require-hashes --only-binary=:all: -r scripts/ci_yaml_requirements.txt
.build/ci-yaml/bin/python -m unittest discover -s scripts -p 'test_*.py'
```

Run `scripts/check_ci_workflows.py` with that environment's Python, `--actionlint` pointing to the pinned 1.7.12 executable and `--report .build/workflow-lint.json`. The workflow contains the verified download and checksum for its Linux binary. Direct actionlint alone reports its known unsupported `queue` key; the paired validator exempts only the exact error at independently validated source positions and retains all other failures.

New macOS jobs must be added to the slot policy and tests. Keep slots on leaf jobs only; reusable-workflow callers and workflow roots must not own a slot while waiting for children. Existing non-native groups require a fixed prefix that is provably disjoint from reserved slot names, including case-insensitive comparisons. Every original test selection and final all-success gate remains required.

These are static checks. Hosted execution, native results, performance measurements, signed-device/provider acceptance and human review have separate evidence requirements. See [current acceptance](CURRENT-ACCEPTANCE.md).

## XCTest failure diagnostics

### Working rules for faster fixes

Use one coordinator to own dispatches and the integration branch. Give each
independent failure one investigation owner; helpers should return a patch and
its evidence before overlapping files are installed. Monitoring should reuse
the existing run ID rather than launch another copy.

Keep the working loop small:

1. Group failures by root cause before assigning helpers. One shared failure
   should have one owner, even when it appears in several jobs.
2. Run the affected cheap checks first, then one focused native diagnostic that
   answers a written question. Reuse compatible local build products and preserve
   the original failure. Avoid rebuilding unchanged products just to inspect logs.
3. Use a development branch without an open PR for focused hosted diagnostics.
   Record its exact commit, run ID, selected scope and next decision. Check for an
   existing queued/running copy before dispatching another.
4. If a run failed for an identified transient infrastructure reason, retry only
   the affected job and its dependents at the same revision. A product failure
   needs a fix, not repeated attempts until it turns green. Changed source needs
   a new run; retained products are evidence only for their original revision.
5. Combine independently verified fixes into one PR regression batch. Run the
   unfiltered release gate on the final combined revision before distribution.

After repeated experiments fail to distinguish the competing explanations,
switch to a smaller reproducer or source-level investigation before another long
journey. Add diagnostics only when they answer the current question. Update the
handoff at a meaningful result or ownership change, and reuse downloaded artifacts
instead of repeatedly exporting the same result bundle.

GitHub supports [rerunning one job or failed jobs with their dependents](https://docs.github.com/en/actions/how-tos/manage-workflow-runs/re-run-workflows-and-jobs).
Keep workflow supersession enabled so a newer branch revision cancels its stale
run; keep the shared macOS slot queues non-cancelling so unrelated jobs do not
evict each other. See [GitHub concurrency behavior](https://docs.github.com/en/actions/how-tos/write-workflows/choose-when-workflows-run/control-workflow-concurrency).

| Situation | Next work |
| --- | --- |
| Source, generation or workflow validation fails | Repair and rerun the cheap validation before allocating a native build. |
| One fixture journey fails | Preserve its first failure and run its complete fixture group on a development branch. |
| One performance case fails | Select that case manually, retaining its original measurements and approved limits. |
| A native case passes but strict validation fails | Investigate the warning or missing evidence; do not count the native pass as acceptance. |
| Several fixes have focused proof | Publish them together for one full PR regression at the combined revision. |
| A release candidate is ready | Run the full release checks for that exact revision; focused passes cannot replace them. |

Before another diagnostic, record the question it will answer and what differs
from the retained run. Preserve source, products and original failure results
before reusing a local build directory. Keep one local simulator test active at
a time so competing tests do not distort animation or performance measurements.
Collect each terminal artifact once and reuse the retained copy for analysis.

Track time spent waiting for a runner, building, starting the simulator, executing
tests and collecting evidence separately. Compare full runs with full runs and
focused runs with the same focused scope. The measured 28m27s focused run is not
a new estimate for the full release suite. Rebalance shards only when their
measured critical path justifies it; the existing five-slot utilization is already
high.

The shared iOS shard runner, StoreKit and Release-performance workflows, and optional local UI check use `-collect-test-diagnostics on-failure`. This lets Xcode collect system diagnostics when XCTest encounters a failure or error. Test selections, warning gates, retries and execution deadlines remain unchanged.

For a focused **local layout or control-discovery investigation**, use
`-collect-test-diagnostics never` when screenshots, accessibility state, the native
log and the complete result bundle answer the question. The installed Xcode help
defines this switch as controlling verbose diagnostics such as a sysdiagnose.
Keep the original selectors, assertions, timeouts, result export and strict
checker. Opt into verbose diagnostics when the investigation needs system-level
evidence (for example a hang or infrastructure failure). CI keeps its existing
on-failure setting.

This distinction has measured value: the Spanish AX5 control-discovery testcase
failed after 193.448 seconds; the whole command finished after 800.080585 seconds.
Its owned `simctl diagnose` child used `--timeout=600`. The native process was
left to finalize; it was not restarted, killed or relabeled as passing. Native65,
strict1 and the original evidence are preserved; text size is restored to Large. For another
local layout check, that broad capture does not answer whether a control was
scrolled into view. Preserve the failure artifacts once and use targeted evidence.

Existing CI result-bundle uploads retain those diagnostics for seven days, including after failures. The Records media shard continues to exclude raw bundles and logs from uploads; its sanitized artifacts remain the only published results. Collection can increase failure-run time and disk use, and an outer deadline may prevent complete finalization or upload. Inspect the actual failed-run artifacts before claiming complete evidence.

A later strict-checker rejection of an otherwise passing XCTest run is not itself an XCTest failure. This option therefore does not guarantee collection for a runtime-warning attachment that is missing from a passing test. Required issue descriptions remain mandatory; changing diagnostic collection does not repair or waive a warning.

## Shared delivery fixture timing

The six shared-delivery cases at `3e96fe3` passed on a hosted iPhone 17 running iOS 26.2. The runner spent about 2m33s on setup before the test step, then about 16m54s running and checking the shard. The six XCTest case durations account for 860.646s of that step. The suite now includes three more journeys. The table groups each whole journey once, using the six hosted case durations and passing local iOS 17 simulator measurements for the additions. [Hosted job and test log](https://github.com/palatis3/room-in-the-cart/actions/runs/42390883332/job/128469594458).

| Contributor shard | Hosted cases (seconds) | Additional local cases (seconds) | Estimated case time |
| --- | --- | --- | ---: |
| `SharedDeliveryUITests-stock-and-purchase` | Record and correct delivery 168.852, Spanish fractional stock 134.521, freezer correction 180.859 | Linked family purchase 54.555 | 538.787 s |
| `SharedDeliveryUITests-recovery-cook-and-closeout` | Unresolved replacement 164.069, replace Wednesday 135.417, dated cook copy 76.928 | Edited cook wording 47.302, financial closeout 94.418 | 518.134 s |

Each job restores the contributor build, boots its simulator, and checks its own selector file against the completed XCTest result. The fixture matrix has 17 jobs across both profiles, admitted through the five shared macOS slots. On the next hosted run, the `iphone-fixture-results-<shard>-<attempt>` artifacts record the per-case results. The two job timelines also include setup and result collection.

## Merge protection and release checks

As of November6, `main` requires a pull request, an up-to-date branch, resolved conversations, and the four GitHub Actions checks `CI gate`, `CodeQL (javascript-typescript)`, `CodeQL (actions)` and `Dependency review`. Admins follow the same rules; force push and deletion are disabled. Zero mandatory human approvals preserves the single-owner workflow. [Applied settings and independent verification](evidence/native/main-protection-20261106/README.md).

These are the unfiltered core/security PR gates. Path-filtered fixture, deep, performance and native-wire workflows are not directly required by branch protection: a documentation-only change can skip them. A merge passing the baseline therefore does not establish full regression acceptance.

Before distribution, run the unfiltered `Pre-release regression checks` workflow on the exact release branch head and require its `Automated release gate` to succeed. It includes all six workflow scopes, strict release metadata, full lockfile vulnerability audits and exact-commit CodeQL/open-finding checks. Source changes invalidate that candidate's release result. Actual signing, live-provider acceptance and physical/human gates remain required. The future distribution integration must enforce this boundary; this manual workflow does not itself upload or technically prevent an independent App Store upload.


The shared shard runner now implements the local option explicitly:

```sh
# Requires the existing compiled products and test-plan manifest for this shard.
# SIMULATOR_ID, TEST_SHARD and EXPECTED_TEST_COUNT must already identify that work.
LOCAL_TEST_DIAGNOSTICS=never bash scripts/run_ios_test_shard.sh
```

Default behavior stays `on-failure`. `never` is rejected before native execution
when either `CI` or `GITHUB_ACTIONS` is set. Invalid modes also fail early. The
mode is printed in the log; the original selectors, 720/900-second allowances,
full result bundle, strict checker and failure exit remain unchanged. This option
avoids verbose system capture; it does not skip XCTest evidence or make a failed
test pass. One-off local runners must record the same explicit flag in their new
command receipt; do not edit a retained run's provenance.

## Exact-run monitoring without repeated log downloads

Use the read-only reporter before allocating more CI work:

```sh
python3 scripts/ci_feedback.py --run 42544579944
python3 scripts/ci_feedback.py --sha d1705d920595be12a3eb8c378f50ad04dbf65ccd
```

It reports the exact revision and attempt, all paginated jobs, failed step names,
three longest steps per job, execution time and time before starting. The latter
includes dependency/slot/scheduling delay, not just the runner queue. Repeated
failed step names are investigation leads, not a count of independent bugs.
Potential duplicate active runs share workflow, branch and SHA; compare manual
scope before cancelling anything. Active counts apply only to the requested
revision/run, not the whole repository.

Completed job summaries are cached in `.build/ci-feedback` by repository, run and
attempt; run metadata is refreshed before reuse. Live snapshots are not cached.
The reporter neither launches/retries/cancels runs nor downloads logs. Fetch the
specific failed job's log only when the summary identifies what needs inspection.
An empty revision result exits nonzero; absence of runs is not a green release.
Keep one coordinator for dispatches and one owner per independent root cause.
Batch qualified fixes for one full PR regression at the combined revision.
