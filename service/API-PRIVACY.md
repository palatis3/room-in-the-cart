# Account lifecycle and operational jobs

The application and operations worker load deletion configuration independently. Enable them only after the source is migrated through 027, the independent journal is provisioned and the deployment owner has approved the retention policy and restore drill.

## Authentication and scope

A valid JWT signature, fixed issuer, signed subject and live exact provider session are required. Deletion and household exit additionally require a signed `amr` authentication event (`otp`, `password`, `oauth` or `sso/saml`) within five minutes. JWT `iat`, token refresh and user metadata do not establish reauthentication. A legacy scope cookie alone has no recent-auth proof. Browser mutations retain exact-origin and CSRF enforcement. Selected helper credentials cannot call account lifecycle routes; authenticate an unrestricted account context first.

Deletion takes an exclusive identity lock, checks all affected households under ordered locks, then commits the identity erasure marker and access revocations atomically. Normal authorization takes a shared identity lock; it fails with `account_action_pending` rather than waiting while holding a household lock. Creation, redemption, enrollment, browser authentication and refresh cannot revive a blocked identity. No provider refresh is attempted after a failed exact-session preflight.

## HTTP contracts

`GET /v1/privacy/deletion-preview` returns:

```ts
{
  adult: boolean,
  deletionAvailable: boolean,
  verifiedBackupRetentionDays: number|null,
  reauthenticationRequired: boolean,
  subscriptionManagementURL: 'https://apps.apple.com/account/subscriptions/',
  subscriptionCancelledByDeletion: false,
  households: [{
    householdId: UUID, memberId: UUID, label: string,
    state: 'active'|'revoked', organizer: boolean,
    otherAdults: [{memberId: UUID, alias: string, organizer: boolean}],
    activeShops: [{shopId: UUID, revision: number, authorityEpoch: number, phase: string}],
    soleGuardianChildren: [{memberId: UUID, alias: string}]
  }]
}
```

`POST /v1/privacy/deletions` accepts:

```ts
{
  clientKey: UUID,
  statusToken: string, // 32 cryptographically random bytes, base64url (43 chars)
  confirm: true,
  households: [{
    householdId: UUID,
    organizer: 'none'|'transfer'|'archive',
    organizerMemberId?: UUID, // an existing active adult, for transfer
    shops: [{shopId: UUID, revision: number, authorityEpoch: number,
             action: 'close'|'transfer', memberId?: UUID}],
    eraseChildProfiles: UUID[]
  }]
}
```

The client creates and retains `clientKey` and `statusToken` **before** sending. Only the token hash is stored. A lost response is recovered with `GET /v1/privacy/jobs/{clientKey}` and `X-Deletion-Token: <statusToken>`, even after the identity and cookies have been revoked. Do not put this token in URLs, analytics or logs. This capability can only read its own minimal job status. Unknown/wrong/expired receipts return 404. It cannot authorize other requests or cancel deletion.

Acceptance returns HTTP 202 only after its SQL-resolved intent is durably journaled before commit and the committed event has a durable external checkpoint acknowledgement. The response is the same safe status DTO as the status route:

```ts
{jobId: UUID, status: 'pending'|'complete', appDataErased: boolean,
 providerAccountDeleted: boolean, completedAt: ISO8601|null,
 receiptExpiresAt: ISO8601}
```

`complete` means the live application erasure transaction finished and the configured provider's account lookup confirmed absence. It is not a claim that old backups, third-party static copies or the user's on-device private Records have been erased. The client must explain these separate scopes and the configured backup horizon. Pending receipts remain usable while the job is unfinished; their configured lifetime restarts at completion. Repeating the exact database acceptance key is idempotent; the HTTP recovery path after revocation is the status capability, not reauthentication as the erased subject.

All of the subject's memberships, including previously revoked memberships, are included. `households` can omit memberships without a responsibility requiring an explicit choice. Foreign household or child IDs are rejected. A sole organizer must explicitly transfer to an existing active adult or archive their organizer responsibility. Active shops need their current revision/authority epoch and an explicit transfer or close choice. Closing the app's shop does **not** cancel a retailer order. A sole verified guardian must explicitly erase the listed child profile in that household; no new guardian is inferred or verified. This does not delete a child's independent provider identity or profile in another household. Child account self-deletion and general guardian-requested deletion remain outside this adult-account route; child network enrollment remains disabled.

`POST /v1/households/{householdId}/exit` accepts `{clientKey,confirm:true,disposition:<one household choice above>}`. It returns `{householdId,left:true,accountDeleted:false}`. It requires recent authentication, closes that membership/grants/windows and preserves the service identity, other memberships and records. Same-identity exact-key retries return the same result without needing the revoked device. It does not erase records or child profiles; `eraseChildProfiles` must be empty, and unresolved sole guardianship returns `guardian_disposition_required`.

Errors include `reauthentication_required` (401), `deletion_unavailable` (503), `organizer_disposition_required`, `shop_disposition_stale`, `guardian_disposition_required` (409), and `unavailable` (404). Missing privileged provider, numeric retention policy or trusted journal port rejects deletion before any job or access mutation. An outage after acceptance leaves a durable pending job, never a false completion.

## Runtime configuration

`PRIVACY_DELETION_ACCEPTANCE=true` enables new requests in the application runtime. `PRIVACY_DELETION_PROCESSING=true` enables claim and erasure work in the [operations runtime](OPERATIONS.md). Both default to disabled. The application can still show responsibilities and handle household exit. The worker can still retire completed receipts on their persisted schedule.

