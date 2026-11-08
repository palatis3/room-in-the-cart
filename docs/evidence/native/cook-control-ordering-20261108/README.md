# Cook control ordering prototype · 2026-11-08

The frozen **R2 pure prototype passed all 12 XCTest methods**, exit0, with source unchanged in root’s recorded local SwiftPM execution. The package below is reproducible source/test evidence, not an installed app change. It makes **no claim of a hosted speech-warning fix, native pause/resume correctness, audible privacy or measured UI responsiveness**.

`prototype/file-hashes.json` SHA-256 is **`9e24726c0664b3abd7153e92a230080132c90b261d694efd43df076e7489ac30`**. All six entries match the frozen source. `execution/run.json` retains the exact command, source pin, timestamps and exit; `execution/native.log` preserves the small complete build/test output. Each of the 12 declared XCTest methods has one passing completion. The separate Swift Testing footer reports zero tests and does not replace that XCTest result. Root ran this once; this publisher did not build or rerun it.

## What the tests establish

The value-only command-admission reducer and MainActor coordinator are exercised with manually delivered preparation and command results. The tests cover held Pause then revocation/Stop ordering; discarding queued Resume; preventing replacement Start until successful Stop acknowledgment; failed Pause/Stop behavior without retry; stale-generation results and audio-lease identities; successful modeled Pause/Resume in the same generation; duplicate preparation callbacks; and duplicate/older command rejection.

The test named for background, VoiceOver, route and close uses manually changed authority plus explicit `stop()`/`close()`. It does **not** deliver real lifecycle, accessibility or audio-route notifications. A held result models delayed completion; it does not block a physical thread. “Immediate” revocation means a synchronous state transition in this model, not proof that native audio stops immediately.

## R1 defects corrected in R2

Repeated preparation completion in R1 could enqueue duplicate Start/Resume or release an active lease. R2 claims a preparation result once and preserves the active lease on duplicate delivery. R1’s sequence fields also did not reject duplicate/older commands; R2 validates admission and revocation sequence ordering. Three added regression methods cover those defects. `prototype/r1-to-r2.patch` and `r1-pins.json` preserve the exact revision boundary; R1 remains unchanged privately. This evidence does not claim a freshly executed R1 negative control.

## Remaining production requirements

There is no AVFoundation/AVAudioSession adapter, owner-thread implementation, thread-safe transport or natural speech end/cancel routing. The reducer explicitly needs independently serialized mutations if a future native owner call blocks. Neither true native pause/resume nor Stop preemption, acoustics, QoS behavior or main-loop latency is measured here.

Automatic close/deinit teardown is absent. A preparation completion after coordinator deallocation returns without releasing through that coordinator; a production transport must own lease teardown independently. The fake records lease identifiers, not real audio-session ownership. Repeat while speaking currently returns false instead of queuing the explicit request behind Stop, so existing app Repeat/readback requirements remain integration work. Result envelopes still carry the command/text; production completion events should carry operation identity only. Failed Stop remains stopping/unavailable, preventing replacement; this does not resolve the product UX for that native failure.

The scratch package uses Swift6 and macOS13+; the app declares Swift5 mode. Local compilation and MainActor XCTest discovery are now demonstrated, superseding only that historical uncertainty in the unchanged `prototype/REVIEW.md`. App/iOS integration and all real speech/lifecycle behavior remain unqualified. No warning gate was relaxed, warning count relabeled, canonical source changed or audit finding closed.

## Reproduction

Use the included `prototype/` as the package path and a new external scratch path so generated output does not alter this evidence. Equivalent command from the canonical repository (not executed by this publisher):

```sh
/usr/bin/xcrun swift test \
  --package-path 'docs/evidence/native/cook-control-ordering-20261108/prototype' \
  --scratch-path '.build/CookControlOrderingReproduction/build' \
  --jobs 2
```

The recorded execution’s exact absolute paths remain in its original receipt. `provenance.json` maps byte-identical originals; `manifest.json` covers this publication except itself. No binaries, caches, large native logs or app artifacts are included.
