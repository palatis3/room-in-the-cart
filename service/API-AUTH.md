# Browser email-code authentication

This is an implemented, locally tested BFF integration. **Live email-code delivery is not enabled.** The staging Supabase template currently delivers a confirmation link, not `{{ .Token }}`. The provider configuration requires custom SMTP or an eligible paid setup before that template can be changed. URL/public-key availability alone must never enable this UI. No live email was sent by the implementation tests; those use a fictional local HTTP provider plus real signed fixture JWTs and PostgreSQL.

## Runtime wiring owned by deployment

```ts
import {BrowserAuthService, SupabaseEmailOTPProvider} from './browser-auth.js';
const provider = new SupabaseEmailOTPProvider({url: supabaseURL, publicKey: publishableKey});
const browserAuth = new BrowserAuthService(repository, verifier, provider, {
  encryptionKey: serverOnlyBase64Key, // canonical base64 encoding of 32 random bytes
});
// Pass browserAuth and an exact webOrigin to createHTTPServer only after
// an explicit deployment enable gate confirms actual email-code delivery.
```

The provider URL must be a fixed HTTPS project origin. Only publishable or legacy anon keys are accepted. The browser-auth encryption key is server-only and separate from the Supabase public key. Deployments must provide a reviewed key-rotation and expired-row cleanup process before enabling real enrollment. Changing the key invalidates old encrypted sessions; it does not recover their credentials.

`HTTPOptions.clientAddress?: (request: IncomingMessage) => string | undefined` is the trusted client-address adapter. Without it, a direct server uses the socket address. With it, missing/invalid trusted metadata fails closed; the handler never trusts `x-forwarded-for` on its own. The Vercel runtime adapter must use only metadata Vercel guarantees it overwrites. The ordinary process-local request map is a resource bound. OTP controls live in PostgreSQL and apply across instances: five send requests per email/hour, twenty per trusted client IP/hour, 120 new challenges per trusted client IP/hour, a 60-second resend delay and five verification attempts per challenge. Email/IP bucket keys are HMACs; raw values are not in those records.

## HTTP flow

Every response is `no-store`. All authentication mutations require the exact configured Origin and `X-CSRF-Token`. An opaque `__Host-ritc_auth` cookie is Secure, HttpOnly and SameSite=Strict. Provider access/refresh tokens never appear in API JSON, localStorage, sessionStorage, URLs or frontend configuration.

| Route | Request | Success |
|---|---|---|
| `GET /v1/auth/session` | — | `{available,authenticated,csrf}`. When available and signed out, sets a 15-minute challenge cookie and supplies CSRF. When disabled: `{available:false,authenticated:false,csrf:null}`. |
| `POST /v1/auth/email/start` | `{email}` | `{status:'check_email'}` only after the provider accepts the request. Email length ≤254. No household membership is created. |
| `POST /v1/auth/email/verify` | `{code}` (six digits) | `{available:true,authenticated:true,csrf}`; rotates the opaque cookie and CSRF, clears the previous household cookie. The code is never stored. |
| `POST /v1/auth/refresh` | `{}` | `{available:true,authenticated:true,csrf}` after verifying the new signed token and the same live provider session/subject. |
| `DELETE /v1/auth/session` | — | `{signedOut:true,providerRevoked:boolean}`; clears local browser/household cookies and revokes the enrolled browser device. Provider failure is reported as false, never as confirmed provider logout. |

Use the returned identity CSRF for `/v1/invites/redeem`, `/v1/households`, and the first `/v1/session` activation. Login alone confers no household authority. Existing creation/redemption contracts still require explicit adult attestation and live authorization. After scoped session activation, use that session's CSRF for household operations. The selected helper grant remains exact across token refresh and household switching.

Authentication failures return fixed codes, never provider text: `login_unavailable` (503), `login_rate_limited` (429), `code_not_accepted` (422), `session_needed` (401), or `csrf_failed` (403). Unknown fields and arbitrary redirects are rejected. A failed code attempt consumes an attempt even when the provider rejects it.

## Stored authority and refresh

Migration `008_browser_email_auth.sql` adds private FORCE-RLS browser records and rate buckets. AES-256-GCM encrypts provider credentials and the temporary email, with the cookie hash as authenticated additional data. Successful verification clears the challenge email and rotates the cookie. Refresh serializes on the browser record, so concurrent requests do not race one-time refresh tokens. The refreshed issuer, subject and session ID must match the recorded identity, and `auth.sessions` must still contain that subject-bound session. Missing, expired, revoked or mismatched sessions stop access.

A BFF-bound household cookie requires a live BFF identity every time. It cannot be used alone to bypass logout or the seven-day BFF lifetime. Existing native/legacy enrollment remains distinct. Local logout commits before the provider request; a provider outage leaves only encrypted pending logout material for a controlled retry, and the API reports the unconfirmed provider state. The bounded AuthMaintenance worker now implements expiry cleanup and durable provider logout retries; see API-PRIVACY.md. An operating owner, separate worker credential and actual cron deployment are still required. Revoked provider sessions are checked before refresh; the service never refreshes a revoked browser identity.

## Evidence

The local suite exercises actual provider HTTP adapter calls to a fictional loopback server, signed JWT verification, encrypted PostgreSQL persistence, CSRF/origin errors, code attempt bounds, multi-instance email/IP limits, forged forwarding headers, concurrent refresh, subject mismatch, provider revocation, context switching, and logout during a provider outage. This is integration evidence, not live SMTP/provider-delivery or real-device acceptance.
