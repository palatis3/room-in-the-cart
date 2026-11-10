# Created-meal Undo: native client and build checkpoint

The native client now represents a verified never-planned meal with explicit null before values, and the reviewed inverse removes the newly added meal. Missing required fields, prior tombstones, later revisions, and protected-meal removal remain invalid. The review has English/Spanish removal wording.

The package passed 149 tests, including four new creation tests, with three expected real-wire skips. A fresh full app/model/UI build-for-testing passed. These tests validate the meal component; they do not yet establish a full creation candidate, real-service outbox retry, or an English/Spanish creation UI journey. No model or UI tests were executed by build-for-testing.

[Verification](verification.json) records source and retained original log/result hashes. Historical six-journey results remain separately scoped.

A subsequent complete-action roundtrip test reproduced an encoder rejection of `meal: null`. The correction now passes the full 150-test client suite with three expected wire skips, including five creation tests. [Encoding regression](encoding-verification.json) preserves the original failure and corrected result. The subsequent r2 app/model/UI build-for-testing also passed with the encoder correction. It reused r1 DerivedData and preserved a separate result bundle; it did not execute model/UI tests. Real-service creation and full UI acceptance remain open.
