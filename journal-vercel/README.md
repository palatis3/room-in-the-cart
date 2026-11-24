# Deletion journal on Vercel

This Vercel Node 22 function hosts the [independent journal authority](../service/journal-authority/README.md). It serves the existing `POST /v1/journal` protocol. The application and maintenance worker reach it over HTTPS using their scoped writer token. The authority uses two least-privilege PostgreSQL logins and its own signing key. PostgreSQL retains the journal, claims, and checkpoints across process and deployment restarts.

## Project settings

Use a dedicated Vercel project with `journal-vercel` as its Root Directory. Enable **Include source files outside of the Root Directory in the Build Step** and select the function region nearest the dedicated journal database. From the linked repository root, build with `NODEJS_HELPERS=0 vercel build --standalone`. Check that the generated `.vc-config.json` has `shouldAddHelpers: false` and that the function bundle includes `service/scripts/journal-authority-config.mjs` and the compiled authority. Deploy the verified output with `vercel deploy --prebuilt`. The tested ordinary hosted build omitted shared service files. The handler authenticates before consuming the raw request stream and requires the original content length. [Vercel monorepo settings](https://vercel.com/docs/monorepos/monorepo-faq) · [Node.js helpers](https://vercel.com/docs/functions/runtimes/node-js/advanced-node-configuration)

Set `JOURNAL_AUTHORITY_JSON` as a sensitive environment variable on the journal project. Use the [authority configuration](../service/journal-authority/README.md#provisioning-inputs) fields through `recordDatabase`, omitting `listen` and `tls`. In the hosted environment both database configurations use a password and a CA bundle for hostname-verified PostgreSQL TLS. Keep owner and recovery credentials in separate operator custody. Give the app and worker the journal's stable HTTPS origin, its public signing key, and the scoped bearer token through the existing app configuration. For a protected deployment, configure the app and worker with [Vercel Trusted Sources](../service/API-PRIVACY.md#runtime-configuration). Use separate credentials and data for pre-release environments.

## Database and recovery

Use a Supabase project dedicated to the journal. Apply the authority SQL files in `service/journal-authority` and register the lineage there. Leave `ritc_checkpoint` and `ritc_records` outside the exposed Data API schemas. For Vercel, the Supavisor transaction endpoint uses port `6543` and login `[ROLE].[PROJECT-REF]`. Copy the exact hostname and trusted CA from Supabase. The handler uses one bounded client pool per database role in each instance, unnamed SQL statements, and transaction-local durability and timeout settings. The hosted role and TLS checks still need to run on the provisioned project. [Supabase connection modes](https://supabase.com/docs/guides/database/connecting-to-postgres) · [Supabase TLS verification](https://supabase.com/docs/guides/platform/ssl-enforcement)

The app's journal events use the PostgreSQL source's 1 MiB per-event limit, including adult and guardian acceptances and worker progress. Their signed and base64-encoded request and response bodies fit the Vercel 4.5 MB limit. If a different source can emit bigger records, recheck the body limit before using this host. Keep operational archive export and restore on the PostgreSQL recovery tools so the 32 MiB journal window never crosses a Vercel response. [Vercel payload limits](https://vercel.com/docs/functions/limitations)

Before enabling deletion, verify the two runtime roles, trusted TLS, cold and concurrent invocations, and normal deletion plus worker reconciliation against a nonproduction source. Exercise a stale application backup with the hosted independent journal and verify alert delivery. Choose and test the separate journal backup and recovery policy against the approved recovery point. A daily backup can omit nearly a day of acknowledged writes, and Supabase describes its 7-day PITR add-on as having a worst-case two-minute recovery point. [Supabase backup behavior](https://supabase.com/docs/guides/platform/backups)

## Local verification

Install the dependencies in `service` and `journal-vercel`, then build `service`. Run the full PostgreSQL authority suite with the Vercel entry point and an SSL-capable local PostgreSQL installation:

```sh
cd service
TEST_POSTGRES_BIN=/path/to/postgresql/bin \
TEST_VERCEL_JOURNAL_AUTHORITY=1 \
TEST_VERCEL_JOURNAL_AUTHORITY_TLS=1 \
node --test tests/privacy-journal-pg-authority.postgres.mjs
```

Set `JOURNAL_AUTHORITY_TEST_ENTRY` to the generated function entry's absolute `file:` URL to test the packaged bundle with the same suite.
