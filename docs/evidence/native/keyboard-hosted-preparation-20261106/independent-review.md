# Corrected execution package — independent re-review

**Ready for the parent to install the isolated overlay. No remaining blocking finding in this bounded review.** The prior provenance finding reproduced below is resolved in this exact revised package. This is review approval, not a native dispatch, causal conclusion or release-acceptance result.

Reviewed immutable hashes:

| Artifact | SHA-256 |
|---|---|
| execution.patch | `1a2684776119a0f6ad7f11a3901e1d42310e39ca9174b8efe3a237f85644651f` |
| execution/manifest.json | `ec0fea4c51648a7498398687305ab00d7d072b1e97c318c93a6ab6ecfe628b3f` |
| execution/validation.json | `b2e9a01d3f985706bdeecfbb3084b16b30417d42f878440c0cfacaf8607e6fb7` |
| Instrumented PickupRepairView.swift | `afb8323925cc88ba1ec0d192d0488126b3dcc8b5e28fbcc3dc629796565add94` |

Independent rechecks: **73 mocked offline tests passed**; all **19 execution-manifest entries** and **29 original preparation entries** match; all **12** reused ownership/finalization/cleanup functions and private stop exception remain byte-identical to the retained 9e9b364 reference; six selectors still match the retained original UI07 plan. Package files were not modified.

The corrected provenance checker reads and hashes ownership and capture-window receipts using a bounded read and duplicate-key rejection. It validates their schemas, binds the command UUID to the owned UUID and command start to the recorded start, parses canonical UTC timestamps, and requires a nonnegative window no longer than 2700 seconds. Wrong devices/starts, malformed or impossible dates, reversed/overlong windows, missing/oversized/duplicate-key/invalid-schema receipts are covered by adverse tests. Failed verification yields unknown timezone/scope, not a positive provenance claim. The 45-second export command timeout remains distinct from the 45-minute maximum data window. A verified command/receipt remains evidence of the requested scope, not proof of exhaustive log delivery.

The parent explicitly authorized a product-transport-only size exception based on its local Debug dylib size of 52,752,832 bytes. Inspection confirms the exception applies only when the raw tar member name is exactly `Products/Debug-iphonesimulator/RoomInTheCart.app/RoomInTheCart.debug.dylib`, the member is a regular file and its size is **strictly less than 80,000,000 bytes**. Other members retain the exclusive 50,000,000-byte limit. Compressed size, total size, count and expansion ratio limits are unchanged. Existing extractor path/type/parent/symlink validation still runs before extraction. Tests reject >=80 MB, leading-dot/absolute/traversal aliases, alternate app/configuration/case/suffix paths, link/directory forms and any other member >=50 MB. The exception is used only by product-tar freeze/restore; neither original result archive policy nor artifact-download policy was broadened. Actual hosted products can still fail unchanged overall bounds; no additional growth is authorized.

The parent's generic arm64 Debug build success with 18 retained warnings was reported separately; this re-review did not execute or independently certify that build. The instrumented source hash matches the parent's stated source. Original diagnostic limitations remain: notification callback isolation at runtime, timing perturbation, incomplete live/persisted delivery, process attribution limits, missing whole launches/suffixes, and no automatic causal inference from silence or a passing diagnostic. No native/build/network/Git operation or extra agent was used here.

---

## Historical first review — finding now resolved above

# Independent execution-package review — 2026-11-06

**One actionable provenance finding should be corrected before freezing/installing this package. No additional native-execution, ownership, selector or failure-gate defect was found in this bounded review.** The finding affects what the derived report claims to have independently verified; it does not make the current harness generate a wrong device/window or allow a native failure to pass.

Reviewed execution patch SHA-256 `527f9602c8db139e665242825506d73831b5995521d408b3936598aadf6542e6`, associated manifest/validation/README, complete workflow and harness/reconciler, and the retained 9e9b364 reference. All execution-manifest hashes match. The previously reviewed one-file app instrumentation is unchanged.

## Finding: export scope verification accepts unowned devices and invalid/reversed windows

**P2 — `execution/overlay/diagnostics/keyboard-dismiss/hosted/reconcile_keyboard_logs.py:193–205`.** `capture_provenance` labels `exportCommandScopeVerified` true by checking UUID syntax and whether the start/end strings end in `+0000`. It does not read `owned-device.json` or `capture-window.json`, parse the dates, compare their order, or enforce a maximum window. Thus its positive scope claim does not establish the advertised owned-device/bounded-window provenance.

Independent offline probes supplied an otherwise exact successful export receipt:

