# Room in the Cart — current handoff

Updated November 11, 2026. Active goal: finish the complete Foundation 2.1 first release: 52 requirements, 27 screen contracts and B11. Not complete or paused. Read [APP-BASELINE](product/APP-BASELINE.md), [Foundation](product/foundation-gen2.1/README.md), [MASTER-GENERATION](product/MASTER-GENERATION.md), [CURRENT-ACCEPTANCE](CURRENT-ACCEPTANCE.md) and [RELEASE-EXECUTION](RELEASE-EXECUTION.md). Scoped passing components do not establish one qualified release candidate.

## Current checkpoint — November 11

This checkpoint supersedes historical running-process and latest-commit statements below.
Published candidate is **14b75714c2b4f7c9119f3103969fdbaef394f11b** on both
`codex/parallel-ios-ci` and `codex/combined-candidate-20261109`. PR1 identifies that
head. Keep this candidate unchanged while its useful native batch runs. This
handoff-only checkpoint is local and must not cause a status-only push.
The grouped candidate includes the Capture source-editor Done control, nine
test interaction corrections and the matrix admission correction below. All
affected local checks pass; combined hosted qualification remains incomplete.
The owner approved the lean workflow going forward. Follow CI-VALIDATION's daily
triage table: affected checks, one investigation per cause, reuse original evidence,
one grouped candidate push, and full combined/release qualification at its proper gate.
No additional wrapper, test suite, or unattended monitor has been introduced.
The owner reaffirmed these changes going forward. CI-VALIDATION now explicitly
defers optional polish, speculative coverage and new tooling while the first
release has unresolved requirements. Finish and qualify the current correction,
then move to the next unresolved cause. Workflow scheduling and fixture balancing
changes are now published. PR1 remains draft and unmerged.

### Next actions — current queue

This table supersedes running/queued wording in the evidence notes below. It was
checked against both GitHub jobs APIs on November 11; recheck live state before
dispatching. Update this table in place rather than adding another status recap.

| Work | Current decision | Next action |
| --- | --- | --- |
| Published14b combined qualification | Core43005537223, fixtures43005537178 and deep43005537248 remain live. Security43005537157 and native-wire43005537184 pass. Core source/web/service/database checks, both sanitizers and the shared StoreKit build pass; native app/fixture builds and other jobs remain active or queued. Both candidate branches and PR1 identify14b75714; main remains1a2530a7. | Collect this batch's results and verify the corrected matrix admission uses the available global slots. No duplicate dispatch or status-only push. |
| Previous84 batch | All five workflows are terminal. Core fails only its ios-tests matrix; fixtures fail only contributor-tests; deep billing remains failed. Security and native-wire pass. The last two quote cases pass: Spanish largest text104.688s and stale/locked save454.307s, both strict1/1 with zero recorded warnings/idle messages/restarts. | Retain original failures and local correction evidence. Do not rerun84 or label it green. |
| Fractional meal-idea follow-up | The original hosted case continued making progress but spent81s on a compound switch query and repeatedly searched downward for text above its current position. Local test-only changes enumerate named switches before checking state and search upward for those two known-above labels. | Build36976, exact enumeration82764 and test16144 ended0. Strict1/1 passes316.514s in `.build/SharedMealIdeaFollowupNov11/focused`, with matching source/plan hashes and zero recorded warnings/idle messages/restarts. Retain for combined qualification. |
| Ten locally qualified corrections, now published | Capture Done (`f33f0c4d`), duplicate Cancel query (`749b5521`), Dinner amount query (`95d6c609`), largest-text meal query (`aa84e60b`), PickupOffer Shop Button lookup (`25fa9e74`), pairing Apply-dismissal wait (`7348989d`), SharedFallback switch-thumb targeting (`080bfd80`), RecordsMedia native off-thumb targeting (`9947d9f6`), store-price keyboard enumeration (`6129bb99`) and fractional meal-idea query/scroll direction are included in14b. | Retain existing focused passes and refreshed975source checks below while inputs stay unchanged. Await combined results; do not assume hosted resolution from local passes. |
| Matrix scheduling correction, now published | Removed the redundant five-row admission limit from the large core/contributor matrices. The five global native slot queues remain the execution cap. Earlier hosted evidence showed pending rows occupying the admission window while slots1/2 had no admitted work. | Confirm utilization in14b. All975source checks and workflow validation pass; no separate native rerun or dispatch is needed. |
| Correction privacy and RecordsMedia | Correction privacy remains unexplained. RecordsMedia has a new locally qualified targeting correction based on the related SharedFallback evidence; hosted resolution remains unproven. | Preserve RecordsMedia privacy. The correction-privacy event already landed near its native on-thumb, so copying off-thumb targeting there is not supported. No unchanged local repeats. |
| StoreKit | Owner chose “Keep the draft for now.” Declined-request evidence and the separate private Apple draft remain local. | Do not submit or re-ask without a changed need or owner instruction. No blind reruns. Other purchase failures remain separate unresolved observations. |
| Merge and release | Full combined qualification remains incomplete; owner-deferred setup and human/device checks remain separate. | Follow RELEASE-EXECUTION without treating focused passes as release approval. |

For routine progress, report the next decision or a changed result, not every
poll. Documentation-only queue maintenance needs a diff check, not a native
build or a hosted run. The existing CI-VALIDATION policy remains the operational
workflow; no new suite, monitor, wrapper or approval step is needed.

### Retained evidence notes

These notes preserve observations at the time of each check. Historical active
job descriptions are not the current queue.

- **Published14b early gates pass:** security completes all three jobs. Database
  job130471980001 passes1,054service,448PostgreSQL and15maintenance tests with zero
  failures/skips. Native-wire130471976207 verifies24Node integration cases and80
  exact Swift scenario results over pinned HTTPS/PostgreSQL, all passing. Both
  thread130471976618 and address130471976683 sanitizer jobs pass their package
  checks; their three declared separate-wire skips remain scoped to those jobs.
  Shared StoreKit build130472142919 succeeds; EN/ES executions are not yet qualified.
  Five native slots have been occupied, with completed jobs yielding to queued
  builds. The large test matrices have not yet been admitted, so this observation
  alone does not prove the matrix-window change improved utilization.
- **Grouped successor published once:** atomic push moved both candidate branches
  from84b903d0 to14b75714 after every producing job and final gate completed.
  No force push, manual dispatch or deployment was performed. PR1 remains draft,
  with its body rewritten for this source and remaining failures. All ten latest
  retained source hashes match the current files; only handoff documentation
  changed after the975-check pass. The full pending source/workflow diff preserves
  original assertions and deadlines. This checkpoint stays local to avoid a
  status-only push while the new batch runs.
- **Final hosted84 quote cases pass:** Spanish largest-text130458506418 passes
  strict1/1 in104.688s; stale-reviewed-save/locked-shop130460142405 passes strict1/1
  in454.307s. Both report zero runtime warnings/idle messages/restarts. Final
  fixture gate130471392767 fails because the contributor matrix contains the
  seven earlier retained failures; dinner and both builds pass.
- **Independent StoreKit source/evidence review:** Astra found no justified app
  change or new corrective hypothesis. The raw current-entitlements check already
  bypasses the adapter; production requires service acknowledgement before access.
  Original, no-sync and pending-first evidence retains the contradiction. An SDK
  issue is plausible but not proved by app-hosted tests; purchase timeouts and the
  observer failure remain separate observations. No edits, native tests, downloads
  or external contact occurred. Keep the owner's private report draft untouched.
- **Four more hosted84 journeys pass:** Spanish skipped-dinner Undo130446453968
  passes1/1 in563.841s. Records130447526908 passes2/2, English157.400s and
  Spanish251.362s, including export/Cancel/deduplication/inert recovery. Lost-reply
  quote130457623018 passes1/1 in465.851s, including exact retry without a duplicate
  private save. All report zero runtime warnings/idle messages/restarts. PR1 stays
  draft/open; both remote candidate branches remain84 and main remains1a2530a7.
- **Ten-fix source checks pass:** session23816 ended0; all975Python checks pass
  in16.833s after the fractional meal-idea correction. Theme, localization,
  generated project, shard shell and diff checks pass. Log:
  `.build/SourceContractsNov11/grouped-meal-idea-followup.log`. Workflow inputs
  remain those already qualified by `matrix-window-workflow-lint.json`.
- **Published84 fractional meal-idea timeout:** job130429903323 executes the
  original case but reaches720s at the shopper tracking preview. Zero recorded
  warnings/idle messages, one runner restart boundary after timeout. Source
  matching query runs498.40–579.83s; downward searches for the preceding quantity
  and the preview meal heading add repeated scrolls. The original is retained
  separately at `.build/SharedMealIdeaFollowupNov11/hosted/original.zip`, artifact
  13845334716, SHA256d6f2f69a1b80701c60fbe8b68e1dc3bab24180ea6f7f9e6bd27bf1e6cc1cd37a.
  The local correction retains the entire approval/proposal/first-adoption journey,
  every original assertion and720s allowance. Build36976, enumeration82764 and
  original test16144 ended0; strict1/1 passes316.514s with zero recorded runtime
  warnings/idle messages/restarts. Source and exact compiled-plan hashes match.
  Final evidence is `SharedMealIdeaFollowupNov11/focused/Tests.xcresult` and
  `validation.txt`. No production change or normal app rebuild was needed;
  hosted resolution remains unproven.
- **Evidence path collision recovered:** the first follow-up attempted an existing
  `.build/SharedMealIdeaNov11/focused/Build.xcresult` and xcodebuild exited64 before
  building. Its earlier raw build console log was overwritten; the original build
  and test bundles and successful r2/r3 evidence remain intact. A notice and the
  rejected command output record that limitation. The earlier hosted directory
  was also reused accidentally; its original archive13833073005 was downloaded,
  hash-verified8700a4edb3817016caedcc25d79a71cba3241f834813ccfaee3901d554dab333 and
  restored into a fresh directory. The mixed directory was retained as
  `SharedMealIdeaNov11/hosted-mixed-after-collision`; do not use it as an original.
  Current84 evidence was extracted afresh into `SharedMealIdeaFollowupNov11/hosted`.
- **More hosted84 fixture passes:** proposal-return130432093233 passes strict1/1
  in349.406s; quote proposal/shopper-adoption130451862218 passes strict1/1 in560.706s.
  Both report zero runtime warnings/idle messages/restarts. Their existing checks
  remain qualified on84; the changed fractional case is separate.
- **Core84 is terminal; UI09 passes8/8:** job130425452320 completes with zero
  recorded runtime warnings/idle messages/restarts. First-run evidence, long paste,
  explicit reminder scheduling/cancellation, preserved filtered-list context,
  Reduce Motion share cancellation, bilingual account-deletion explanation,
  sampled accessibility audit and export/cancelled deletion/restart all pass.
  Gate130452403128 fails only `ios-tests`; UI01/05/07/10 retain the four original
  failures already qualified locally. No other core job failed. No new correction
  or repeat is justified by this terminal result.
- **Shared quote financial labels pass hosted84:** job130448069082 completes
  strict1/1 in222.107s, zero recorded runtime warnings/idle messages/restarts.
  The original filled-field meaning and named-adult grant action checks pass.
- **Matrix admission correction qualified locally:** the published fixture queue
  held three pending rows on slots3/4 and two executing rows on slots0/3, with
  core UI09 on slot4; later quote jobs for available slots1/2 were not admitted.
  The core and contributor matrices now rely on their existing global slot queues
  without the second `max-parallel: 5` window. Parsed YAML comparison proves this
  is their only configuration change: jobs, gates, tests, deadlines and slots are
  identical. Session92419 passes975source checks in17.307s; workflow lint passes
  all18independently validated queue nodes. Logs and the original queue snapshot
  are `.build/SourceContractsNov11/matrix-window-*`. Coverage is unchanged; actual
  utilization improvement remains to be measured on the next grouped candidate.
