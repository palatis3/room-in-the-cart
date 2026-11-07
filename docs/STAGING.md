# Staging environment

Room in the Cart has its own Supabase organization and project. Its Vercel team was renamed from DoorFrame Staging at the user’s request; the app has a separate Vercel project.

- Organization: `ybzztipzreurtjtjhmbo` (Room in the Cart).
- Project: `uwjxrotnocxxomqdetzk` (Room in the Cart Staging), US West Oregon.
- Auth URL: `https://uwjxrotnocxxomqdetzk.supabase.co`.
- PostgreSQL transaction pooler: `aws-1-us-west-2.pooler.supabase.com:6543/postgres`, verified in the project dashboard.
- Migrations 001–041 are live. All 41 hosted migration checksums matched the reviewed source. The upgrade preserved the 128 existing non-registry tables and began with zero device grants. [Deployment evidence](evidence/b11/staging-041-preparation-20261107/deployed.json)
- Runtime role `ritc_runtime` inherits `ritc_app`, is not a table owner, superuser or RLS bypass role. It has no tenant scope by default.

The public client configuration in `config/staging.json` contains a publishable key, never the database password or a service-role key. Debug and Staging builds receive this configuration; Release requires its own production configuration.

The runtime password is stored only in the ignored, owner-readable `.tools/staging-runtime.json` on this development Mac. It must be provisioned as a sensitive deployment variable, never copied to the app, browser bundle, repository, logs, or a diagnostic export. The migration owner is not an application credential.

Remote PostgreSQL connections verify the server certificate and hostname. `config/supabase-ca.crt` is the public CA downloaded from the project's Database Settings certificate link. SHA-256: `807025ad50d4ed219d2c9c7d299c004f824eb00cf7f65afef607d07b72e6cafa`. Supply its PEM as `DATABASE_CA_PEM`; do not disable certificate verification. The shared runtime strips connection-string SSL overrides.

## Deployment

The live staging project is `room-in-the-cart-staging`, owned by the renamed **Room in the Cart** Vercel team (`team_zkjaW5rtwPK9URZDeSoybwXB`; existing URL slug `doorframe-staging`). The verified service and web URL is https://room-in-the-cart-staging.vercel.app. This is the dedicated staging environment, not the App Store production release.

The root `vercel.json` builds the narrow web client and Node service together. `/v1/*` and `/health` route to the same Node HTTP implementation used by integration tests; the web client uses a same-origin, HttpOnly-cookie session. Production publishing remains a separate release gate.

Browser email-code sign-in additionally requires `EMAIL_OTP_ENABLED=true`, `SUPABASE_URL`, `SUPABASE_PUBLISHABLE_KEY`, and a server-only `BFF_TOKEN_ENCRYPTION_KEY` containing a canonical base64-encoded 32-byte key. Keep the flag false until email delivery is configured and verified. Vercel deployments use the platform-overwritten client-address header for request limiting; direct local requests use their socket address.

Required server variables: `DATABASE_URL`, `DATABASE_CA_PEM`, `JWT_ISSUER`, `JWT_AUDIENCE`, `JWT_JWKS_URL`, and the exact HTTPS `WEB_ORIGIN`. Apple billing configuration must use the actual signed app and App Store product. Child network access remains disabled until real guardian verification and consent revocation are integrated.

## Evidence and open gates

The installed Staging iPhone app reached the live service and opened Help and Support in Mobile Safari. All three simulator tests passed. The Staging scheme also produced an unsigned arm64 device archive. [Native build verification](evidence/b11/staging-040-preparation-20261107/native-iphone.json)

The owner deferred Apple Developer membership and email-provider configuration on November 3, 2026. Development continues; signed distribution and live email-code sign-in are pending those setups. The current Supabase default email sends a magic link without a code, and its dashboard requires custom SMTP or a paid plan to edit that template. `emailOTPEnabled` remains false until the configured email includes a token and delivery is verified. Native builds receive an explicit disabled availability setting; service/BFF enablement must follow the same gate.

- `evidence/staging-public-smoke.json`: deployed health/session responses, missing and invalid credential denial, and wrong-origin denial. Signed-in journeys remain separate gates.

- `evidence/staging-schema-verification.json`: migrations, RLS counts, and inspected platform trigger definition.
- `evidence/staging-advisors-initial.json`: initial advisor findings; migration 005 resolved all security warnings. The sole remaining security INFO notes the intentionally admin-only migration registry.
- `evidence/staging-service-smoke.json`: local HTTP service connected to live staging PostgreSQL with verified TLS, unauthenticated access denial, invalid JWT rejection, and wrong-origin denial. This is not public deployment or signed-in end-to-end evidence.

Live session checks are installed and a nonexistent session is denied without exposing `auth.sessions` to the runtime or public roles (`evidence/staging-session-boundary.json`). Full signed-in provider logout testing, household onboarding/invitations, narrow helper access, real browser/native authenticated journeys, operational retention, and Apple purchase verification remain release gates. See `IMPLEMENTATION.md` and `../service/IMPLEMENTATION.md` for the complete requirements register and service scope.
