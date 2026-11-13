# Cook destination trace qualification

The installed diagnostic completed the **original five cases in the original order**, with **5/5 native passes**, native exit 0 and no console lifecycle failures. The saved-copy case passed in **123.18 seconds**. **Strict verification failed (exit 1):** the preceding readback case again recorded the User-interactive→Default QoS runtime warning without its required `Complete Issue Description.txt` attachment. Warning evidence is **unavailable**, not zero. This is local diagnostic qualification and nonreproduction of the original destination-switch failure, not a causal correction or hosted acceptance.

The original hosted failure remains in [speech-causal-review](../speech-causal-review/README.md) and [speech-runtime-original](../speech-runtime-original/). Root ran exec 95723, using the installed source hashes in `run.json`, on the existing local iPhone 17 / iOS 26.2 simulator. The exact original selector list, observed start order and native completion lines are in `audit/selectors.txt`, `audit/order-audit.json` and `audit/native-boundary.json`. All original physical-center tap/immediate readback, later correction/share/history assertions, helper bounds and other cases remain unchanged apart from the opt-in environment assignment described by the retained patch.

## Captured destination behavior

The unchanged stdout sink yielded **117 valid markers**, no malformed markers, app PID 96559 and two diagnostic state-lifetime tokens. Per-token uptimes are monotonic. The app stdout is **62,150,929 bytes**, SHA-256 `76a59edf43218dd427c24c6fdf4864eaa88a68eb5b8a4ae2457307b5d17df854`; it remains scratch only. Its stored result object was 3,125,196 bytes. The diagnostic directory advertised name/type but no expanded size; the export succeeded within the unchanged 256 MB limit.

The first lifetime records the initial saved-copy visit, recipient check, mark-sent and navigation away. A second lifetime appears after the test deliberately reopens the saved copy. In that second lifetime:

- Stdout line **485590**: setter entry receives false→true, with review/correction present and access active.
- Line **485592**: the original setter returns with confirmation true and correction cleared, matching its existing behavior.
- Line **485593**: SwiftUI observes false→true. The same token remains through subsequent correction review and sharing.
- Lines **509881–509887**: the test's final explicit “Check previous send” invokes `invalidate()`, resets confirmation true→false, and accepts the fresh baseline. This later expected reset follows the passing immediate readback and correction/share assertions; it is not the original off-after-tap failure.

`audit/marker-lines.txt` preserves the validated marker text with original stdout line numbers; `markers.json` and `continuity.json` provide the compact parsed sequence. The second lifetime has no final disappear marker before test termination; no complete teardown-lifecycle capture is claimed. New state tokens show distinct diagnostic state storage in this instrumented run, not which SwiftUI ancestor established that storage. onChange can coalesce transitions, and logging/extra observations can perturb timing. A passing trace does not establish what happened in the original hosted execution.

## Separate speech warning

`audit/runtime-issues-separate.json` retains issue `82C528A1-D263-4337-814C-0AB7940662D6` assigned to `testShopperReviewsExactEditedCookWordingBeforeReadback`, with its **23 zero-address, unsymbolized source frames**. No runtime issue is assigned to the saved-copy case. The strict output and unavailable warning receipt are preserved exactly. No matching QoS signature in this exported app stdout does not negate the structured warning. This replay did not collect a new live OS Hang Risk stream; the original hosted six-record stack evidence remains separately retained. The exact hosted Pause symbolization and standalone control comparison are not silently reattributed to this new local issue.

## Audit correction and original preservation

The first root audit invocation refused `unable to open database file` because fresh xcresult had only Data/Info.plist and SQLite had not yet been materialized. It created no output directory. Its exact script, command-output refusal and receipt are preserved (`post-terminal-audit-v1.py`, `audit-execution-v1.log`, `audit-first-refusal.json`).

The corrected read-only audit hash-copied the original result first, ran summary/tests tools only on the inspection copy to materialize SQLite, then checked its finished actions and performed strict verification/capture. The original result's complete bounded file manifest was reverified unchanged. No SQLite file was created in the original. `audit/materialization-receipt.json` and `audit/audit-status.json` record that boundary. The original preparation documents and nested `sourcePins.status`/static-check fields describe their earlier uninstalled/uncompiled preparation snapshot; the current installed/native qualification is established by the terminal audit, not those historical labels.

## Release and privacy boundary

Root's separate generic unsigned Release build completed exit 0 and its built-app check passed. `release-trace-exclusion.json` pins all **three Mach-O executables** (app and embedded Share/Widget extensions) and reports no ASCII/UTF-16LE/UTF-16BE occurrence of either pack or cook trace marker/scope string. `release-boundary.json` pins the existing Release build log/command and app location. This is exclusion evidence for those literals in that product, not production-release readiness.

The trace is gated by DEBUG plus contributor fixture, existing UI/fixture arguments and an exact fixed selector scope. Markers contain monotonic time, PID, random diagnostic-only state token and Booleans; no recipient text, copy wording, business IDs, payloads or errors. Runtime warning records preserve their diagnostic description/frame fields separately. Full stdout, result bundles, derived data, binaries and full logs are excluded. Exact-copy origins/hashes are in `retention-manifest.json`; all retained files are covered by `file-hashes.json`. `privacy-review.json` records the compact text/URL review.

No additional native test, build, simulator action, source modification or commit was performed for this read-only audit and retention. The original hosted switch failure remains unresolved, and the strict runtime-warning gate remains failed/unavailable.
