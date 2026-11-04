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
- `.github/workflows/ci.yml` runs on pushes, pull requests and manual dispatch. It tests the web and service packages, runs PostgreSQL integration and maintenance checks against disposable data, and verifies generated sources. The iPhone job verifies the Debug and unsigned Release bundles and saves the model test results. Two UI jobs reuse the same simulator build and run their assigned journeys serially on separate runners. The [GitHub Actions history](https://github.com/palatis3/room-in-the-cart/actions/workflows/ci.yml) shows each job’s result for each commit.

## Current verification and staging

Hosted CI compiled the unsigned iPhone Release and passed all 563 native model tests on iOS 26.2. The local build with the accessible meal-week layout also passed 563 model tests on iOS 27. A Release build from a clean clone saved and reopened the sample comparison on fresh iOS 17 and iOS 27 simulators. The full native UI regression remains open. [Hosted CI evidence](docs/evidence/native/hosted-models-20261104.json) · [Local model validation](docs/evidence/native/meal-week-20261104/validation.json) · [Fresh-install validation](docs/evidence/native/release-first-install-20261104.json)

Staging has migrations 001–008 applied. The upgrade through 029 passed a local rehearsal. The protected hosted backup and rollout review are pending. Launch also awaits approved policies and support, live provider and recovery checks, physical-device and mixed-phone acceptance, Apple signing, live StoreKit, and App Store review. [Staging plan](docs/STAGING-UPDATE-PLAN.md) · [Release requirements](docs/CURRENT-ACCEPTANCE.md#remaining-production-work-and-release-gates)

The original product baseline, Foundation 2.1 requirements, and master generation are in [docs/product](docs/product). Start with [APP-BASELINE](docs/product/APP-BASELINE.md).
