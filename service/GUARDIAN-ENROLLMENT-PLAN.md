# Guardian enrollment implementation and release gates

Local implementation checkpoint, November 3, 2026. This file replaces the earlier unimplemented design checkpoint. The app-owned API is [guardian-enrollment-v1.d.ts](../shared/contracts/guardian-enrollment-v1.d.ts); the original proposed path re-exports it. Migration `021_guardian_enrollment.sql` is implemented and locally exercised after 001–020. No deployment, real OTP/PV email, provider account deletion, child-network activation, or KWS Publish to Test action was performed by this lane.

## Implemented authority flow

1. An authenticated adult opens the exact approved en/es direct notice and declares parent/legal guardian status. Fresh child membership requires a current household organizer. An existing actual guardian can manage an existing child relationship, but cannot restore organizer-revoked membership without current organizer authority.
2. A pending opaque child slot is bound to household, initiating guardian, device, exact live provider session, notice version/digest, method and location. No child member or request access exists yet. Verification commits its opaque nonce/attempt and exact retry intent before contacting KWS.
3. The real KWS adapter uses the documented fixed OAuth endpoint, the reviewed exact Service API origin and `POST /v1/verifications/send-email`. HTTP 202 is request acceptance only. A definitive 401 renews the token once; timeouts, lost responses and other uncertain outcomes never automatically resend. Exact application retry recovers the persisted attempt. The application and provider enforce per-email bounds.
4. Only the official raw-body HMAC callback can commit adult verification through the separate verifier login. It binds the exact organization and explicit organization (`productId:null`) or product scope, environment, attempt/nonce, current provider-confirmed guardian email and live session/device. Duplicate identical evidence is harmless; changed evidence, wrong scope/nonce and ended setups cannot confer authority. Redirects, receipts and client booleans never verify a guardian.
5. Adult verification is not guardian consent or independent proof of legal relationship. The guardian separately grants permission for the exact reviewed notice and names the intended child's sign-in email. Only keyed email/intent digests are persisted. This combined method and the direct notice require operator approval.
6. A bounded, single-use invitation covers the intended child's provider signup/sign-in before any child OTP request. Browser entry uses an invitation-bound BFF challenge, then normal OTP verification; native entry uses a retained random challenge secret, server-authorized OTP start, direct provider code verification into the existing native vault, and authenticated admission. Admission requires signed OTP AMR, the current confirmed child email and exact live subject/session. Generic authenticated status is insufficient.
7. The child separately claims the invitation with a random device-generated pairing code. The initiating guardian compares and confirms it. A trusted verifier-only finalizer rechecks approved child admission, current guardian/child emails, session, notice, consent, relationship and organizer authority, then atomically creates the intended child member, new immutable consent generation, paired device and finish intent. Browser finish installs an HttpOnly scope and returns no credential; native finish returns its own retained device secret as the device token.
8. Own-request commands/projections remain the existing restricted S22 path. Generic device enrollment and adult invitation redemption cannot enroll/promote a child. Withdrawal revokes the generation, devices and replay windows. Guardian/member revocation, erasure and terminal setup transitions cannot be cleared or resurrected through ordinary runtime SQL or HTTP.

## Data and privileges

Enrollment, attempt, authenticated event, invitation, claim, signin admission, native challenge and exact intent have separate tables. Tenant rows use forced RLS. The application login cannot write provider evidence, stamp verified child admission or execute finalization. `ritc_guardian_verifier` has only the narrow authenticated event/admission/finalization functions and bounded callback reads; it must not inherit application, worker, owner or bypass privileges.

The privileged admission/finalization transactions hold the same nonblocking shared identity erasure fences as application transactions, before taking household locks. This prevents a pending child's zero-target erasure from racing into a newly activated profile. BFF household hooks run outside browser row transactions; provider calls run outside household locks. Paired browser finish rotates the same scoped-session row, including exact retries.

The private negative `guardian_child_principal` classification contains only the provider UUID and an identity hash, with no runtime table grants. It is bound by foreign key to the provider principal's actual lifetime (`auth.users ... ON DELETE CASCADE`), not an arbitrary retention timer. Removing a grocery profile or expiring an erasure marker cannot turn that same live provider account into an adult. No child provider account is deleted as a side effect of guardian profile erasure.

