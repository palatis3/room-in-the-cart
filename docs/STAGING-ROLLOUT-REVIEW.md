# Room in the Cart staging update for owner review

The prepared update brings the existing staging database and companion web screens to the reviewed application version. It is a staging update; App Store distribution remains a separate release step.

| Item | Exact target |
|---|---|
| Runtime source | `d0b0b12ee0cb8412f17e82c92a91013217560670`; service, API, web, configuration and lockfiles match reviewed `3d26f1f` |
| Supabase | Room in the Cart Staging, project `uwjxrotnocxxomqdetzk`, organization `ybzztipzreurtjtjhmbo` |
| Vercel | `room-in-the-cart-staging`, project `prj_MsdHyy06CKCuFeAvoOCpnJRQ1vGa`, team `team_zkjaW5rtwPK9URZDeSoybwXB` |
| Staging address | https://room-in-the-cart-staging.vercel.app |
| Application rollback target | Current READY deployment `dpl_9mAfUc4cPpz6FQLiVLn5tRvFkDvD` |

The update applies the existing 21 pending SQL migrations, 009–029, using the application's unchanged transactional checksum runner. These cover session maintenance, account lifecycle, helper review, meal collaboration, quotes, measurement, guardian enrollment, and protected deletion/recovery infrastructure. [Every migration filename and checksum](evidence/b11/staging-readiness-20261106/live-upgrade.json) is pinned. No already-applied migration file changes.

The actual staging database was captured into an encrypted archive on this Mac, with recovery material in the login Keychain. An isolated restore verified the real Auth/app schemas, all 58 original tables and 90 rows, roles, grants and policies. A second fresh restore successfully upgraded through 029, preserved the original data outside the expanded migration registry, and left the verified 008 baseline byte-identical. Both local servers are stopped and both encrypted volumes are detached. [Capture](evidence/b11/staging-readiness-20261106/live-capture.json), [restore](evidence/b11/staging-readiness-20261106/live-restore.json), [upgrade](evidence/b11/staging-readiness-20261106/live-upgrade.json).

Execution sequence:

1. Recheck the exact project, source/checksums and captured staging state. Stop for review if the protected recovery evidence no longer covers the live state.
2. Apply 009–029 in order with the existing runner. Verify all 29 checksums and the resulting ownership, privileges and RLS.
3. Provision a separate maintenance login restricted to `ritc_worker`, plus protected scheduler authentication. Keep credentials in the existing staging project's server configuration (`WORKER_DATABASE_URL`, `WORKER_DATABASE_CA_PEM`, `CRON_SECRET`), with protected recovery copies; never place them in client bundles, Git or chat.
4. Build/deploy the pinned server and web source to this same staging project. Verify the staged build before assigning its staging domain. Preserve the current deployment identifier for application rollback.
5. Check public API boundaries, all named web routes and compiled assets, protected maintenance access and observed housekeeping. Record exact deployment identity and test results.

Provider deletion stays disabled until independent journal/observer recovery and provider activation are verified. The owner-deferred email setup and paid Apple setup remain separate. Child verification activation also remains separate from installing its prepared schema. Current CI failures and simulator evidence are recorded honestly; this proposal is not first-release acceptance.

On failure, retain the database evidence and each completed migration's checksum; do not drop newly created data or invent reverse migrations. Keep or restore the previous compatible application deployment, and leave affected provider paths disabled. The protected 008 restore supplies an independently verified recovery baseline, not an automatic destructive rollback.

The latest read-only check confirms the old deployment still passes six public API checks but fails 19 checks for the candidate web build, including the missing named routes. Separate worker and scheduler configuration is currently absent. [Current comparison and rollback evidence](evidence/b11/staging-readiness-20261106/staging-candidate-current.json).

Owner approval is pending. Earlier explicit backend approval covered local installation; no hosted migration or deployment has been performed as part of this proposal.