- **Grouped source review:** the complete iOS diff from published84 through
  383553ec contains the Capture source-editor Done behavior and eight test
  targeting/synchronization corrections. Reviewed the focus binding and existing
  Done action, actual control identities and retained assertions. No additional
  finding, removed acceptance assertion, increased existing deadline or added
  retry was identified. This review does not replace combined execution.
- **English saved-change and skipped-dinner Undo pass hosted84:** jobs130438757335
  and130439790701 each complete strict1/1, in375.861s and402.290s respectively,
  with zero recorded runtime warnings/idle messages/restarts. Saved-change now
  passes in both languages. These original cases retain Cancel, relaunch, exact
  retry, later food and protected-lunch assertions. No unchanged repeat is needed.
- **Nine-fix cheap source validation passes:** revision6129bb99 passes all975
  Python checks in17.598s; session81315 ended0. Log:
  `.build/SourceContractsNov11/grouped-6129bb99.log`. Theme, localization, generated
  Xcode project, shard shell syntax and diff checks also pass. Reuse while inputs
  remain unchanged; no combined hosted acceptance is claimed.
- **UI08 passes hosted84:** job130415884001 completes strict7/7, with zero
  recorded runtime warnings/idle messages/restarts. Mixed-language list measures,
  cook correction/recipient acknowledgement, receipt usable-amount correction,
  the Spanish Dinner idea journey625.946s, checkout restore, comparison Save
  viewport and largest-text source/details all pass. No unchanged repeat is needed.
- **Store-price keyboard enumeration qualified locally:** UI10 job130431281389
  completes7/8; its missing-price case stalls querying an absent keyboard through
  `firstMatch` after Done. The screenshot shows no keyboard; the failure occurs
  before price assertions. Original artifact13844975113 is retained at
  `.build/MissingStorePricesNov11/hosted/original.zip`, SHA256
  3303436dc91162d19e2f084dd88f39544e8a134fe3e0a84d7875971625d537fa.
  `revealContent` now enumerates present keyboards, matching the existing scroll
  helper. Viewport bounds, price/availability assertions and deadlines are unchanged.
  Build16814, exact enumeration22767 and test13197 ended0. Strict2/2 passes at
  `.build/MissingStorePricesNov11/focused/Tests.xcresult`: entered quotes246.577s,
  missing prices89.34s, zero recorded warnings/idle messages/restarts. Source and
  exact compiled-plan hashes match. No production change or normal rebuild is
  needed; this ninth local correction still needs combined hosted qualification.
- **Spanish saved-change Undo passes hosted84:** job130441316648 completes
  strict1/1 in370.965s, with zero recorded runtime warnings/idle messages/restarts.
  The original Cancel, Apply, relaunch, exact retry and later-food preservation
  assertions pass. No unchanged repeat is needed.
- **Correction-privacy recording review:** retained video frames at actual
  51.933s and53.375s show the fully visible enabled switch. Later requested times
  resolve to that same53.375s frame; they are not independent later captures.
  `.build/CorrectionPrivacyNov11/hosted/toggle-frames/frame-times.json` preserves
  actual times. Together with the event and hierarchy, this does not explain the
  missing dialog or support copying the off-thumb correction. No source change
  or unchanged local rerun was made.
- **Eight-fix cheap source validation passes:** revision9947d9f6 passes all975
  Python checks in16.738s, session75023 ended0, log
  `.build/SourceContractsNov11/grouped-9947d9f6.log`. Theme, localization, generated
  Xcode project, shard shell syntax and diff checks pass. Reuse these checks while
  their inputs remain unchanged; this does not replace combined hosted qualification.
- **Recovery/cook/closeout passes hosted84:** job130413496843 completes strict5/5,
  zero recorded runtime warnings/idle messages/restarts. Pending-credit closeout,
  unresolved replacement preserving the original meal, dated meal replacement,
  exact edited cook wording and reopened recipient send record all pass. No
  unchanged repeat is needed; physical-device audio acceptance remains separate.
- **RecordsMedia off-thumb targeting qualified locally:** the new SharedFallback
  evidence supports testing native thumb targeting in RecordsMedia's enabling
  helper, which previously tapped92percent across the owning row. The helper now
  requires the native child switch, reveals it, taps its off-thumb once if off,
  and retains the original immediate parent-state assertion plus a native-state
  assertion. No retry, timeout increase, production change or removed privacy gate.
  Build32039, exact enumeration60062 and test61678 ended0. The allowlisted report
  confirms strict1/1, zero skips and zero runtime warnings at
  `.build/RecordsMediaNov11/thumb-target/Tests.xcresult`; source and exact compiled
  plan hashes match. Raw logs, recovery material, screenshots and bundles remain
  private; no hosted raw RecordsMedia artifact was downloaded. Syntax/automation/
  diff checks pass. This is a qualified test interaction change, not a proved
  root cause or closure of the hosted failure. No further normal build is needed.
- **Both shared-food editing languages pass hosted84:** Spanish130420763601
  completes strict1/1 in456.063s; English130419812928 completes strict1/1 in549.149s.
  Both have zero recorded warnings/idle messages/restarts. The original expired-
  quote, Cancel, Apply and relaunch-retry assertions pass on the same candidate.
  English's initial log404 occurred while the job was completing; the same handle
  subsequently returned its successful result and logs, with no restart.
- **Pairing return qualified locally:** UI07 job130414154436 completes6/7,
  zero recorded warnings/idle messages/restarts. The original pairing case failed
  66.908s because its immediate navigation helper found no visible Back control
  after Apply. The screenshot shows Dinner library, a Back button and Dinner
  changes saved. Apply saves asynchronously before closing its sheet; the test now
  explicitly requires the Apply control to disappear within the existing10s
  convention before navigating. No production behavior or assertion was removed.
  Original artifact13842696612 is retained at `.build/PairingReturnNov11/hosted/original.zip`,
  SHA2566288e05af437066e4cb62ca2bc4c058812f7fc0e609da3ce37f823971165f723.
  Build10667, exact enumeration98794 and test94631 ended0. Strict1/1 passes46.34s,
  zero warnings/idle messages/restarts, at `.build/PairingReturnNov11/focused/Tests.xcresult`.
  Source/compiled-plan hashes match; syntax/automation/diff checks pass. Existing
  chosen-schedule and no-repeat pairing assertions remain. Hosted resolution is
  not yet qualified; retain this correction for the grouped candidate.
- **SharedFallback switch correction qualified locally:** job130419222033 executes2/2;
  recipe approval/lost-reply recovery passes183.394s, but five-wrap fallback fails
  129.944s at line128 when selecting the usual dinner. The nested native switch
  was off, was tapped once, and its parent did not report1 within3s. Zero recorded
  runtime warnings/idle messages/restarts. The earlier bootstrap crash did not
  recur in this execution. Original artifact13842981833 is hash-verified at
  `.build/SharedFallbackNov11/hosted/original.zip`, SHA256
  2078a551846378cf16147e69a09b5c2e57a70b2714b5bcc47ac35f136f8e5026.
  The retained event taps340.5,604; recording frames show the usual-dinner switch
  fully visible and still off after that track-center tap. Exported AX snapshots
  contain only the application root, so they do not establish the child hierarchy.
  The test helper now targets the current native thumb and requires both native
  and parent state to match within the unchanged3s deadline. Build87817,
  enumeration92849 and original test12162 ended0. Strict1/1 passes153.87s with
  zero recorded warnings/idle messages/restarts at `.build/SharedFallbackNov11/focused/Tests.xcresult`.
  Source and exact fixture-plan hashes match; syntax/automation/diff checks pass.
  Original food, cost, agreements, Apply and cook-note assertions remain.
  No production change or normal rebuild; hosted resolution remains unproven.
- **UI06 passes hosted84:** job130413281674 completes strict7/7 with zero recorded
  runtime warnings/idle messages/restarts. This covers store quotes639.673s,
  authorization hold, printed fluid-ounce labels, recipe capture/Cancel,
  retained placement, confirmed deletion and Spanish source wording. No repeat
  of these unchanged cases is needed.
- **UI04 and stock/purchase now pass hosted84:** UI04 job130384868050 completes
  strict7/7, zero recorded runtime warnings/idle messages/restarts. It includes
  the dinner cap/Cancel journey130.762s and the complete protected-lunch,
  short-fill repair, settlement and next-shop journey549.362s, qualifying the
  earlier UI04 corrections on the published candidate. SharedDelivery stock/purchase
  job130403237746 completes strict6/6, zero runtime warnings/restarts and one
  diagnostic animation-idle message. Its confirmed-order retry, purchase correction,
  delivery correction, freezer coverage and two Spanish cases all pass.
  No unchanged repeat is needed for either group.
- **PickupOffer launch lookup qualified locally:** UI05 job130404370119 executed
  all7 cases (6passed/1failed), with zero recorded runtime warnings, idle messages
  or runner restarts. Its earlier bootstrap crash did not recur in this execution.
  The saved-offer case timed out268.807s querying `newComparison` through Any;
  the retained screenshot shows Compare packs visible on Shop. Original archive
  13842266019 is retained at `.build/PickupOfferNov11/hosted/original.zip`, verified
  SHA25616c2200e4b736fb2b6e6a0b6fa781568356e7b2e7c9155297e6b60a33cef58d4.
  The launch and Shop-return queries now target Buttons, matching the production
  NavigationLink and the passing neighboring shortcut case. No app behavior,
  assertion, retry or timeout changed. Build38486 and enumeration1428 ended0;
  original test20185 ended0 and strict1/1 validation passes201.79s, zero recorded
  warnings/idle messages/restarts, at `.build/PickupOfferNov11/focused/Tests.xcresult`.
  Source and exact compiled-plan hashes match. Syntax/automation/diff checks pass.
  This includes saved forecasts, restart/reopen, response updates and Cancel;
  hosted resolution remains unproven. Keep the correction for the grouped push.
  Prior grouped source checks passed975 before this edit; the final cheap pre-push
  checks must include this new source. No further normal app rebuild is needed.
- **Capture source Done qualified locally:** published84 fixture job130383822595
  completed all13 cases, with12 passes and one failed keyboard-dismissal assertion
  in the original typed/structured request journey (315.238s). The screenshot
  taken after failure shows the keyboard gone; delayed accessibility state versus
  animation timing is not conclusively distinguished. The source TextEditor had
  no explicit Done control. CaptureReviewView now binds its focus to the existing
  keyboard Done action; the original test taps that control and still requires
  keyboard disappearance, unchanged draft text, Cancel with no write and exactly
  one explicit own-request send. `.build/ContributorRequestNov11/focused/Tests.xcresult`
  passes strict2/2: original English177.560s and Spanish largest-text60.639s,
  one execution each and zero recorded runtime warnings, idle messages or restarts.
  Build65106, enumeration77918 and test44490 ended0. Source and exact compiled-plan
  hashes match `focused/source-and-plan.txt`. Normal Debug build61375 also ended0
  at `.build/ContributorRequestNov11/Normal-Build.xcresult`. No local native process
  remains active. Original hosted archive13838746581 is retained at
  `.build/ContributorRequestNov11/hosted/original.zip`, SHA256
  e19b82d1649c0607d2b2a6376429aac9e285645e3cefe6e0c2b972601220e6d4.
