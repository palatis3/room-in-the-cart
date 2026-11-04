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

Do not interpret a normal suite's skip as a StoreKit pass. A local plan should execute **15 scenarios per locale (30 runs)**, with zero skips. Apple documents that all `SKTestSession` instances share one environment, so these tests must remain serial. [SKTestSession](https://developer.apple.com/documentation/storekittest/sktestsession)

## Scope of the scenarios

- Annual StoreKit product, localized display name and price, one-year term, Family Sharing disabled.
- Actual purchase has the expected account token. Unavailable service delivery leaves Free access and the same unfinished transaction after a repeat Subscribe action.
- Actual transaction updates reach the app's observer but do not grant paid access.
- New adapter/model and explicit AppStore.sync replay unfinished delivery without restoring a local paid snapshot.
- Ask to Buy pending, approval, and decline for a fresh customer.
- Restore a completed local purchase, verify the original transaction and expiry, and exercise cancellation and decline on the same annual SKU and account. The fixture completes the expired transaction update before testing new purchases. The separate interrupted-delivery case verifies that the app leaves its undelivered transaction unfinished.
- Simulated cancellation, invalid signature and unavailable product leave Free routes usable.
- Renewal retains original purchase identity; expiration removes current entitlement; refund records revocation.
- Billing retry without grace and configured grace produce their respective StoreKit states, while shared paid access still requires the service.

These are local StoreKit scenarios, not Apple server-notification or second-device evidence. The unavailable-service test exercises interrupted delivery. Interactive purchase-sheet interruptions, subscription management UI, reinstall on another physical device, real storefront prices, server reconciliation, grace configuration in App Store Connect, and release review remain subsequent evidence.

## US English and US Spanish

Both plan configurations use app region `US` and StoreKit storefront `USA`. App language is `en-US` or `es-US`. The English StoreKit product-metadata locale is `en_US`; the Spanish product-metadata locale is explicitly `es_MX`, with Spanish (Mexico) offer text and a US dollar price. This does **not** switch the storefront to Mexico or change the app language to Mexican Spanish. The Spanish test-plan configuration is named `US Spanish app · Spanish (Mexico) offer · USA storefront` so results preserve the distinction.

The first actual SDK 27 simulator run verified that setting `SKTestSession.locale` to `es_US` normalizes it to `es_MX`. The original exact-es_US assertion therefore failed and is recorded below. Apple's official locale table lists Spanish (Mexico) as an additional supported language for the United States storefront; its metadata shortcode list documents `es-MX` and `es-ES`, not `es-US`. The fixture now uses supported metadata, while the tests separately assert the app's Spanish language/US region, retained metadata locale, StoreKit USA storefront, USD currency and expected Spanish offer. US Spanish app copy/accessibility acceptance still requires the parent's UI/human review. [Apple United States storefront languages](https://developer.apple.com/help/app-store-connect/reference/app-information/app-store-localizations/), [Apple metadata locales](https://developer.apple.com/documentation/appstoreconnectapi/managing-metadata-in-your-app-by-using-locale-shortcodes)

## Evidence and remaining gates

The full plan ran serially on three local simulator runtimes. Both configurations ran every method with zero skips.

| Runtime | US English | US Spanish |
| --- | --- | --- |
| iOS 17.0 | 15 passed | 15 passed |
| iOS 27.0 | 13 passed, 2 failed | 13 passed, 2 failed |
| iOS 27.1 | 12 passed, 3 failed | 13 passed, 2 failed |

Both iOS 27 runtimes failed the fresh-customer decline and the same-SKU sequence. StoreKitTest marked the declined request as failed with its pending flag cleared. StoreKit 2 exposed the same request ID as a verified, unexpired, unrevoked Xcode entitlement on the same synthetic account. The app's service-authority and Free continuity assertions passed. The English iOS 27.1 run also timed out waiting for the observed transaction to appear in the unfinished queue. That observer case passed in both languages when run alone. The local StoreKit gate remains open. [Run summaries, structural diagnostics and source hashes](../../../docs/evidence/native/local-storekit-full-matrix.json)

The initial 14-method run also captured the Spanish metadata-locale mismatch. The next full run reproduced the Ask to Buy failure in both languages, and the isolated decline passed in both. [Initial run](../../../docs/evidence/native/local-storekit-initial-summary.json) · [Second full run](../../../docs/evidence/native/local-storekit-second-summary.json) · [Isolated decline](../../../docs/evidence/native/dot-storekit-decline-summary.json)

Apple sandbox purchases, signed-device checks, durable server verification and TestFlight remain separate acceptance gates.

The purchase recovery change passed all 15 iOS 17 scenarios in each locale. On iOS 27, the focused offer, unavailable-delivery purchase and restore checks passed in Spanish. The English offer and restore checks passed, and the English purchase check passed when rerun alone after reaching the initial one-minute timeout. [Purchase recovery evidence](../../../docs/evidence/native/membership-delivery-20261104/validation.json)
