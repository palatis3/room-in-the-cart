# Service implementation and continuation handoff

This is a real PostgreSQL-backed HTTP service for a bounded request/shop slice, not the complete launch service. It has no public identity bypass or in-memory success repository. Unknown routes return errors. Production launch remains blocked by the remaining work below.

## Run and verify

Node is pinned in `../.node-version`. Install with `npm ci --ignore-scripts`, compile with `npm run build`. `npm test` runs independent shared checkout vectors, JWT/configuration boundaries and Apple verifier/unit checks. `npm run test:integration` requires a real PostgreSQL database and explicitly fails if its database URLs are absent:

```sh
TEST_ADMIN_DATABASE_URL=postgresql://migration_owner@localhost/ritc_test \
TEST_DATABASE_URL=postgresql://ritc_runtime@localhost/ritc_test \
npm run test:integration
```

Run migrations using `MIGRATION_DATABASE_URL=... npm run migrate`. Migration checksums and a database advisory lock prevent changing an applied migration or racing migration runners. Create a separate login role that inherits `ritc_app`, is `NOSUPERUSER NOBYPASSRLS`, and does not own tables. Never serve requests with the migration owner. All service tables are in private schema `ritc`, not an exposed Supabase/PostgREST schema. The runtime startup asserts role restrictions. A tenant policy and composite foreign keys reinforce explicit authorization checks.

`npm start` uses `DATABASE_URL` and optional JWT configuration from `.env.example`; it does not auto-read `.env`. An absent identity configuration denies authentication. The default process listens on loopback port 3001; deploy behind managed HTTPS with a process/container adapter. The shared runtime and Vercel adapter are maintained by the deployment owner; verify staging evidence separately before claiming a deployed flow.

The GitHub `service-postgres` job provisions an ephemeral PostgreSQL 17.11 test database and separate runtime role, runs migrations, enables actual billing database tests and executes the HTTP/database regression suite. Fixtures are fictional. The tests use real signed ES256 fixture JWTs and a local trusted JWKS adapter; no production signing key is used. Billing transaction tests substitute Apple's remote authority, while separate tests run the actual official verifier against invalid signatures. No real Apple sandbox transaction has yet been delivered.

Local evidence from this development run: `.tools/service-integration.log` contains the core PostgreSQL/HTTP scenarios and billing transaction subtests. `.tools/postgres` is an ignored, locally compiled PostgreSQL 17.11 installation from the official source archive, SHA256-verified before extraction. Its no-SSL build is only for loopback/socket fixture testing; it is not a deployment artifact.

## Identity and authorization

Native clients authenticate with a verified access JWT and separately enrolled `X-Device-Token`. The JWT must use ES256/RS256 and match configured HTTPS issuer, audience and JWKS; `sub`, `iat`, `exp`, and a signed `session_id` are mandatory. A token is not a membership grant. Device enrollment binds issuer/subject/session to an active membership. Deployed child access is hard-disabled pending an actual reviewed provider. Fictional test fixtures separately exercise the consent boundary; when explicitly configured in tests, access requires a current verified guardian relationship, live notice-specific consent and active guardian; consent evidence cannot be unrevoked. There is no public route that creates consent evidence from a checkbox.

Browser clients exchange a verified bearer identity through a managed-login BFF for an opaque Secure HttpOnly SameSite=Strict cookie. Cookie-authenticated mutations require the configured exact Origin and session CSRF header. JSON responses do not return the device secret. Logout revokes its device, replay windows and session and clears the cookie. All responses are `no-store`; error bodies contain only a fixed code, recovery text and generated correlation ID. Request contents, tokens and database errors are not logged.

Every authenticated transaction, device enrollment, workspace discovery and browser session checks the signed session ID against the configured provider's live auth.sessions row and subject, including not_after. A private boolean function holds a SHARE lock until the transaction completes, serializing provider deletion with the authorized action. The runtime has no direct access to auth.sessions. Missing, deleted, mismatched or expired sessions fail closed, including reenrollment. No browser `/v1/auth/start` OAuth callback flow exists yet; this is an explicit remaining dependency, not a placeholder success route.

