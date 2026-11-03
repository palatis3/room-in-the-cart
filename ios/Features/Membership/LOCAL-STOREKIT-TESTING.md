# Local StoreKit development scenarios

This is the local Xcode step required by Foundation 12, before real sandbox or TestFlight evidence. `HouseholdLocalTesting.storekit` contains only `local.testing.household.annual`, an annual auto-renewing subscription with Family Sharing off. Its 49.99 price is a research fixture, not an approved price or App Store Connect product. Do not put this identifier into the production app's `HouseholdSubscriptionProductID`, service allowlists, or release configuration.

`StoreKitScenarioTests.swift` exercises the real `StoreKitMembershipStorefront`, `MembershipModel`, StoreKit 2 transactions and `SKTestSession`. It deliberately uses `UnavailableMembershipService`, has no service URL or HTTP call, and cannot fabricate a paid household. Local verification alone never grants named seats or shopper authority. A transaction with unavailable durable delivery must remain unfinished for retry. The existing 36 Membership tests cover authenticated service contract, binding, seats and lifecycle separately.

## Parent-owned project and scheme integration

1. Add `ios/Tests/StoreKitScenarioTests.swift` to `RoomInTheCartTests`.
2. Add `ios/Features/Membership/HouseholdLocalTesting.storekit` to the **test target's Copy Bundle Resources**. The suite resolves that resource from `Bundle(for: StoreKitScenarioTests.self)` and starts `SKTestSession(contentsOf:)`. Do not add the fixture to the release app bundle.
3. Add `ios/Tests/LocalStoreKit.xctestplan` to a dedicated Debug-only test scheme named `RoomInTheCart-LocalStoreKit`. The plan selects only `StoreKitScenarioTests`, sets `parallelizable` false, and has US English and US Spanish configurations. Do not attach it to the shipping app's Launch action or Release/Staging schemes.
4. Link StoreKitTest only in the unit-test target if Xcode does not autolink it. The installed SDK exposes it under `$(SDKROOT)/Developer/Library/Frameworks`; source compilation was checked with that framework search path.
5. Run one test host with parallel testing disabled. The opt-in `RITC_LOCAL_STOREKIT_TESTS=1` is supplied by the plan; ordinary native runs skip this suite before creating any StoreKit session. Do not run any other StoreKit session concurrently, including interactive transaction-manager tests. Each case resets configuration overrides and clears local test transactions before/after use.

Example after the parent attaches the plan and chooses an available simulator:

```sh
xcodebuild test -project ios/RoomInTheCart.xcodeproj \
  -scheme RoomInTheCart-LocalStoreKit -testPlan LocalStoreKit \
  -destination 'platform=iOS Simulator,id=<chosen-simulator-UUID>' \
  -parallel-testing-enabled NO -maximum-concurrent-test-simulator-destinations 1 \
  -only-testing:RoomInTheCartTests/StoreKitScenarioTests \
  -resultBundlePath /tmp/ritc-local-storekit.xcresult
```

Do not interpret a normal suite's skip as a StoreKit pass. A local plan should execute **14 scenarios per locale (28 runs)**, with zero skips. Apple documents that all `SKTestSession` instances share one environment, so these tests must remain serial. [SKTestSession](https://developer.apple.com/documentation/storekittest/sktestsession)

## Scope of the scenarios

- Annual StoreKit product, localized display name and price, one-year term, Family Sharing disabled.
- Actual purchase has the expected account token; unavailable service delivery grants no paid access and leaves the transaction unfinished.
- Actual transaction updates reach the app's observer but do not grant paid access.
- New adapter/model and explicit AppStore.sync replay unfinished delivery without restoring a local paid snapshot.
- Ask to Buy pending, approval, and decline.
- Simulated cancellation, invalid signature and unavailable product leave Free routes usable.
- Renewal retains original purchase identity; expiration removes current entitlement; refund records revocation.
- Billing retry without grace and configured grace produce their respective StoreKit states, while shared paid access still requires the service.

These are local StoreKit scenarios, not Apple server-notification or second-device evidence. The unavailable-service test exercises interrupted delivery. Interactive purchase-sheet interruptions, subscription management UI, reinstall on another physical device, real storefront prices, server reconciliation, grace configuration in App Store Connect, and release review remain subsequent evidence.

## US English and US Spanish

Both plan configurations use app region `US` and StoreKit storefront `USA`. App language is `en-US` or `es-US`; StoreKit session locale is `en_US` or `es_US`. The fixture has explicit `es_US` product/group metadata in addition to its prior `es_MX` entry. The tests assert that StoreKit retains the requested session locale and serves the expected Spanish product name. A fallback to Mexico must not be reported as US Spanish acceptance.

The SDK accepts a generic Foundation Locale in the session API, but fixture/session acceptance of `es_US` has **not yet been exercised in the Xcode test host**. Apple's App Store Connect metadata shortcode list documents Spanish Mexico and Spain; that list alone does not establish the local StoreKitTest restriction. If the host rejects `es_US`, retain app language `es-US`, region `US` and USA/USD, report the exact StoreKit limitation, and separately label any `es_MX` product-metadata test. US Spanish app copy/accessibility review remains required. [Apple metadata locales](https://developer.apple.com/documentation/appstoreconnectapi/managing-metadata-in-your-app-by-using-locale-shortcodes)

## Evidence and remaining gates

The 14 scenarios compile against the installed StoreKitTest SDK with the app's real Membership sources, targeting iOS 17. The fixture and test plan are syntactically valid JSON. Evidence: `/tmp/ritc-storekit-stage/typecheck.log`. No simulator execution, local purchase success, real sandbox purchase, TestFlight submission, certificate/account provisioning or Apple server trust result is claimed by this compilation. The parent owns project/scheme attachment and the first serial simulator run; preserve its `.xcresult` and exact per-locale results before checking the local Foundation 12 gate.
