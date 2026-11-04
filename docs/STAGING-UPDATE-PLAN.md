# Next staging update

Preparation only. The candidate is not pinned or authorized for deployment yet. Do not execute this plan against hosted services until the source, migrations and owner review below are complete.

## Exact target

- Supabase project `uwjxrotnocxxomqdetzk`, Room in the Cart Staging, organization `ybzztipzreurtjtjhmbo`.
- Vercel project `prj_MsdHyy06CKCuFeAvoOCpnJRQ1vGa`, `room-in-the-cart-staging`, team `team_zkjaW5rtwPK9URZDeSoybwXB`.
- Existing endpoint: `https://room-in-the-cart-staging.vercel.app`.

The last verified hosted catalog had 30 application tables through migration 008. The November 4 connector check denied read access, so recheck the registry before preparing a deployment. Local source contains 001–029, including the private journal observer, worker recovery, guardian and device enrollment fencing, deletion runtime binding, source rollover and chained quarantine replay. The current source passed 178 local application and wire tests and 13 observer tests. A separate 14-case run covers the independent authority, quarantine restore, worker capacity, runtime boundaries, competing writers, source rollover and chained quarantine replay. [Current local evidence](evidence/b11/privacy-window-20261104/validation.json)

The [native scoped evidence](evidence/native/integrated-local-20261103/evidence.json) preserves separate518/518 and526/526 model runs and original mixed UI results. Later dedicated Free-batch, S24two, S23 functional/post-caption and S21 English/Spanish scopes pass independently. [Current polished build proof](evidence/native/current-build-20261103/polish/build-proof.json) pins470-input production source `36479321a5cadd46a6226c553d3e6946958e04b822dbf7aff73b2457a4f6c0bc`: unsigned arm64 Release and ordinary Debug compile/metadata checks pass, including the privacy-purpose correction, with22durable files preserved in the ordinary preview replacement. Native source/proof checkpoint is `b23a23a`. These results do not establish one all-green UI run, signed distribution or live provider operation. The durable client, private observer and HTTPS authority compose in a local test. Hosted authority and observer provisioning remain open. See the [current acceptance map](CURRENT-ACCEPTANCE.md). Never apply a draft file or change an applied checksum. The existing Doorframe site/project is outside this update.

## Candidate preparation

1. Pin the final source revision, dependency lockfiles, migration checksums and immutable build artifacts. Run the current native/client, service/PostgreSQL, operations and browser checks required by the actual changes. Record the scope of older passing screen evidence separately. Guardian proof, child onboarding admission, consent, pairing, revocation and erasure need real local HTTP/database coverage.
2. Verify the existing hosted registry against unchanged migrations 001–008 with the migration administrator. Preserve a private backup and schema/privilege inventory before mutation; keep credentials and database contents out of Git, chat and public evidence. Confirm the backup's actual scope and restore procedure. Old backups without the future external journal cannot be described as safe pre-erasure recovery.
3. Prepare the reviewed additive migrations in order, each transaction/checksum recorded with the existing migration runner. Application runtime credentials never become migration credentials. Verify RLS, role privileges, functions and isolation after application.
4. Prepare separate least-privilege worker and guardian-verifier logins. The worker must not inherit application access or own schema/database/tables. The verifier receives only its reviewed verification functions. Keep role passwords in protected server configuration, never app/web bundles, command arguments or evidence output.
5. Build the same service and web source for the dedicated staging project. Preserve the previous deployment identifier for application rollback. If a migration cannot safely reverse, rollback means the previous compatible application plus disabled affected network paths; it does not mean dropping new data or inventing a down migration.

## Runtime configuration boundaries

The operations function uses `WORKER_DATABASE_URL`, verified TLS and a distinct `CRON_SECRET`; it performs bounded housekeeping and aggregate monitoring. Its prepared daily schedule is slow reconciliation, with no exact-time guarantee. Keep both deletion switches off for staging until the hosted gates are reviewed. The local rehearsal used a separate HTTPS authority and a simulated provider. Before activation, verify hosted backup and restore, credential isolation, issuer binding, alert delivery and quarantine replay on a verified hosted backup. Deploy matching client and authority revisions so both recognize definite writer refusals. [Deletion runtime configuration](../service/API-PRIVACY.md#runtime-configuration)

The standalone journal authority and HTTPS client now pass the local two-cluster drill. A staging activation proposal must identify its separately operated database, backup and restore domain, key custody and operator recovery procedure. Keep the authority logins and signing key on the authority host. [Independent authority runbook](../service/journal-authority/README.md)

KWS organization terms were accepted personally by the owner. The Test portal's observed service origin is `https://api.kidswebservices.com`. The agent has not published Test configuration, copied API keys or sent verification email. Before any secret provisioning, identify the exact KWS environment and server destination. Keep client credentials, webhook secrets and any verifier credentials exclusively in the staging server's protected configuration.

Child enrollment must remain unavailable until the same readiness predicate covers every route: real configured provider, approved bilingual notices/method, covered child identity onboarding, current consent and verification, and the required sign-in/BFF delivery configuration. A feature flag, a KWS 202 response, a receipt or a test fixture cannot establish those facts. SMTP setup remains explicitly deferred by the owner. Do not enable it as a side effect of this update.

The owner-supplied business and support address are Venture House Group LLC and hello@roominthecart.com. Public help/privacy/terms/support source currently contains draft-review boundaries. Publishing those staging pages is separate from approving them as final production policies. Never configure a native policy URL as operational before checking the published route.

## Final owner decision and hosted verification

Once the candidate is reviewable, present its revision, actual migration list, backup/rollback details, affected data/functions, proposed secret destinations and any KWS Test publication as one concrete decision. Earlier approval for local backend installation does not authorize hosted migration or provider deletion. No paid plan, unrelated project change, production distribution or provider deletion is part of this plan.

After an authorized update, verify public health/auth/origin boundaries, exact migration checksums and worker-role isolation, protected scheduler access and observed execution, published public routes, and authenticated staging journeys using fictional review accounts. Preserve exact deployment/build identities and rollback results. Do not replace these with local fixtures or a successful HTTP health response.
