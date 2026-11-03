# HouseholdClient

Native, dependency-free URLSession client for the B06 service. It uses Supabase's official Auth HTTP endpoints (email OTP request/verify, rotating refresh, verified `/user`, scoped/global logout). The configured managed identity establishes only an account; all household and object grants remain service-owned. No custom household password or account-derived adult role exists.

The app composition root supplies `HouseholdServiceURL`, `SupabaseProjectURL`, and `SupabasePublishableKey` through its Info.plist build configuration. URLs must use HTTPS; only a `sb_publishable_` client key is accepted. Never put a Supabase secret/service role key in the app. `HouseholdModel()` stays unconfigured when any value is missing and does not prompt at launch. The OTP email template must include `{{ .Token }}`. No Apple client ID, callback URL, certificate, app group or identity provider setup is invented here.

Refresh credentials and enrolled device binding use device-only unlocked Keychain entries. Access tokens live in memory. Default URLSession is ephemeral with cookies/cache disabled and redirects rejected. Network errors expose coarse codes only; no tokens, email, item text or response bodies are logged. Sign-out clears account/UI projections and local retry state even when remote revocation fails; the UI truthfully says when remote sign-out could not be confirmed.

A user chooses an authorized workspace and explicitly keeps existing local work private. This code never reads or uploads the local shopping database. Native requests persist an immutable encoded envelope and its original operation key, replay window, base, household, member and device binding before send. Response loss retries exactly those bytes. A stored enrolled device can resume after process death; changed identity/session/device or expired window requires review and never silently rewraps an old operation. Shared receipt, local draft, waiting, review conflict and access-ended states are separate. Retry delays honor numeric/date Retry-After and bounded exponential jitter. There is no automatic offline shared basket commit.

The service currently supports preprovisioned verified adult memberships. `GET /v1/me/workspaces`, device enrollment, replay windows, bootstrap and own-request send/edit/withdraw are implemented clients. Child consent/enrollment and invitation issuance are not enabled. `ScopedCookView` is a deliberately narrow type, but `ScopedCookClient` fails closed until the server publishes and implements its redemption/projection contract; it does not simulate a received view. No live end-to-end claim is made without a configured service, managed Auth project, approved membership and real devices.

App lifecycle must call `HouseholdModel.lock()` on background when an account is active. Household settings also observes background; return uses LocalAuthentication plus refreshed service access. When OS owner authentication is unavailable, a fresh email login is required. The app's adult-local and contributor persona router must keep their private stores and screens separate.

Verified 2026-11-03 against official sources:
- https://supabase.com/docs/guides/auth/auth-email-passwordless
- https://supabase.com/docs/reference/swift/auth-verifyotp
- https://github.com/supabase/auth/blob/master/openapi.yaml
- https://supabase.com/changelog.md
- https://supabase.com/changelog/cbc-tls-ciphers-deprecated (modern iOS URLSession TLS; no obsolete cipher override)

Run `swift test --package-path ios/Packages/HouseholdClient`. Fake-network tests cover Auth identity verification and token isolation, rejected configuration, sign-out during failure, durable exact retry, changed-key rejection, authorization headers and scope revocation. These are contract tests, not a live Supabase/service integration run.