## Transaction behavior

Every household operation locks its household serialization row before reading membership/device/consent and mutable state. This deliberately favors correctness for a small household over parallel writes inside one household. Access-revocation database triggers use the same lock. Queries have bounded statement/lock timeouts. Pending requests never mutate the basket. A server preview binds actor, shop revision, request revision, epoch, decision, input fingerprint and expiry. Apply rechecks them and recomputes all totals in the transaction.

Prices are integer cents with exact intermediate arithmetic. Quotes explicitly declare scope, completeness, fees, tax, deposits, discounts and observation/expiry. Unknowns remain unknown. Threshold fees count only eligible goods. Item caps cannot produce a whole-checkout assurance. An addition over the cap requires explicit overage acceptance; unresolved or differently scoped totals require explicit unknown-cost acceptance. Linking an existing line adds no duplicate purchase line.

Replay windows are server-issued, device-bound and expiring. The durable key namespace is household+actor+clientKey; the canonical digest includes the entire versioned command including its replay window. Current authorization is rechecked before returning a stored response. A changed-body key conflicts, an expired window or compacted response requires refresh, and neither re-executes the original operation. The operation identity, disposable response, change event, request/basket effects and snapshots commit together. An injected failure after mutation but before the event insert is covered by rollback tests.

Freeze preserves an immutable dated snapshot. Shopper transfer increments the authority epoch without replacing the frozen basket. A formerly authorized shopper can submit separately attributed placement evidence against their actual historical snapshot; it remains pending and cannot close the new shopper's basket. The current shopper can reconcile a matching frozen snapshot. Placed truth is not silently reopened or patched. Contributor edits to accepted requests require a linked follow-up.

## Implemented HTTP surface

All household routes require the device credential, except enrollment. UUIDs are opaque. Browser cookies supply the equivalent enrolled device server-side. Mutation bodies are strict allowlists; unknown fields are rejected.

| Route | Behavior |
|---|---|
| `GET /health` | Process is running; does not claim product readiness. |
| `GET /v1/me/workspaces` | Own active adult memberships only. |
| `POST /v1/households/{h}/devices` | `{}` to enroll against existing membership; returns deviceId/deviceToken. |
| `DELETE /v1/households/{h}/devices/current` | Revoke this enrolled device/windows. |
| `POST /v1/households/{h}/replay-windows` | `{}` returns `{id,expiresAt}`. |
| `GET /v1/households/{h}/bootstrap` | Minimal household label, own member ID, current shop ID, role and capabilities. |
| `GET /v1/households/{h}/requests/mine?cursor={requestId}` | Own-only paginated request projection; includes owning shopId, never prices or other authors. |
| `GET /v1/households/{h}/shops/{s}` | Current shopper's reviewed quote, basket, revision and epoch. |
| `GET /v1/households/{h}/shops/{s}/inbox?cursor={requestId}` | Current shopper only. |
| `POST /v1/households/{h}/shops/{s}/previews` | Request decision preview with current base and explicit add/link/defer/dismiss/handled choice. |
| `POST /v1/households/{h}/commands` | One strict versioned idempotent intent. |
| `POST /v1/session` | Verified bearer plus `{householdId}` creates browser cookie session. |
| `GET /v1/session` | Unauthenticated or scoped session/CSRF/replay metadata. |
| `DELETE /v1/session` | CSRF-protected browser logout. |
| `POST /v1/households/{h}/billing/purchase-context` | Configured Apple authority; server-issued appAccountToken. |
| `POST /v1/billing/verify` | Authenticated household + signedTransactionInfo; durable receipt after transaction commit. |
| `GET /v1/households/{h}/entitlements` | Verified current entitlement snapshot. |
| `GET /v1/households/{h}/billing/seat-candidates` | Purchaser-only eligible adult candidates. |
| `PUT /v1/households/{h}/billing/seats` | Purchaser changes up to two adult seats against exact revision. |
| `POST /v1/apple/notifications` | Official signature verification before routing to bound household. |

