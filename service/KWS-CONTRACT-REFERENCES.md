# Verified KWS integration references

Read in the official Epic documentation and authenticated Developer Portal on November 3, 2026. These describe the provider protocol, not activation or successful live verification. No service agreement, verification email or provider setting was accepted, sent or enabled by the agent during this read.

## Server authentication

[Official PV integration guide](https://dev.epicgames.com/docs/kids-web-services/parent-verification-service/pv-service-integration): obtain a developer token at `https://auth.kidswebservices.com/auth/realms/kws/protocol/openid-connect/token` with HTTP Basic client credentials and form body `grant_type=client_credentials&scope=verification`. The JSON response contains `access_token` and `expires_in`. Credentials differ between test and production. Obtain the exact service API host from the portal's Integration Information; the guide also identifies `https://api.kidswebservices.com`. Renew an expired token after 401; bound retries and backoff. Credentials remain server-only.

## Start verification

[Authenticated managed-verification API specification](https://dev.epicgames.com/portal/en-US/room-in-the-cart/kws/api-docs/kws-managed-verification), OAS 3.0 / API 1.0:

- `POST /v1/verifications/send-email`, JSON with `location`, `externalPayload`, `userContext`, `email`, `language`. The schema requires `location` and `email`; this app also supplies its explicit parent context, language and opaque binding nonce.
- HTTP 202 JSON contains `response.trustEmailRequestAccepted` and metadata `timestamp` / `requestId`. Acceptance only means the verification-email request was accepted. It does not prove adulthood or record guardian consent.
- The displayed specification lists this one operation. No provider idempotency key or status endpoint was documented. An ambiguous lost response must remain uncertain; do not invent automatic exactly-once resend semantics.

The integration guide limits `externalPayload` to a JSON or UTF-8 string of 250 characters, describes country/subdivision location and guardian-language inputs, and requires `userContext: parent`. Test email recipients must be organization developers/admins or supported aliases. [API reference](https://dev.epicgames.com/docs/kids-web-services/parent-verification-service/pv-service-api-reference) requires a nonempty User-Agent and states a ten-request/hour limit per email in both environments. App-side bounds must also apply.

## Trusted completion

[Official webhook configuration](https://dev.epicgames.com/docs/kids-web-services/parent-verification-service/set-up/pv-service-configure-webhook): read `x-kws-signature` fields `t` and one or more `v1` signatures. Compute HMAC-SHA256 using the held webhook secret over the timestamp, a period and the **original UTF-8 request body**; compare the hexadecimal signature in constant time. The published timestamp example is in milliseconds. Secret rotation can produce multiple `v1` signatures; any matching currently held secret authenticates the bytes. Do not reserialize JSON before verification. The provider retries non-2xx responses with backoff.

The event discriminator is `name: parent-verified`; the body includes `time` (documented as ISO8601), `orgId`, `productId`, and `payload` containing `parentEmail`, `externalPayload`, and `status.verified` / `status.transactionId`. Organization-level examples permit null product IDs; use the explicitly reviewed configuration and never silently widen a product-scoped binding. Deduplicate exact verified events and retain stale/ended enrollment denial. A return-URL query is not activation authority.

## Product boundary

[Official PV flow](https://dev.epicgames.com/docs/kids-web-services/parent-verification-service/pv-service-flow) distinguishes adult verification from obtaining consent and giving the required notice. Room in the Cart must separately check the live guardian account's confirmed email, current notice/version, explicit guardian declaration and consent, child pairing and activation. No identity document, card data or biometric belongs in the app's proof records.

The user signed in, created the Room In The Cart organization and personally accepted the KWS Developer Terms. Parent Verification offered self-service setup once permissions loaded; other services showed Contact us. The Test Integration Information displayed `https://api.kidswebservices.com` as the service API host. Credentials remained masked and were not provisioned into the app or backend. “Publish to Test” was not selected. Approved notices, deployed configuration, live delivery and actual verification remain unverified.
