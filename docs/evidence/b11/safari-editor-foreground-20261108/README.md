# Safari editor foreground revocation

**The scoped editor case passes in actual iPhone Simulator Safari.** After Home → Safari, the dated cook view, previously received suggestion, unsent correction and editor controls stayed concealed while fresh authority was held. Releasing the revoked-grant response left the exact access-ended notice and enabled Refresh, with the previous content absent. The three observations share one document identity. There were **zero product write attempts and zero effects**.

This advances E03/B06/B11 mobile-browser privacy acceptance for one already authorized editor. It is not full Safari or release acceptance, and no production behavior was changed for this case.

## Observed sequence and evidence

Root opened the isolated `/view`, visually checked the granted household/shop, revision7 and dates, item/amount/action, then typed the exact unsent correction without sending. The initial observation confirms all prescribed content and editor controls. **Exact received-suggestion wording was confirmed by the bounded DOM flag; it was not separately fully visually inspected.**

Root used the actual Device Hub Home action and visibly reached iPhone Home. While away, the fictional grant was revoked and `/v1/session` held. Root returned through the Safari app without Reload, Back or navigation and visually observed Loading with no private editor content. The held observation records one pending authority request and no private text or controls. After explicit release, root visually observed “Access has ended. Ask your household for a new invitation.” and enabled Refresh. The final observation records those exact outcomes.

[Original receipt](receipt.json) contains initial/held/final, sampled lifecycle/DOM flags and synthetic server events. [Root observations](root-observations.json) distinguish native observations from DOM evidence. Screenshots were viewed in the CUA transcript; **no standalone PNG or video export is claimed**.

[Independent read-only verification](verification.json) reran the original immutable verifier after shutdown and returned `passed-scoped`, exit0. It verified the same document, actual hidden→visible cycle, held authorization, all concealment checks, prescribed final state and zero mutations. The only product requests were four initial GETs followed by the held session GET; response statuses were200,200,200,200,403. [Root verification](root-verification.json) agrees.

## Exact device and product inputs

The root-owned iPhone17 Simulator ran iOS26.2, system build23C54; MobileSafari26.2 (`8623.1.14.10.9`). Light appearance, Large content size and increased contrast off are recorded in [native identity](native-identity.json). These observations retain the system-reported identity rather than infer a physical device or provider environment.

The [harness manifest](harness-manifest.json) identity is `7dd7b55a7e0c35ef9a67b3190ed9260ecf9a04a213bd07d2d469b9aff1d5eaf1`. Its five assets were reused from the verified `58419f9822b26a93820c2f4cfa4a45e7cd257a11` web build only after all24 recorded current runtime/config/lock/public/contract inputs matched. [Source equality](preparation/source-equality.json) and the unchanged historical [build receipt](preparation/build-receipt.json) bind that decision. Historical pending-execution wording in preparation receipts is preserved; this actual execution is the subsequent result.

Selected [frozen probe](frozen/probe.js), [fixture](frozen/fixture.mjs), [server](frozen/server.mjs), [schema](frozen/observation.mjs) and [verifier](frozen/verify-foreground.mjs) are exact copies of their manifest-pinned bytes. Fixed marker detection uses `textContent`, so hidden retained private text is detected; input values and disabled/hidden control presence are checked separately. No arbitrary page text is exported. Diagnostic observation POSTs are separate from product writes. Every completed synthetic API response goes through the fixture's forbidden-field accounting. Server-only canaries prove only this fixture's response construction, not production backend isolation.

## Retained failures and cleanup

The first launch failed with ENOENT because the run-parent directory did not exist. No listener or browser opened. Root created the empty parent and launched again; immutable helpers and criteria stayed unchanged. [Original setup failure](setup-failure.json) remains a failure, not an additional pass.

Offline preparation finished71/71 tests with zero skips/failures and13 syntax checks. [Preparation receipt](preparation/preparation-receipt.json) and [final log](preparation/offline-tests-r6.log) retain scope. Earlier composition-harness failures are retained in [r2](preparation/offline-tests-r2.log) and [r3](preparation/offline-tests-r3.log), with failed source copies: the probe initially missed JSDOM DOMContentLoaded, then separate transpilation caches gave ApiError different class identities. These were harness setup corrections, not production fixes or relaxed acceptance criteria. Offline tests are not additional Safari executions.

Root stopped session46195/PID9127 serving port62215 with exit0, then verified that exact port closed and PID absent. Capture Keyboard stayed off. [Cleanup](cleanup.json) is attributed to root; this evidence publication did not start or stop any process or use the active native lane. All32 original contributor `foreground-fixed` files and their results remained byte-identical.

## Limits and reproduction

This is sampled Simulator Safari evidence using a fictional editor grant/API. It does not establish continuous-frame or App Switcher privacy, physical-device or real-provider behavior, helper scope, fresh invitations, same-grant recovery, BFCache, stale-proposal submission, Spanish or human accessibility. The diagnostic toolbar and instrumentation can affect layout/timing. No broader browser, backend-isolation, performance or release claim follows.

[Copy provenance](copy-provenance.json) identifies source files and byte-preserving hashes. `file-hashes.json` inventories this compact evidence package. The pure `verify-evidence.mjs` checks those hashes, the original harness identity and selected frozen helpers, then reruns the receipt assertions without a browser, listener, native process or filesystem mutation:

```sh
.tools/node-v22.23.4-darwin-arm64/bin/node docs/evidence/b11/safari-editor-foreground-20261108/verify-evidence.mjs
```
