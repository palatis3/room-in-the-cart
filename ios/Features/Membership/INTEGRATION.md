# Membership integration handoff

The native module uses StoreKit 2 and an authenticated service adapter. No test purchase or local price grants access. `HouseholdLocalTesting.storekit` is an explicitly local annual-price hypothesis; its Xcode transactions are rejected by the server's Sandbox/Production verifier.

## Composition and lifecycle

Construct `HTTPMembershipEntitlementService(baseURL:deviceToken:token:)` with an HTTPS service origin and closures for `HouseholdModel.deviceAccessToken()` and `adultAccessToken()`. The selected household must already be enrolled. Every billing request sends both `Authorization: Bearer …` and `X-Device-Token`. The default session is ephemeral, does not store cookies/cache, and refuses redirects.

Request `purchaseContext(householdID:)`. Use its server-issued UUID in `MembershipContext.appAccountToken`. Catch **only** `MembershipFailure.notPurchaser` to build a context with a nil token for an authenticated adult viewing a shared named seat. Do not convert wrong-household, sign-in, access-denial, or transport failures into a nil-token context. The context's `purchaserID` is the current authenticated member ID; the snapshot's `purchaserID` identifies the actual subscription purchaser. Display names and household identity come from the authenticated projection.

A nil-token context cannot purchase or manage seats and does not observe, submit, finish, or sync the purchaser's StoreKit transactions. It fetches its own service-authorized shared entitlement on start, refresh and Restore. An unseated adult remains Free.

The app root retains `@StateObject private var membership = MembershipCoordinator()` and injects `.environmentObject(membership)`. Call `membership.bind(to: household)` from the app task, then `membership.foreground()` when `scenePhase` becomes active. The coordinator chains the household's synchronous `onScopeChange` hook and observes projection/identity/lock changes. It owns one model/transaction observer per authorized scope, refreshes it on foreground, and stops it before account/household change, lock, sign out or a service authorization rejection. A new identity waits for a fresh authorized projection. Generation-bound credential closures and model generations reject late work. `MembershipEntryView(household:)` reads that coordinator; disappearing from the view does not stop observation. Shared operations still require independent server role, grant, shopper and revision checks. `hasPaidAccess` never grants those permissions.

## Actual service contract

| Method and route | Request / response |
| --- | --- |
| POST `/v1/households/:id/billing/purchase-context` | `{}` → `{appAccountToken}`. An authenticated active adult who is not the existing purchaser receives 409 `purchase_context_not_purchaser`, mapped to `.notPurchaser`. |
| POST `/v1/billing/verify` | `{householdId,signedTransactionInfo}` → `{acceptedTransactionID,durable,snapshot}` after the repository transaction commits. |
| GET `/v1/households/:id/entitlements` | `MembershipSnapshot` with camel-case native field names and ISO 8601 dates. |
| GET `/v1/households/:id/billing/seat-candidates` | `{adults:[{userID,displayName,isAdult}]}` for the purchaser. |
| PUT `/v1/households/:id/billing/seats` | `{revision,userIDs}` → new snapshot. At most two distinct active adults; whole assignment replacement in one locked transaction. |
| POST `/v1/apple/notifications` | Apple V2 `{signedPayload}`; cryptographically verified, current status reconciled, then durable acknowledgement. |

The adapter maps `purchase_already_bound` to `.wrongHousehold`, `refresh_required` to `.refreshRequired`, `membership_inactive` to `.membershipInactive`, and `access_ended`/`session_needed` to `.signInRequired`. Transient billing/storage/rate-limit failures remain retryable delivery failures. An inactive entitlement clears its paid projection while preserving local Free work. A failed restore remains visible even after a successful Free-status fetch.

## Trust and delivery

The server uses Apple's official `SignedDataVerifier` with online certificate checks and deployment-owned trusted Apple roots, then checks configured environment, bundle, product, ownership, dates and account token. It fetches current subscription status and verifies nested transaction/renewal JWS before access changes. An old signed receipt cannot itself restore refunded access. Original-purchase binding, delivery deduplication, notification audit, tenant RLS and two numbered adult slots are persisted in migration 002. Seats never modify shopper authority or household grants.

The client grants no access for pending/cancelled/unverified transactions and finishes only after a durable service receipt with matching transaction ID, purchaser and household. Undelivered transactions remain unfinished for retry. Entitlement leases are bounded to five minutes and the known expiry/grace deadline. Billing code has no reference to local records or manual-planning stores; lapse does not delete that work.

## Verification and remaining evidence

The focused handoff suite has 36 deterministic XCTest cases using the real model/HTTP/StoreKit source and injected StoreKit/service boundaries. It covers cancellation, pending, signature denial, durable-before-finish, interruption/retry, wrong household/account restore, stale/refund precedence, expiry/grace, two adult seats, no shopper authority, sign-out callbacks, second-seat read access, device headers, service errors and TLS configuration. Eight coordinator lifecycle cases also cover screen-independent startup, one observer across foreground refreshes, lock, delayed construction after sign-out, household-switch delivery races, same-household reenrollment, credential isolation, identity changes awaiting a new projection, and authorization rejection. These run on macOS without Apple purchase UI. All module files and tests also typecheck for iOS 17 simulator, and the en/es string catalog compiles.

Six TypeScript billing tests pass, including actual official-SDK rejection of unsigned and forged JWS. PostgreSQL integration is coordinated by the service/build owner; it must run `src/billing/tests/postgres.test.mjs` under the non-owner runtime role with migrations 001–004. The test now also checks the typed non-purchaser purchase-context denial.

This is not sandbox purchase evidence. Release still needs the owner's Apple team agreements, permanent bundle/product configuration, real localized product, server roots/API key and separate environment endpoints, signed build, a signed test notification, and device evidence for purchase, interrupted delivery, reinstall/second-device restore, second-seat recovery, renewal, billing retry/grace, expiry and refund. No App Store account, certificate or successful purchase is assumed by this module.

Apple references: [official App Store Server Library](https://github.com/apple/app-store-server-library-node), [unfinished transactions](https://developer.apple.com/documentation/storekit/transaction/unfinished).
