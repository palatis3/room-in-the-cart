# Local CI validation

## Default feedback loop

1. Read the existing run's compact report before scheduling more work:
   `python3 scripts/ci_feedback.py --run RUN_ID --format text`.
   Assign one owner per independent cause; the coordinator owns dispatches and integration.
2. Validate changed source and workflow contracts locally. Use one focused original
   journey to qualify a fix, with a recorded source revision, question and expected
   result. Reuse compatible build products; retain the first failure's evidence.
3. Inspect the existing result once. If the experiment did not distinguish causes,
   investigate source or use a smaller reproducer before repeating a long journey.
4. Combine verified fixes into one PR regression batch. Full release checks must
   pass at the final combined revision; focused passes are supporting evidence.

The compact report lists every unsuccessful or unfinished job, including skipped
and cancelled jobs with no failed step. It includes the five longest execution
windows and their longest steps. These are triage hints, not a critical-path
calculation or a count of distinct bugs. Omit `--format text` for complete JSON.
Neither format dispatches work or downloads logs.

Before changing shard allocation, compare like-for-like full batches: elapsed
time, Mac runner-minutes, build/setup/test/evidence time and time before jobs
start. The last measured batch already used 91.22% of five-slot capacity.
Shared archives already avoid recompression; additional splitting or caching
needs measured benefit. A new layout is not automatically a faster one.

## Reduce repeated UI traversal before increasing deadlines

The retained Spanish AX5 Dinner R3 run reached all five keyboard checks and
approval but exhausted its 720-second allowance at relaunch. R4 reduced the
restored-review block from 49 to 29 gestures and reached final acceptance 56.77
seconds earlier. The final empty-list assertion completed at 715.60 seconds,
but teardown exceeded the unchanged allowance at 720.251 seconds: native65/strict1.
This remains a failed run. R5 adds persistent access to Continue editing to remove
the remaining 19-gesture trip; its completed run remains unsuccessful (native65).
This change has not established a full journey pass.
Every original assertion, gesture bound, deadline and persistence check remains.
[Exact candidate and retained evidence](evidence/native/dinner-accessible-fields-20261109/README.md).

## Primary Xcode 27.1 toolchain

Existing native workflows now use Xcode 27.1 build 27A9275 at
`/Applications/Xcode_27.1.app` on the arm64 `xcode-27` hosted runner. Local Xcode
27.1 matches this exact compiler build; no local download is needed. Existing
PR, manual and release triggers retain their original coverage and strict gates.
There is no additional compatibility workflow or duplicate scheduled suite.
All 17 native job definitions still share the same five global slot queues;
16 migrate and the required Swift CodeQL job retains the security exception below.

