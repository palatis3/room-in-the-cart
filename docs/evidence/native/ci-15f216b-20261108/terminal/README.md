# Terminal hosted cohort: 15f216b

All six original pull-request workflows are terminal as of **2026-11-08 05:16:51 UTC**, attempt1, source `15f216b01e41c111ec99bbd812419cec32e6a5e4`. **The cohort failed.** Later local corrections, diagnostic passes and Safari evidence do not replace these original hosted outcomes.

| Scope | Native result | Strict/job outcome |
| --- | --- | --- |
| Core ordinary UI | **65/68 passed,3 failed,0 skipped** |47 cases belong to passing shards; UI05/UI07/UI10 failed. Available warning receipts cover68 cases and report0. Two runner restarts belong to UI07/UI10. |
| Fixture UI | **67/69 passed,2 failed,0 skipped** |61 cases belong to passing jobs. Two native-failure jobs plus the native5/5 cook job fail strict verification. Warning counts cover64 cases and report0; cook's5-case warning count is **unavailable**, not0. |
| Core Chromium browser step | Browser launch timed out before history-privacy assertions |Separate startup failure;140unit tests passed. Later outbox case passed, but neither result supplies the missed history-privacy assertions. |

The Records fixture is intentionally restricted to its original redacted1/1 count report and exact selector. Its console/restart count is not collected; the fixture aggregate reports0 restarts only across available console receipts. The69 selectors are counted independently of the68 ordinary selectors; neither number includes model tests, StoreKit or performance cases.

## Original failures

| Job / selector boundary | Original evidence |
| --- | --- |
| Core UI05, job128613594078: PickupOffer saved-offer/restart case fails its pre-save Branch equality, expected `Main branch`, observed `Ma` at59.745s | [Receipt](ui-05/verification.json), [line-numbered excerpt](excerpts/ui-05.txt). The immediate predecessor passed143.477s. No persisted truncation or later restart failure is inferred from that readback. |
| Core UI07, job128617122245: Spanish original-food-name/saved-answer case exhausts720s before Compare/Save | [Receipt](ui-07/verification.json), [excerpt](excerpts/ui-07.txt). First missing animation-completion notification follows aQuantity Listo at31.66s; eleven60s waits then a runner restart. Original eight-case predecessor scope is retained. |
| Core UI10, job128624830058: fresh-branch-pricing/earlier-inclusive-quote case exhausts720s during Branch deletion | [Receipt](ui-10/verification.json), [excerpt](excerpts/ui-10.txt). First60s idle wait follows Inclusive total Done93.06s; initial checkout saves, then repeated idle waits and restart occur before the fresh-pricing assertions. Shared symptom with UI07 is not an established common cause. |
| Fixture SharedFallback, job128624899598: five-usable-wraps case fails the bounded switch-value expectation | [Receipt](SharedFallbackUITests/verification.json), [excerpt](excerpts/SharedFallbackUITests.txt). `value == "1"` is not satisfied; XCTest waiter returns2 instead of1 at source107, case27.993s. Other case passes. |
| Fixture SharedStoreQuote, job128631169252: known-trip/private-proposal/adoption case fails keyboard readiness for `sharedQuotes.first.extraMinutes` | [Receipt](SharedStoreQuoteUITests-testKnownTripUnknownBreakEvenPrivateProposalAndExplicitShopperAdoption/verification.json), [excerpt](excerpts/SharedStoreQuoteUITests-testKnownTripUnknownBreakEvenPrivateProposalAndExplicitShopperAdoption.txt). Source251; no later private-save/adoption success is claimed. |
| Fixture cook/readback, job128624824824: all5 native cases pass, including destination-copy152.735s; strict warning-evidence gate fails | [Receipt](SharedDeliveryUITests-recovery-cook-and-closeout/verification.json), [original strict excerpt](SharedDeliveryUITests-recovery-cook-and-closeout-summary.txt). The passing readback case has a User-interactive→Default QoS warning with0 required Complete Issue Description.txt attachments. Its warning count remains unavailable. |
| Core web, job128608399841: `browserType.launch` timeout15000ms at history-privacy.test.mjs:76 | [Original excerpt](web-failure-excerpt.txt) and [exact browser execution order](excerpts/web-browser-order.txt). History case runs first; outbox runs afterward. Chrome156.0.8078.79 is reported. This is a startup boundary, not a privacy assertion failure or proof of an application leak. |