See `src/contracts.ts` for authoritative executable command validation and `../shared/contracts/service-v1.d.ts` for client DTOs. Author send/edit/withdraw use base shopRevision0/authorityEpoch0; edit/withdraw require requestRevision. Send accepts an explicit next route; frozen/placed shops always route arrivals next. The current-shop bootstrap is not used as the target for editing an older request; use the request's shopId.

Implemented commands: `shop.create`, `shop.patch`, `shop.freeze`, `shop.reopen` (frozen only), `shop.transferAuthority`, `shop.reportPlaced`, `shop.reconcileReport`, `request.send`, `request.edit`, `request.withdraw`, `request.clarify`, and `request.apply`.

## Household lifecycle additions

See [API-LIFECYCLE.md](API-LIFECYCLE.md) for the tested creation, invitation, browser-switch, helper view/proposal and guardian-read/withdrawal contracts. Migrations 005–007 add live session checks, policy/index hardening, adult lifecycle persistence and exact helper-session grant selection. Applied 001–004 were not changed. Helper proposals are durable pending suggestions and never mutate the basket. Shopper-only inbox rows include authorAlias; contributor projections remain minimal.

Current local evidence: `.tools/service-lifecycle-integration.log` covers the complete core and lifecycle regression suite plus real billing transactions, with no skipped database tests. `.tools/service-unit-fast.log` contains 22 passing checkout/JWT/billing/runtime fast tests with zero skips. The final PostgreSQL log contains 38 passes, zero failures and zero skips. The general `npm test` log (`.tools/service-unit.log`) additionally lists one database-only group as skipped when its database environment is absent; that group is exercised by the separate integration command. Neither log claims a deployed OAuth callback, verified child consent method, real Apple sandbox transaction, or end-to-end device acceptance.

## Remaining work

1. Managed browser sign-in callback/BFF and native enrollment UX, actual provider configuration and real iPhone/Android invitation journeys. Adult self-serve creation and hashed single-use invitations now exist and are tested against PostgreSQL; identity is still established by the external login provider.
2. Provider-backed guardian enrollment and child erasure. Guardian relationship/consent read and withdrawal are implemented; creation of verification evidence remains unavailable and child networking remains disabled in the deployed runtime.
3. Helper pending-proposal review completion and an explicit shopper apply workflow. One-shop redacted views, exact selected-grant sessions, current-view updates, propose-only suggestions and grant revocation are implemented. Broad meal planning, private-field disclosure and automatic proposal application are not implied.
4. Scoped change feed/cursors, account/session revocation integration, synchronization bootstrap after expired windows, outbox consent and operational replay-window/receipt compaction policy. The event table currently records transactional evidence; it is not exposed as a finished sync feed.
5. Expand from the current core integration scenarios to all 20 foundation routing traces, deterministic authority-transfer/placement interleavings, authorized deletion/tombstone/restore, encrypted backups, retention jobs, production shared rate limiting and metrics. Do not call the test subset full B07 acceptance.
6. Shared planner, fulfillment, inventory/allocation, meal-week grants, capture/media, files/import/exports and remaining 52 launch requirements; coordinate with independently implemented native engines.
7. Apple identifiers, root certificates, API key, sandbox/production environments, product setup and real StoreKit sandbox evidence. Billing is fail-closed without this configuration. See `src/billing/SETUP.md` if supplied by its owning agent.
8. Staging deployment, least-privilege credentials, Supabase JWKS/session behavior, minimum/current-device end-to-end checks, real browser/iPhone/Android invitation tests, and approved release operations. Local tests and a healthy empty Supabase project are not deployment or launch evidence.
