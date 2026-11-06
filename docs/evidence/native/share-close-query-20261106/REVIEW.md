# UI10 system-share Close query — bounded independent review

**No concrete wrong-element, duplicate-match or hidden-Close query defect is supported by the retained evidence.** The failure establishes that the existence-and-hittability expectation did not complete within its original15-second allowance, before any Close tap. The log shows substantial accessibility-query latency; it does not establish the underlying app/system/XCTest cause or eventual successful readiness. No production fix, query rewrite, longer wait or changed gate is justified by this review.

## Actual hierarchy and query

The exact804 helper queries all app buttons with `identifier == "header.closeButton" OR label == "Close"`, then takes `firstMatch`. The current helper is byte-identical to the frozen804 helper; only the separate failure screenshot handling changed elsewhere.

The retained complete failure hierarchy contains **one matching Button** (line173): `header.closeButton`, label `Close`, frame `{{346.0,92.0},{36.0,36.0}}`. It belongs to `ActivityListView → ShareSheet.RemoteContainerView → UIActivityContentView` navigation bar. Both predicate clauses describe the same node; an OR predicate does not produce duplicate rows merely because both clauses match. No separate Close or Cerrar button appears in this hierarchy, and the sole matching node's frame lies inside the402×874 window. Thus the actual retained snapshot supplies no alternate first match or offscreen matching button to blame.

This is a late application-wide debug hierarchy, not the resolved query snapshot at every expectation poll. It does not expose hit testing or establish accessibility hittability. An earlier transient duplicate, stale query snapshot or other remote accessibility state cannot be ruled out, but none is demonstrated. The hierarchy's query chain describes the application root, not which node `close.firstMatch` resolved to during each poll.

## Timing and what remains unknown

- Share tap at187.60s; event synthesis187.81s; post-tap idle wait188.13s.
- First readiness-predicate evaluation190.58s, existence query190.59s, debug capture202.87s: approximately12.28s in that observable query/debug interval.
- Second evaluation203.59s, existence query203.59s, Find204.60s, debug capture204.79s, hierarchy requests204.80/206.12s, failure206.35s.
- No Close tap was reached. Subsequent cancellation-history, frozen-snapshot preservation and relaunch assertions were not exercised by this failed case.

The retained activities do not record separate true/false values for existence and hittability, nor the return time of each property call. The first long interval therefore cannot be labeled a proven false existence result, a proven hittability-only failure, a busy app loop or a specific system animation. Only two predicate evaluations are visible in the relevant interval; the test did not demonstrate15 seconds of rapid, repeated negative checks.

Both predicate activities name debug-description attachments with the same payload ID at202.87/204.79s. The initial review read only their metadata. The parent subsequently exported their one shared text payload from a fresh verified192-file result copy; the reviewer then read that250-byte text file without further extraction. It contains only the query chain: target application → Button descendants → identifier/label OR predicate → First Match. It contains no resolved node, attributes or existence/hittability Boolean values and therefore supplies no additional cause proof. The already-exported complete hierarchy remains the supported node-count evidence. The parent reported the original UI10 ZIP matched its retained hash and will preserve/recheck all192 original result files; this reviewer did not perform a new archive/extraction verification.

The earlier review's video observation reports a visible unobscured X, but the requested206.205s frame decoded at202.605s using an approximate recording origin. That is not a synchronous failure screenshot and pixels cannot establish XCTest hittability. The ordinary failure screenshot showed Settings after restoration. The later teardown-capture correction preserves future failure context earlier; it is not a causal fix or a new execution of this failure.

## Production presentation

Current `PickupHomeView.swift:390–456` creates a `UIActivityViewController` with the dated text, assigns its completion callback, and presents it through `.sheet(item: $sharing)`. The Share action first awaits recording `.shareOpened`, checks current access/snapshot/stock basis, then sets the presentation item. Completion records shareCompleted/shareCancelled. No custom Close control, altered hit area, custom presentation animation or competing app Close button is introduced in this path. The retained remote share hierarchy proves presentation occurred by that late observation; source/evidence do not locate a defect in these asynchronous boundaries.

The OR query is broad in principle, but replacing it with an identifier-only query would be speculative for this failure because the sole observed match already has the expected identifier. The source comment about remote elements surviving dismissal concerns the later dismissal checks, which this run never reached; it is not evidence of a stale duplicate before the first Close tap.

## Provenance and scope

Candidate804030e68473d022e72b464940061c01c611a0bd; core run42272379454 attempt1; UI10 artifact13539417665. Independently rehashed frozen test source, activity export, query timeline, failed-case raw log and complete hierarchy against the retained share-failure-inspection proof; all five match. Original hierarchy SHA256 `2398fbf92fb6e929a9982ecff7e9feecef9a8b35dd97a8a9762380d1826518ca`.

No raw Records media, browser, native tool, test run, network, Git or tracked-source change was used. This scratch report and its compact source/evidence hashes are the only writes. The5-pass/1-fail UI10 outcome, allowed warnings and implicit runner restart retain their original strict meaning.
