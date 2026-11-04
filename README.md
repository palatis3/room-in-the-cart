# Room in the Cart

Native iPhone implementation of Foundation 2.1, with an account-free pack comparison and shopping list, meal planning, pickup workflows, recovery tools, and connected household and membership modules. The [current acceptance map](docs/CURRENT-ACCEPTANCE.md) tracks verified behavior and remaining release work.

Open [RoomInTheCart.xcodeproj](ios/RoomInTheCart.xcodeproj) in Xcode, choose **RoomInTheCart-Release**, select an iPhone simulator, and run. The simulator preview runs without a signing team, account, or backend setup. Use **RoomInTheCart** for Debug development. The deployment target is **iOS 17.0** and hosted CI builds with Xcode 26.3.

The app has Shop, Dinners and Records tab roots. Shop includes staged list import, distinct manual/meal/protected contributions, exact comparison, checkout review and pickup reconciliation. Meals retain stable identities and dates; reviewed dinner planning and optional on-device capture are integrated in source, with additional acceptance work underway. Records supports comparison reopen and scoped encrypted export/recovery into isolated workspaces. Household and StoreKit membership adapters are integrated in source, with role-aware routing and a local device-owner gate after shared use. This is not a claim that every launch requirement or live provider flow has passed acceptance.

In **Shop**, open **List order and aisles** to arrange the active items, or **Large-print list** for a printable copy. **Dinners** can start the first pickup and prepare an editable meal idea from an original pattern. Saving an idea to the dinner library and applying its ingredients to a pickup are separate decisions. In **Records**, connected adults can review entered prices and period budgets. Choose the household overview for a period that includes more than one permitted shop. Optional pickup feedback is off until enabled in Settings.


In **Records → Family decision history**, review the pickup evidence and record what your household observed. The cook handoff can save a dated copy and separately record who received it and who acknowledged it. **Review prior staples** lets a named Household shopper revisit the store and purpose before adding a need to a fresh list.

## First task

1. Open **Shop → Compare packs** and enter 12 wraps.
2. Enter two quotes. Pack A has 8 wraps for $3 and Pack B has 6 for $2. Set an optional $30 item limit.
3. Tap **Compare enough food**. Either quote needs two packs, costing $6 for A or $4 for B. Blank quantities and prices stay unresolved.
4. Tap **Save comparison** and wait for **Saved on this iPhone**. Relaunch, open **Records**, and choose the saved comparison.

Costs and limits apply only to the item. They exclude other groceries, fees and taxes. There are no network calls in this flow and no sample household data on a fresh install.

## Build and verify

Requirements: macOS, Xcode with an installed iPhone simulator, Python 3.9+, Node 22.14.0/npm. The handoff reference verifier separately requires Python 3.13+.

```sh
bash scripts/check.sh
```

The script checks generated files, runs Swift package and web/service tests, and verifies the Debug simulator bundle. Project files and assets are committed. Regenerate the project when adding or removing Swift files.

Run the app model and UI tests through the **RoomInTheCart** scheme’s Test action or use the command below. Get the simulator UUID from `xcrun simctl list devices available`. Use the **RoomInTheCart-LocalStoreKit** scheme for the simulated billing cases.

```sh
RUN_UI_TESTS=1 IOS_SIMULATOR_DESTINATION='platform=iOS Simulator,id=YOUR_SIMULATOR_UUID' bash scripts/check.sh
```

Tests use a separate DEBUG-only workspace and typed input, never the user's normal comparison database. UI tests exercise persistence, unknown values, Spanish, large text, dark appearance, and automated accessibility checks. Automated audits do not substitute for a human VoiceOver/device session.

## Structure

