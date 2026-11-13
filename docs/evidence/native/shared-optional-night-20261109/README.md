# Shared meals with an optional night — November 9, 2026

Foundation2.1 D04/B02/B10 allow a selected shared meal before its night is known.
The service and native client now encode that choice as an explicit null day;
a missing key remains invalid. New meal/idea editors start unscheduled, and later
scheduling preserves occurrence, ingredient, group and protected-allocation IDs.
A meal without a night cannot acquire a deadline. English/Spanish facts, cook
copies, recovery and captured-order details show the unknown schedule explicitly.
Dated payloads and exact sealed recovery provenance remain supported.

Original HTTP controls reproduced three422 failures. Final service checks pass:
3 focused HTTP,98 domain,454 fast (1 DB skip),260 integration (3 browser skips).
Native acceptance includes a successful ordinary Debug build,69 complete affected
model cases with strict validation,108 package passes (3 approved wire skips),
24 inventory checks and structural localization validation. Only two test files
changed after model acceptance; production native source stayed identical.

The two existing EN/ES civil-date journeys passed unchanged. The new editor
journeys initially failed because XCTest tapped the centre of the labelled switch
row, leaving it off, and then because a review marker was outside the rendered
form area. Retained video, synthesized-event coordinates and accessibility output
support those diagnoses. Tests now target the visible switch thumb, assert its
state and deadline availability, query the compact date control by identifier,
and reveal the review marker before checking its exact identity. Both complete
EN/ES optional-night journeys pass native and strict; assertions were strengthened,
not removed. These fixtures verify editing/review, not server persistence.

The real native HTTPS/PostgreSQL lane passes all7 Node scenarios and12 exact Swift
executions. Two separate Swift processes select a null-day meal, read it after
restart, schedule it, and retry the exact saved operation. Independent SQL checks
prove preserved protected Lunch2/Dinner4 bindings and snapshots, exactly two
committed patches despite four sends, and unchanged basket/quote facts. The owned
disposable database and private fixture state were stopped/removed by the original
wrapper; evidence uses a unique directory. No production data or providers were used.

No migration or hosted deployment. Older native String decoders cannot read null;
coordinate the service/native rollout. This is focused local evidence, not full
combined CI, a physical-device check, or App Store acceptance. The wire test proves
client-process reconstruction; iPhone UI relaunch acceptance remains distinct.
[Exact scope and retained evidence hashes](verification.json).