- **Latest published84 checkpoint:** all916model tests and Swift CodeQL pass;
  balanced04 passes all13 selected cases. Balanced01 completes3/4, failing the
  duplicate-request journey's sheet-dismissal wait at RequestDuplicateComparisonUITests:146
  (job130383822777). Balanced05 completes13/14, failing the correction-privacy
  opt-out confirmation's existence assertion at LibraryPrivacyUITests:240
  (job130383822827); all3 shared-meal-change cases pass. Follow-up evidence for
  these two failures is recorded below; neither hosted failure is closed. Core UI01–03,
  balanced03 and DinnerDecisionSheet are active or queued with later fixtures.
  Keep the published batch running and the qualified Capture fix local; do not
  push a checkpoint or dispatch duplicate tests. Billing remains unresolved below.
- **Duplicate-request cancellation lookup qualified locally:** original hosted
  failure493.788s is preserved in artifact13839196346, verified SHA256
  f71398b8c84f715d90168a4e20349a4c02322dd34e406b4aaba863e5290d0ac3,
  `.build/RequestDuplicateNov11/hosted/original.zip`. Its screenshot and hierarchy
  show the inbox and saved Lee outcome after the failed5s disappearance wait;
  they do not prove exactly when dismissal completed. The test now scopes all
  Cancel queries to the actual Button instead of all accessibility descendants.
  The original later-page journey passes93.35s, strict1/1, zero runtime warnings,
  idle messages or restarts, at `.build/RequestDuplicateNov11/focused/Tests.xcresult`.
  Build83280, enumeration26119 and test99766 ended0; source and compiled-plan hashes
  match. Syntax, existing automation contract and diff checks pass. No production
  behavior, assertion, timeout or test selection changed. This is scoped local
  qualification, not proof that the hosted timing failure is resolved. Hold for
  the next combined candidate; no normal app rebuild is needed for this test-only edit.
- **Correction privacy remains a hosted-only observation:** original artifact
  13838907255 is verified SHA256
  8313748d3bd09d506b6bc0d05b0504cf073cad6387e69ae50b3f2ab1147baca1,
  `.build/CorrectionPrivacyNov11/hosted/original.zip`. The synthesized event lands
  at356.4,504.83 inside the visible on-switch309,491,63,28; the failure screenshot
  still shows enabled memory and no dialog. A simple missed/off-screen coordinate
  is not supported. One unchanged original journey reused the existing fixture
  build and passes80.35s, strict1/1, zero warnings/idle messages/restarts, at
  `.build/CorrectionPrivacyNov11/original/Tests.xcresult` (enumeration57438,
  test49804 both ended0). It includes named forgetting, last-entry outcome,
  Cancel/no deletion, explicit opt-out, retained Spanish spellings and redacted
  offline support. No production or test source change is justified by this pass;
  retain the hosted failure and investigate further only with new evidence.
  Original source/plan identity is recorded in `original/source-and-plan.txt`;
  the fixture cache was subsequently rebuilt for the duplicate-request correction.
- **Single current queue:** RELEASE-EXECUTION now points here instead of repeating
  an obsolete49b live-run summary. It retains integration/release completion
  criteria. No new workflow, tool, suite or status-only push was added. No local
  native process remains active at this checkpoint; useful84 jobs are still live.
- **Normal capture walkthrough:** installed the completed normal Debug build on
  ownedA50C91FC and launched without fixture/reset arguments (PID93549). Installed
  and cached executable SHA256 both match
  50ee88cd1a29392bb94272faee82d0ce9e60a6a9ec044884662a13dd9fa4669a;
  CaptureReviewView still matches the qualified source066d9d0e6fdedc0d3dbbff8a274ded4c9e9887aa070375b90344046debc5c06c.
  Through Shop → Shopping list → Type or paste a list → Capture and review fields,
  typed `12 wraps` and `2 cans beans`. The visible Done control dismissed the
  keyboard with both lines intact. Cancel returned to the empty outer draft;
  cancelling that returned to the unchanged empty shopping list and prior save
  timestamp. No list additions, permission changes or network sign-in occurred.
  Device Hub screenshots establish this scoped visual result; its AX bridge did
  not expose the app tree, so this is not spoken accessibility acceptance. Two
  pointer scroll attempts did not reveal the lower review control; review-button
  reachability is not established by this walkthrough. CUA completion recorded.
- **Capture reachability follow-up:** launched the installed normal Debug app
  without fixture/reset arguments (PID99104). Installed/cache executable SHA256
  both match d3bb40340053b9a6d8b062fd78ae1adb77d1cab2d02bd88627dffc95c78ad363;
  CaptureReviewView still matches the qualified066d9d0e source above. A touch
  drag outside the text editor revealed the wording acknowledgement and disabled
  Review captured fields action. Acknowledging enabled it; tapping opened the
  parsed review with the actual destination and the12-wrap line. Cancel returned
  to the blank outer draft; its Cancel returned to the unchanged empty list and
  original November10 11:42PM save time. This closes the earlier reachability gap.
  Coordinate timing during keyboard animation altered the second temporary line
  to `2 or`; this is not an exact text-entry qualification. Nothing was applied.
  Device Hub exposed screenshots but no app AX nodes; spoken accessibility and
  physical-device acceptance remain open. CUA completion recorded.
- **Additional84 hosted pass:** DinnerDecisionSheet job130386648785 completes all5
  original cases with zero recorded runtime warnings, idle messages or restarts.
  UI01–03 and balanced03 remain in their test steps; RecordsMedia has started
  restoring products. Do not download private RecordsMedia raw artifacts.
