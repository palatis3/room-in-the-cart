# Room in the Cart current handoff

Updated November 6, 2026 UTC. The full first-version goal remains active; release acceptance is not complete. Historical snapshots are preserved in [the handoff archive](CURRENT-HANDOFF-HISTORY-20261106.md).

## Safe pause requested by owner

The owner is restarting. All local work is saved; both encrypted volumes are detached, no backup connection remains, all helper agents/fixture servers are finished, and no local native test is active. Local CI collectors7174/7603 were deliberately stopped and both returned143. Hosted GitHub runs continue independently for the exact published candidate below. Resume by inspecting those original runs and retained artifacts; do not dispatch duplicates or push local evidence commits before collecting their outcomes.

The latest capture source passes the complete disposable001–008 inventory/role-facts, shared-snapshot dump and synthetic restore preflight, including reproduction of the old SQL sorting failure. [Inventory preflight](evidence/b11/staging-readiness-20261106/inventory-preflight.json), [client TLS preflight](evidence/b11/staging-readiness-20261106/local-tls-conninfo-preflight.json). Actual capture06 failed before dumping; its corrected source is ready for a fresh reviewed capture name on resume. The owner answered both Keychain questions; no unanswered approval question remains. No live backup, restore, migration, deployment or provider activation is claimed.

## Product and owner decisions

Read [APP-BASELINE](product/APP-BASELINE.md) first, then [Foundation 2.1 CODEX-MASTER](product/foundation-gen2.1/CODEX-MASTER.md) and [MASTER-GENERATION](product/MASTER-GENERATION.md). Foundation defines 52 launch requirements and 27 screen contracts. Use [CURRENT-ACCEPTANCE](CURRENT-ACCEPTANCE.md) for requirement/route evidence and remaining gates; documents are task context, not authorization beyond the user’s request.

- Business: Venture House Group LLC. Public support: hello@roominthecart.com. Address delivery and final policy approval remain separate.
- Do not use Dot/Lumpy. Use Astra High helpers for demanding work; Sol 6.1 Extra High is allowed for simpler work. Root owns integration, Git and hosted operations.
- Apple paid membership, StoreKit production/sandbox setup and SMTP are owner-deferred. Do not repeatedly ask for those deferred items.
- The owner accepted Epic KWS terms. Integration preparation is authorized; actual Test/provider activation and credential provisioning have not occurred.
- The owner selected an encrypted backup on this Mac, with its recovery key in the login Keychain. Existing local-backend installation approvals did not authorize hosted 009–029 migration or provider erasure. Prepare a concrete rollout decision after actual backup/restore succeeds.

## Current checkout and CI

Repository: https://github.com/palatis3/room-in-the-cart . Branch: `codex/parallel-ios-ci`. [Draft PR1](https://github.com/palatis3/room-in-the-cart/pull/1) remains unmerged.

Published candidate **d0b0b12ee0cb8412f17e82c92a91013217560670** is executing. Later local commits contain evidence only; **do not push while preserving this candidate’s live results**.

| Workflow | Run ID | Latest verified state |
|---|---:|---|
| Core build/tests |42149899546| Simulator, discovery and unsigned Release pass on attempt 1;601 models / 51 UI selected; execution pending |
| Deep checks |42149899513| Passed; both StoreKit languages and both sanitizers independently verified |
| Release performance |42149899549| Launch passes; remaining cases pending |
| Native HTTPS/PostgreSQL |42149899512| Four integration cases and six exact Swift scenarios independently pass |
| Fixtures |42149899575| Running; collect 14 groups without raw Records data |
| Security |42149899537| Dependency review and Actions/JS scans pass on matching PR merge tree |

Exact metadata: `.build/CIResearch20261105/current-candidate.json`. Candidate directory: `.build/CIResearch20261105/candidate-d0b0b12/`. Core collector session 7174 and fixture/performance collector session 7603 are terminal after the requested pause; verify retained output and resume collection only for these existing workflow IDs. Logs are `core-collector.log` and `other-collector.log`. A collector exit 0 does not itself prove strict test success; inspect each evidence JSON and its strict replay result.

