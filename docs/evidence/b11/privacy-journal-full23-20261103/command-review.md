# Prepared final001–023 local command

Executable: `/Users/palatis/Documents/Codex/2026-11-03/task-2/privacy-journal-implementation/evidence/run-full23-reviewed-alternative.sh`

It executes the Node22 binary with `env -i PATH=/usr/bin:/bin LC_ALL=C LANG=C` from `full23/service`, running `scripts/journal-full-023-drill.mjs` and logging to `evidence/full23-drill.log`. All PostgreSQL pools/tools use fixed `/tmp:55432`, explicit fixture database/user and empty fixture password callback; no ambient PG*, URL, service or options.

New collision-checked DBs only: `ritc_b11_j022_src_20261103_v023` and `ritc_b11_j022_restore_20261103_v023`, owner palatis/template0. Only these DB ACLs change: revoke PUBLIC CONNECT, grant CONNECT to existing `ritc_b11_j022_app`, `ritc_b11_j022_worker`, `ritc_guardian_test_verifier`. Existing roles/flags/passwords/memberships are checked, never changed. Preflight exact verifier membership and privilege negatives, post-migration actual verifier non-owner check, app/worker/proof private table/helper denials remain. All prior DBs/evidence retained unchanged. No role creation, no preserved DB/ACL mutation, no DB drops.

Frozen owner-final021 and023 hashes are asserted in the source manifest. Migration022/module/CLI remain exactly the reviewed installed source. No source file is written by this command.

The actual local test extends the successful001–022 backup-before-acceptance/journal/source erasure/quarantined restore/exact replay/isolated runtime sequence with authorized managed-device fences for selected adult+child and retained sibling/foreign household. Tests assert strict noncredential inventory wire fields; revoked bearer cannot mint a replacement; app cannot set device.session_id or access the fence; source/full replay eraser clears only selected target fences; restore provider timestamps remain NULL and zero provider calls; retained current device works, its fenced provider session cannot reenroll, a fresh login can. Synthetic provider/email only; source provider calls only adults. No remote/deploy/real provider/retention policy or production enablement.

Build passed; pure suite running. Command is prepared and has not yet executed. The original rejected new-role command is not included or retried. Requires the distinct reviewed automatic approval invocation, and no approval is inferred from elapsed time.

Exact hashes:

```json
{
  "wrapper": "8914498c7fad76bd35d98e54176376692d6b98b881d27d8b955ebb33b88dad95",
  "harness": "2cea44fa785fed0eaa90f0a5e70b6317acf15ea9895294cf790769b7ee07d3f1",
  "sourceManifest": "bffb53fdbf0b1d40d0899094a9454a89c75b7dd66e81faf8f4e6ecc3e3222c2c",
  "sourceArchive": "9281f3828b9858f0f3c19611935926602f2d0659cbe04222ac83aafa279a72ca"
}
```