- `ios/Packages/CoreDomain`: exact rational quantities, checked USD cents, ledger contributions, checkout, pickup policy, reviewed dinner planning and pack-selection evidence.
- `ios/Packages/LocalStore`: versioned SQLite comparison and ledger databases, serialized writes, immutable revisions and scoped comparison tombstones. Whole-ledger retirement uses durable deletion intent and replay-safe cleanup.
- `ios/Packages/HouseholdClient`, `ios/Packages/RecordArchive`: scoped network contracts/retry handling and encrypted recovery validation.
- `ios/Packages/DeviceSurfaces`, `ios/Extensions`: isolated selected-text inbox, generic widget routes and local reminder primitives. App composition is undergoing integrated testing.
- `ios/App`, `ios/Features`: native composition and comparison, ledger, pickup, records, household and membership views/models.
- `shared/contracts`: fictional pack vectors and accepted Foundation semantic color tokens.
- `service`: PostgreSQL/RLS-backed household and billing service, verified provider sessions, narrow projections and a reusable runtime/HTTP adapter. Browser authentication is implemented but provider enablement is deliberately off; new privacy/maintenance migrations require separate deployment review.
- `web`: invite, own-request and narrow helper clients with reviewed requests and identity-bound retries; the deployed client correctly reports unavailable email sign-in until provider configuration is enabled.
- `.github/workflows/ci.yml` runs on main pushes, pull requests and manual dispatch. Source checks, Swift package tests with coverage, the simulator build and unsigned iPhone Release validation run independently. The Release build also supplies Swift CodeQL analysis. PostgreSQL and web/service checks use disposable data.

## Continuous integration

The simulator build enumerates the compiled tests and assigns every enabled case once. Disabling an ordinary compiled test fails planning; the separate StoreKit suite is the only allowed exclusion. Model tests use one job. Ten smaller UI jobs share the compiled app, with at most five test jobs running concurrently. The planner uses observed hosted durations where available, scaled local durations for other existing cases and a default estimate for new cases. Each job verifies the exact executed test identities and count, rejects missing or skipped tests, and retains its result bundle, screenshots, logs and timing. The test step has a 40-minute limit and the job has a 55-minute limit. A runner killed before connecting can retry once. An executed failing test fails its job. The final **CI gate** rejects failed, cancelled or skipped prerequisite jobs, including any failed test matrix member.

