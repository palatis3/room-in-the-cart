# Safari reports missing pending storage without resending

The **queue-evicted case passes** in the same owned iPhone17 Simulator/iOS26.2 MobileSafari. After one attempted Send was dropped before any fixture effect, the real browser held one pending IndexedDB command. An explicit fixture action deleted that fresh origin's test outbox. One actual product Refresh then reported the missing pending request, removed its pending/Retry controls and sent no additional command. Final counts remain **one POST attempt, zero effects and zero received rows**.

The deletion was deliberate test-fixture eviction, not OS-initiated storage pressure, global Safari storage denial or deletion of another origin's data. Actual Safari/product behavior after the missing store is the qualified boundary.

## Actual observations

1. On fresh loopback origin52252, root opted into queue storage, typed `SAFARI_QUEUE_OATS_4101`, reviewed it, selected drop-before-effect mode and tapped Send once. Root observed waiting/pending. [Queued observation](observation-queued.json): one stored row, waiting marker and Retry, one attempt and zero effects. The stored command and attempted POST share SHA256 `df82284df7df720c95d3cfc1f8510972765f58dea41f783cdc663e60b784b570`.
2. Root selected the `evicted` phase and clicked the clearly separate fixture **Erase fixture pending storage** control once. [Evicted observation](observation-evicted.json) records `action:explicit-eviction` and zero stored rows immediately afterward. This action targets only the named test outbox at the fresh task origin; it is not a product control.
3. Root selected `final` and tapped actual product Refresh once. The exact notice appeared: **A pending request is no longer stored on this browser. Check Your requests for its status.** Lower UI showed no pending/Retry and **Your requests → No requests yet**. Root completed the final evidence capture. [Final observation](observation-final.json): exact missing status, online contributor form, ready/non-busy state, no pending marker/Retry and zero stored rows. Counts remain one attempt/zero effects throughout all three observations.

The native visible outcomes above were inspected in root's Device Hub CUA transcript. No standalone PNG/video export is claimed. The probe measures fixed status/control flags; the server independently records zero received rows and no post-eviction resend. [Complete stopped receipt](receipt.json).

## Verification and provenance

The unchanged frozen R2 verifier was rerun read-only after completion. It returned exit0, `passed-scoped`, one attempt and zero effects; [output](verification.stdout.txt), [verification and additional explicit-eviction checks](verification.json). Final receipt SHA256: `8a845c6f0c6cd32739a55f59aac01644e415c55893aae17448e8f6b021fa8c5f`.

[Helper/provenance manifest](helper-provenance-manifest.json) remains `bffa8e626fc1f2e5645864c38d0017ab215e19170aef59383c3d417cb6ddcb62`. Verification rechecked the frozen helpers, copied web assets and root's independently built975cfb1 receipt. Exact [probe](probe.js), [observation schema](observation.mjs), [case verifier](verify-case.mjs) and [pin verifier](verify-pin.mjs) reference copies are bound by [copy provenance](copy-origins.json). Verification ran the complete frozen scratch package; these references are not a separate executable installation.

The [original real Safari identity](../owned-simulator-safari.json) and instrumented fixture HTML limitations remain applicable. Runtime build23C52 and the executable mount's `iOS_23C54` path remain distinct observations. No desktop WebKit, physical-device, live-service PostgreSQL or provider claim is added.

## Cleanup and remaining scope

Root stopped exec83178/PID8917 with terminal exit0. The evidence collector independently checked only owned port52252 and received ECONNREFUSED. All64 earlier evidence files remain byte-identical, including setup failures and prior manifests; [preservation](prior-proof-preservation.json). No product/UI/server/helper action, handoff change, commit or push accompanied this publication.

Four history cases and three queue cases now qualify in their recorded scopes. **Queue-permission revocation remains unexecuted.** Cold Safari process restart, device reboot, OS-generated eviction, Spanish Safari, live identity, physical/human use, full Safari acceptance and complete first-version release remain outside this result.