Use `SUPABASE_URL` for the fixed HTTPS provider origin and inject `PRIVACY_SUPABASE_ADMIN_KEY` through the server's secret manager. The application verifier must use that origin's `/auth/v1` issuer and `/auth/v1/.well-known/jwks.json` endpoint with the configured audience. The worker verifies the issuer on every claimed job before erasing data or calling the provider. The adapter validates the returned subject, requests hard deletion and confirms absence by lookup. A linked Apple identity requires successful upstream token revocation. The environment composition currently supports accounts without an Apple identity and refuses linked Apple accounts.

Inject `PRIVACY_DELETION_JSON` into each enabled runtime. Its strict version 1 fields are:

| Field | Value |
| --- | --- |
| `version` | Number `1` |
| `pins` | Full registered durable journal scope, including writer and authority fingerprints |
| `writerPrivateKey` | Writer's PKCS#8 Ed25519 private PEM |
| `authorityPublicKey` | Independent authority's SPKI Ed25519 public PEM |
| `authority` | `origin`, `writerToken`, optional `ca` PEM |
| `observer` | `databaseOid`, `observerRoleOid`, `ownerRole`, `ownerRoleOid` and fixed `connection` with `host`, `port`, `database`, `user`, optional `password` and pinned `tls` with `ca` and `servername` |
| `retentionPolicy` | Approved integer `receiptRetentionDays`, `erasureMarkerRetentionDays` and `verifiedBackupRetentionDays` |
| `retentionApprovalReference`, `restoreApprovalReference` | References to the owner's actual approvals |

Use `privacyDeploymentConfigurationId` from the built service to derive `pins.configurationId` from the issuer, validated policy and both approval references. Register that same ID in the source and checkpoint. The application and worker verify their own source binding against the dedicated observer and the registered pins before starting deletion work. The authority signs the aggregate capacity response against a fresh nonce. A mismatched source, unreachable authority or unresolved journal claim keeps deletion unavailable. Marker retention covers the verified backup and receipt horizons. Deployment custody keeps the authority signing key and database logins separate from these runtimes. See the [independent journal runbook](journal-authority/README.md).

Both class-level `run` calls cap batch size at 100 and requested runtime at 25 seconds. Claims are durable 30-second leases, with bounded exponential retry delays up to one hour and content-free error categories. Provider requests time out after five seconds; an in-flight request can finish after the requested loop budget. Erasure calls additionally use a ten-second PostgreSQL statement timeout and two-second lock timeout. Each privacy lease processes at most 100 target profiles. Oversized profiles that repeatedly hit the statement timeout remain pending and require operational investigation; they are not marked erased.

Auth maintenance clears expired temporary email ciphertext, expired challenge rows and rate buckets older than 24 hours in bounded batches. Expired authenticated browser states are locally revoked and queued for provider logout. Revoked credentials are never refreshed. A provider outage retains encrypted credentials only while a still-live access token can be retried. Confirmed absent provider sessions finish successfully; expired access with an existing provider session is reported as `logoutExpiredUnconfirmed`, clears unusable ciphertext and never claims provider revocation. The caller must record the aggregate counters for monitoring.

Privacy maintenance removes own request text/quantity/clarification, disposable receipts/previews, own helper proposals/view payloads, consent/proof links, identity aliases and bindings, browser credentials, and purchaser billing payloads. It retains de-identified structural IDs needed by other members' references. Shopper-adopted personal source labels are redacted from basket/snapshot projections while other authors' private request text remains. Household labels created by the erased account become a generic label. Shared grants/seats are revoked; another member's Free records remain. Deleting an account does not cancel App Store renewal.

A retired Apple original transaction is retained only as SHA-256 of canonical environment plus original ID, without signed payload, purchaser or household fields. Billing checks it **after** verified Apple resolution and before binding, under a shared transaction-key serialization boundary with erasure. It is not automatically purged by generic deletion retention: no safe Apple renewal/replay horizon has yet been approved. It cannot grant access or consent.

The [local privacy journal contract](PRIVACY-JOURNAL.md) describes the required port, source progress barriers, owner-only exact-preimage restore plans, atomic leased receipts and quarantine gate. Replay never marks a provider account deleted or a restored public status complete.

## Remaining release evidence

The runtime test exercises an isolated source and authority using a simulated provider. Hosted provider deletion, Apple-token revocation, scheduled execution and a hosted backup and restore drill still require evidence. Restore tooling must preserve the deletion marker/target journal outside a restored database and reapply erasure before serving it; restoring a pre-deletion database alone would omit the marker. The backup owner must test that workflow and its maximum horizon before enabling deletion. Provider/log retention and retired-purchase marker retirement remain policy decisions; this code does not invent legal retention exceptions. Native and web account-settings integration must use these exact contracts and show the separate subscription/local-records/backup scopes.

Primary references checked during implementation: [Apple account deletion](https://developer.apple.com/help/app-review/guideline-reference/5-1-1-account-deletion), [Supabase admin deletion](https://supabase.com/docs/reference/javascript/auth-admin-deleteuser), [Supabase admin HTTP implementation](https://github.com/supabase/auth-js/blob/master/src/GoTrueAdminApi.ts), [signed JWT fields](https://supabase.com/docs/guides/auth/jwt-fields).

## Local verification commands

Run `npm run test:integration` against a disposable application database using `TEST_DATABASE_URL` and `TEST_ADMIN_DATABASE_URL`. The operations tests intentionally use a separate disposable database because expiry jobs can touch every due authentication row: set `OPERATIONS_TEST_DATABASE_URL` and `OPERATIONS_TEST_ADMIN_DATABASE_URL`, then run `node scripts/test-operations.mjs` after the TypeScript build. Both fixtures require a migration administrator and a non-owner application login; the test setup provisions only the local non-owner `ritc_test_worker` role. No production credentials belong in test logs.
