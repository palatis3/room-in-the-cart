# Fixed Simulator Safari foreground passes

Both fixed cases pass the unchanged scoped verifier. Root observed a concealed Loading screen while fresh authority was held. Same actor then recovered the exact unsent draft and own request; revoked actor then showed the exact access-ended notice and enabled Refresh, with no private request/form/draft/Retry. Each actual Home→Safari journey retained the same document, one held authority request, initial→held→final observations and zero product commands/effects.

[Same-actor receipt](foreground-same/receipt.json) and [revoked receipt](foreground-revoked/receipt.json), original verification logs and root reviews are byte-exact retained copies. Native actions/visuals are attributed to root's recorded observations. Publication performed no browser/native/server action. Screenshots remain in the CUA transcript only; no standalone images were exported or reconstructed.

## Provenance and unchanged criteria

Fixed manifest identity: `9d8302a00fde50e5e137166a52bd4496745f69e348e23acd974a3a43f794f5ba`.

Original manifest identity: `161583ff8c0771c0bd85f3765a0a9981333840cfef91ed225ce793f11aee4414`.

The original two real Safari failures remain unchanged in [baseline](../baseline/README.md). Prepublication verifyPin calls checked both complete scratch bundles and their helper/build dependencies. All36 original scratch files, including both failure receipts, remained unchanged; all14 copied executable/test helper files matched exactly. Both original verifiers still reject `private field/control exposed: ownA`; both fixed receipts pass with the same checks. The entire22-file public baseline is hash-preserved separately.

The [installed build receipt](provenance/build-receipt.json), SHA256 `076e56f429de76022c4e8e3f994a7ace2478e62044839f62d8d63ebf970b0015`, pins source commit `58419f9822b26a93820c2f4cfa4a45e7cd257a11`,12TypeScript sources and5web assets. Exact new assets were checked against both fixed bundle and web/public-build during harness preparation. The receipt's “not yet run” Safari/install-in-progress fields describe its earlier recording time; they remain unedited. These subsequent case receipts and browser logs supply later outcomes. This source was committed locally and **not deployed**.

The retained frozen files are the tested manifest/probe/fixture/observation/server/verifiers. Full product assets remain in scratch, so this bounded archive is not a standalone runnable fixture. Copied verify-pin retains original external-path expectations. Use [audit-fixed.mjs](audit-fixed.mjs) for self-contained retained-proof verification; [offline-audit.json](offline-audit.json) records its successful execution. It also checks the original failures, byte retention, log counts, test identity and exact build map.

## Separate regression evidence

- [Portable original-source negative control](tests/original-source-negative-verification.json): exact committed12-case test bytes, including root's monotonic3s mocked-boundary deadline, yield3pass/9fail on original product source. Exact log and the two portable files are retained.
- [Installed web tests](tests/installed-web-tests.log):152/152pass,0skip; includes normal TypeScript/Vite build and the portable source regressions. The log hash matches the installed build receipt.
- [Chromium regression](tests/chromium-passed.log):14/14pass,0skip, Chrome158.0.8127.18, covering existing browser history/privacy and outbox-eviction tests. This is separate desktop Chromium evidence, not Safari foreground evidence.
- [First browser attempt](tests/chromium-initial-missing-browser.log):0pass/2fail because the requested Chrome executable was absent. It is retained separately as unavailable setup, not hidden or counted as two product failures. The later root-run Chromium result followed browser availability.

## Identity, cleanup and limits

[Native identity](native-identity.json) is the unchanged baseline read-only identity receipt. Root used the same owned Simulator Safari: simulator4C7FAE04-D40B-4ADC-8F75-1366C09B1695, MobileSafari26.2, bundle8623.1.14.10.9, baseline PID3395. That receipt contains two runtime-inventory entries sharing the iOS26.2 identifier, builds23C52 and23C54; this proof does not resolve one active build from that inventory. No fresh simulator query occurred during publication.

Root reports both listeners stopped exit0 and their ports closed: same PID29623/session34310/port55396; revoked PID30620/session34188/port55615. [Execution boundary](execution-boundary.json) records those statements; offline checks match receipt origins and root stopped-state reviews. They do not independently re-observe historical process/port state.

These are two minimal same-document foreground qualifications using actual Simulator Safari and a synthetic local API. No physical-device, provider, public household data, App Switcher snapshot, continuous-frame or global browser acceptance claim follows. Probe checks cover recorded samples; attribute-only and input-property changes between samples can be missed. A before-app-listener sample is context, while the unchanged post-task→held rule requires every recorded sample concealed. Neither native pass erases the original exposures.
