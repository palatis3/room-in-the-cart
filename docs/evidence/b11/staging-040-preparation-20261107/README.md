# Room in the Cart staging update through migration 040

The approved staging update is live. The [post-promotion record](deployed.json) identifies the deployment, database verification, and public web checks.

The update adds shared delivery and pantry evidence, reviewed dinner recovery and cook instructions, purchase confirmation, and explicit carry of a deferred request to a later pickup. The runtime source is `eae1e721cb08b8d678200a2345f5c3abb18df6c6`.

| Component | Reviewed staging target |
|---|---|
| Database | Room in the Cart Staging, Supabase project `uwjxrotnocxxomqdetzk`, verified at 030 |
| Service and web | Vercel project `prj_MsdHyy06CKCuFeAvoOCpnJRQ1vGa`, alias `room-in-the-cart-staging.vercel.app` |
| Application rollback | Previously verified ready deployment `dpl_2tfRmEfTGLW63sSTksJ6xJ9MZ97P` |

The encrypted source backup and the independent restore rehearsal are complete. Before deployment, recheck the live registry and source data against that backup, the alias target and the checksums of all ten pending migrations. Apply 031–040 in order with the transactional migration runner. Verify the registry, permissions and preserved rows. Build the pinned runtime separately from the live alias, verify the built routes and access boundaries, promote to the staging alias, and repeat the checks. Application rollback restores the recorded deployment. Database recovery uses the private verified restore after reconciling any later writes.

The deployment uses existing staging provider and maintenance settings. Production billing, email delivery, guardian verification activation, provider deletion and App Store distribution are outside this update.

[Candidate checksums and tests](candidate.json) · [Encrypted backup and restore](backup-restore.json) · [Mixed-phone walkthrough](mixed-phone.json)
