# Created-meal Undo: native client and build checkpoint

The native client now represents a verified never-planned meal with explicit null before values, and the reviewed inverse removes the newly added meal. Missing required fields, prior tombstones, later revisions, and protected-meal removal remain invalid. The review has English/Spanish removal wording.

The package passed 149 tests, including four new creation tests, with three expected real-wire skips. A fresh full app/model/UI build-for-testing passed. These tests validate the meal component; they do not yet establish a full creation candidate, real-service outbox retry, or an English/Spanish creation UI journey. No model or UI tests were executed by build-for-testing.

[Verification](verification.json) records source and retained original log/result hashes. Historical six-journey results remain separately scoped.

A subsequent complete-action roundtrip test reproduced an encoder rejection of `meal: null`. The correction now passes the full 150-test client suite with three expected wire skips, including five creation tests. [Encoding regression](encoding-verification.json) preserves the original failure and corrected result. The subsequent r2 app/model/UI build-for-testing also passed with the encoder correction. It reused r1 DerivedData and preserved a separate result bundle; it did not execute model/UI tests. Real-service creation and full UI acceptance remain open.


## Creation UI qualification, November 10

Fresh Xcode 27.1 build from 627 frozen inputs passed on the owned iPhone 17 simulator, iOS 27.0. The new fixture model test and both complete English/Spanish creation Undo journeys passed with zero failures, skips or recorded runtime warnings. Each journey checks review, Cancel without a write, explicit meal removal, protected lunch/later meal/staple preservation, lost response, relaunch and exact durable retry: two POST attempts, one write. All 16 planner controls pass with the two new isolated selectors included.

Root independently checked all 627 canonical and archived inputs, 280 product entries and unchanged original model/EN/ES result bundles. Ten screenshots were exported from inspection clones. Six screenshots were visually reviewed; the Spanish surviving-meal summary has a crowded ingredient label/value and needs a layout correction. Functional success does not close that visual finding. English fixture meal titles and original quantity wording remain intentionally unchanged under Spanish localization.

[UI verification](ui-verification.json) pins the original results and screenshots under `.build/CreatedMealUIQualificationNov10/r2`. The synthetic HTTP fixture uses actual native screens and durable outbox; it is not authenticated real-service UI, human accessibility or full release acceptance. Separately, the [real Swift/service/database lane](../../service/created-meal-undo-20261110/native-wire-verification.json) passes 16 Node/50 Swift cases. No unchanged successful UI rerun is required until a relevant correction changes its inputs.
