# Safari hides restored history until authority is rechecked

The **same-actor history case passes** in actual iPhone Simulator Safari. Safari restored the same document from its back-forward cache. Before fresh authorization completed, the original request and unsent draft were absent from the restored page. After the held authorization response was released, the same request and exact draft returned. The fixture recorded **zero command attempts and zero effects**. This is one scoped browser qualification, not full Safari or release acceptance.

The owned device was **iPhone 17 Simulator, iOS 26.2 (23C52)**, running **com.apple.mobilesafari 26.2**, with en-US/en_US global language settings. Read-only process inspection identified Safari PID3395 and verified its executable matched the simulator's MobileSafari bundle. The simctl runtime reports buildversion23C52, while the executable mount path includes `iOS_23C54`; both observed values are retained unchanged, without normalization. [Identity receipt](owned-simulator-safari.json). This was not desktop Playwright WebKit, a WKWebView host or a mobile user-agent simulation; real Safari navigation was driven through Device Hub CUA.

## Actual sequence and observations

1. Open the isolated fictional request page. Root visually verified `SAFARI_OWN_A_7d91`, entered `SAFARI_DRAFT_A_bf31` into the actual Item field without submitting, and captured [initial](observation-initial.json).
2. Follow the neutral fixture link using Safari. Root verified the neutral page, then held the fixture's next authority response through the separate stdin control channel.
3. Use Safari's actual **Back** control. The document token remained identical and its synchronous `pageshow` recorded `persisted=true`, with both own-request and draft flags already false. The [held observation](observation-held.json) records one pending authority response, a busy product view, and no private fixture wording. Root visually observed the full Loading view without the original request or draft while the response remained held.
4. Release the response without changing actor. The [final observation](observation-final.json) records zero held responses, a ready/non-busy product view, and restoration of the exact original request and unsent draft. Root visually confirmed both. No request was sent by navigation or evidence capture.

[Full final fixture receipt](history-same-receipt.json) contains exactly these three observations and the bounded synthetic server events. The per-phase files preserve their exact JSON objects. The diagnostic's `pagehide-before-app-listener` sample deliberately precedes the application's concealment handler and is not treated as a privacy verdict. The actual persisted `pageshow`, held view and final authorized result are the acceptance boundaries.

Root's screenshots were inspected in the Device Hub CUA conversation transcript. **No standalone PNG/video export is claimed.** Native visual observations are reported by root; telemetry and read-only verifier results are separately retained.

## Exact inputs and verification

[Helper/provenance manifest](helper-provenance-manifest.json) pins the reviewed R2 fixture, probe, verifier, source snapshot and five copied web assets. Manifest identity: `bffa8e626fc1f2e5645864c38d0017ab215e19170aef59383c3d417cb6ddcb62`. Root independently built runtime `975cfb15ccc402b55d31960f6d03d46c66104d69`; all five web asset hashes match this bundle and deployed041. [Build receipt](verified-build-inputs.json). This is artifact identity, not acceptance of every capability in that runtime.

The JS/CSS/assets were unchanged. Served fixture HTML inserted a bounded diagnostic script and clearly separate evidence toolbar outside the product root. The probe records only fixed fictional marker/control/status Booleans, document identity, lifecycle time, user agent, storage count and command digests. It neither replaces product input/actions nor dispatches lifecycle events. Instrumentation can perturb timing and changes the fixture's HTML/layout; this result does not establish uninstrumented appearance or performance.

The exact reviewed verifier was rerun read-only after root stopped the listener; it returned exit0, `passed-scoped`, `persisted:true`, `cache:private, max-age=0`. [Verification](verification.json), [stdout](verification.stdout.txt). Final receipt SHA256: `a70bdcd552cb4d049c4815288430aaa4e4d648156d18a5b8a9beebe66c6a7aa5`. [Copy provenance](copy-origins.json) and [file hashes](file-hashes.json) bind retained evidence. Scratch helpers remain under `.build/SafariQualificationNov08/proposal/`; no canonical product or workflow change was required. Earlier preparation's13fixture/DOM checks and31synthetic verifier controls are documented separately in [the preparation receipt](preparation-receipt.json); those controls are not additional Safari executions.

## Original setup failure and cleanup

The first `history-same` listener (PID3368; exec74497) was started without `tty:true`, leaving its stdin control channel closed. Initial own-request/draft observations succeeded, but **no Back action was attempted**. Root stopped it cleanly, terminal exit0. [Original setup boundary](setup-failure-boundary.json) and [unaltered original receipt](setup-failure-receipt.json) preserve this failed setup; it is not reclassified as a history pass.

Root restarted with `tty:true`, retaining the same reviewed helpers and a new isolated origin/output case `history-same-interactive` (PID4003; exec59250). After the completed case root sent stop and received terminal exit0. Independent read-only PID inspection found PID4003 absent; root separately verified both owned ports51017/51184 refused connection. Capture Keyboard was temporarily enabled for troubleshooting and restored off. The task Safari tab remains on its own synthetic origin with the listener stopped. No simulator reset, arbitrary website-data clearing or unrelated process termination occurred.

## Scope still open

Only `history-same` executed. **Seven proposed cases remain unexecuted:** changed actor, revoked authority, offline authority, pre-send offline queue/reload/retry, committed lost reply, IndexedDB eviction and queue-permission revocation. No no-store control, forward/back repetition, fresh invitation/helper/editor scope, cold Safari restart, sign-out, Spanish Safari, physical hardware, live identity provider or household-data acceptance is claimed.

Foundation B06/B07 and B11 require scoped cache/privacy and iPhone/Android offline evidence; the explicit Safari/browser matrix is in `docs/product/foundation-gen2.1/08-build.md:13–25`. This result closes only the same-actor persisted-history subcase. Existing native CI failures and owner-deferred Apple/SMTP/KWS/human gates remain independent. No commit, deployment, migration, provider activation or external action was performed in preparing this evidence.
