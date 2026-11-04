# Room in the Cart

Native iPhone implementation of Foundation 2.1, with an account-free offline comparison and shopping ledger, pickup workflows, recovery tools, and connected household and membership modules. The full launch product is still under implementation; [the requirement tracker](docs/IMPLEMENTATION.md) records evidence and remaining acceptance gates.

Open [ios/RoomInTheCart.xcodeproj](ios/RoomInTheCart.xcodeproj), choose **RoomInTheCart**, and run on an iPhone simulator. Deployment target: **iOS 17.0**. No signing team is needed for simulator builds. Device distribution requires real bundle identifiers and signing configuration.

The app has Shop, Dinners and Records tab roots. Shop includes staged list import, distinct manual/meal/protected contributions, exact comparison, checkout review and pickup reconciliation. Meals retain stable identities and dates; reviewed dinner planning and optional on-device capture are integrated in source, with additional acceptance work underway. Records supports comparison reopen and scoped encrypted export/recovery into isolated workspaces. Household and StoreKit membership adapters are integrated in source, with role-aware routing and a local device-owner gate after shared use. This is not a claim that every launch requirement or live provider flow has passed acceptance.

In **Shop**, open **List order and aisles** to arrange the active items, or **Large-print list** for a printable copy. **Dinners** can start the first pickup and prepare an editable meal idea from an original pattern. Saving an idea to the dinner library and applying its ingredients to a pickup are separate decisions. In **Records**, connected adults can review entered prices and period budgets. Choose the household overview for a period that includes more than one permitted shop. Optional pickup feedback is off until enabled in Settings.


In **Records → Family decision history**, review the pickup evidence and record what your household observed. The cook handoff can save a dated copy and separately record who received it and who acknowledged it. **Review prior staples** lets a named Household shopper revisit the store and purpose before adding a need to a fresh list.

## First task

1. Open Shop → Compare packs.
2. Enter an item, total need, units, and two pack quotes. Optional confirmed stock is already available for this need; protected portions partition the total.
3. Compare enough food. Blank quantities/prices remain unresolved.
4. Save comparison, terminate the app, reopen and select the saved comparison.

Costs and limits apply only to the item. They exclude other groceries, fees and taxes. There are no network calls in this flow and no sample household data on a fresh install.

## Build and verify

Requirements: macOS, Xcode with an installed iPhone simulator, Python 3.9+, Node 22.14.0/npm. The handoff reference verifier separately requires Python 3.13+.

```sh
python3 scripts/generate_theme.py
python3 scripts/generate_xcode_project.py
bash scripts/check.sh
```

Project files and generated assets are committed; ordinary Xcode builds need no generator installation. Regenerate the project when adding/removing Swift files. `--check` verifies reproducibility. The scripts automatically use `.tools/node-v22.14.0-darwin-arm64` if present locally; clean environments should install the pinned Node version.

To run app unit/UI tests, select the scheme's Test action in Xcode or:

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
- `.github/workflows/ci.yml` runs on pushes, pull requests and manual dispatch in the private Room in the Cart repository. It tests the web and service packages, runs PostgreSQL integration and maintenance checks against disposable data, verifies generated sources, and builds and tests the iPhone app. The [GitHub Actions history](https://github.com/palatis3/room-in-the-cart/actions/workflows/ci.yml) shows each job’s result for each commit.

## Current verification and staging

Checkpoint `967df15` passed **140 native model tests with zero skips and unchanged source hashes**, CoreDomain 115 tests, LocalStore 73 tests, and unsigned Release/compiled-metadata checks. The parent also tested that checkpoint plus the new large-list fixture on an iPhone SE (2nd generation) simulator running iOS 17.0: 141 model tests passed. Five minimum-iOS functional/viewport scenarios passed across two runs; the unfiltered accessibility audit still fails. The large-list Debug fixture found slow behavior under test; it is not a physical-device Release latency measurement.

The [integrated native suite](docs/evidence/native/integrated-helper-review-summary.json) passed all 255 tests on an ad-hoc-signed iPhone 17e simulator running iOS 27. The [Free pickup journey](docs/evidence/native/free-pickup-through-next-shop-summary.json) exercised protected lunch portions, checkout, short fill, meal repair, a dated cook note, settlement and reuse of the saved dinner in a fresh shop. A [separate fresh-install journey](docs/evidence/native/urgent-repair-two-meals-summary.json) saved two meal needs before any order and reopened both after restart. Both UI journeys reported a frame-dimension warning during text entry. The [local billing matrix](docs/evidence/native/local-storekit-full-matrix.json) passed 30/30 on iOS 17.0, 26/30 on iOS 27.0 and 25/30 on iOS 27.1. The broad accessibility audit, billing acceptance and signed-device distribution remain open.

Staging is deployed at [room-in-the-cart-staging.vercel.app](https://room-in-the-cart-staging.vercel.app). [Public smoke evidence](docs/evidence/staging-public-smoke.json) records six checks, and real browser verification confirms fresh English/Spanish loads without a false save-error banner. Supabase migrations 001–008 are applied with preserved checksums; staging advisor checks reported no warnings or errors. Local migrations 009–012 cover authentication maintenance, account deletion, helper review and budget history. Staging deployment of those migrations remains pending. No live email, consent, account-deletion-provider or real StoreKit entitlement flow is claimed by these checks.

The owner has deferred email-provider configuration and Apple membership/signing. Email sign-in remains explicitly unavailable, and child consent remains disabled pending its own actual provider configuration. No credentials belong in the repository.

Debug/Staging/Release have separate provisional bundle IDs, the same product display name, and no embedded credentials. Logs accept enumerated structural failure events only. All food and financial data stay out of logs.

See [implementation status](docs/IMPLEMENTATION.md) and [provenance](docs/PROVENANCE.md). [APP-BASELINE](docs/product/APP-BASELINE.md) is the initial orientation; the accepted Foundation and master generation are preserved beside it in `docs/product/`. Original handoff files remain unchanged in `/Users/palatis/Downloads/Handoff/`.
