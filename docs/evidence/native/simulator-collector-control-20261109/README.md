# Standalone simulator collector — November 9, 2026

A small iOS Simulator helper now has verified Logging capture: readiness was
observed; the helper, tracer and table-of-contents exporter exited normally;
exported data contains exactly two boundary events and three ordered, matching
positive intervals from the bound helper and simulator. Thirteen offline negative
controls pass. Independent root review verifies original source/artifact hashes.

The first attempt exposed a supervisor identity error: Xcode's public `simctl`
path is a Bash launcher. The corrected supervisor verifies both launcher bytes
and its literal final executable, then binds the actual process without weakening
ownership checks. The second attempt reached recording and retained its events,
but exceeded the fifteen-second finalization window and required cleanup signals;
it remains unqualified. Its output was inspected without repeating the app test.

One subsequent control changed only that diagnostic's finalization allowance to
thirty seconds. It finished in 21.75 seconds overall, with a five-second recording
and no cleanup signals. The original failed receipts remain unchanged. This does
not change hosted or app performance budgets. The separate successful validation
receipt qualifies only this standalone simulator helper—not application capture,
hosted missing metrics, a performance baseline or release acceptance.

Before an app trace, bind the actual application process and relevant measurement
intervals; preserve original measurements and strict gates. Do not infer that a
successful helper collector fixes absent XCTest measurements.

[Exact retained-original hashes](verification.json). Raw results stay under
`.build/SimulatorSignpostControlNov09/`; no trace archive was added to Git.
