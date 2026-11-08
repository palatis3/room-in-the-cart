# Active Stop: controlled owner qualification

On November 8, the isolated speech r5 candidate compiled successfully and passed all 43 selected model and owner-transport tests, native 0 and strict 0. All 40 prior cases remain, with three additional tests. This candidate is **not installed in the canonical app** and does not resolve the recorded real speech warnings.

The change avoids querying native speaking/paused state when an admitted utterance has no matching terminal callback: the existing policy necessarily calls Stop in that situation. A false native Stop still blocks new playback until an explicit successful retry. Matched-terminal and unadmitted cases retain their idle-state checks. The delta covers Stop and shutdown without changing the initial Start checks, QoS, checker settings or logging.

The three added tests hold fake-engine state getters while exercising the production owner thread. They verify successful Stop without those reads, a failed Stop retaining the playback barrier, and matched-terminal Stop requiring observed idle. They do not measure actual AVFoundation latency or audible playback.

The exact 556-input candidate manifest is `d2f233f64af0540e77cd66b995c39bada71522bc9f8f6b4fab1ee2927e36c590`. Build ran 17:11:13–17:14:34 UTC; model execution ran 17:14:41–17:14:55 UTC on iOS 26.2/23C54 using Xcode 27.1. Strict inspection completed once at 17:15:13 UTC: 43 passed, zero skipped or failed, zero recorded runtime warnings, zero observed idle messages or runner restarts in the 133-line test log. These counts describe this test scope only.

Source, compiled products, build evidence and original result were unchanged at verification. The preceding r4 actual-app products, result and six receipts were cloned and verified before rebuilding. Its native 5/5 and strict failure remain preserved; see [actual-app evidence](../cook-thread-owner-actual-app-20261108/README.md) and [retained fault stacks](../cook-owner-fault-stacks-20261108/README.md).

`proposal/` holds the reviewed delta, selectors and source pins. `execution/` holds exact commands, guards, run receipts and strict results. The copied original preparation inventories intentionally refer to their private complete packages; `file-hashes.json` at this directory's root inventories this public subset. The build log review records remaining package sysroot and five test-declaration warning types. No warning suppression or test retry was used.

Actual API/framework wait diagnosis, English animation timeout, wider accessibility and full launch acceptance remain open. A separate bounded system-trace harness is being prepared; no r5 real-AV run or trace is claimed here.
