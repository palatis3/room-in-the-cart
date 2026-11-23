# Apple billing on the Release service

The submitted app connects to the service origin embedded in Release. On that service, set `APPLE_ENVIRONMENT=Production`. An authenticated adult's selected household determines which Apple environment verifies a purchase, refreshes an entitlement or reconciles a seat change.

## Server configuration

| Variable | Value the release owner supplies |
| --- | --- |
| `APPLE_BUNDLE_ID`, `APPLE_PRODUCT_ID` | The Release app's bundle identifier and auto-renewable subscription product identifier, matching the signed build and App Store Connect. |
| `APPLE_APP_ID` | The positive numeric Apple ID from the Release app record. |
| `APPLE_ROOT_CA_PATHS` | Comma-separated paths to trusted Apple root CA certificate files available in the deployed runtime. Vercel packages the certificates under `service/src/billing/certificates` with the API function. |
| `APPLE_KEY_ID`, `APPLE_ISSUER_ID` | The In-App Purchase key ID and issuer UUID. |
| `APPLE_SIGNING_KEY_PEM` or `APPLE_SIGNING_KEY_PATH` | Supply exactly one source. Vercel uses the complete multiline `.p8` contents as a server-side Secret. A standalone process can read the same key from a protected file path. Keep the private key outside the repository and app bundle. |
| `APPLE_REVIEW_HOUSEHOLD_IDS` | Optional comma-separated UUIDs of dedicated fictional review households on the Release service. An empty or absent value routes every household to the primary environment. |

For Vercel, set `APPLE_ROOT_CA_PATHS` to the following repository-relative paths. The three certificates come from [Apple PKI](https://www.apple.com/certificateauthority/).

```text
service/src/billing/certificates/AppleIncRootCertificate.cer,service/src/billing/certificates/AppleRootCA-G2.cer,service/src/billing/certificates/AppleRootCA-G3.cer
```

From a directory linked to the intended Vercel project, use `vercel env add APPLE_SIGNING_KEY_PEM production --type secret < /absolute/private/path/SubscriptionKey.p8` to supply the existing key without copying its contents into a command. Use the Production target of the separately linked staging project for a staging deployment built with `--prod`. Check the selected project's deployment protection and target before creating the deployment.

Provision the review purchaser and any second adult using the normal household enrollment flow. Use a fresh fictional household for each independent purchase scenario. Confirm its UUID from the service and restrict invitations to review participants. Set the same review list across serving instances before the first sandbox purchase and keep it in place throughout review and restore testing. Updates to the list take effect when the runtime restarts. Retire a review household through normal account lifecycle procedures before removing its UUID. An existing purchase stays bound to its original environment and household.

On a separately deployed staging service with its own app record and test database, `APPLE_ENVIRONMENT=Sandbox` selects the single Sandbox gateway. Leave the review list empty on that deployment.

## App Store Server Notifications V2

In App Store Connect, open the Release app's **App Information → App Store Server Notifications**. Enter both HTTPS URLs using the service origin from the submitted build and choose Version 2 for each. Apple defaults sandbox delivery to the production URL if the sandbox field is empty. [Apple's server URL instructions](https://developer.apple.com/help/app-store-connect/configure-in-app-purchase-settings/enter-server-urls-for-app-store-server-notifications/)

| App Store Connect field | Path on the Release service |
| --- | --- |
| Production Server URL | `/v1/apple/notifications` |
| Sandbox Server URL | `/v1/apple/notifications/sandbox` for consent and TEST. Sandbox purchases also need a configured review household |

For purchases, each endpoint verifies the outer Apple signature and the signed transaction against its configured environment. The transaction's signed account token must map to a purchaser in a household assigned to that endpoint. The service verifies Apple's current subscription status before committing an entitlement. Signed TEST notifications acknowledge endpoint connectivity and create no entitlement.

## Consent revocation

The same V2 URLs can receive consent revocations before enabling purchases. Configure `APPLE_BUNDLE_ID`, `APPLE_ROOT_CA_PATHS`, `APPLE_ENVIRONMENT` and, for Production, `APPLE_APP_ID`. Leave the product ID, signing key sources, key ID, issuer ID and the review household list absent for a verification-only deployment. A Production deployment then accepts a signed production notification at the primary URL and a signed sandbox notification at the sandbox URL. A standalone Sandbox deployment accepts sandbox notifications at the primary URL.

For `RESCIND_CONSENT`, the service verifies Apple’s signed envelope and checks its `appData` bundle and environment, plus the app Apple ID in production. When Apple supplies `appData.signedAppTransactionInfo`, the service also verifies that nested app transaction. Apply migration 072 before enabling delivery. A successful reply follows a durable insert of the environment, notification UUID and Apple’s signature timestamp. Repeated delivery has one receipt per environment. The service discards the signed payload and download identifier. [Apple’s appData schema](https://developer.apple.com/documentation/appstoreservernotifications/appdata)

Apple blocks the revoked child’s app from launching. The optional app transaction identifies the Apple Account’s download for this app. Room in the Cart guardian enrollment uses a separate authenticated identity, and its subscription token belongs to the purchasing adult. This notification establishes no household, child login, or website session to revoke. Guardian consent withdrawal and account erasure continue to use their authenticated flows. A policy requiring cross-platform suspension would need a separately verified binding, a defined scope for shared devices, and a way to handle renewed consent before enabling it. [Apple’s age assurance Q&A](https://developer.apple.com/support/age-assurance/) · [App transaction identity](https://developer.apple.com/documentation/storekit/apptransaction/apptransactionid)

On a signed sandbox device, use **Sandbox Apple Account → Manage → Revoke App Consent**, enter the bundle ID and confirm delivery to the configured sandbox URL. Compare the stored notification UUID and environment with Apple’s delivery record and verify the controlled household and purchase seats keep their prior state. This live delivery is a release-owner check. [Apple’s sandbox instructions](https://developer.apple.com/documentation/storekit/testing-age-assurance-in-sandbox)

## Candidate checks

1. Request a test notification through each environment of Apple's server API and inspect its delivery status. [Apple's notification test instructions](https://developer.apple.com/documentation/appstoreservernotifications/enabling-app-store-server-notifications)
2. On a signed TestFlight build using the Release origin, sign in to the review household, purchase the actual localized product, and restore with the purchasing Apple account after reinstalling. Confirm the service records the `Sandbox` environment for the purchase and updates the correct household after renewal or expiry. [Apple's TestFlight purchase guide](https://developer.apple.com/help/app-store-connect/test-a-beta-version/testing-subscriptions-and-in-app-purchases-in-testflight/)
3. With a second fictional household outside the review list, verify that the same sandbox purchase cannot create or restore a paid entitlement. Confirm the second adult in the review household receives only the seat assigned by the purchaser. Supply the tested role access and purchase steps in App Review's private notes.
