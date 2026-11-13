# Safari removes a pending request when queue permission ends

The **queue-revoked case passes** in the same owned iPhone17 Simulator/iOS26.2 MobileSafari. An API disconnect left one real pending command in the browser's IndexedDB. After the fixture restored connectivity but revoked this device's queue permission, one actual product Refresh removed the stored request, pending/Retry controls and queue-permission controls. The authorized online request form remained available. **No command POST or effect occurred.**

This completes the proposed **eight minimal Safari cases**, each with its separately retained scope. It does not complete broader Safari, physical-device, provider or first-version release acceptance.

## Actual sequence and observations

1. On fresh loopback origin52401, root opted into queue storage, typed `SAFARI_QUEUE_OATS_4101`, reviewed it, disconnected fixture API traffic and tapped Send once. Root observed waiting/pending and completed capture. [Queued observation](observation-queued.json): one IndexedDB command, waiting marker, Retry and queue-permission control, with zero attempts/effects. Command SHA256: `36f5382061d72fce07a459d61fd266785d6fc9e7384b683ed1c91bf0f0cd495a`.
2. Root restored fixture API connectivity and set queue permission false while retaining the same actor's household authority. Root tapped actual product Refresh once. The visible result was the authorized blank request form, empty top-level status and empty Your requests. No pending card, Retry or queue-permission controls remained. Root completed the final fixture capture. [Final observation](observation-final.json): online contributor form ready/non-busy, empty status, zero stored rows, no pending marker/Retry/queue-permission controls and still zero attempts/effects.

Queue permission ending is distinct from household access ending. The expected result here is the usable online form, not an access-ended notice. The probe detects the actual opt-in/turn-off button and legacy storage checkbox variants; their absence and the surviving authorized form prevent a blank/error page from passing. [Full stopped receipt](receipt.json) records no command request at any boundary.

Root's native observations are in the Device Hub CUA transcript only. No standalone PNG/video export is claimed. Real browser storage cleanup and UI recovery are observed; the authority change itself is a controlled fixture input, not a live-provider/server/PostgreSQL action.

## Exact verification and cleanup

The unchanged frozen R2 verifier was rerun read-only and returned exit0, `passed-scoped`, zero attempts/effects. [Output](verification.stdout.txt), [verification and supplemental assertions](verification.json). Receipt SHA256: `9db96800dd33067ca7c2172410b5cac1583f36ecfaf002f22f4754255d17d904`.

[Helper/provenance manifest](helper-provenance-manifest.json) remains `bffa8e626fc1f2e5645864c38d0017ab215e19170aef59383c3d417cb6ddcb62`. The read-only verifier also rechecked frozen helpers, copied assets and root's independently built975cfb1 receipt. Exact [probe](probe.js), [observation schema](observation.mjs), [case verifier](verify-case.mjs) and [pin verifier](verify-pin.mjs) reference copies are hashed in [copy provenance](copy-origins.json). Execution used the complete frozen scratch package; these reference copies are not an independent harness installation.

Root stopped exec79057/PID9493 with terminal exit0. The evidence collector independently checked only owned port52401 and received ECONNREFUSED. All80 older evidence files remain byte-identical; [preservation](prior-proof-preservation.json). No product/helper/UI/server action, handoff change, commit, push or deployment accompanied this publication.

## Completed subset and remaining limits

The separately retained minimal cases are [same-actor history](../README.md), [changed/revoked/offline history](../additional-history/README.md), [offline queue](../queue-offline/README.md), [lost reply](../queue-lost/README.md), [explicit fixture eviction](../queue-evicted/README.md) and this permission-revocation case. Earlier proof files correctly retain their then-unexecuted cases; they are not rewritten by this later result.

The [actual Safari identity](../owned-simulator-safari.json) and instrumented fixture HTML limitations remain unchanged. Runtime build23C52 and the executable mount's `iOS_23C54` path remain distinct recorded facts. These are Simulator Safari results, not desktop WebKit. No claim covers real radio-offline/PWA behavior, OS-generated storage eviction, cold Safari process restart, device reboot, no-store history controls, fresh invitations/helper/editor scope, sign-out, Spanish Safari, live identity, physical/human testing, full Safari acceptance or complete first-version release. Existing native CI and deferred provider/distribution gates remain independent.