The official [runner catalog](https://github.com/actions/runner-images/blob/main/README.md)
and [Xcode 27 image](https://github.com/actions/runner-images/blob/main/images/macos/xcode-27-arm64-Readme.md)
were checked November 9, 2026. `xcode-27` is a **public preview** runner, distinct
from `macos-26`. Published image `20261026.0314.1` includes the selected toolchain
and iPhone 17 on iOS 27.0. Each migrated job checks the exact Xcode version/build
and arm64 architecture after checkout. Simulator selection requires both
`com.apple.CoreSimulator.SimRuntime.iOS-27-0` and `iPhone 17`, including when
creating an owned device. It cannot silently select the image's newer iOS 27.1
runtime, which currently offers iPhone Duo instead. The actual runtime build is
recorded; the image documentation does not publish its build identifier.
The rolling preview label is not an immutable image pin. Runner availability and
successful hosted execution still need qualification at the migrated revision.

`ios-swift-codeql` remains required on `macos-15` with Xcode 26.3. GitHub's
[official CodeQL support notice](https://github.blog/changelog/2026-10-19-codeql-changes-for-macos-27-xcode-27-and-swift-6-4/)
explicitly excludes Swift 6.4 and traced Xcode 27 builds; `build-mode: none` is
not a Swift replacement. This hosted security exception preserves manual Swift
analysis and its gate. It does not inherit the iOS 27 runtime selector and does
not require installing Xcode 26.3 locally. Remove it only after official support
and a successful equivalent analysis are established.

The iOS 17 deployment contract and separately required local minimum-OS testing
remain unchanged. There was no hosted iOS 17 runtime lane to migrate, and the
preview image does not advertise that runtime. Compiler equality alone does not
establish OS/runtime or hardware equivalence; products must not cross incompatible
toolchains. Historical results and their original environment identities remain
historical evidence.

### Performance calibration blocks release until approved

The approved performance profile remains byte-for-byte unchanged at Xcode
26.3/17C529, iOS 26.2/23C54, iPhone 17, arm64, Release/TestSchemeAction. It cannot
approve measurements from Xcode 27.1/iOS 27.0. PR and full release enforcement
remain enabled, so they fail closed without an exact approved new profile.
Use the existing manual `ios-performance.yml` workflow with `case=all` and
`enforce_baselines=false` to collect the new environment's complete metrics and
retained evidence. Review those actual measurements before adding an approved
profile; do not relabel the old baseline, drop a metric or treat collection as a
release pass. Missing metrics and test/warning failures still fail collection.

Enforced performance runs reject proven environment incompatibility before
expensive native work. The Linux planner compares configured Xcode version,
iOS version, device model and runner architecture with approved profiles. It
reuses the existing workflow pins; it cannot know the hosted runtime build.
After simulator selection, the build runner reads the actual runtime build,
device type, architecture and Xcode version/build before compiling. Test runners
repeat this read-only check before boot to detect image drift between jobs.
These checks neither boot a device nor run tests. A compatible profile at this
stage is only permission to proceed: the unchanged post-test validator still
requires the exact complete result environment, all metrics and approved limits.
Calibration-only runs skip baseline availability checks and retain every late
evidence requirement. The current 26.3 baseline therefore fails enforced Linux
planning immediately, while explicitly requested calibration remains available.

### First hosted migration qualification

After reviewing and publishing a candidate revision, use the already registered
core workflow's first-class manual Dinner scope:

```sh
gh workflow run ci.yml --ref codex/my-reviewed-fix -f ios_scope=dinner
```

Confirm the selected ref's immutable SHA and existing runs before dispatch and
record the returned run's `head_sha`. Full compiled inventory validation happens
before narrowing work. Every enabled ordinary model test is retained, plus exactly
these original UI journeys in `ui-01`:

- `FreeJourneyUITests/testFirstPickupCanStartFromDinnersAndReviewAnEditablePattern`
- `FreeJourneyUITests/testSpanishDinnerIdeaReviewsPacksAndLeavesListEmptyAfterApproval`

The original full manifest, selector files and compiled enumeration remain in the
retained test-plan artifact. The same runner verifies exact executed selectors,
counts and warnings with unchanged test allowances. Every other core job remains
required, including release compilation, package tests and Swift CodeQL. This
reduces core UI work; it is not a single-job smoke test or complete release coverage.

`ios_scope` defaults to `full` and is exposed only for manual dispatch, never as a
reusable workflow input. PR, push and release calls retain the full suite. The
focused run is named a Dinner diagnostic, has a distinct `Dinner diagnostic gate`,
and uses its own workflow concurrency group, so it cannot cancel a full run on the
same ref or present its success as the normal `CI gate`. Native jobs still share
the same five non-cancelling slot queues. Unknown scopes and attempted narrowing
outside manual dispatch fail closed. No temporary alias workflow is required.

Follow the focused run with performance collection and the full existing
core/deep/fixture/native-wire/release batch once the combined app revision is ready.
An independent fixture smoke remains available through `ios-fixtures.yml` with
`shard=DinnerDecisionSheetUITests`, retaining that entire original fixture group.
Keep the first failure and inspect it before repeating work. This migration has
no hosted pass until the corresponding run receipts are recorded.

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

### Bounded scroll measurement diagnostic

The manual performance workflow has an optional `capture_scroll_signposts`
input, default off. It is permitted only with `case=scroll` and explicit
`enforce_baselines=false`. Linux checks reject other combinations before allocating
Macs; the wrapper independently rejects them. The run name and workflow cancellation
group distinguish this diagnostic from ordinary performance qualification. The
existing five native slots, original test command, assertions, metrics and strict
validators remain unchanged.

The wrapper checks the pinned source/toolchain/runtime, then requires a separate
signpost transport control before starting the original XCTest case. It retains
bounded metadata only, comparing live capture with persisted logs. Unsupported
capabilities, schema or a missing pre-control stop before the test; loss/caps or a
missing post-control make the diagnostic inconclusive. It does not change logging
configuration or retain raw messages. `live-signpost-diagnostic.json` records the
limits and outcome alongside the original evidence. An instrumented pass is not
an approved performance baseline or release acceptance. Run once for the written
capture question, inspect the result and stop; do not retry until green.

For a capability failure before XCTest, first use the default-off manual
`capture_preflight_only=true` with `capture_scroll_signposts=true`, `case=scroll`
and `enforce_baselines=false`. It uses the existing slot, boots the simulator and
checks the six CLI/runtime capabilities. It compiles nothing, reads no test
products, starts no log transport and invokes no XCTest. Its separate cancellation
group does not replace ordinary qualification. Success means
`capabilities_checked_not_transport`, never a performance pass.

Opted-in full captures also check these capabilities before compilation, then
repeat the guards on the actual test runner. Incremental atomic receipts retain
fixed command labels, status, exit code, elapsed time and bounded error categories;
raw command output and private payloads are not retained. An interruption may
leave a `running` stage, which is incomplete evidence. Preserve the first failure
and use the named stage to choose the next change instead of extending timeouts
or rerunning unchanged. The capability artifact is
`iphone-scroll-capture-capabilities-<attempt>`; original capture/metric acceptance
requirements remain unchanged.

For opted-in capture, the existing runner environment guard writes a fresh local
`runner-identity.json` after successful environment and applicable baseline
validation. The collector can reuse that exact version check within the same
job instead of making its fourth `xcodebuild -version` query. Bindings include
source SHA, run/attempt, job/runner, simulator, developer directory, enforcement
mode and observed architecture/version. The test consumer creates its own receipt;
it never restores one from the build job. Invalid supplied receipts fail closed.
Without a supplied receipt, the standalone direct query remains. Live simulator
and log capability checks still run. This is duplicate-work removal, not a fix or
acceptance claim for missing metrics. Receipt write time is reported separately.

### Exact-revision qualification receipt

Before scheduling the combined regression batch, create one receipt for the
immutable **tested** revision. Update it after inspecting each terminal attempt,
then check it before describing the revision as qualified:

```sh
python3 scripts/check_qualification_receipt.py --init FULL_40_CHARACTER_TESTED_SHA > .build/qualification.json
python3 scripts/check_qualification_receipt.py --receipt .build/qualification.json
```

The generated template is deliberately incomplete and defaults to `merge` scope.
The checker exits 1 for missing/unsuccessful qualification and 2 for inconsistent
or changed evidence. Exit 0 means only that the offline checklist is consistent
and complete for its declared scope. It does not fetch current branch protection,
approve a merge, or establish distribution readiness. Follow
[the release execution plan](RELEASE-EXECUTION.md) for the separate live-provider,
physical, language, accessibility and distribution requirements; the receipt
hashes that plan rather than duplicating its checklist.

The three scopes cannot substitute for one another:

| Scope | Required evidence |
| --- | --- |
| `focused` | Terminal successful diagnostic runs with exact checkout identity; supporting evidence only. |
| `merge` | PR runs supplying `CI gate`, both CodeQL language checks and `Dependency review` at the same tested revision. Live branch freshness and conversation resolution still require current GitHub review. |
| `automated_release` | The existing full `Pre-release regression checks` run and its successful `Automated release gate`; all separate release execution requirements remain. |

Reuse JSON already saved from `ci_feedback.py`; the new checker makes no API calls
and downloads nothing. Preserve the exact `run_id` and `attempt` when adding a
`runs` entry. Every file reference has this form, with paths relative to the
repository root (absolute paths are also supported):

```json
{"path": ".build/qualification/run-123-attempt-2.json", "sha256": "FULL_64_CHARACTER_FILE_SHA256"}
```

A run entry names `run_id`, `attempt`, `coverage` (one of the three scopes),
`feedback` (the saved reporter payload), `checkout_proof`, `question`, and
`change_since_prior_attempt`. The checkout proof is a small JSON identity record
with exactly these fields, transcribed from retained checkout/build provenance:

```json
{"run_id": 123, "attempt": 2, "head_sha": "FULL_40_CHARACTER_RUN_HEAD_SHA", "tested_sha": "FULL_40_CHARACTER_TESTED_SHA", "provenance": {"path": ".build/qualification/original-checkout-record.json", "sha256": "FULL_64_CHARACTER_FILE_SHA256"}}
```

For example, this `runs` entry records a focused attempt without upgrading it
to merge evidence. Replace every illustrative identity and digest with retained
values; `shasum -a 256 FILE` computes a local file digest.

```json
{
  "run_id": 123,
  "attempt": 2,
  "coverage": "focused",
  "feedback": {"path": ".build/qualification/feedback.json", "sha256": "FULL_FILE_SHA256"},
  "checkout_proof": {"path": ".build/qualification/checkout.json", "sha256": "FULL_FILE_SHA256"},
  "question": "Do both original Dinner journeys pass with the reviewed input fix?",
  "change_since_prior_attempt": "First qualification of the reviewed fix; previous failure retained separately",
  "prior_attempts": [{"path": ".build/qualification/first-failure.json", "sha256": "FULL_FILE_SHA256"}]
}
```

For PR runs, GitHub's head SHA and the checked-out merge SHA may differ. Record
both, and bind every contributing run to the same `tested_sha`; do not relabel
head-only evidence as a tested merge revision. For other events the head must
equal the tested revision. The checker verifies consistency with the saved
report and verifies the referenced original provenance file's digest. It does not
independently establish the truth of a hand-written checkout attestation: review
the linked source record. Unfilled `REPLACE:` template fields keep the checklist
incomplete. Keep the question concrete and record what changed since the prior
attempt, or state that this is its first qualification. Add prior failure file
references under `prior_attempts`; a later pass must not overwrite those bytes.
An unchanged repeat needs an explicit new diagnostic question before scheduling.

### Compact evidence for future batches

Commit the decision, source-change map, exact SHA/scope/run/attempt identities,
important readbacks, unresolved findings and digest-bound original locations.
Keep source changes in `source_changes`, separate from evidence inventory. Avoid
committing another complete source snapshot or repeated exported payload solely
to restate an existing result. This policy does not delete retained history,
rewrite commits or exclude executable evidence from security scanning.

Each contributing run needs an `originals` entry: `run_id`, `attempt`,
`retrieved_copy` (a verified local file reference), `immutable_uri`, `retention`
set to `project-lifetime`, `custodian`, and timezone-bearing
`retrieval_verified_at`. A private retained original may use an absolute local
archive path or `file:///absolute/archive/path`; the checker reads that file and
verifies the same digest, reporting it as **local-only**, not independently
archived. No external account, upload, publication or paid storage is required.
A remote URI must identify a committed blob at a full commit SHA, or a
digest-addressed archive containing the same SHA256 in its path, for example
`https://ARCHIVE_HOST/sha256/FULL_64_CHARACTER_FILE_SHA256`. Remote locations are
reported as attestations with checked local bytes, never independently fetched.
The original
should preserve the complete required raw evidence, including result bundles,
logs and inventory/provenance, not just a selected screenshot. A seven-day
Actions artifact link is not a durable original. Do not remove an existing local
or committed original merely because a receipt exists. If replacing its retained
location, first independently retrieve the proposed archive, verify its digest,
and confirm project-lifetime retention with the named custodian. The offline tool
checks the local archive/retrieved bytes and recorded attestation; it cannot
verify remote availability or a storage provider's retention promise. No archive
service or paid storage is provisioned by this workflow.

Optional `timing` on a run accepts a hash-bound `jobs` JSON reference containing
the complete `total_count`/`jobs` response and a `phase_steps` mapping. Map exact
observed step names to `setup`, `build`, `test_and_validation`, or `collection`.
For example, map `Run selected tests and verify complete execution` to
`test_and_validation`, preserving that combined work. The checker rejects
wrong run attempts, duplicate job IDs, incomplete counts and overlapping phase
assignments; it reports unmapped and untimed steps explicitly. These are sums of
whole step windows, which may overlap across jobs, not critical-path duration,
Mac runner-minutes or pure XCTest time. Reuse retained job metadata if available;
do not download another result bundle just to populate this optional table.
Use the existing reporter's execution/pre-start windows for scheduling context.

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