- **Bounded billing documentation check:** Apple's current
  [Ask to Buy instructions](https://developer.apple.com/documentation/storekit/testing-ask-to-buy-in-xcode)
  still say a declined request does not deliver a transaction. The inspected
  [Xcode27 StoreKit notes](https://developer.apple.com/documentation/xcode-release-notes/xcode-27-release-notes)
  and [27.1 notes](https://developer.apple.com/documentation/xcode-release-notes/xcode-27_1-release-notes)
  did not identify a fix/workaround for this observed decline-entitlement result.
  This limited documentation review does not prove an SDK root cause. No new
  billing experiment, toolchain change, skipped assertion or replacement CI run.
- **Separate StoreKit Apple report prepared, not submitted:** two local text files
  are ready in `.build/StoreKitTriageNov11/apple-report-draft/`. REPORT.txt SHA256
  6168c00d9c0d3e663c7768f641cc1c699a8e3500266b1fb832204cb406fc6760;
  EVIDENCE.txt SHA25634b6699e307205095bb9e5a823ccfbeae63fb69db43fc73bf41be096d03d30ef.
  The reviewed draft reuses the original, no-post-decline-sync and after-pending
  results; no tests were repeated. It states the app-hosted scope and unproven
  SDK cause, and includes only structural counts/matches and original hashes.
  The owner answered “Keep the draft for now.” Do not submit these files or
  re-ask without a changed need or owner instruction. Earlier approval covered
  the different XCTest crash report and is not reused here. Keep live84 running.
- **UI02 and UI03 now pass hosted84:** jobs130384868069 and130384868189 each
  execute all6 original cases with zero runtime warnings, idle messages or
  restarts. This qualifies the earlier stock/carryover, replacement/cook and
  saved-offer reminder corrections on the published candidate. UI01 finishes5/6:
  first-pickup dinner-pattern fails281.785s in an accessibility snapshot query.
- **Records Media hosted failure retained privately:** job130400401548 reports
  one executed/failed case, zero skips or runtime warnings, at the switch-state
  assertion RecordsMediaUITests.swift:144. Only the allowlisted public report was
  read; no hosted raw RecordsMedia bundle was downloaded or inspected. The
  unchanged original reused the contributor cache and passes137.949s locally,
  strict1/1, zero recorded runtime warnings, at
  `.build/RecordsMediaNov11/original/Tests.xcresult`. Enumeration87379 and test35597
  ended0; source and compiled-plan hashes still match. Local logs, screenshots,
  recovery material and result bundles remain private under that directory.
  The pass covers selection/disclosure, encrypted export, preview/Cancel,
  separate recovered copy, readable media and scoped deletion. It does not
  establish the hosted cause or close that failure. No source change or repeat
  of this passing unchanged local case is justified without new evidence.
- **First-dinner lookup qualified locally:** UI01's original archive13839774561
  is retained at `.build/FirstDinnerPatternNov11/hosted/original.zip`, verified
  SHA25677415ac34137f5e005bff47022e73f53918a6739de0c8f3a1e49726ce7703429.
  Its screenshot shows the original amount field visible; its scroll trace says
  found after0gestures. The next broad Any/multiple-editable-type snapshot query
  stalled. The local test helper now selects explicit `ingredient.*.amount`
  identities through native TextFields. No production behavior, input, assertion
  or timeout changed. Syntax/automation checks pass; normal build-for-testing12105
  and exact two-selector enumeration27986 ended0. Session49477 ended0; the
  original English first-pickup and Spanish dinner-idea journeys pass136.161s
  and134.23s at `.build/FirstDinnerPatternNov11/focused/Tests.xcresult`.
  Sequential exports and strict2/2 validation confirm one execution each,
  zero recorded runtime warnings, idle messages or runner restarts. Source and
  exact compiled-plan hashes match. This test-only correction needs combined
  hosted qualification, not another normal app rebuild. No local native process
  remains active. Keep this fix local while the useful84 batch continues.
- **Created-meal Undo passes hosted84 in both languages:** English130402388859
  passes532.87s and Spanish130402753890 passes485.73s; both strict1/1 with zero
  runtime warnings, idle messages or restarts. No repeat is needed.
- **Largest-text request follow-up qualified locally:** balanced03 job130383822866 logged
  all9 cases (8passed/1failed) in2223.194s, then hit its40-minute step deadline
  before export/validation completed. The failed case is the largest-text
  protected-lunch journey:368.068s, timed out resolving `Protected portions`
  beneath a broad Any parent. Original artifact13840727565 is hash-verified at
  `.build/RequestPackLargestTextNov11/hosted/original.zip`, SHA256
  2b6b342332da4b697d2c55c1f820deb74751a41711cbdd6b99e5f0063be0d786.
  Tests.xcresult lacks Info.plist; retain it and the complete Tests.log without
  inventing a validated hosted result. The local largest-text case now selects
  its combined meal rows as StaticText, matching the existing other-meals test.
  No production change, assertion removal, retry or deadline increase. Build30752
  and exact selector enumeration51179 ended0. Session62285 ended0: the one
  original case passes74.834s at `.build/RequestPackLargestTextNov11/focused/Tests.xcresult`.
  Sequential exports and strict1/1 validation confirm all existing visibility,
  date, portion, contrast, disabled-Apply and no-write assertions, zero recorded
  runtime warnings, idle messages or restarts. Source and compiled-plan hashes
  match focused/source-and-plan.txt. No local native process remains active.
  No normal app rebuild is needed for this test-only correction. Keep it local
  for the next combined candidate; hosted timing improvement is not yet proven.

- **Source-check repair now passes hosted:** aa176fed core42976888365 source
  job130377944571 failed two stale Python expectations, so its native build/test
  jobs were skipped. The observer contract still pinned the reporter before
  b13a5999's explicit missing-identity failure; the dispatch test still expected an
  automatic PR performance trigger. Reviewed that reporter diff: missing identity
  still fails, skips warning qualification and reports unverified execution; no
  metrics, baseline or successful-case acceptance changed. Its two hash pins now
  match the reviewed reporter. Dispatch profiles now reject events absent from
  the actual workflow, and the existing test verifies explicit manual baseline
  enforcement instead. Full Python source checks pass975 in17.170s at
  `.build/SourceContractsNov11/tests.log`, session52004 ended0. This is a local
  source-only correction; no local native rerun is required. Theme, localization,
  generated Xcode project and shard shell checks also pass. Live recheck confirmed
  fixture builds130378032119/130378032395 were still pending, with no fixture tests
  started. Published84b903d0 once to supersede this already-disqualified candidate
  before spending a full fixture run. All aa176fed runs are now terminal: core
  failed, security passed, fixtures/deep/native-wire cancelled by normal concurrency.
  Original failures and cancellation outcomes remain visible. Successor source
  job130379939475 passes all975Python checks in12.653s, pinned workflow lint,
  localization/generated-file checks and the Foundation verifier on GitHub.
- **Published runs:** core42977513683, fixtures42977513804, deep42977513637,
  security42977513616 and native-wire42977513755 all identify84b903d0. No automatic
  performance run was created, as intended; full release still enforces baselines.
  The broad existing PR diff still selects deep checks. PR metadata was updated
  to this candidate, scoped validation and remaining release boundaries.
- **84b903d0 verified progress:** core source/web/service/PostgreSQL jobs pass.
  Database job130379939021 records1054service,448database and15maintenance passes,
  zero failures/skips. Native-wire130380056383 passes24Node cases and80 actual Swift
  executions, zero Node failures/skips. Security42977513616 passes all3jobs.
  Main test-products build130380172855 is terminal success; its916model selection
  and UI groups are queued. Contributor fixture build130380090029 passes; all5
  rebalanced groups are queued. Dinner build130380090022 is still packaging;
  Swift CodeQL is compiling, English/Spanish StoreKit and Thread Sanitizer are
  active. These are live checkpoints, not full CI or release acceptance.
  Next: read the current runs; diagnose actual new failures locally and retain
  successful unchanged checks. No local native process or background monitor runs.
- **Additional84b903d0 results:** unsigned iPhone Release job130380173794 passes
  compilation and built executable/assets/privacy/environment/extension checks.
  This run does not establish signing or production release metadata. Package
  job130380173826 passes579 tests (CoreDomain201, DeviceSurfaces30,
  HouseholdClient241, LocalStore74, RecordArchive33), with3deliberate client-wire
  skips covered separately by the passing actual-transport job. Both Address and
  Thread Sanitizer jobs130380128198/130380128257 pass. Dinner fixture build
  130380090022 passes; contributor groups01,02,04,05 are executing or booting.
  Swift CodeQL remains active; ordinary model/UI groups remain queued.
- **Billing remains failed at the unchanged source:** deep42977513637 finishes
  both locale jobs with EN11/15 (130382728246), ES10/15 (130382728889), zero skips
  or recorded runtime warnings. Failures match the previous families: Ask to Buy
  readiness/approval timeouts, purchase timeout, verified current entitlement for
  the declined request, plus the Spanish transaction-observer timeout. The decline
  diagnostic still records failed1/purchased0 versus verified current1; membership
  stays Free. No new root cause is established for the timing failures. Billing
  source is unchanged from49b; StoreKitScenarioTests SHA256 remains
  f5efe4f674f5708dc784cd5cacf8e67e854f92302b0d83cb0aa80ad522d12c88.
  Preserve the original GitHub ZIPs locally: `.build/StoreKitTriageNov11/hosted-en-84/original.zip`
  (artifact13836524188, SHA256 f331b4aca60df944d6020a1c1a4dddaa137362a9bc339835937ec9ad81c367a1)
  and `hosted-es-84/original.zip` (artifact13837517541, SHA256
  9f553fca9a5d72f79a9ad5ac4f6cfaca7d7a6d5f6c452089e43a5be3309624d0).
  Both downloads match the hosted hashes and archived summaries. Do not repeat
  the already-rejected local StoreKit experiments without new evidence. Continue
  the independent core/fixture batch; no assertions, deadlines or release gates
  have been relaxed. Keep this checkpoint local without a status-only push.

- **Records switch correction qualified locally:** hosted job130360190957 failed
  the English source-selection step; Spanish passed163.382s. Its recorded tap hit
  the visible native switch's track center but left both switch and owning row
  off. The test now targets the off-position thumb and retains both state checks,
  all export/privacy/Cancel/deduplication/inert-recovery assertions and deadlines.
  `.build/SharedRecordsNov11/focused/Tests.xcresult` passes strict2/2: EN112.799s,
  ES116.908s, one execution each, zero runtime warnings/idle messages/restarts.
  Build17248 and test4945 ended0; source and exact compiled-plan hashes still match.
  Swift syntax and the existing automation contract pass. No production change.
  The original archive13834852047 remains in `.build/SharedRecordsNov11/hosted`,
  SHA256 ade2ca0e927e4e4f7248a66b30b209d50149bc7753aed0add72d14b2a8aa43cf.
  No local native process remains active. Private recovery screenshots stay local.
- **Store quote timeout correction qualified locally:** hosted job130363718894
  reached its720s deadline in the known-trip/private-proposal/shopper-adoption
  journey. The original log shows large reveal drags carrying nearby fields out
  of the lazy Form, followed by repeated searches in both directions. The helper
  now bounds near-edge drags to the observed overflow, preserving full visibility,
  switch state checks, all30attempt bounds and the original720s deadline.
  `.build/SharedStoreQuoteNov11/focused/Tests.xcresult` passes strict2/2: the full
  original journey311.942s and Spanish largest-text54.857s, one execution each,
  zero runtime warnings/idle messages/restarts. Build98925, enumeration73821 and
  test84886 finished0; source and exact compiled-plan hashes still match. Swift
  syntax and the existing automation contract pass. No production change.
  Original artifact13834588872 is hash-verified at `.build/SharedStoreQuoteNov11/hosted`,
  SHA256 e6526416c03c642c63be917c0fdde0d13eadd12695d446beb9e73f75d0c5753f.
  This local pass does not prove hosted runtime improvement. Quote lost-reply/
  relaunch130364984253 passes570.119s and stale-quote130366824736 passes520.034s
  hosted, each strict1/1 with zero runtime warnings/idle messages/restarts.
- **The49b candidate batch is terminal:** all6workflows have finished. Fixtures
  42953140722 has23successful jobs and7failed jobs (6producing jobs plus its gate).
  Core42953140531 has15successful and5failed jobs (4producing jobs plus its gate).
  The final quote job passed; there are no additional unknown failures from the
  completed batch. Known assertion/gesture corrections have affected local passes;
  fixture rebalance and UI05/SharedFallback owned setup require hosted verification.
  The grouped successor aa176fed was published after final diff/ref review; all
  five automatic runs identify it. No duplicate manual dispatch occurred.
- **UI05's seven original app cases now pass locally:** completed normal products
  were reused after compiled enumeration confirmed the exact hosted selectors.
  `.build/CoreUI05Nov11/local/Tests.xcresult` passes strict7/7 in529.650s, one
  execution each, zero runtime warnings/idle messages/restarts. Session40744 ended0.
  This covers ranged-pack relaunch, freezer reservations, next-shop cancellation,
  Spanish protected lunch, navigation restoration, saved offers and shortcut touch
  targets. No source correction was required. The original hosted bootstrap failure
  remains failed; the changed hosted simulator setup still needs verification.
- **Meal-idea timeout correction qualified locally:** hosted job130350223702 executed
  the fractional approval/proposal/shopper journey but reached its720s limit while
  revealing the final shopper controls. Original archive13833073005 is verified at
  `.build/SharedMealIdeaNov11/hosted`, SHA256
  8700a4edb3817016caedcc25d79a71cba3241f834813ccfaee3901d554dab333.
  The existing helper unnecessarily queried viewport geometry before returning
  already-hittable controls and computed it twice before each scroll. A local
  test-only correction avoids these duplicate queries, preserving all assertions,
  24-attempt bounds and original deadlines. Swift syntax/automation checks and
  fixture build25292 pass in `.build/SharedMealIdeaNov11/focused`.
  First local run failed the fractional case355.628s on a partially obscured
  switch; its screenshot proves the interactive keyboard remained visible while
  large drags oscillated across the row. Lifecycle passed107.185s. Successor
  `focused-r2` makes the production tracking Form dismiss on scroll immediately
  and uses near-edge proportional drags without weakening full visibility; the
  fractional case passes317.787s. Its lifecycle case failed99.947s searching for
  the Select All menu while scrolling the form. `focused-r3` now reveals the
  focused field before long press and waits directly for the native menu. Build
  18482 and test36640 both finished0. Both original cases pass together: fractional
  journey321.383s, lifecycle108.440s, strict2/2 with one execution each, zero runtime
  warnings/idle messages/restarts. All approval, cancellation, privacy, fractional
  food, price-acknowledgement and exactly-once assertions and720s limits remain.
  The current source/plan hashes match the successful attempt. Normal Debug build
  91422 also passes at `.build/SharedMealIdeaNov11/Normal-Build.xcresult`.
  Preserve both failed local bundles and the original hosted timeout. Hosted
  runtime improvement still needs the combined successor; no speed ratio is claimed.
  No local native process remains active. Both normal and fixture caches are current.
- **Hosted saved-change Undo passes:** job130352394524 confirms1/1 in310.133s,
  zero runtime warnings/idle messages/restarts, including cancellation, relaunch,
  exact retry and preservation of later food.
- **Additional hosted passes:** English food-editor130343662276 passes596.073s;
  Spanish saved-change Undo130358073646 passes350.635s; skipped-dinner Undo passes
  EN439.498s/ES419.745s in130356584214/130359138519. Idea lifecycle130350641107
  passes350.333s. Delivery recovery/cook/closeout130335504205 passes all5 original
  cases. Financial-field quote130362439353 passes249.082s, and Spanish largest-text
  quote130365595808 passes108.394s. Each log confirms its full selection, zero
  runtime warnings/idle messages/restarts. The hosted fractional-idea timeout
  remains failed despite its local correction; Records and other quotes are still
  active or queued. Do not repeat these successful unchanged cases locally.
- **New bootstrap failure classified:** SharedFallback job130340123821 finished
  with no selected test started, the same `XCTWaiter(StallHandling)` startup fault
  as UI05. Its original archive13831339171 is retained in
  `.build/SharedFallbackNov11/hosted`, SHA256
  f83aeeab36fd3500ca1fd03994eb35815d8c1d01452fdaf6b0abee0f3c89728f.
  The current reporter reprocesses it as two unverified cases without KeyError;
  `checker-followup.txt` remains failed. This is not a fallback app assertion failure.
  The next candidate extends the existing owned-simulator selection only to UI05
  and SharedFallback. Existing 14 selection/ownership checks, the fixture workflow
  check and pinned workflow lint pass. UI01 (6/6) and balanced01 (4/4) hosted logs
  confirm successful owned-device creation, complete execution and owned cleanup.
  Fresh setup is a hypothesis to qualify in the next hosted batch, not a proven
  fix; no retry, selector, runtime or deadline changed.
- **New hosted pass:** Spanish food-editor job130346397067 executed its original
  expired-quote/Cancel/Apply/relaunch journey successfully in369.644s, strict1/1.
  No replacement run was dispatched for this pass.
- **Interrupted civil-date coverage qualified locally:** all eight original
  SharedMealCivilDate tests pass against the completed contributor build, without
  a rebuild or Swift changes, in `.build/SharedMealCivilNov11/Tests.xcresult`.
  Enumeration verified all eight selectors before execution; strict result
  validation confirms8/8, one execution each, zero runtime warnings, idle messages
  and runner restarts. Execution took207.239s. This covers EN/ES, four US zones,
  largest text, staged cancellation/dismissal/confirmation and scheduling without
  replacing meal needs. Session73427 ended0. First parallel summary export hit
  xcresulttool's lazy database creation collision; sequential re-export and strict
  validation passed without rerunning tests. Do not export the same fresh bundle
  concurrently. The original hosted timeout remains failed; the rebalanced group
  still needs hosted qualification. No local native process remains active.
- **English created-meal Undo now passes hosted:** job130329027253 confirms1/1
  in504.019s, zero runtime warnings/idle messages/restarts, including Cancel,
  relaunch and exact retry while preserving lunch, later meals and staples.
- **Qualified local changes:** workflow scheduling 6a7a43ca/0813bedb,
  comparison/pickup corrections ebbf4356/ac3493da, numeric dinner input 4cf0ffcc,
  and runner-failure reporting b13a5999. The reporter's 48 tests passed; reprocessing
  the original UI05 bundle still fails clearly for 7 unverified selections instead
  of raising KeyError. It does not convert the runner crash into a pass.
- **UI04 qualified locally:** commit 78cf5940 keeps exact keyboard-dismissal/value
  checks, scopes the retained handoff button to the active collection, waits for
  the library Back control after Apply, and removes the fragile adjacent-field
  keyboard/scroll optimization. The original full Free journey passes in 358.031s in
  `.build/CoreUI04Nov11/focused-r4/Tests.xcresult`, strict 1/1 with no runtime
  warnings, idle messages or runner restarts. It covers protected lunch, short
  delivery/repair, settlement, next-shop reuse/relaunch and saved history. The cap
  journey's unchanged correction passed in 56.839s in the first focused bundle; that
  bundle overall remains failed. Original hosted and local r1–r3 failures are
  retained, including r3's 138.069s Group servings scroll oscillation. No original
  outcome assertion or test execution limit was relaxed.
- **Household selector qualified locally:** commit 5b4fb46f changes only two
  meal-change-occurrence lookups from Any to the observed native Button type.
  The original planner→shopper proposal test passes in 101.813s, strict 1/1,
  zero runtime warnings/idle messages/restarts, preserving Cancel, send, separate
  shopper review and exactly-once Apply. Build 55209 and test 36140 ended 0 normally.
  Results: `.build/SharedMealChangeNov11/focused`. The original balanced05 job
  130307937540 remains failed (13/14, including all nine guardian tests passing).
  Its screenshot shows the picker and a passing sibling's log resolves its type.
  Artifact 13830436305 is retained in `.build/SharedMealChangeNov11/hosted`, verified
  SHA256 e27dafca2a1f261d63fbce4d54718c4d1b110f7d90d0960a536702c9164fb0ab.
  Swift syntax and the existing automation contract pass. No new native suite
  was added and no production behavior changed for this selector correction.
- **Request editor keyboard and expiry qualified:** commit 5f1eec54 adds the
  existing explicit Done control to item, price and clarification fields. The
  first local run proved the keyboard actually remained visible after the test's
  swipe; a visible-keyboard assertion alone did not fix it. The original Cancel
  preview journey now passes in 102.797s and largest-text lunch/date journey in
  76.540s, strict 2/2 with zero warnings/idle messages/restarts, in
  `.build/RequestPackNov11/focused-r2`. The expiry assertion now checks the full
  device-local representation of the fixture's 2099-01-01T00:00:00Z instant, rather
  than hard-coding 2098. A Foundation probe confirmed 2099 in UTC and 2098 in New York.
  The ordinary Debug app also builds (`.build/RequestPackNov11/Normal-Build.xcresult`).
  Original hosted artifact 13831526605 is hash-verified and retained in
  `.build/RequestPackNov11/hosted`; its Info.plist is missing after the 40-minute
  deadline, so no complete hosted result or unexecuted civil-date pass is claimed.
  The failed initial local bundle and screenshots remain in `focused`.
- **Measured fixture rebalance:** commit 725f72cb moves the two device-management
  tests from balanced03 to balanced02 and eight civil-date tests from balanced03 to balanced04. It preserves
  five groups, 26 fixture jobs, 89 tests, five macOS slots and all limits/assertions.
  Existing 16 planner and 1 workflow checks pass (workflow check uses `.build/ci-yaml/bin/python`).
  The overloaded original03 finished 11 of 19 cases before timeout; current balanced02/04 had
  shorter 24.3/23.4-minute job windows. Successor wall time needs hosted verification.
- **Dinner visual polish:** commit a73c3016 applies existing canvas/surface/text
  colors to Dinner library and Dinner ideas and uses the existing readable
  exclusions prompt. Builds pass in `.build/DinnerLibraryPaletteNov11`.
  Direct Device Hub review verified both screens in light/dark, then the final
  readable prompt in light. Original System appearance was restored. No meal was
  created or applied. Screenshots are retained in the conversation; CUA completion
  was recorded for both parts. This is scoped visual proof, not full accessibility.
- **Core batch is terminal:** run42953140531 finished with15 successful jobs and
  five failed jobs, including the final aggregation gate. UI01 and UI06–10 pass;
  the final UI09 job130328328776 confirms8/8, zero runtime warnings/idle messages/
  restarts. It includes contextual reminders, cancelled share/import, large text,
  automated accessibility and owner export/deletion safeguards. All916 model
  tests, non-UI checks and builds pass. The remaining red jobs are the previously
  diagnosed UI02/03/04 assertions (all five have local passing corrections) and
  UI05's seven unexecuted cases after bootstrap failure. No new core failure emerged.
  Original job: https://github.com/palatis3/room-in-the-cart/actions/runs/42953140531/job/130328328776.
- **Fixture batch remains active:** run42953140722 has passing balanced01/02/04,
  DinnerDecisionSheet, RecordsMedia, both created-meal Undo journeys, Spanish
  food-edit review and delivery stock/purchase. Delivery is6/6 with zero runtime
  warnings/restarts and two idle messages. Balanced03/05 and SharedFallback retain
  the failures classified above, plus the fractional meal-idea timeout. Food-edit,
  idea lifecycle, all four operation Undo and recovery/cook cases now pass as
  recorded above; Records and remaining quote cases are active or queued. Do not replace this
  useful run just because core has finished. No duplicate dispatched.
- **Next publication:** inspect new terminal failures once, then group verified
  changes after this useful batch. UI02/03/04 and the observed balanced03/05
  assertions have passing local affected checks. UI05 bootstrap failure has clearer
  reporting, not proven runtime resolution; civil-date coverage now passes locally
  as recorded above and still needs combined hosted qualification. No local native process is active. Normal and contributor caches
  both contain completed current builds. Preserve original failures and do not
  repeat unchanged passing checks. Provider/signing owner deferrals remain unchanged.

## Workspace and ownership

Latest checkpoint: UI03 follow-up is committed in **ac3493da**. The normal Debug build succeeded and the two original failed journeys passed in `.build/CoreUI03Nov11/focused/Tests.xcresult`: pickup retailer-confirmed amendment/restart **81.568s**, known comparison save/reopen **60.21s**. Strict validation confirms **2/2**, one execution each, zero runtime warnings, zero observed animation-idle messages and zero runner restarts. Pickup fields are entered once and verified exactly after Done; saved comparisons use a Button query instead of Any. All substantive assertions remain. Original hosted UI03 artifact13828052692 and screenshots are retained in `.build/CoreUI03Nov11/hosted`. Local test session80623 ended0; no new hosted run was dispatched. The workflow changes remain local for the next grouped push; published49b core/fixture work is still useful and must not be restarted just for these changes. Core UI01 also completed successfully. Sol monitoring stopped on a reported usage limit; the root agent checked GitHub directly. No unattended monitor is promised.


Canonical repository `/Users/palatis/Room in the Cart`, branch `codex/parallel-ios-ci`; ambient Spanish worktree is stale. Both this branch and `codex/combined-candidate-20261109` are published at **49bde5529263db829e8857249982b851f9cd33bb**. PR1 remains draft/open. Its merge checkout60a699e2e22a43af6780a214f589f2ea998745e0 and candidate have identical treeb97902d1a13224d2d8f26747fdae6f11925547b3; base remains1a2530a7. The normal automatic integration batch is running; do not dispatch a duplicate or push status-only changes while it runs. Twelve grouped local commits after5e include protected Dinner portions, labels/palette, profile-specific caches, fixture protocol/selector corrections, explicit meal-source adoption, checkout entry and Records controls. All are now in the published candidate.

Latest local source/test commit is **ac3493da**, following four unpublished implementation commits after the frozen published49bde552 candidate: two workflow changes and two qualified UI-test corrections. It narrows automatic deep checks to billing/household, shared packages and relevant infrastructure, and makes performance manual/reusable only. Full core/fixture coverage and release deep/performance calls remain unchanged; release still enforces approved baselines. The existing13performance-environment,6StoreKit-workflow and19performance-planning checks pass, as do8representative path selections and pinned workflow lint. A follow-up caught the older trigger-coverage and Xcode-migration expectations before publication; those now match the intended policy and pass8trigger,3toolchain and9release-preflight tests. The literal/trailing-prefix trigger parser is preserved; release guards and full core/fixture selection remain intact. Do not push this commit while the49b batch is useful; group it into the next necessary candidate update. No native suite was rerun for these workflow-only edits.

No Dot/Lumpy. Astra helpers edit explicitly assigned, nonoverlapping files in the canonical checkout; root reviews, integrates, commits and dispatches. Do not create scratch-install approval steps for already authorized local implementation. Root owns the single local native/PostgreSQL execution slot. Preserve original failures, private fixtures and unrelated untracked evidence. Stage named paths only. Do not re-request owner-deferred provider or signing setup.

## Development priority

User explicitly requested less engineering overhead and fewer repeated tests on
November 10. Finish product behavior first; use affected build/tests per edit,
batch broad regression at integration/release, and stop optional hosted diagnostic
work for now. Follow the new priority section in [CI-VALIDATION](CI-VALIDATION.md).
Do not erase known failures or represent deferred checks as passed.

## Active execution and next actions

Current49b batch: [core42953140531](https://github.com/palatis3/room-in-the-cart/actions/runs/42953140531), fixtures42953140722, security42953140572, native-wire42953140520, deep42953140476 and performance42953140562. Security and native-wire are already successful. Core source/TypeScript/PostgreSQL jobs, Swift packages, Swift CodeQL, iPhone simulator and unsigned Release builds, both fixture builds and both sanitizers passed. The916-model shard130306719801 passed all916selected tests with0failures,0runtime warnings and0runner restart boundaries (actual execution54.903seconds; strict export verified916/916). Root is collecting UI execution and remaining job results; Sol `combined_core_monitor` stopped on a reported usage limit. Performance failed the same unapproved Xcode27.1/iOS27.0/iPhone17/arm64 baseline preflight before macOS work. English StoreKit job130304057202 is now terminal failure: all15executed,11passed and the same four historical originals failed,0runtime warnings. Spanish also failed10/15 with the additional post-restart observer failure documented below. Remaining core and fixture integration jobs are still being collected. This does not invalidate the passing core/fixture builds or establish billing qualification. The updated PR body records current staging and scoped validation; this is not full candidate acceptance.

Current49b DinnerDecisionSheet fixture130307734032 passes all5selected journeys (264.022seconds actual test execution), including both languages and largest text, with0runtime warnings/runner restarts. Result export verified5/5; artifact13827397421 uploaded successfully. Remaining core and household UI jobs are still live; do not infer their results from this fixture pass.

The current49b UI-02 job130306719795 failed one of six cases: `testUnknownPackAmountRemainsUnresolvedAfterSaveAndRestart` stalled while looking up Done after focusing bPrice, before entering its price or reaching Compare. The original screenshot shows the focused empty field, keyboard and visible Done; query attachment identifies the label-IN/FirstMatch lookup. Artifact13827553775 (SHAf702a828885c251e1a56160bfcee167f7b54bc6bba4d036671c1db86ca61419a) is preserved in `.build/ComparisonUnknownNov11/hosted`.

Commit **ebbf4356** changes only the comparison UI-test helper: exact existing Done/Listo identifiers and one cached successful readiness check, preserving the one focus retry,3-second waits, exact entered values and all result/save/restart assertions. Fresh normal Debug build passes. Both original affected journeys pass in `.build/ComparisonUnknownNov11/focused`: unknown English46.33seconds, Spanish saved answer62.19seconds; strict2/2,0runtime warnings/idle messages/runner restarts. Swift syntax and existing automation contract pass. Build74794 and test19778 ended0; no local native process is active. The normal cache now contains this standard scheme build. Group this correction with the held workflow commits after the useful current batch ends; do not push/restart early.

The preceding5e batch is terminal: core16passed/4failed, fixtures14passed/16failed, security3passed, wire1passed, deep4passed/3failed and performance0passed/1failed/3skipped. Counts include aggregate gates. It passed915models and combined backend1,054unit/448database/15maintenance checks. Its three failed core UI originals now pass locally; fixture failures are grouped in the qualified corrections below. The proposal-return case passed255.882s/strict1of1 but failed artifact upload, and Guardian failed app launch before its body. Preserve these infrastructure distinctions. All original logs/results remain retained; old5e is not relabeled green.

Previous Deep42923486877 fails both StoreKit locales: 11/15 pass in each; two pending-request waits, one purchase timeout and the restored/declined-entitlement contradiction remain open. Both sanitizers pass. Performance42923486984 fails its early compatibility gate because the Xcode27.1/iOS27.0 baseline is unapproved; no measurement pass is claimed. Optional framework/performance experiments remain deferred.

A local scene-aware purchase hypothesis built but did not resolve the four selected StoreKit failures. Its source change was **reverted**, not integrated. `.build/StoreKitPresentationNov10/result.json` records the rejected patch and native logs. Xcode finalization was deliberately interrupted after all cases recorded failures; no complete result-bundle qualification is claimed. The rejected StoreKit source change remains absent. The earlier ordinary-app walkthrough used a normal Debug build (`.build/ManualDinnerWalkthroughNov10/Build.xcresult`). `.build/TrackingFlowUIQualificationNov10/r1/dd` contains the completed contributor/stock/carryover build from Records r2; do not reuse that fixture entry point for ordinary Shop acceptance. The earlier normal build/results remain retained in `.build/ManualDinnerReminderNov10`. Use the existing local lightweight-capture guidance rather than repeating this hypothesis or adding another diagnostic framework.

Staging048 is now deployed and verified within the scope below. Next product acceptance is authenticated household/provider lifecycle and the remaining device/human release work; public route checks do not close those requirements. Browser walkthrough remains deferred: the latest CUA attempt reports local browser use disabled. Do not repeatedly request owner-deferred setup.

Latest additional hosted result: balanced05 (`130212601929`) executed all14selected cases and passed13, including allthree SharedMealChange journeys. `GuardianEnrollmentUITests/testCancelSetupDialogHasExplicitCancelAndForegroundRestoresStatus` failed before test-body actions: app launch never obtained a process ID after210.55s. This is launch-stage evidence, not a demonstrated guardian-flow defect. Preserve the original job log; do not introduce a speculative application fix or broad retry. Re-evaluate the original case in the next combined candidate batch. The latest local commits and active native session are recorded above and in the focused follow-up section. That historical batch is terminal; the current PR and live batch are49bde552 as recorded above. PostgreSQL is stopped.

## Earlier component checkpoints

1. Local backend r3 is terminal PASS: `.build/SharedDemandGraphNov09/root-records-protected-backend-r3`. All eight new Records-v2 HTTP cases pass. Full regression: 1,031 offline plus one database-only skip; 441 PostgreSQL plus three separately assigned browser skips. Root verified309inputs/phase hashes and byte-identical compiled production against qualified r1; signed restore/erasure passed; database stopped. [Proof](evidence/service/records-protected-conversion-20261110/records-http-verification.json).
2. Records import-review correction builds and passes BOTH original EN/ES journeys (2passed,0failed,0skipped,0reported runtime warnings), session82335 terminal0. Original build/test logs and result bundle: `.build/SharedRecordsNov10/review-focus`. Screenshots inspected for review dates/actions and recovered disclosure. r12's failure is retained: opening a later import left the viewport below its details; the view now scrolls and moves accessibility focus to the import review. A subsequent generated-heading localization correction uses the existing Records catalog; final build validation passed (session45626 terminal0). No backend/wire/model suite was unnecessarily repeated.

3. Combined core successor [42905420428](https://github.com/palatis3/room-in-the-cart/actions/runs/42905420428) at `a19c5cf7` passes source checks (970Python), TypeScript service/web, all1,054service unit,447database integration and15maintenance tests. PostgreSQL17 tools fixed all three restore failures. This older run is now terminal failure:12jobs passed and8failed including the aggregate gate. Its failures are summarized below; do not rerun its unchanged revision. Swift package tests all passed, but its post-run gate rejected an added regression against an old exact inventory. The local checker now treats the reviewed inventory as a required minimum while requiring every compiled test to execute, pass and obey the same skip policy. Nine focused checker tests pass; rechecking the original hosted artifact passes196CoreDomain,30DeviceSurfaces,241HouseholdClient,74LocalStore and33RecordArchive, with the same three deliberate wire skips. This does not change the failed hosted job's recorded status. Existing logs/artifacts are under `.build/CombinedCoreNov10`; no package tests were rerun. Optional performance diagnostic42892918759 remains deferred and failed.
4. Selected and carried history now includes exact food graph/pack/tracking revisions, stock corrections and carried delivery ancestry. Old files remain readable with explicit capture coverage. Cross-shop cook text requires current shopper scope on each recorded source; stock-only physical evidence never includes source budgets/other meals. Backend12focused and client11focused checks pass. Database passes444,0fail,3separate browser skips (session77437 terminal0; owned cluster stopped and removed). Native app build and11focused archive/erasure checks pass (sessions74688/60719 terminal0) in `.build/SharedRecordsNov10/carried-history-native`,0skips/0reported runtime warnings. Database logs: `.build/SharedRecordsNov10/carried-history-database`. Localization passes30catalogs/4,751entries. No local process is active.
5. Qualify the grouped feature and CI repairs with one full core CI batch; use focused existing checks for any diagnosed failure, then batch its repair. Existing local restore erasure reconciliation was inspected and verified, including pending cleanup across restart, stale recovery opens, media erasure and deleted-source import refusal; do not invent a second recovery subsystem. Remaining work is combined regression, actual authenticated/deployed household and deletion acceptance, plus the release boundaries below. No household authority is restored from these files.

6. Dinner proposal group editing is installed locally: explicit ingredient/group quantities can be edited independently; exact totals are checked before planner review or shopper seed review. Protected lunch, IDs, original evidence and unknowns remain explicit. SharedMealChangeTests passes15/15, including the9wrap/7dinner+2lunch regression, Cancel, exact retry and scope changes. Production app builds through `.build/SharedMealGroupEditingNov10/native/Build-r4.xcresult`. Direct Device Hub walkthrough verified9total,7dinner,2protected lunch, unchanged original after Cancel, then1proposal/0applications. The newly attempted automated UI case was removed from the pending diff after test-input/selector failures and repeated60-second XCTest animation-idle waits; originals `Tests.xcresult`, `UI-r2.xcresult`, `UI-r3.xcresult` remain unqualified. UI-r2's post-test diagnostic collector was interrupted by exact PID; UI-r3 was interrupted and its driver exited75. No hosted/native diagnostic qualification is claimed. The scoped model regression remains automated; the flag-only fixture remains available for direct UI reproduction.
7. The five model fixture suites that failed43cases in the hosted914-case shard are repaired locally: current `/demand/tracking` projections, v2 request review/retry and truthful legacy/recovery expectations. Production authorization and expiry guards are unchanged. Build-for-testing passes. The initial61-case focused run passed47/47 across the four non-request suites and12/14 request cases; after correcting the request fixture’s invalid far-future candidate expiry, only its14cases were rerun and all pass. Strict result validation confirms14executed/14passed,0runtime warnings. Existing transport, Cancel, protected quantity, exact-byte retry and apply-once assertions remain. Logs/results: `.build/TrackingFixtureRepairNov10`. No unrelated service/database/package suite or broad CI was repeated.
8. Hosted run42905420428 remains unqualified: iOS Debug/test build and unsigned Release build pass; UI-01/03/05/06 and Swift CodeQL pass. Hosted UI-02/07/08 failures now have local focused passing repairs (below). UI-04 timed out after720seconds in `FreeJourneyUITests/testFreeDinnerProtectedLunchShortFillRepairSettlementAndNextShop`; other6cases passed. Astra’s read-only audit of job130150130793 found cumulative runtime, not a demonstrated stuck route: settlement at689s, next-shop dinner Apply at715s, and a reused-dinner capture at748s after the720s timeout fired. Final relaunch/Records assertions never completed. The small test-only correction now uses typed button queries and returns directly to `dinnerWeekEntry` instead of first revealing the unrelated library. Normal Debug build passes; the original journey passes locally in427.655seconds, including final relaunch and Records assertions, with the original720-second allowance. Strict validation confirms1executed/1passed,0runtime warnings. Logs/results: `.build/FreeJourneyQueryRepairNov10`. Local iOS27.0/SDK27.1 success does not qualify hosted timing or the combined candidate. UI-10 passes all8cases. UI-09 finished with7/8passing; its reminder journey timed out evaluating the known `ledgerReviewImport` Button through an Any query after successful typing. The two-line typed-button correction now builds and passes the original reminder journey locally in146.534seconds,1/1executed with0runtime warnings and every assertion/time limit retained. Results: `.build/ContextualReminderQueryRepairNov10`; original failure: `.build/CombinedCoreNov10/ui-09.log`. Batch all verified corrections into the existing PR head for one integration batch. Shared-meal fixture review is now repaired and all three original S17 UI journeys pass locally: planner proposal/Cancel/separate shopper Apply once; shopper seed/Cancel/Apply; repeated clock-time review and day move without extending the deadline. The fixture explicitly starts with tracked manual soup of unknown usable quantity, not legacy adoption. Current v2 read and v1 review/command responses retain exact proposal identity and preview binding. Strict result checks pass with0runtime warnings. Originals are `.build/FocusedUIRepairsNov10/Shopper-r2.xcresult` and `ProposalDeadline-r2.xcresult`. The initial setup/title-selector failures remain preserved in `Tests.xcresult`. This is isolated-fixture acceptance, not deployed mixed-device verification.
9. Focused normal-app UI repairs pass: typed Compare-button lookup avoids the saved XCTest Any-query traversal fault; comparison entry waits for its existing focus-driven Done control before typing; share cancellation waits separately for dismissal and the unchanged frozen snapshot. Hosted UI-07 failed the old share-dismissal wait despite a visible frozen snapshot; UI-08 failed typing before the save/viewport assertions because no input had focus. Native normal Debug build passes. All3original failed journeys pass in `.build/FocusedUIRepairsNov10/CoreTests-r2.xcresult`: large-text Edit112.84s, share cancellation107.45s, save/viewport56.12s. Strict validation confirms3executed/3passed and0runtime warnings. Share cancellation retains exact frozen text, persisted cancellation history and unplaced state after relaunch. Comparison tests retain exact input, whole control visibility and known totals. These local passes do not rewrite the historical failed hosted jobs or qualify the complete candidate. No model/service/database suite was repeated for these test-only edits; no broad successor dispatched.

## Local Dinner and reminder correction qualified

Free manual Dinner edits could discard reviewed portion bindings: increasing eight wraps to nine while changing dinner servings could reduce two protected lunch wraps to an inferred1.8. The local correction keeps protected bindings, reviews mutable group amounts explicitly and applies them atomically. Legacy proportional meals use their existing known allocation as the baseline; unknown quantities remain unresolved. Review and Cancel save nothing. Six focused domain cases pass, including the two-pack boundary, replay, legacy compatibility, invalid-allocation rejection and a bindings-only bypass. Normal app/test compilation passes. All8selected native cases pass with0reported runtime warnings: six Dinner draft tests, the existing Free preview/Cancel/apply-once model test and the original offer-reminder UI journey (177.39s). Results: `.build/ManualDinnerReminderNov10/Build-r2.xcresult` and `Tests.xcresult`. The first build failed only in the new test fixture, which was corrected to use the public ledger API; the original build log remains retained. The ordinary Free app was then exercised directly: created eight wraps with dinner3/lunch1 servings and protected lunch; reviewed nine wraps with dinner4/lunch1 servings and explicit seven/two allocation; Cancel preserved the saved eight wraps/four servings; Apply saved nine wraps/five servings. After actual termination and relaunch without resetting the workspace, the editor retained nine total wraps, seven dinner wraps and two protected lunch wraps. No pack quotes were entered in this walkthrough; the two-pack boundary is covered separately by the domain regression. This simulator walkthrough does not replace physical-device or human accessibility acceptance. No successor CI batch has been dispatched; preserve the current hosted5e batch before publishing these local changes.

The follow-up label-only change keeps captions visible for filled serving and quantity fields, adds44-point minimum field heights and uses neutral English/Spanish protected-serving wording. Localization and syntax checks pass. Incremental normal Debug compilation passes (`.build/ManualDinnerWalkthroughNov10/Labels-Build.xcresult`); native visual review confirms visible total/group serving captions, group-allocation caption and protected lunch wording with the saved9/7/2amounts retained. No behavioral test suite was repeated for this presentation-only change.

## Current focused follow-ups

Meal input improvement is committed in **4cf0ffcc**. Ordinary manual dinner entry exposed text-autocorrection behavior in a quantity field. Numeric dinner-template and week-edit inputs now disable autocorrection/capitalization and use numbers-and-punctuation (fractions remain enterable); integer lead time uses numberPad. No parser, quantities, reservation policy or save behavior changed. Swift syntax checks pass in Release/Debug profiles; normal Debug build14610 ended0 in `.build/DinnerNumericInputNov11/Build.xcresult`. The installed app (PID71920, ownedA50 iOS27.0) directly displayed the punctuation keyboard, retained `2 1/2` after Done, displayed the minutes keypad, and retained `30` after Done. Returned to Dinners without reviewing/applying the meal. Only a fictional local pickup named `meal walkthrough` was created. Screenshots are in the conversation; this is a scoped manual input check, not full meal/locale/accessibility acceptance. Both CUA parts were completed. The normal Debug cache now supersedes the temporary StoreKit diagnostic products; original StoreKit source remains restored. Group this source change into the next candidate update and let combined coverage exercise affected dinner routes.

The observed Dinner palette mismatch is corrected using existing `WorkingForm`, `workingSurface` and theme roles on the root, chosen-meal list, occurrence, manual editor and preview. Normal Debug compilation passes in `.build/ManualDinnerWalkthroughNov10/Theme-Build.xcresult`. Direct simulator review confirmed the light root/list/detail/manual screens and dark root; the app appearance preference was restored to System. This is scoped visual review, not full human accessibility acceptance.

Core UI06 passed six of seven cases but the store-quote journey stalled on an Any-type lookup for the Cancel preview button. Its original log is `.build/CombinedCoreNov10/successor-ui-06.log`. The two affected Cancel/Apply queries now use their actual Button type; assertions and limits are unchanged. The original journey now passes locally in414.29seconds, including Cancel, Apply, restart and preserved earlier comparison. Strict validation confirms1executed/1passed,0runtime warnings and no runner restart (`.build/QuoteCancelLookupNov10/Build.xcresult`, `Tests.xcresult`). No assertion or timeout was relaxed. Hosted Spanish created-dinner Undo failed because its fixture lacked the current `/demand/tracking` read. Balanced03 hit its40-minute step timeout after four request-pack failures; two Apply failures likewise reflect a missing tracking fixture response, while the keyboard and largest-text menu failures need focused gesture requalification. Its raw result bundle is incomplete without Info.plist; original log and raw PNG payloads are retained in `.build/RequestPackFollowupNov10/hosted`. Fixture endpoint, menu and gesture corrections are prepared; no native pass is claimed yet. Keep the existing hosted batch running and batch verified corrections once.

The six-case fixture repair batch is terminal PASS in `.build/FixtureProtocolRepairsNov10`: build and all6selected original/compatibility cases pass, with0reported runtime warnings and no runner restart. Strict result validation passed. Cancel-preview160.339s, largest-text122.911s, reviewed-pack Apply259.569s, carried-request Apply109.936s, Spanish creation Undo252.754s and non-meal Undo207.740s all retain their original substantive assertions/time limits. The fixtures now supply current tracking reads; Undo preserves exact receipts, unknown quantities and protected/source facts. Menu and keyboard corrections operate the actual controls. Session8828 ended0; no PostgreSQL process or new hosted batch was started. The separate FoodEditor/MealIdea changes were installed after this binary and are not covered by it.

FoodEditor tracking preflight is qualified and committed in6ddeb371. Its unchanged Spanish expired-quote/Cancel/Apply/relaunch-exact-retry journey passed251.299s in `.build/FoodIdeaFixtureFollowupsNov10/Tests.xcresult`; do not repeat it for unrelated edits.

The Meal Idea first-adoption successor now builds and passes the original full journey in `.build/FoodIdeaFixtureFollowupsNov10/r6`: **1/1passed386.51s,0runtime warnings,0observed animation-idle messages,0runner restarts**, strict result validation passed. It retains original legacy soup, adds a separately unpriced Chickpeas pack, binds the exact half-cup meal source, preserves exclusions, verifies Cancel/no basket writes, requires explicit unknown-cost approval and applies exactly once while retaining both meals. Stable per-line item/manual/unit identifiers support the actual controls; numeric facts, permission gates and original substantive assertions remain. The other proposal lifecycle case is unchanged.

Earlier r1/r2 failures were new selector errors; r3 exposed the incorrect drag endpoint. r4 exhausted12minutes in old setup due repeated framework animation-idle waits. After an owned simulator restart, r5 had no such stall and proved the keyboard had moved below the app while its AX element remained. r6 verifies actual on-screen keyboard dismissal and passes. All originals are preserved under the same folder. No failed original has been relabeled passing. Session38350 ended0; there is no active local native test at this checkpoint.

The checkout interaction correction is committed ind8e67c35: charge entry follows displayed order with one Done, preserving known/unknown data and assertions. Both original weighed-checkout cases pass79.01s/72.53s in `.build/WeighedCheckoutFollowupNov10`, strict2/2,0runtime warnings,0observed animation-idle messages and0runner restarts. The original UI10 had seven60-second idle waits before Save could execute; no arithmetic defect was established. Normal-profile session40122 ended0 and `.build/NativeNormal/dd` remains available for ordinary-app builds.

Records is now also qualified: `.build/SharedRecordsNov10/hosted-control-followup/r2` builds and passes both original EN/ES journeys118.61s/116.99s, strict2/2,0runtime warnings,0observed idle messages and0restarts. Its prepared Save button is revealed before the retained assertion; the actual nested63x28UISwitch is tapped once, with bounded confirmation of both native/parent state. Privacy, export, encryption, Cancel, dedupe and inert recovery assertions remain. The first outer-tap correction failed both locales; its originals are preserved alongside the hosted artifact/log. Session79181 ended0. No local native or PostgreSQL execution is active.

The final old store-quote stale-save/locked-shop failure was checked once unchanged against the cached contributor app. `.build/StoreQuoteStaleFollowupNov10` passes the full original case228.54s, strict1/1,0runtime warnings,0observed idle messages and0restarts. It preserves stale action/no rebase, explicit local retry clearance and locked-shop behavior. Session91453 ended0. The hosted original's cumulative Done/extraMinutes/reviewSave query delays remain in `.build/CombinedCoreNov10/successor-store-quote-stale.log`; no specific product cause was established. This scoped pass supported publishing49b without another code change.

The separate StoreKit diagnostic is complete and its temporary source has been restored exactly to HEAD (preimageSHAf5efe4f674f5708dc784cd5cacf8e67e854f92302b0d83cb0aa80ad522d12c88). Nothing from it was committed or pushed. `.build/StoreKitTriageNov10/approval-trace` built and passed the original English approval case0.631s with existing forwarding stage logs: product loading/preflight/purchase/pending all completed. This traced result alone was not accepted as a fix.

A fresh rebuild of the unchanged original then ran all four previously failing English cases in `.build/StoreKitTriageNov10/original-four`. Approval passed0.322s and no-durable-delivery purchase passed0.048s; both decline variants failed after~10seconds each (4executed,2passed,2failed,0skipped). Both have the same direct SDK contradiction: SKTestSession reports failed1/pending0/purchased0, while raw StoreKit2 currentEntitlements reports that same Xcode request verified, unexpired and unrevoked. App membership remains Free; its unavailable-delivery notice follows the verified callback. Do not weaken those assertions, special-case production for a test-only response or claim billing qualified. The prior purchase hangs did not recur locally; their hosted cause remains unproven. Session52227 ended65 normally with a complete bundle. No native/PG process is active. Next inspect the current49b CI results and address actual new findings; do not repeat these unchanged StoreKit diagnostics or the rejected scene-aware hypothesis. Owner-deferred paid Apple/sandbox acceptance remains separate.

A bounded post-decline restore diagnostic is also complete: `.build/StoreKitTriageNov10/decline-without-restore` built and ran only the two original English decline cases after removing the single post-decline `AppStore.sync()` call. Both still failed with the same failed1/pending0/purchased0 versus verified current-entitlement contradiction; no skips or runtime warnings. This rules out that extra restore as necessary for the local failure. Original assertions and time limits were unchanged. Session51686 ended65 with a complete result bundle. The test source was restored byte-for-byte to HEAD; nothing was committed or pushed. Those temporary products were subsequently replaced by the original-source observer build described below. Do not repeat this rejected hypothesis.

The49b deep batch is terminal failure: English11/15 and Spanish10/15, both sanitizers and shared build passed. Spanish job130304057801 added `testRealTransactionObserverAttemptsDeliveryWithoutUnlock` missing the expected unfinished transaction after the preceding purchase timeout/runner restart. Source review confirms `.notConfigured` cannot reach finish; the failed assertion does not distinguish raw SDK absence from unverified data. One unchanged Spanish case alone was rebuilt from original source and passed0.234seconds (1/1,0skips,0runtime warnings) in `.build/StoreKitTriageNov10/observer-spanish`. Build49805 ended0; test70615 ended0. This is a scoped local pass, not proof of hosted root cause or full billing qualification. Do not add a speculative production patch or repeat the unchanged case. Original source SHA remainsf5efe4f674f5708dc784cd5cacf8e67e854f92302b0d83cb0aa80ad522d12c88. No local native process is active.

A single new decline-order diagnostic is complete in `.build/StoreKitTriageNov10/decline-after-pending`. Apple's [Ask to Buy test sequence](https://developer.apple.com/documentation/storekit/testing-ask-to-buy-in-xcode) observes Product.purchase returning pending before decline. The temporary helper waited for purchase completion and asserted the pending report before resolving the request. Both new checks passed, but the original English decline still failed10.698s with the same raw verified/unexpired/unrevoked declined transaction and failed1/purchased0/pending0 test-session state. This rules out early decline before the pending result as necessary for this local failure. App access stayed Free; zero tests skipped. Build55020 ended0; test43369 ended65. Original source was restored byte-for-byte to HEAD (SHAf5efe4f674f5708dc784cd5cacf8e67e854f92302b0d83cb0aa80ad522d12c88). Retain the patch, log and complete result; do not repeat this rejected hypothesis. The cached LocalStoreKit test products contain the temporary diagnostic and require a matching rebuild before further execution.

Current49b contributor-balanced-02 job130307937749 passes all11original cases, strict11/11 and0runtime warnings,0runner restarts; one animation-idle diagnostic was observed. It covers current cook instructions/refresh, Spanish request privacy/large text, typed/structured cancel-send, import recovery, optional measurement consent and stock-review Cancel/confirm/restart. Core UI05 has started; remaining jobs were still live at this checkpoint. No new hosted run was dispatched.


A direct Device Hub check opened the ordinary Debug app and inspected its three empty home screens (Shop, Dinners, Records) with live AX and screenshots. Each displayed its expected primary actions and tab navigation without observed clipping. Running PID66199 on ownedA50matched debug executableSHA36fd0ef978c1be4579bb16cf8821dfa5860d977703a8840e063edfebc0086b81, identical to `.build/NativeNormal/dd/Build/Products/Debug-iphonesimulator/RoomInTheCart.app/RoomInTheCart`. No records were created/deleted and no permissions changed. This is three-root visual proof only, not all27routes, full accessibility or a physical-device pass. CUA completion was recorded.

Five unused owned simulators were shut down after confirming no attached test/debugger. Their data remains intact and their CPU-heavy iOS17processes exited. Only activeA50C91FC and the preexisting generic iPhone175FDE1E82 remain booted. CI-VALIDATION documents scoped cleanup; no causal claim about hosted animation faults follows. The successful r6 follows cleanup and an owned restart.

Local builds now keep profile-specific caches (CI-VALIDATION): contributor/stock/carryover retains the existing derived-data path; `.build/NativeNormal/dd` now contains the completed original-source LocalStoreKit observer build, with the original test-source SHA restored. This avoids repeated dependency invalidation when changing fixture flags; no elapsed-time speedup has been measured yet.

## Local fixture follow-up qualified

The carryover test now targets the observed nested native switch, checks its full unobscured frame, taps once and confirms the state. The later-page request test passively waits for Lee and the exact saved outcome after dismissal; it still forbids scrolling or tapping to make the return assertion pass. The original screenshot already showed the correct return outcome. Only the two test files changed. Contributor fixture compilation passes and both original journeys pass (2/2executed,0runtime warnings); the existing automation-contract check passes. No application behavior, journey timeout or substantive assertion was relaxed. These corrections are included in published49bde552 and its current combined batch.

## Staging048 deployed

A fresh encrypted041backup and two actual restores now pass. The second restore
upgraded through048, preserving all129original non-registry tables, original
shop columns and41registry records/timestamps. The baseline stayed byte-identical;
both local servers stopped and both Keychain-backed images reopened and detached.
The two historical backfills matched expected empty sets in this staging snapshot;
existing populated integration cases remain separate evidence. Current immutable
Vercel application/worker entrypoints require authentication. Dry upload inspection
now excludes Supabase CLI temporary metadata; all211regular inputs are tracked.
[Review preparation](evidence/b11/staging-048-preparation-20261110/README.md).

The owner explicitly approved042–048 and the matching server/web rollout. All48
migrations are applied once, and source `5e5f5c90` is live at
`https://room-in-the-cart-staging.vercel.app`, deployment
`dpl_BfzRizUi3ksDXfTGdDDFtDcxpN7J`. Both aliases and the scheduled worker point to
that deployment. Seven public API/auth/worker checks and13exact web-route/asset
checks pass. Existing rows, backfills, migration checksums, catalogs, roles,
default ACLs, ownership and privacy-function restrictions were verified; encrypted
images are detached. The048-compatible maintenance deployment is
`dpl_72cBW5Biz5YKYjvPyqn4dNYEX4EH`. Use it to close writes if recovery is needed;
do not promote041over later048writes or automatically restore over later activity.

Two verifier assumptions were corrected without reapplying migrations or changing
permissions. Hosted extensions equal their live preflight; the selective local
restore intentionally contains fewer extensions. Direct live runtime/group SQL
was unavailable because the CLI role cannot impersonate those roles and Vercel
does not export the sensitive runtime credential. Actual deployed runtime startup,
authentication checks, hosted role/policy parity and local restored RLS evidence
are recorded separately; do not claim the unavailable live SQL probe passed.
The scoped result and original failures are retained in
`.build/Staging048Nov10/rollout-verification.json` and `.build/StagingDB048Nov10`.

## Qualified product work

The existing Supabase CLI can access Room in the Cart Staging even when the
connector cannot. Do not repeat reconnect requests or the completed048rollout.

The rollout review caught missing production activation of shared-food tracking:
fixtures enabled `trackingV2`, but `createRuntime` did not. The new actual-runtime
regression reproduced404, then passed after enabling the existing feature in the
production composition. Build and21focused runtime/privacy/tracking checks pass
in `.build/RuntimeTrackingNov10`; the local PostgreSQL cluster is stopped. The
read does not adopt food, and anonymous/revoked sessions remain denied. Existing
guardian/provider activation is unchanged. This runtime is now deployed after048;
the041 service is not a safe rollback after new-state writes. The completed
rehearsal and hosted verification checked046 label-provenance and047 meal-identity
backfills against the actual staging snapshot, whose expected backfill sets were empty.

Fresh combined backend r1 passes **1,031 offline / 433 PostgreSQL** with one/three declared skips. Includes 40 protected-conversion tests, 21 actual API cases, 12 Records projection tests and signed restore/erasure. Root independently verified 308 current/archived source inputs, phase hashes and compiled products; PostgreSQL stopped. Actual Swift client transport passes **24 Node cases / 80 Swift scenario invocations**, zero failures/skips, retaining the original21/70. Root verified428inputs; successful private wire fixture removed after shutdown. [Backend and wire proof](evidence/service/records-protected-conversion-20261110/README.md).

Protected tracked/transferred cross-unit meal edits now use current exact source proof through review and command recomputation. Whole Undo restores original bytes while comparing with the immutable accepted-forward conversion, including explicit missing evidence. An independent review caught the older-basis precedence defect before installation. Historical line-order collision in the wire fixture is fixed. Proposal-backed protected conversion, plain-unbound cross-unit edits and whole protected aggregates remain unsupported specialized cases. They are not automatically release blockers: qualify the promised edit/proposal using supported original-unit entry before adding machinery.

Shared Records server v2 exports current partial/erased facts without authority/replay tokens; explicit v1 stays separately guarded. Native current-shop adapter, independent encrypted recovery and explicit unknown source dates are installed. Initial package qualification passes230client tests plus three real-wire skips and33archive tests. Native r9 app build and135selected model tests pass with zero runtime warnings. [Native component proof](evidence/native/shared-records-20261110/verification.json).

## Records successor findings

The new real-route suite first passed439database tests, failed two new cases and skipped three browser cases. All preceding433passed. The failures were fixture assumptions: authority transfer requires the organizer and increments authority epoch without changing shop revision. Test-only correction is installed; r3 above now passes all eight cases and the full441database regression. Original r2 private fixture and evidence retained. [First failure](evidence/service/records-protected-conversion-20261110/records-http-first-failure.json).

UI r10 built but found a real repeated-export error visibility defect. `prepareExport` now requests a fresh action outcome so the existing view reveals/focuses each error; background-refresh behavior is unchanged. r11 rebuilt and the focused model regression passed, including cleared private documents and unchanged registry bytes. Its English journey passed private export, encrypted save and import Cancel, then a test-only wrong-direction search failed. Two post-outcome Choose file calls now search below the result; all assertions and32-attempt/20-second bounds remain. r12 failed later because the import details were above the retained viewport. The review-focus successor above passes both journeys. [Original UI failure](evidence/native/shared-records-20261110/ui-first-failure.json), [direction failure](evidence/native/shared-records-20261110/ui-direction-first-failure.json).

## Hosted and minimum-iOS status

CI46a3e6bf passes295portable helper controls and all three exact-commit658-check workflow profiles,793inputs/50pins. [Profile proof](evidence/ci/launcher-startup-timing-20261110/profiles.json).

Hosted42892918759 booted normally in55.214seconds. Supported-launcher inventory acquisition observed about13.5seconds of bash residency, followed by about15.7seconds of zero-output bound simctl before the original30-second deadline. Startup validation/Popen were fast. Owned SIGINT, terminal children, later scoped cleanup and device deletion were verified. Original ZIP19/TAR20/50source pins retained. [Hosted proof](evidence/ci/launcher-startup-timing-20261110/hosted-42892918759.json). A supported, unsampled runtime-plus-exact-device query pair under one unchanged deadline is a possible next experiment, not a proven fix; earlier targeted queries also timed out. No app performance or baseline qualification follows from these helper controls.

Minimum-iOS Spanish XCTest callback fault remains open. Approved Apple report showed Sent with three attachments; feedback ID/transfer completion was not observed. Do not resubmit or repeat unchanged. [Fault](evidence/native/minimum-os-first-fault-20261109/README.md), [host feasibility](evidence/ci/minimum-os-host-feasibility-20261109/README.md).

## Remaining full-release boundaries

Finish promised meal edits/proposals with preserved reservations and Undo; permitted historical Records and selected backup/recovery; authenticated/deployed deletion acceptance (existing local erasure/recovery checks pass); verified guardian-scoped access/export/deletion; actual authenticated mixed-device household/provider lifecycle; operational restore and alerts; physical iPhone features; human English/Spanish accessibility; actual mailbox and policy operation; signed TestFlight/billing/App Store gates. Follow [CI-VALIDATION](CI-VALIDATION.md), freeze one combined revision and run complete regression before merge. Green CI alone is not release authorization.

Scope clarification from the November 10 Foundation audit: S20 and P07 require
saved pickups, notes, approvals, actual fills and unresolved outcomes; the personal
backup contract includes selected authorized history. They do not require an
exhaustive internal event browser. S21 explicitly permits previously exported
dated copies to remain; do not build remote recall of independently held files.
The service authorization matrix requires guardian-scoped access/export/erasure,
while S20/Restore forbid recovering consent or live authority from a backup.
Use ordinary permitted-record recovery rather than inventing a separate guardian
recovery subsystem. Preserve these actual user requirements; do not turn every
specialized implementation limitation into extra launch scope.

Staging approval and completed deployment extend through048 for source5e5f5c90. Later hosted updates still need their applicable review and authorization. Paid Apple membership/signing, SMTP and KWS activation remain owner deferred. Operator: Venture House Group LLC. Support: hello@roominthecart.com.

Historical originals remain in their evidence folders and git history. Previous handoff text is preserved at `.build/HandoffNov10/before-records-checkpoint-consolidation.md`.
