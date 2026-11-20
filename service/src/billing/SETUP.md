# Apple billing on the Release service

The submitted app connects to the service origin embedded in Release. On that service, set `APPLE_ENVIRONMENT=Production`. An authenticated adult's selected household determines which Apple environment verifies a purchase, refreshes an entitlement or reconciles a seat change.

## Server configuration

| Variable | Value the release owner supplies |
| --- | --- |
| `APPLE_BUNDLE_ID`, `APPLE_PRODUCT_ID` | The Release app's bundle identifier and auto-renewable subscription product identifier, matching the signed build and App Store Connect. |
| `APPLE_APP_ID` | The positive numeric Apple ID from the Release app record. |
| `APPLE_ROOT_CA_PATHS` | Comma-separated paths to trusted Apple root CA certificate files available in the deployed runtime. |
| `APPLE_KEY_ID`, `APPLE_ISSUER_ID`, `APPLE_SIGNING_KEY_PATH` | The In-App Purchase key ID, issuer UUID and path to its protected private key file. Verify the deployed function can read each configured file. Keep the private key outside the repository and app bundle. |
| `APPLE_REVIEW_HOUSEHOLD_IDS` | Optional comma-separated UUIDs of dedicated fictional review households on the Release service. An empty or absent value routes every household to the primary environment. |

Provision the review purchaser and any second adult using the normal household enrollment flow. Use a fresh fictional household for each independent purchase scenario. Confirm its UUID from the service and restrict invitations to review participants. Set the same review list across serving instances before the first sandbox purchase and keep it in place throughout review and restore testing. Updates to the list take effect when the runtime restarts. Retire a review household through normal account lifecycle procedures before removing its UUID. An existing purchase stays bound to its original environment and household.

On a separately deployed staging service with its own app record and test database, `APPLE_ENVIRONMENT=Sandbox` selects the single Sandbox gateway. Leave the review list empty on that deployment.

## App Store Server Notifications V2

In App Store Connect, open the Release app's **App Information → App Store Server Notifications**. Enter both HTTPS URLs using the service origin from the submitted build and choose Version 2 for each. Apple defaults sandbox delivery to the production URL if the sandbox field is empty. [Apple's server URL instructions](https://developer.apple.com/help/app-store-connect/configure-in-app-purchase-settings/enter-server-urls-for-app-store-server-notifications/)

| App Store Connect field | Path on the Release service |
| --- | --- |
| Production Server URL | `/v1/apple/notifications` |
| Sandbox Server URL | `/v1/apple/notifications/sandbox` with at least one configured review household |

Each endpoint verifies the outer Apple signature and the signed transaction against its configured environment. The transaction's signed account token must map to a purchaser in a household assigned to that endpoint. The service verifies Apple's current subscription status before committing an entitlement. Signed TEST notifications acknowledge endpoint connectivity and create no entitlement.

## Candidate checks

1. Request a test notification through each environment of Apple's server API and inspect its delivery status. [Apple's notification test instructions](https://developer.apple.com/documentation/appstoreservernotifications/enabling-app-store-server-notifications)
2. On a signed TestFlight build using the Release origin, sign in to the review household, purchase the actual localized product, and restore with the purchasing Apple account after reinstalling. Confirm the service records the `Sandbox` environment for the purchase and updates the correct household after renewal or expiry. [Apple's TestFlight purchase guide](https://developer.apple.com/help/app-store-connect/test-a-beta-version/testing-subscriptions-and-in-app-purchases-in-testflight/)
3. With a second fictional household outside the review list, verify that the same sandbox purchase cannot create or restore a paid entitlement. Confirm the second adult in the review household receives only the seat assigned by the purchaser. Supply the tested role access and purchase steps in App Review's private notes.
