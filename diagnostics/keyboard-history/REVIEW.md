# One exact-product keyboard-history diagnostic

Diagnostic only; no release acceptance and no fix claim. This overlay is based on source169613bfabeb00355649f96d6bc88ad91064f708 (d0b0b12 plus opt-in event instrumentation), **without** the later Done geometry fix. The root reviewer owns branch/commit/push/dispatch. Nothing here dispatches a workflow.

## Hypothesis and scope

Original contributor-balanced-02 ran Spanish Contributor, English Contributor, two Measurement cases, then the failed stock changed-meal case and passing stock sibling. The Spanish case actually dismissed bilingual keyboard onboarding. The earlier exact169 diagnostic ran only changed-meal stock on a newly created simulator and passed. This proposal reconstructs the original six-case history once using the exact already-built169 products, on a fresh owned simulator. It keeps one runner invocation and records actual case order, onboarding observations, app PIDs, animation waits, and instrumented events.

A failure with events may distinguish missing Done entry, incomplete focus/keyboard transition, missing toggle setter, or a later reset. A pass is nonreproduction. The six-case prefix combines language/keyboard interaction, elapsed time, and app launches; it cannot by itself identify a particular causal predecessor. A fresh simulator also cannot reconstruct unknown original hosted-image state. The separate quote singleton failure remains unresolved and is **not selected** by this diagnostic.

## Overlay files and workflow

Apply only `.github/workflows/ios-fixtures.yml` and the six files in `diagnostics/keyboard-history/` from this proposal to the exact169 base. Keep all runtime and original test code unchanged. Supply the resulting full reviewed commit SHA as `expected_sha` when the root reviewer dispatches once. The harness rejects a different HEAD, dirty tracked checkout, changes outside this exact overlay allowlist, and workflow attempts other than1.

Workflow permissions are only `contents: read` and `actions: read`. `GH_TOKEN` is provided solely to artifact retrieval; no token is placed in command arguments or printed. The artifact redirect request has no Authorization header. The checkout does not persist credentials. No new API keys/secrets are needed.

1. `restore.py` fetches pinned source-run metadata and its artifact list; verifies repository IDs, source commit/branch, workflow/path/event, attempt1, completed/success state, names/IDs/sizes/digests/nonexpiry; downloads by fixed IDs; checks fixed ZIP hashes and bounded members before extraction. Live download fails closed if artifacts have expired. It never falls back to another run or rebuild.
2. Both ZIPs' every member is bounded/path/type/duplicate/CRC checked. Only required old evidence metadata and the one compiled selector plan are extracted; no prior xcresult/screenshots/media is copied to the outgoing evidence directory. Product TAR is verified by fixed SHA, then every archived product hash is matched against the original238-file manifest. Absolute/traversal/noncanonical paths, links, special files, duplicates, unknown extras, and unbounded entries fail. Exactly three known172-byte AppleDouble entries with fixed payload SHA are accepted and omitted. Restored file modes preserve executable bits without owner/setuid/xattrs.
3. The525-file original source manifest must exactly match169 Git objects, not current main. Every original runtime/script file in the diagnostic checkout also matches that manifest; only the workflow differs. The entire tracked checkout and all238 restored products are frozen for preflight/post-run verification. No xctestrun or executable is modified.
4. `prepare.sh` requires arm64, Xcode26.3/build17C529, and available iOS26.2/build23C54, then creates and boots one named/owned iPhone17. No global settings, keyboard defaults, installed devices, or quiescence settings are changed.
5. `run.sh execute` copies the original compiled-plan six selector bytes unchanged into arguments and calls xcodebuild exactly once with test-without-building, parallel testing NO, test timeouts YES, original720/900-second allowances, and diagnostics collection never. It exports the same `TEST_RUNNER_RITC_KEYBOARD_DIAGNOSTIC=1` opt-in used by the prior diagnostic. No enumeration/build/install pre-run, retry, extra test action, or test helper edit. The original40-minute test-step ceiling remains; the70-minute overall job only leaves bounded restore/boot/collection/cleanup/upload overhead.
6. Live Unified Logging runs during the one test invocation; the EXIT trap records liveness and stops the stream. The always-run collection step independently exports persisted events for the last55 minutes on this fresh simulator (a collection bound, not a test timeout change), records source/product/selector freeze, exports xcresult, and runs the unchanged original strict validator with expected6. Failures stay failures. Missing result/capture, different order, capture-set discrepancy, or changed inputs also fail the diagnostic without relabeling the underlying test result.
7. Cleanup validates the stored run ID, UUID, simulator name and runtime against current inventory, then shuts down/deletes only that owned device. The artifact contains only `.build/keyboard-history/`: this run's six-case xcresult/logs/events, metadata/hashes and observations. It does not include restored products, prior-run media, or Records media; Records tests are not selected.

## Pinned inputs

| Input | Fixed identity |
|---|---|
| Source repository | palatis3/room-in-the-cart, ID1445928007 |
| Source commit/run/attempt |169613bfabeb00355649f96d6bc88ad91064f708 /42176801822 /1 |
| Source workflow |407500252, `.github/workflows/ios-fixtures.yml` |
| Events artifact |13484227125, keyboard-events-1,1,020,752 bytes |
| Events ZIP SHA256 |8db6da6d34f0558a93b71e8e37bc5eaa4cc583fa4c899c81ba3b6101520a170d |
| Products artifact |13484396727, keyboard-products-1,51,830,824 bytes |
| Products ZIP SHA256 |9dc1a1a53b645f00a666c9f08f1286eced4ede0a45c19f91456ac9fe6845e545 |
| Inner product TAR SHA256 |a5c87f66347417d3ebafdec2b87d45c7c6b5eda3d9f5819298ad94147241e87f |
| Six-selector file SHA256 |beb687223139990138c7431da849b74459d1764fbc06c5977e17b29e17e2d3c4 |
| Restored products |238 files,194,257,759 bytes |

The selector file was independently compared byte-for-byte with the original d0 contributor-balanced-02 artifact during preparation; it matches. Restore additionally checks all six against the archived compiled manifest. Raw log order is checked after execution; the ordering assumption is not silently accepted.

## Review and offline validation

Preparation used only cached archives and Git object reads. Run the archive-only path with fresh scratch directories if needed:

```sh
python3 diagnostics/keyboard-history/restore.py \
  --local-cache /absolute/path/to/hosted-run42176801822 \
  --out /absolute/fresh/scratch/evidence \
  --work /absolute/fresh/scratch/inputs \
  --products /absolute/fresh/scratch/restored
```

This mode performs no network or native command and does not claim current runtime-source equivalence (`runtimeSourceUnchanged:false` because the current main checkout is deliberately ignored). It still checks the source artifact against all169 Git blobs and restores/verifies every product. The hosted path additionally enforces current diagnostic checkout identity and unchanged runtime source. No native simulator or XCTest validation was performed during proposal preparation.

Expected evidence is `restore-verification.json`, `identity.json`, `preflight-inputs-unchanged.json`, `frozen-inputs-unchanged.json`, `history-observations.json`, `parsed-events.json`, both raw event logs, `Tests.log`, `Tests.xcresult`, and strict/command/export exit files. Missing event evidence is inconclusive even if XCTest passes. Stream/export agreement is useful but cannot guarantee Unified Logging emitted every app event.