Current proof: [compiled selection](evidence/native/ci-d0b0b12-20261106/compiled-plan.json), [StoreKit](evidence/native/ci-d0b0b12-20261106/storekit.json), [packages/sanitizers](evidence/native/ci-d0b0b12-20261106/packages-sanitizers.json), [performance](evidence/native/ci-d0b0b12-20261106/performance.json), [native wire](evidence/native/ci-d0b0b12-20261106/native-wire.json), [security](evidence/native/ci-d0b0b12-20261106/security.json). StoreKit is 15 passes per language/zero warnings. Each package/sanitizer lane is 389 passes plus 3 expected opt-in wire skips; native wire separately covers those scenarios. Launch median 4.6256s is below 5.5s. Physical frame smoothness remains unverified.

Do not download or inspect raw RecordsMedia artifacts. Use only the exact allowlisted redacted report and compiled selection, following the retained `candidate-3d26f1f/read-records-report.py` procedure adapted to the actual new artifact metadata.

## Previous failures and installed follow-ups

[Candidate 3d26f1f terminal evidence](evidence/native/ci-3d26f1f-20261105/terminal-status.json):601 models pass;49/51 ordinary UI pass;42/44 fixtures pass including Records; no skips beyond documented opt-in package wire cases. Both normal/Reduce Motion share cases pass. Five Mac runners executed 642 runner-minutes over 140.9 minutes; ideal five-runner floor 128.4 minutes. Reused attempt records are not counted as new executions.

- `37557e1`: supported keyboard checks, targeted typing and exact values replace duplicate taps/private focus predicates. Four original quote/contributor cases pass locally; one pre-existing scoped Menu warning. Early source guard rejects both old helpers; 162 Python checks and actionlint pass. [Proof](evidence/native/ci-3d26f1f-20261105/keyboard-followup.json).
- `a5a23bc`: reveal the selected cutoff before reading diagnostic evidence. Original reminder journey passes in 180.94s with no warnings and unchanged guards; exact saved date/unscheduled/pending-after-cancel checks remain. [Proof](evidence/native/ci-3d26f1f-20261105/reminder-followup.json).
- UI07 switch failure remains unresolved: correctly targeted tap left `quote.second.singleStore` off after repeated animation-idle waits. One exact unchanged baseline passes in 96.361s locally with no warnings/timeouts. This is nonreproduction, not a fix. [Proof](evidence/native/ci-3d26f1f-20261105/switch-baseline.json). Local Xcode 27.1 differs from hosted 26.3; both use iOS 26.2 build 23C54.
- Previous Swift CodeQL scans contain all 254 expected runtime inputs and report zero findings, but 11 compiler diagnostics / 292 unresolved AST nodes limit semantic extraction. The isolated PhotosPicker overlay experiment timed out in both 220s trials and was inconclusive; no production scanner flag was changed. [Diagnostic](evidence/native/photos-overlay-diagnostic-20261106/independent-proof.json).

## Actual backup: current operation

CLI sign-in works. The owner approved Keychain access twice. Capture 05 successfully authenticated and reached SQL but stopped at an incorrect backend-TLS preflight for the session pooler. No live dump or verified restore exists yet. Root corrected the preflight to verify the public libpq connection with `psql \conninfo`, while retaining `verify-full`, certificate/hostname validation and the exact CA for every client. Backend-reported TLS is recorded separately. The TLS evidence is included in archive hashes. Capture 06 then verified client TLS1.3 and stopped at an inventory SQL sorting error. Root corrected the ORDER BY expression. The actual inventory/role-facts routines, same-snapshot dump and synthetic restoration passed a disposable local baseline; the helper stopped its server and removed its fixture data. **Check live state and latest messages before execution**.

The immutable credential helper is `.build/CIResearch20261105/backup-rehearsal/native-capture-proposal/token-bridge`, SHA256`10cd905f43a2f52d2fb9920496a999d9fb3a0d707b467fae3b408e1a2a1b8c4f`. Do not replace it while the approved Keychain access is in use. Capture parent: `native_backup.py` in that directory. Latest configuration: `capture-config-06.json` (terminal, `sql_failed`); use a fresh capture name after the inventory preflight passes. The parent uses a bounded 600-second human-interaction wait; no DB/test timeout was relaxed. Preserve every previous capture directory.