1. Export UUID `11111111-1111-4111-8111-111111111111`, owned-device UUID `22222222-2222-4222-8222-222222222222`, and both dates `not-a-date+0000` produced `exportCommandScopeVerified=true`, `exportCommandPassed=true`, `exportWallTimeZone=UTC`.
2. A valid UTC start one minute later than its end also produced `exportCommandScopeVerified=true`.

These were temporary synthetic receipts, not native/log commands. The real harness presently generates a sensible device/window; this finding concerns independent readback accepting malformed or mismatched evidence. The inconclusive diagnostic status and native/strict gates remain intact.

Recommended correction: read/hash the ownership and capture-window receipts, bind export UUID and start to them, strictly parse UTC timestamps, require ordered dates and the already-authorized finite-window bound, and reject absent/mismatched receipts or malformed/out-of-bounds dates. Add adverse cases for wrong UUID, wrong start, invalid/reversed/overlong dates and missing receipts. Alternatively narrow the report field/documentation to command-shape/UTC-option observation and explicitly relinquish owned-device/window verification; the stronger intended provenance is preferable before the evidence package is frozen.

## Checks supporting the rest of the package

- **Source and workflow identity:** full expected SHA must equal HEAD and GITHUB_SHA; manual dispatch required. Every tracked file is compared against HEAD, and exact804 baseline plus overlay allowlist is enforced. Build and run snapshots must match. Pinned checkout/upload/download actions use read-only permissions; checkout disables retained credentials. The two leaf jobs share slot2, queue max/cancel false, with build finishing before run. No caller holds the slot while awaiting the child.
- **Build/selection:** effective ordinary Debug app conditions must equal DEBUG plus the diagnostic flag. Original xctestrun is preserved and hashed. One compiled enumeration must equal the complete retained ordinary plan; six UI07 selectors and order must match. No fixture substitution, additional UI actions, test retries or new runtime launch flag appears. Repeated execute refuses retained execution/capture evidence.
- **Ownership/shutdown:** independently compared AST source segments: all 12 named process-ownership/finalization/cleanup functions and the private `_CaptureStop` exception are byte-identical to 9e9b364. Identity checks precede signals; separate collect/cleanup callers do not claim to reap another parent's process. Parent17/child10-second deadlines, append-only receipts, finalization and escalation remain bounded. Simulator cleanup is limited to the recorded UUID/name/runtime.
- **Transport:** builder SHA256 passes through workflow outputs and is checked before extraction. Product/source manifests, original xctestrun and separate device identities are rechecked. The extractor rejects traversal, absolute paths, unsupported types/modes, duplicate paths, link parents and escaping symlinks before writing. Compressed/member/total/count/ratio bounds are retained. These are enclosed-tar checks; there is no additional artifact-envelope pre-download bound, as documentation states. Actual product size may fail the limits; no exception is authorized.
- **Native evidence:** original exit is retained in Tests.status.json; collection requires native zero plus exact804 strict checker, six identities/counts, actual runtime, start order without duplicate suppression, original/result-copy preservation and unchanged source/products. Diagnostic export/reconciliation cannot override a native/strict failure. xcresult inspection targets the verified copy. Existing runtime-warning checking remains delegated to the pinned strict checker.
- **Parser privacy and sequence handling:** only fixed event/enum fields, numeric sequence/uptime, validated timestamps and process IDs enter derived events. Malformed text is represented by line number, not echoed. Duplicate/conflicting sequence observations and input-order regressions are retained; large gaps are compact ranges. Reports always remain diagnostic-only/inconclusive. Equal scene observations are permitted and equal focus changes rejected. Live timezone remains unknown. Matching logs and clean finalization do not establish complete delivery or causality.

## Verification performed and limits

Ran all **68 mocked offline tests: passed** in the execution hosted directory using `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -p 'test_*.py' -v`. Ran independent read-only manifest/function comparisons and the synthetic provenance probes above. No package source was changed; this review is outside the execution manifest.

Whole-process omissions remain intrinsically possible. The parser supports optional expected PIDs, but the harness does not currently supply them, so its expected-process missing-data feature is not exercised by this execution path. Treat absent launches as unknown, as documented; do not infer all app launches were observed.

Capture/read/parser failure can leave nativeAndStrictPassed true when native/strict checks independently pass; that field is deliberately not diagnostic completeness. Reconciliation exit/status receipts must be reviewed separately. No compiler/native/build, Git, network, hosted/dispatch or extra-agent operation occurred. This review does not establish iOS integration, hosted admission, actual archive sizes, log delivery, runtime callback isolation, reproduction or a production fix.