Cook's [raw runtime JSON](SharedDeliveryUITests-recovery-cook-and-closeout/pristine-members/test-speech-runtime.json) retains five actual Hang Risk/NSCondition wait records, separately from the one structured warning node and unavailable strict warning count. Its [error output](SharedDeliveryUITests-recovery-cook-and-closeout/pristine-members/test-speech-runtime-error.txt), start receipt, full small warning receipt and structured results are preserved. Missing warning attachment does not erase those diagnostics. No blanket suppression or app-thread correction is implied.

## Complete cohort outcomes

| Workflow | Original run | Conclusion |
| --- | --- | --- |
| Build and test | [42440464721](https://github.com/palatis3/room-in-the-cart/actions/runs/42440464721) | failure |
| iOS deep checks | [42440464691](https://github.com/palatis3/room-in-the-cart/actions/runs/42440464691) | success |
| iOS fixture checks | [42440464791](https://github.com/palatis3/room-in-the-cart/actions/runs/42440464791) | failure |
| iOS Release performance | [42440464669](https://github.com/palatis3/room-in-the-cart/actions/runs/42440464669) | success |
| Native Swift HTTPS and PostgreSQL | [42440464677](https://github.com/palatis3/room-in-the-cart/actions/runs/42440464677) | success |
| Security checks | [42440464675](https://github.com/palatis3/room-in-the-cart/actions/runs/42440464675) | success |

The deep-check receipts report15/15English and15/15Spanish StoreKit passes, each with0skips/warnings/restarts. Thread and Address Sanitizer runs each report437passes plus3expected wire skips. The separate native-wire receipt reports6Node HTTPS/PostgreSQL cases and10native Swift scenarios. All three Release performance lanes pass their pinned environment's baselines; these measured UI timings include automation/input/accessibility overhead. Security success records the dependency-review and JavaScript/Actions CodeQL job conclusions, not a universal security guarantee. Original small receipts remain linked by the checkpoint paths.

## Exact inventories and evidence integrity

[Terminal checkpoint](checkpoint-20261108T051651Z.json) and [fixture terminal inventory](fixture-terminal-inventory.json) are byte-exact originals. [Reconciliation](reconciliation.json) independently recalculates counts, verifies all40referenced receipt hashes, confirms six terminal workflows and reconciles every fixture row against its source-planner selectors and exact hosted selector file. The17fixture rows contain exactly69unique selectors, with no missing, extra or duplicated selector. [Combined selector file](fixture-selectors-69.txt) concatenates the inventory rows; it is not a claimed global execution order across concurrent jobs. Each shard's original selector order remains separately retained under its pristine-members/test-plan path. The compiled ordinary-discovery receipt independently pins68enabled UI cases and the ten-shard counts.

`runtimeWarningsInAvailableReceipts:0` in the checkpoint is explicitly a partial-coverage statistic. It cannot be read as zero warnings for the entire fixture cohort. Likewise native passes within failed jobs are not strict acceptance passes. The aggregate strict counts47and61 denote cases contained in successful jobs, not independent additional test executions.

[Retention receipt](retention.json) records original paths, byte counts and SHA256 for every copied file, and original log hashes plus precise line selections for each derived excerpt. Full raw logs and artifacts remain in scratch; omitted excerpt intervals are not continuous evidence. The receipts distinguish CRC-verified range-selected members from archive digests supplied by GitHub metadata; no whole archive is newly verified by this publication. The tiny ordinary-discovery receipt retains its separately recorded full-archive verification. No archive, transport payload, xcresult, large stdout, screenshot/video or product binary is copied here.

Final file hashes and privacy review cover the completed publication. No CURRENT/product/workflow edits, native/UI/server ownership changes, remote actions, commit or push occurred.