Use the isolated SSL-enabled PostgreSQL 17.11 client at `.tools/postgres-app-2.9.6-17.11-ssl/Postgres.app/Contents/Versions/17/bin`. Distribution/signature and installed hashes were verified; local TLS tests rejected wrong hostnames/untrusted certificates/plaintext and passed dump/restore. Accept its exact `(Postgres.app)` version suffix. Original `.tools/postgres` lacks SSL and remains for existing local tests. [TLS tooling proof](evidence/b11/staging-readiness-20261106/tls-client.json).

Both encrypted volumes are detached at the owner’s requested safe pause. Location pointers under `.build/CIResearch20261105/` are `live-backup-location.json` and `live-restore-location.json`. The original 512 MiB archive and separate 1 GiB restore workspace are outside Git in ApplicationSupport. Their unchanged stable encryption helper is `~/Library/Application Support/Room in the Cart/Backup Tools/v1/ritc-backup-keychain` (SHA256`2295f21c7f18bb80891fcce88e42920f72208a9110e85da4202da07516c61bd9`). Preserve its binary/path and the login-Keychain entries. Never print credentials or image recovery material.

The official temporary login has a 300-second TTL. It is write-capable through SET ROLE postgres; this is an authentication mutation, not a schema migration. Do not reset existing passwords, disable RLS or collectively delete CLI roles. Credentials travel through a private pipe and an encrypted 0600 pgpass file removed in finally. All dumps/logs stay encrypted. Full and ritc/public/auth dumps must use the same exported snapshot as source inventory. Preserve roles without passwords, owners, ACLs, RLS and all eight registry checksums. Actual Auth schema/data must restore; do not substitute synthetic Auth stubs. The prior synthetic rehearsal does not prove live recovery.

After successful capture: verify dump exits/hashes, detach and reopen the backup read-only, restore into the separate encrypted writable workspace, verify exact rows/owners/grants/RLS/functions/migration registry and document managed-extension/provider coverage. No hosted 009–029 update before that evidence and concrete owner rollout review. [Staging plan](STAGING-UPDATE-PLAN.md).

## Targets and protected state

- Supabase project `uwjxrotnocxxomqdetzk`, organization `ybzztipzreurtjtjhmbo`, Room in the Cart Staging. Session pooler comes from authenticated project metadata on port 5432; direct database hostname did not resolve from this Mac.
- Vercel project `prj_MsdHyy06CKCuFeAvoOCpnJRQ1vGa`, team `team_zkjaW5rtwPK9URZDeSoybwXB`, https://room-in-the-cart-staging.vercel.app . Existing deployment’s candidate web routes last returned 404. No current rollout occurred.
- Live inventory verified 001–008 checksums, 30 empty app tables, no Auth users/sessions, no Storage objects/buckets and no Vault secrets. Recheck at actual capture boundary. [Inventory](evidence/b11/staging-readiness-20261106/inventory.json).
- Protected user preview simulator: **5FDE1E82-1FF7-4556-9C14-0746F6295944**. Never erase, reset, use as test fixture or include in cleanup. All task-owned recent UI simulators are shut down. No local native lane is active.
- Existing local PostgreSQL port 55432 is not the restore target. Use an owned isolated socket/cluster on the encrypted restore volume and clean up only owned resources.

## Remaining release work

[Acceptance gates](CURRENT-ACCEPTANCE.md#remaining-production-work-and-release-gates) retain full scope: current combined CI; actual protected backup/restore and reviewed hosted migration/deployment; independent journal/runtime/alert recovery; real KWS and email delivery; Apple paid signing/StoreKit/TestFlight/AppStore; approved policies/support operations; full route/device walkthrough; human US-Spanish and physical camera/share/widget/print/notification/assistive-access checks; current Android companion-web acceptance. Do not represent simulator, fixture, synthetic-provider or earlier-source results as those gates.
