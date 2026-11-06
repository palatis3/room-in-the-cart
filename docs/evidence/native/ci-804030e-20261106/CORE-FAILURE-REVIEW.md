# Current candidate native failures

Candidate `804030e`, core run42272379454 attempt1, has two executed failures. All ten native UI groups acquired a runner; UI07 remains collecting. Of the45 cases with evidence so far,43 passed and2 failed. No manual retry or timeout change was made.

The saved-offer deadline-reminder journey in UI06 exceeded its original720-second allowance after ten approximately60-second XCTest animation-completion waits. The first starts after the Done tap at126.40seconds. Other UI06 cases, including the previous candidate’s largest-text failure, pass. That pass does not establish a fix for the recurring synchronization problem. Runtime warnings are zero; the implicit XCTest runner restart remains a strict lifecycle failure.

The Reduce Motion share-cancellation journey in UI10 failed before any Close tap because the Close existence-and-hittability predicate did not become ready within15seconds. Root viewed the extracted video frame: the system share sheet and unobscured Close X are visible. The requested failure-relative206.205-second frame actually decodes at202.605seconds, using the recording attachment timestamp as only an approximate origin. This is not a synchronous failure screenshot. Pixels and the hierarchy cannot establish XCTest hittability. The ordinary teardown screenshot instead shows Settings and is not evidence of the share sheet at failure.

The share tap occurs at187.60seconds, the first predicate evaluation at190.58, a delayed existence/debug query at202.87, another check203.59 and the failed assertion206.35. The existing15-second bound is preserved. Root verified every file hash in the agent’s inspection proof and reviewed production UIActivityViewController presentation and the actual test helper; no causal production fix is established. UI10 otherwise passes5cases with2existing allowed warnings. The implicit runner restart remains recorded.

Original archives remain retained. The agent verified all209 UI10 extracted members against its ZIP; inspection operated on a fresh result copy. Root independently verified all listed inspection outputs, including the case video, exported frames, query details and hierarchy. No raw Records media was accessed. This evidence is failure analysis, not release acceptance.

[Failure details](core-native-failures.json), [media provenance](share-failure-inspection.json), [query timeline](share-close-query-timeline.json), [sampled pre-failure frame](share-pre-failure-frame.png).

## Follow-up screenshot correction (not covered by this run)

The Reduce Motion test now captures a failed screen inside its teardown block before restoring the system setting. XCTest runs teardown blocks before `tearDownWithError`, which previously captured Settings after restoration. The new capture is failure-only; test actions, assertions, waits, system-setting restoration and pass criteria stay unchanged. The complete FreeJourneyUITests file passes standalone iPhone-simulator type checking with the actual XCTest Swift overlay and zero diagnostics under local Xcode27.1. A weak capture is promoted to an immutable local before crossing into MainActor, avoiding a new concurrency warning. This is not a full target build. [Type-check scope](failure-capture-typecheck.json). No native execution of this follow-up has occurred, and it is not a fix for the Close-readiness failure.

## Saved-offer recording limitation

The failed UI06 recording is a60-byte pending-attachment error, not decodable video. Adjacent retained accessibility snapshots have empty application roots. Neither can establish whether the keyboard hid, which field held focus, or whether the interface kept animating. Root verified all inspection-output hashes; the original ZIP/extraction remains preserved. [Recording and snapshot provenance](saved-offer-recording-inspection.json).
