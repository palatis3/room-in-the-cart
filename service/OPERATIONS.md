# Scheduled housekeeping and operator commands

The application and operations function use different PostgreSQL logins and pools. `api/maintenance.js` composes the operations runtime without importing the application runtime. Its current responsibilities are bounded browser-auth expiry/logout retries, expired temporary email and rate-bucket cleanup, completed privacy-receipt cleanup, aggregate monitoring, and bounded guardian setup expiry/policy-gated purge.

With the default settings, privacy maintenance retires completed receipts at their persisted dates. Processing pending deletions requires the explicit worker flag and verified [privacy runtime configuration](API-PRIVACY.md#runtime-configuration). Review the provider, approved numeric horizons and independent restore drill before enabling it.

## Suspend public service before recovery

Set `SERVICE_MAINTENANCE=true` on a reviewed deployment to reject every application and HTTP operations request with 503, `Cache-Control: no-store` and `Retry-After: 60`. This includes health, bearer/cookie sessions, direct API function routes and the scheduled maintenance endpoint. The gate runs before pool, identity, provider, worker or request-body processing. Only absence or the exact value `false` enables normal service; any other value fails closed. Static Help, privacy and support pages may remain available. Migration and recovery/operations CLI commands remain intentional manual paths and are not suspended by this HTTP gate.

The setting is captured when a function runtime starts. On Vercel, an environment edit requires a new deployment; it does not change earlier immutable deployments. Prepare and verify a maintenance candidate before enabling migration 042 features. Verify direct deployment URLs, alias targets and existing deployment protection separately. A gate in the new deployment cannot retroactively suspend an older URL. Do not promote application 041 after amendment use: its successful delivery response omits amended line identities. A write-only pause is insufficient because those reads are incomplete.

During recovery, retain schema 042 and its erasure fences, deny public reads and writes, and repair forward. A database restore requires reconciliation of later writes and replay of the separately retained deletion journal before reopening access. Privacy acceptance/processing flags affect deletion jobs only and are not a whole-service outage switch. An intentional full worker freeze must also avoid operator CLI invocations; do not discard pending jobs or leases.

## Credentials and deployment configuration

Apply the reviewed migrations with the migration administrator. Deletion processing requires migration 028 and a registered source and authority. Provision a dedicated login that inherits `ritc_worker`; it must not inherit `ritc_app`, own the database/schema/tables, be superuser, or bypass RLS. Do not grant it raw table privileges. Store its URL separately as `WORKER_DATABASE_URL`, and keep the application login in `DATABASE_URL`. The runtime rejects a matching application username and independently verifies the connected role.

Remote worker connections verify the TLS certificate and hostname. Supply `WORKER_DATABASE_CA_PEM` only when the deployment needs a private CA. PostgreSQL URL query options cannot override TLS, host, credentials, startup role, or timeouts. An explicit local loopback URL may use `?host=%2Ftmp` for a disposable Unix-socket fixture; that socket exception is rejected in Vercel. An empty URL password does not inherit `PGPASSWORD`.

The scheduler requires a secret-manager generated `CRON_SECRET` containing 32–256 URL-safe ASCII characters. The HTTP function accepts exactly `Authorization: Bearer <CRON_SECRET>` using a constant-time digest comparison. It never accepts an application user JWT or cookie. Missing/invalid scheduler configuration returns 503; missing/wrong/duplicate authorization returns 401. Authentication happens before pool construction. The response is always `no-store`. Only exact `/internal/maintenance` and `/api/maintenance` paths are accepted; queries, other methods, and GET bodies are rejected. The direct API path uses the same authentication.

Logout additionally uses the existing `SUPABASE_URL`, `SUPABASE_PUBLISHABLE_KEY`, and `BFF_TOKEN_ENCRYPTION_KEY`. Public Supabase metadata by itself leaves provider logout unconfigured and allows basic housekeeping, including when email login is disabled. Supplying the encryption key requires all provider fields and a canonical base64 32-byte key. Only access-token logout is called; revoked credentials are never refreshed. A missing provider/key schedules an honest retry while access is valid. Expired access with a still-present provider session is `logoutExpiredUnconfirmed`, clears unusable ciphertext, and never claims provider revocation.

The source schedule is one run daily at `0 8 * * *` UTC, targeting `/internal/maintenance`, rewritten to `/api/maintenance`, with a separate function `maxDuration: 60`. Vercel sends the configured cron secret as a Bearer header. Hobby scheduling is once daily with an hourly execution window; this is slow reconciliation, with no prompt-retry or exact-start assurance. Durable retry timestamps do not cause an invocation. An operator can run another bounded batch when necessary; this source does not upgrade a plan or create a paid scheduler. See [Vercel cron authentication](https://vercel.com/docs/cron-jobs/manage-cron-jobs) and [cron scheduling limits](https://vercel.com/docs/cron-jobs/usage-and-pricing).

## Bounds and interrupted work

Each invocation uses a fixed batch of 25, a 10-second auth-loop budget, an 8-second deletion-loop budget when enabled, and an aggregate 25-second abort deadline checked before claims, further calls, and result commits. In-flight operations may finish after that deadline: provider requests time out after five seconds; PostgreSQL statements after two seconds, lock waits after 500 ms, client query waits and connections after three seconds. The 60-second function limit leaves room to return a failure and close out an in-flight bounded operation. A deadline or storage error returns 503 and emits a fixed failure category, never a false completion. A provider outcome interrupted before the completion commit retains its 30-second lease and encrypted credentials for a later retry. Database claims and completion checks protect duplicate invocations; the in-process runtime also rejects overlapping runs.

## Operator CLI

Use Node 22.23.5 and install/build the service first. Load credentials from the deployment secret manager into the process environment; do not paste them into command history, an issue, or this document.

```sh
npm --prefix service ci --ignore-scripts
npm --prefix service run build
npm --prefix service run operations -- status
npm --prefix service run operations -- run
```

`status` checks the worker role and emits aggregate counters without housekeeping. `run` performs one bounded batch and emits the same counters. Both need `WORKER_DATABASE_URL`; the CLI authenticates through the dedicated database login and does not need the HTTP cron secret. Exit code 0 means the bounded invocation completed, 1 means it failed, and 2 means invalid arguments. Pending work still appears in a successful result and can require operator attention.

## Monitoring and recovery

Retain only the emitted `operations_result`/`operations_failed` objects in the operations log sink. They contain counters, duration, fixed mode/configuration flags, and attention state; never session/subject/household IDs, credentials, grocery text, provider response bodies, or exception messages. `ritc.operations_health()` is worker-only and returns aggregate counts. Application users and public callers cannot read these counters.

Review `attentionRequired`, `authDue`, `authRetryPending`, per-run `logoutExpiredUnconfirmed`, `leaseLost`, and `privacyPending`. The `privacyJournal` object reports `disabled`, `configuration_required`, `source_unavailable`, `authority_unavailable`, `blocked` or `ready`. When a signed capacity observation is available, it includes used and reserved record/byte counts, authority mode, uncertainty and `nearLimit`. The runtime sets `nearLimit` when either used plus reserved total reaches 80% of its limit. A near-limit warning, failed readiness, capacity deferral, `journalDeferred` or mismatched issuer sets `attentionRequired`. `journalDeferred` means a competing writer prevented an observation or reservation during the batch. The worker stops claiming new jobs in that batch and retries on a later invocation. An unconfirmed expired logout requires provider-side session investigation through the authorized provider tools; do not report it as revoked. Pending auth retries after an outage can be processed by another CLI batch when their durable due time arrives. If batches remain full or overdue counts do not fall, investigate capacity and the scheduler before making a completion claim.

The deployment operator must check that a successful content-free event appears after each expected daily execution window, and investigate a missing event or failure. Repository source does not establish that a cron has executed, that a log-retention policy exists, or that an external alert has been configured. Record that separate deployed evidence during the authorized rollout.

Pause new requests with `PRIVACY_DELETION_ACCEPTANCE=false`. Pause destructive worker steps separately with `PRIVACY_DELETION_PROCESSING=false`. Preserve pending work and durable leases during rollback. A blocked journal requires the owner recovery procedure and replacement of any writer instance that recorded an uncertain outcome. Before restoring any database, replay the separately retained deletion journal before serving household data; migration 020 changes aggregate visibility only and does not replace the restore gate.

## Local evidence

The dedicated operations suite deliberately runs in its own disposable database because housekeeping can affect all due auth rows. Set `OPERATIONS_TEST_DATABASE_URL` to a non-owner application login and `OPERATIONS_TEST_ADMIN_DATABASE_URL` to that disposable database's administrator, then run:

```sh
npm --prefix service run test:operations
```

The runner applies migrations and executes the existing auth lease/retry tests plus actual HTTP/worker-pool/PostgreSQL tests serially. It tests denied HTTP access before database setup, wrong roles, fixed request scope, auth expiry, provider outage/retry, expired/unconfirmed outcomes, abandoned/interrupted leases, privacy cleanup-only behavior, aggregate permissions, and the runnable CLI. Provider requests use fictional bounded HTTP fixtures, not a live provider account. Production scheduler execution, live-provider revocation, backup retention, restore replay, alert delivery, and policy approval remain separate release evidence.

## Guardian setup housekeeping

Migration 021 adds `guardian_housekeeping`, executed in the actual scheduled/CLI `run` path using the same batch of 25 and aggregate 25-second deadline. Its SQL skips locked households rather than waiting across active work. Technical expiry retires invitation, pairing and BFF challenge authority immediately; no provider call occurs. `status` remains read-only.

Pending and withdrawn-evidence deletion requires all of `GUARDIAN_PENDING_RETENTION_HOURS`, `GUARDIAN_EVIDENCE_RETENTION_DAYS` and `GUARDIAN_RETENTION_APPROVAL_REFERENCE`. There are no default legal horizons. Without the approved numeric policy, the worker expires access but preserves evidence. Supply the same policy to the application readiness composition and worker. Active consent is excluded from purge; independent provider accounts and lifetime-bound negative child classification are untouched. Per-run `guardian` counters contain only `expired`, `purged` and `retentionConfigured`. KWS verification runs through its dedicated integration.