## Runtime configuration

Missing configuration leaves public availability false and child networking disabled. There is no child-network Boolean override. All conditions use the same service readiness predicate:

- Actual KWS gateway, authenticated webhook verifier and distinct verifier pool.
- Attached real email OTP/BFF onboarding composition (`EMAIL_OTP_ENABLED` plus its existing complete configuration).
- Both approved en/es notices with identical notice/method versions, exact text digests and explicit approval references.
- Explicit approved pending/evidence retention policy.

Provider variables are `KWS_ORGANIZATION_ID`, `KWS_SCOPE` (`organization` or `product`), `KWS_PRODUCT_ID` only for product scope, `KWS_ENVIRONMENT`, `KWS_CLIENT_ID`, `KWS_API_KEY`, `KWS_SERVICE_ORIGIN`, `KWS_USER_AGENT`, and `KWS_WEBHOOK_SECRETS_JSON` (active rotation secrets). The reviewed exact origin is `https://api.kidswebservices.com`; unreviewed regional hosts are rejected rather than guessed. Test/production credentials and signing secrets must remain separate.

Application variables are `GUARDIAN_VERIFIER_DATABASE_URL`, canonical 32-byte base64url `GUARDIAN_EMAIL_DIGEST_KEY`, and `GUARDIAN_APPROVED_NOTICES_JSON`. Each notice contains `version`, `digest` (SHA256 of its exact UTF-8 `text`), `locale`, `text`, `scope:"own_requests"`, `methodVersion`, and `approvalReference`. No real notice has been approved by this implementation.

`GUARDIAN_PENDING_RETENTION_HOURS`, `GUARDIAN_EVIDENCE_RETENTION_DAYS`, and `GUARDIAN_RETENTION_APPROVAL_REFERENCE` are explicit operator policy. There are no legal-retention defaults. The scheduled operations runtime always performs bounded technical expiry; terminal staged/evidence purge occurs only under supplied policy. It never calls KWS or deletes provider accounts. See [operations runbook](OPERATIONS.md).

## Wire entry points

- Public `GET /v1/guardian/availability?language=en|es` supplies availability only.
- Adult `GET /v1/households/{h}/guardian/notice?language=...`, enrollment collection/detail and verification/consent/invitation/confirm/cancel actions implement the shared contract.
- Browser `POST /v1/child-invitations/auth/start` requires the current BFF challenge cookie, exact configured Origin and CSRF. `GET /v1/child-invitations/session` is the authoritative invitation-bound admission on reload, independent of generic sign-in status.
- Native `POST /v1/child-invitations/native-auth/start` precedes direct provider OTP verification; bearer `.../admit` binds its retained challenge to the exact freshly authenticated child session. Neither app endpoint returns provider tokens.
- Claim/status/finish remain separate authenticated child routes. Browser finish then uses the existing `GET /v1/session` bootstrap/replay-window/CSRF response and `/v1/auth/refresh` provider-session refresh.
- KWS callback is `POST /v1/guardian/providers/kws/webhook` with the official `x-kws-signature` and original bounded UTF-8 bytes.

## Evidence and remaining gates

`npm --prefix service run test:guardian` uses the bundled Node 22 runtime and a new disposable local `/tmp:55432` database, freezes migrations 001–021, supplies separate application/verifier/worker logins, and destroys its fixture database afterward. It does not send real email. Focused tests exercise real PostgreSQL/HTTP, KWS protocol fixtures, native/BFF onboarding, role/tenant/private projection boundaries, retries, expiry/revocation/reconsent, real erasure worker behavior, scheduled operations and deterministic erasure/finalization and browser/household lock races. Broader adult-BFF/request/runtime-privacy and dedicated operations regressions also ran locally. Exact manifests/results belong to the final evidence snapshot; source changes require their own rerun.

Official protocol references are recorded in [KWS-CONTRACT-REFERENCES.md](KWS-CONTRACT-REFERENCES.md). Live provider delivery/verification, an operator-approved notice and method, actual retention policy, SMTP configuration, deployed callback/worker roles and device/client acceptance remain separate release gates. Preparation and fixture proofs do not certify those external conditions.
