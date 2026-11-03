# Room in the Cart

Native iPhone implementation of Foundation 2.1, with an account-free offline comparison and shopping ledger, pickup workflows, recovery tools, and connected household and membership modules. The full launch product is still under implementation; [the requirement tracker](docs/IMPLEMENTATION.md) records evidence and remaining acceptance gates.

Open [ios/RoomInTheCart.xcodeproj](ios/RoomInTheCart.xcodeproj), choose **RoomInTheCart**, and run on an iPhone simulator. Deployment target: **iOS 17.0**. No signing team is needed for simulator builds. Device distribution requires real bundle identifiers and signing configuration.

The app has Shop, Dinners and Records tab roots. Shop includes staged list import, distinct manual/meal/protected contributions, exact comparison, checkout review and pickup reconciliation. Meals retain stable identities and dates; advanced dinner scenarios and optional capture are being added separately. Records supports comparison reopen and scoped encrypted export/recovery into isolated workspaces. Household and StoreKit membership adapters are integrated in source, with role-aware routing and a local device-owner gate after shared use. This is not a claim that every launch requirement or live provider flow has passed acceptance.

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

- `ios/Packages/CoreDomain`: exact rational quantities, checked USD cents, ledger contributions, checkout and pickup policy; dinner planning is in active development.
- `ios/Packages/LocalStore`: versioned SQLite comparison and ledger databases, serialized writes, immutable revisions and scoped comparison tombstones. Whole-ledger retirement is under development.
- `ios/Packages/HouseholdClient`, `ios/Packages/RecordArchive`: scoped network contracts/retry handling and encrypted recovery validation.
- `ios/App`, `ios/Features`: native composition and comparison, ledger, pickup, records, household and membership views/models.
- `shared/contracts`: fictional pack vectors and accepted Foundation semantic color tokens.
- `service`: PostgreSQL/RLS-backed household and billing service, verified provider sessions, narrow projections and a reusable runtime/HTTP adapter. New lifecycle endpoints remain under regression testing.
- `web`: invite, own-request and narrow helper clients with reviewed requests and identity-bound retries; initial managed-login/BFF and deployed end-to-end acceptance remain open.
- `.github/workflows/ci.yml`: package tests, localization/token/project checks, native build/UI test artifacts and unsigned device compilation. Workflow execution on a remote host is not yet verified.

## Current verification and staging

Native integration compiles with ledger, pickup, records, household and membership composition. Focused native AppModel (14), LedgerAdapter (7), Pickup (15) and Records adapter (6) tests have passed. The membership coordinator's timing-sensitive test was made deterministic; its 36 isolated tests pass, with the main native rerun pending at this snapshot. Full UI/accessibility regressions remain active; these counts are not a complete launch acceptance claim.

The web source passes TypeScript, a Vite production build and 41 tests. The service live-session slice passes 28 local PostgreSQL test entries with zero skips, including revocation, subject matching and expiry. [Supabase staging smoke evidence](docs/evidence/staging-service-smoke.json) records verified TLS and denial checks against the staging runtime. Migrations 001–005 are applied to staging with checksums preserved; 005 is immutable. The reported staging security advisor has no warnings or errors; its admin-only migration registry intentionally has RLS without a user policy. Migration 006 remains separate until its tests pass. These checks do not establish production deployment or real purchase/consent flows.

Vercel team/deployment setup and Apple signing are being handled by the project owner. No credentials belong in the repository. Child consent remains unavailable until an actual reviewed provider integration is configured.

Debug/Staging/Release have separate provisional bundle IDs, the same product display name, and no embedded credentials. Logs accept enumerated structural failure events only. All food and financial data stay out of logs.

See [implementation status](docs/IMPLEMENTATION.md) and [provenance](docs/PROVENANCE.md). [APP-BASELINE](docs/product/APP-BASELINE.md) is the initial orientation; the accepted Foundation and master generation are preserved beside it in `docs/product/`. Original handoff files remain unchanged in `/Users/palatis/Downloads/Handoff/`.
