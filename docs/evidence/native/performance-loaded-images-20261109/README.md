# Performance runner observation and build efficiency

The diagnostic runner now attaches a small, bounded post-measure image report to
the original scroll case. All three selectors, measured bodies, assertions and
limits are preserved byte-for-byte after reversing the explicit additions. The
optional collector's source pin was updated through the reviewed change; drift
still fails. Callback storage and code persist for the runner's lifetime because
dyld cannot unregister it. This is diagnostic instrumentation, not a baseline
configuration.

## Local verification

- Twenty synthetic parser controls pass after correcting a control helper's Swift
  access level; the original compiler failure is retained.
- Release build and bundle validation pass in 710.757 seconds. The compiled inventory
  contains exactly the original three performance selectors.
- Initial setup stopped before XCTest because the historical test app was still
  installed. Its complete app/data were preserved and verified before removing that
  installation from the owned simulator. No rebuild was required.
- The changed runner then passes the full scroll case, strict validation and the
  required metric validator. Five scroll-duration samples have median 2.581955166
  seconds; three memory series also have five samples. Hitches remain unavailable.
- Saved SQLite has 500 rows, 500 contributions, zero checkoffs and revision 3.
- The post-measure runner report completes within its limits: 1,130 callbacks,
  5,263,912 parsed bytes. Main Thread Checker UUID
  `E40A186A-8D7D-3029-B5CD-D42C967992C0` is observed once on arm64. RPAC has no match.
  This does not establish loading during measurement, initialization, AUT-process
  state or the cause of missing hosted measurements.

The first inspection's exact-tree check failed because `database.sqlite3` appeared
inside the result bundle during read/export inspection. Every original member kept
its exact bytes; no member changed or disappeared. Separate custody review records
the new 286,720-byte Xcode results database, its successful SQLite integrity check
and stable follow-up manifest. The original inspection receipt remains unchanged.
The precise writer/timing was not instrumented. No native rerun or result rewrite
was performed, and no shared validator was weakened.

## Remove unused architecture work

The existing hosted performance producer now uses `ARCHS=arm64 ONLY_ACTIVE_ARCH=YES`.
Its runner and consumer already require arm64. Project Release defaults, device
archives, consumer arguments, metric requirements and the five shared slots remain
unchanged. Two new controls execute the actual producer shell with a stub compiler
(success and exit-17 propagation) and verify arm64-only plan archive/restore identity.
All 95 targeted planner/provenance/capture controls, the final 433-test offline suite
and workflow lint pass.

The local diagnostic above used the prior dual-architecture command. The optimized
producer still needs its own frozen hosted qualification. No before/after timing
claim or new performance baseline is made. Hosted missing measurements and the
original minimum-iOS failure remain open; full combined regression and merge are
not approved.

[Exact source, samples, observation and original hashes](verification.json).
Originals remain under `.build/PerformanceLoadedImagesNov09/`; custody and failed
attempts are retained rather than duplicated into Git. The original source/helper
review and parser harness also remain there for reproducibility.
