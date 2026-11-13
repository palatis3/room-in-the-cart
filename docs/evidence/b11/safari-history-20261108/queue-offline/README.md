# Safari retains an offline request and sends it once on explicit retry

The **queue-offline case passes** in the same owned iPhone17 Simulator/iOS26.2 MobileSafari used for the history cases. The real browser kept one pending command in IndexedDB across a disconnected reload and a connected reload. Neither reload sent the command. One explicit product Retry then produced **one POST, one fixture effect and one received request**, with no pending row or Retry control remaining.

This is real Safari input, native Reload, IndexedDB persistence and explicit retry against a synthetic loopback authority. Only API traffic was disconnected; the app shell remained available. It is not a radio-offline/PWA, physical-device, provider or PostgreSQL acceptance claim.

## Actual sequence and four observations

1. Root enabled the actual browser queue permission, entered the fixed fictional item `SAFARI_QUEUE_OATS_4101`, reviewed it and tapped Send once after the fixture's API disconnect. Root observed the marker and waiting state. [Queued observation](observation-queued.json): one stored command, Retry present, zero command attempts/effects.
2. Root used Safari's native Reload while API traffic remained disconnected. Private fixture text disappeared; the exact account-load-unavailable notice and enabled Refresh appeared, with a ready/non-busy view. [Extra disconnected-reload observation](observation-offline-reloaded.json): the same one IndexedDB row/digest survives, zero commands, no displayed private marker or Retry. This extra observation is retained and independently checked beyond the frozen verifier's three required phases.
3. Root reconnected the API and used native Reload. The pending item and product Retry returned without a command POST. [Connected-reload observation](observation-reloaded.json): same one row/digest, online request form, empty top-level notice, zero attempts/effects. The top-level notice is separate from the pending card's wording.
4. Root tapped the actual product Retry once. The exact **Received by the shopper.** status and received marker row appeared; the pending card disappeared. Root clicked Record fixture observation and observed its completion. [Final observation](observation-final.json): one attempt/effect, zero stored rows, no Retry, ready/non-busy state.

The pending command SHA256 is identical across all three pre-retry storage observations and the actual POST: `12a0f02ae5298a54789d03934f618d500eff10447d0ba0f0d7a07ea2f899a834`. [Full stopped receipt](receipt.json) preserves all four observations and server events. Root's visual observations are retained only in the Device Hub CUA transcript; no standalone PNG/video export is claimed.

## Verification and provenance

The unchanged frozen R2 `verify-case.mjs queue-offline` was rerun read-only after completion and returned exit0: `passed-scoped`, one attempt and one effect. [Output](verification.stdout.txt), [verification and supplemental checks](verification.json). The original receipt SHA256 is `c749cd9ee5165c4b4ab256c482a37b680da07382fc419a52695b03b7ac7dfb95`.

[Helper/provenance manifest](helper-provenance-manifest.json) identity remains `bffa8e626fc1f2e5645864c38d0017ab215e19170aef59383c3d417cb6ddcb62`. Read-only verification rechecked all frozen helper/asset hashes and the root's independently built975cfb1 receipt. Exact reference copies of the [probe](probe.js), [observation schema](observation.mjs), [case verifier](verify-case.mjs) and [pin verifier](verify-pin.mjs) are retained with [copy hashes](copy-origins.json). These are reference copies; the recorded verification ran the complete frozen scratch package, not these files as a standalone installed harness.

[Original runtime identity](../owned-simulator-safari.json) records actual simulator MobileSafari; simctl buildversion23C52 and the executable mount's `iOS_23C54` path remain distinct unchanged facts. Root confirms this case used that same owned Safari. JS/CSS/assets remain unchanged; fixture HTML injects the bounded diagnostic and separate toolbar described in the [original proof](../README.md). This does not establish uninstrumented rendering or performance.

A supplementary packaging check initially assumed that connected cold reload would set the top-level waiting notice. The receipt instead correctly records the restored pending card/Retry with empty top-level status. The [packaging correction](packaging-check-correction.json) preserves this erroneous extra assumption and its correction. The original verifier already passed; no frozen helper, product behavior, receipt or original verifier assertion changed.

## Cleanup and remaining scope

Root stopped exec49068 with terminal exit0. This evidence collector independently checked only the owned loopback port51726; it returned ECONNREFUSED. No browser, native application or server was started or controlled while publishing the proof. [Prior-proof preservation](prior-proof-preservation.json) verifies all30 earlier evidence files remain unchanged.

Four history cases and this one queue case now qualify in their documented scopes. **Queue lost-reply, eviction and permission-revocation cases remain unexecuted.** No claim covers cold Safari process restart, device reboot, actual OS storage eviction, fresh invitations/helper/editor scope, sign-out, Spanish Safari, live identity, physical/human use, full Safari acceptance or first-version release. No product/helper edits, handoff changes, commit, push or deployment accompanied this publication.