GitHub Free currently permits five concurrent macOS jobs and twenty total jobs. Independent macOS build and analysis jobs share that account limit with the test jobs. Linux source, backend and security checks use the total concurrency allowance. The new topology still needs hosted timing and a complete passing run. [GitHub runner limits](https://docs.github.com/en/actions/reference/limits#job-concurrency-limits-for-github-hosted-runners), [workflow results](https://github.com/palatis3/room-in-the-cart/actions/workflows/ci.yml)

macOS jobs use the standard Apple Silicon `macos-15` image with Xcode 26.3. The earlier Intel run reached the individual UI-test time limit while making progress and exceeded the traced Release build limit. Native-runner timing is being validated; the historical Intel durations remain conservative balancing estimates, not promised completion times. These standard runners are free for this public repository. [GitHub runner specifications](https://docs.github.com/en/actions/reference/runners/github-hosted-runners), [installed toolchain](https://github.com/actions/runner-images/blob/main/images/macos/macos-15-arm64-Readme.md)

The **Security checks** workflow scans TypeScript/JavaScript and GitHub Actions with CodeQL. Pull requests run dependency review, failing on newly introduced high or critical dependency vulnerabilities. Dependency review requires the repository's dependency graph. Swift CodeQL uses the existing unsigned Release compilation. [GitHub CodeQL](https://docs.github.com/en/code-security/concepts/code-scanning/codeql/codeql-code-scanning), [dependency review](https://docs.github.com/en/code-security/concepts/supply-chain-security/dependency-review)

Use **Pre-release regression checks** on the candidate branch before an App Store submission or update. It runs the ordinary checks together with the additional suites below. Its final gate rejects failures, cancellations, skipped prerequisite jobs, missing performance baselines, incomplete CodeQL language coverage for the exact commit, serious open source findings, and high/critical vulnerabilities anywhere in the dependency lockfiles. The compiled Release app must also have production support/policy URLs and an Apple subscription product ID. The branch must still point to that candidate when the gate finishes. This workflow does not sign or upload an app.

The additional workflows also run on pull requests that change their workflow or selection/measurement scripts, so changes to the checks themselves get hosted validation before merging. Performance pull-request checks enforce approved baselines; only an explicit manual calibration run can omit them. All these macOS jobs share the same five-runner limit.

| Additional lane | What it checks | Execution |
|---|---|---|
| iOS deep checks | Memory errors and data races in all five Swift packages; 15 simulated StoreKit purchase, restore, renewal and revocation cases in each configured language | Separate sanitizer and billing jobs |
| iOS fixture checks | Contributor requests, guardian/enrollment and device boundaries, shared meals and quotes, library/privacy, recovery, stock corrections and carryover | Two Debug fixture builds reused by 17 class jobs covering 44 methods; at most five concurrent jobs |
| iOS Release performance | Responsive cold launch; real 500-item paste/import/search/checkoff/relaunch; scroll duration and app memory | One optimized Release build reused by three fresh simulator jobs |
| Existing dependency audit | Known vulnerabilities already present in the complete service and web dependency locks | Two short Linux jobs |

Performance uses the dedicated **RoomInTheCart-Performance** scheme with an optimized Release app, no debugger, coverage or sanitizers. Measurement validation requires five finite XCTest samples for launch/scroll/memory, independently checks the exact 500-row SQLite state, and verifies all 20 rendered checkoffs after relaunch. Missing measurements cannot count as a pass. Simulator scroll runs explicitly report when frame-hitch metrics are unavailable. UI search/checkoff round trips include XCTest input and idle waiting; they are not frame-latency measurements. [Apple performance testing](https://developer.apple.com/documentation/xcode/writing-and-running-performance-tests), [animation metrics](https://developer.apple.com/documentation/xctest/xctossignpostmetric/scrollinganddecelerationmetric)

Run **iOS Release performance** manually with baseline enforcement off to collect calibration. Strict pre-release runs require reviewed limits in `scripts/ios_performance_baselines.json` matched to the exact Xcode, simulator model, OS/build and architecture. Calibration does not automatically become a baseline. Hosted calibration and baseline adoption are still pending, so the strict performance release gate deliberately remains closed. See the verifier's `calibration.json` for the measured environment and candidate values. [Apple baseline guidance](https://developer.apple.com/documentation/xcode/writing-and-running-performance-tests)

Ordinary CI already exercises English, Spanish, large text, dark appearance and automated accessibility audits. The checkout property test independently prices every billed increment for 480 seeded quotes to catch rounding and stacked-fee discontinuities. Package coverage identifies untested logic; a percentage alone does not establish correctness. [Apple coverage guidance](https://developer.apple.com/documentation/xcode/determining-how-much-code-your-tests-cover)

Before distribution, validate the actual signed candidate with `scripts/check_built_app.py --configuration Release --require-release-metadata`, real-device accessibility and animation review, sandbox/TestFlight billing, and live-provider acceptance. The microphone permission probe requires a fresh simulator with native prompts and an available on-device recognizer and remains a separate check. These requirements are not satisfied by fictional household fixtures or local StoreKit. [Apple diagnostic tools](https://developer.apple.com/documentation/xcode/diagnosing-memory-thread-and-crash-issues-early), [StoreKit testing](https://developer.apple.com/documentation/storekit/testing-at-all-stages-of-development-with-xcode-and-the-sandbox)

## Current verification and staging

Hosted CI compiled the unsigned iPhone Release and passed all 563 native model tests on iOS 26.2. The local build with the accessible meal-week layout also passed 563 model tests on iOS 27. A Release build from a clean clone saved and reopened the sample comparison on fresh iOS 17 and iOS 27 simulators. The full native UI regression remains open. [Hosted CI evidence](docs/evidence/native/hosted-models-20261104.json) · [Local model validation](docs/evidence/native/meal-week-20261104/validation.json) · [Fresh-install validation](docs/evidence/native/release-first-install-20261104.json)

Staging has migrations 001–008 applied. The upgrade through 029 passed a local rehearsal. The protected hosted backup and rollout review are pending. Launch also awaits approved policies and support, live provider and recovery checks, physical-device and mixed-phone acceptance, Apple signing, live StoreKit, and App Store review. [Staging plan](docs/STAGING-UPDATE-PLAN.md) · [Release requirements](docs/CURRENT-ACCEPTANCE.md#remaining-production-work-and-release-gates)

The original product baseline, Foundation 2.1 requirements, and master generation are in [docs/product](docs/product). Start with [APP-BASELINE](docs/product/APP-BASELINE.md).
