# Three additional Safari history cases pass

**Changed actor, revoked authority and offline authority each pass** on the same owned iPhone17 Simulator/iOS26.2 MobileSafari used for the original same-actor case. All three restore an actual persisted BFCache document, conceal the old request and exact draft while one fresh authority response is held, and finish in the required visible state with zero product mutations. These results bring the qualified history subset to **four cases**. The four queue cases remain unexecuted.

The unchanged frozen R2 helper/probe/verifier manifest is `bffa8e626fc1f2e5645864c38d0017ab215e19170aef59383c3d417cb6ddcb62`. [Original helper/build provenance](../helper-provenance-manifest.json) and [actual Safari identity](../owned-simulator-safari.json) remain authoritative. The runtime metadata's23C52 build and executable mount's `iOS_23C54` path remain distinct, unchanged observations. Root confirms all three journeys used the same owned Safari app through Device Hub CUA, not desktop WebKit or a WKWebView host.

## Actual outcomes

Every case began with the original actor A request and exact unsent draft, moved to the neutral page, used actual Safari Back, and captured exactly **initial → held → final**. Each retained the same document token, `pageshow.persisted=true`, and absent private flags at the synchronous restored-pageshow boundary. The held capture recorded `pendingAuthority=1`; final captures recorded zero held responses and a ready, non-busy product view.

| Case | Fresh authority result and root's visible observation | Evidence |
|---|---|---|
| Changed actor | Only actor B's own request appears; the actor A request and draft are gone, and the Item draft is blank. | [Exact receipt](history-changed-receipt.json), [verifier output](history-changed-verification.stdout.txt) |
| Revoked authority | Exact **Access has ended. Ask your household for a new invitation.** notice, enabled Refresh, no Retry or private wording. | [Exact receipt](history-revoked-receipt.json), [verifier output](history-revoked-verification.stdout.txt) |
| Offline authority | Exact **Could not load your account. Refresh to try again.** notice, enabled Refresh, no Retry or private wording. The fixture disconnects API traffic while keeping the shell available; this is not full radio-offline/PWA acceptance. | [Exact receipt](history-offline-receipt.json), [verifier output](history-offline-verification.stdout.txt) |

Root inspected screenshots in the CUA conversation transcript. No standalone PNG/video export is claimed. Visual observations are root-reported; the immutable receipts and verifier predicates provide separate bounded evidence. The diagnostic HTML/probe limitations described in the [original proof](../README.md) still apply.

## Verification and cleanup

The exact frozen verifier was rerun read-only for each case after completion. All returned exit0, `passed-scoped`, `persisted:true`, cache `private, max-age=0`. [Verification summary](verification.json) preserves the terminal product flags, zero command attempts/effects, zero product non-GET requests and root-reported cleanup. No server/browser/native action was performed while publishing this evidence.

Root stopped all three PTY listeners with terminal exit0 and independently confirmed their ports refused connections: changed exec79655/PID5108/port51382; revoked exec56981/PID5414/port51461; offline exec31558/PID5801/port51556. This evidence collector did not send controls, revisit the tabs or restart those processes.

Receipt SHA256 values are preserved in [copy provenance](copy-origins.json):

- Changed: `6f26edf41830643110f004ef1b7d48cb36c2adfe400ac87adc574bd011d6a1f9`.
- Revoked: `84116928548e808ec46f6df47afe855b42cea2d7009c218f3cfe8b7780fb28a9`.
- Offline: `aa0248a179dd4f1808dc6a6fee0fbbbeabbca4250665bb405061700c709cf951`.

All16 original proof files, including the closed-stdin setup failure and original hash manifest, remain byte-identical; see [preservation](original-proof-preservation.json). Its earlier statement that seven cases were unexecuted describes that earlier checkpoint. This new directory adds only the three completed history cases, without rewriting prior results.

## Remaining scope

`queue-offline`, `queue-lost`, `queue-evicted` and `queue-revoked` have **not executed**. No no-store control, forward/back repetition, fresh invitation/helper/editor scope, cold Safari restart, sign-out, Spanish Safari, live provider, physical-device/human acceptance or full first-version release is claimed. The existing native CI failures remain independent. No canonical product/helper change, commit, deployment, migration or external action accompanied this publication.
