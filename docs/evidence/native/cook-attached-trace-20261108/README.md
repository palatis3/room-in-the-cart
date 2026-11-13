# Attached cook trace: native pass, strict failure, incomplete capture

The unchanged edited-cook UI case passed **1/1 in 60.621 s**, with real Play/Pause/Resume/Stop taps. Strict inspection returned **1**: the User-initiated runtime warning had no required `Complete Issue Description.txt` attachment. Two runtime-warning activities remain: User-initiated→Default and User-interactive→Default, at 18:03:14.768 and 18:03:14.859 UTC. Their timestamps fall after Play; they do not measure wait duration or identify a signaling thread. Explicit `on-failure` diagnostics did not make the required attachment available in this run. This is not a speech/QoS repair or release qualification.

The recorder attached to exact owned app PID 91693 after matching executable/debug-library hashes and observing the same PID/start-time/path twice. All 556 source files, qualified model proof, original fixture products and their preservation clone remained unchanged. The original test and privacy/authority gates were unchanged. [Native summary](native-summary.json), [strict result](strict.txt), [verification](native-verification.json), [warning metadata](warning-activities.json).

| Observation | UTC |
|---|---|
| Recorder launch |18:03:00.228558|
| Readiness notification observed |18:03:08.116050|
| Play tap activity |18:03:14.060|
| Pause tap activity |18:03:16.910|
| Resume tap activity |18:03:18.550|
| Stop tap activity |18:03:20.250|
| 4 GiB sampled volume-growth stop requested |18:03:21.798155|

The recorder stop request followed the four taps, so it was worth checking retained data. It did **not** establish actual recorded coverage. Recorder termination was forced after the 120 s finalization grace (then TERM/KILL), exit**-9**. Capture eligibility is false. Source/result preservation is separate from that failure. [Sanitized receipt](capture-receipt.json).

The observed trace grew to approximately 4.915 GB, but the final retained bundle contains only **137 files /12,387,518B**: `form.template`, `RunIssues.storedata`, a symbol manifest and 134 symbol archives. The previously observed raw member is absent; no `.atrc` or `.ktrace` remains inside this bundle. Final free space was 44,037,591,040 B. A smaller final directory is not evidence of successful compact storage or preserved event rows. No shared-service staging file was inspected or deleted, and shared collector quiescence is unproven. [Growth observations summary](growth-summary.json), [retained file hashes](retained-bundle-manifest.json).

There is no captured owner/main wait duration, waker, signaling stack or acoustic proof in this package. The prior all-process trace's successful raw import cannot substitute for this run: its retained interval ended before its own Play/Pause. Root executed the separately reviewed 60 s `.trace` TOC check once on a verified APFS clone. It returned native exit **10** / wrapper exit **2** after **1.777416 s**, with 0 stdout bytes and 66 stderr bytes: `Export failed: Trace is malformed; instrument run data is missing`. The original bundle, native result, source and capture/strict receipts remained unchanged. [Exact outcome and pins](retained-toc-outcome.json).

The retained instrument data is unavailable. No table, playback interval, wait-duration or waker claim can be derived from this capture. No raw fallback, retry or further recording was performed; template and symbol presence did not establish usable run data.

The native case-end→first observed xcodebuild-terminal interval was 30.429701 s, separate from recorder finalization. It includes diagnostics/result/runner cleanup and observation latency; it is not exclusive diagnostics-collection latency or a speech wait measurement.

Full native log/result, trace and observation stream remain preserved privately. This package publishes only compact outcomes, fixed action/identity metadata and hashes; it contains no speech text, screenshots, raw trace data or user-specific absolute paths. [Provenance](provenance.json). No canonical product edit, native execution, top-level status edit or commit was performed by the packaging agent.
