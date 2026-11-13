# Staging update through migration 048 — preparation

The candidate adds shared food quantities and source tracking, protected meal
changes and Undo, confirmed retailer amendments, request-acceptance Undo, and
current/historical Records exports. Production runtime tracking is enabled so the
current native client can actually use these existing routes.

Service/web source reviewed: `c92b66237a7da9c53da7d71bea7c244d7f3cfa64`.
Later ignore-file changes exclude local Supabase CLI metadata from deployment and
Git. The existing service/web source passed the hosted backend batch before the
runtime activation correction; that correction reproduced the original404 and
passes21focused runtime/privacy/tracking checks. Full combined CI is still pending.

## Verified preparation

- Existing CLI access confirms Room in the Cart Staging is healthy. All41live
  migration checksums match source. Six public API/auth smoke checks pass.
- The public alias still points to ready deployment
  `dpl_F2S6YE9JQ7rhoYWr67wbZHDJo9v2` (041).
- A fresh encrypted041backup completed, reopened through the login Keychain and
  passed file-hash verification. Secrets and database contents remain private.
- Two actual Auth/public/ritc restores passed. Migrations042–048 applied only to
  the second clone. All129original non-registry tables retained their data;
  original shop columns and all41registry timestamps/checksums were preserved.
- The upgraded clone has147tables, including17newtables. Both historical
  backfills match the expected sets. This live snapshot has no rows eligible for
  those two backfills; populated cases remain covered by existing integration
  tests. New shop defaults, RLS and unscoped runtime access were checked.
- The untouched baseline stayed byte-identical. Both clusters stopped; both
  encrypted images reopened successfully and are detached.
- Vercel dry inspection selects211tracked regular files after excluding local
  CLI metadata. No upload or deployment has occurred.

Private execution logs and original results remain under
`.build/StagingBackup048Nov10` and `.build/Staging048Nov10`. Reuse them; do not
repeat this rehearsal for unrelated UI-test changes.

## Rollout sequence still to prepare and approve

1. Bind the final service/web upload to its reviewed commit and prepare the
   existing maintenance mode for both application and worker entry points.
2. Recheck protected old deployment URLs and current aliases, then stop writes
   for the migration/candidate switch. Account for in-flight requests and workers.
3. Run the existing checksum/advisory-lock migration runner through048, then
   verify the hosted registry before promoting the compatible service/web build.
4. Verify protected deployment and public alias health/auth/web behavior, then
   exercise authenticated current-client paths when the owner email setup permits.

After new-state writes, the041service is not a safe rollback: it lacks the new
tracking guards. Keep compatible maintenance available and repair forward.
Restoring the old database over later writes or deletions requires reconciliation.
The backup proves the selected app/Auth restore, not managed Storage/Vault or
external-provider restoration.

No hosted048migration or deployment is approved or performed yet. Guardian
verification activation, provider deletion, SMTP and Apple distribution remain
separate; this preparation does not enable them.
