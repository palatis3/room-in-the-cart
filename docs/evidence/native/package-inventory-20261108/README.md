# Shared-order compiled test inventory

The pre-push audit found four new shared-order client tests absent from the reviewed SwiftPM inventory. The actual full HouseholdClient package run discovered108cases:105passed and the same3wire-fixture tests deliberately skipped. The original inventory rejects that compiled set; adding exactly the four reviewed identifiers makes the unchanged strict verifier pass. Other package inventories and skip policy are unchanged. Eight verifier unit tests pass.

[Exact proof and old-inventory rejection](verification.json). This updates the core and both sanitizer jobs’ required inventory; it does not claim new sanitizer results or weaken completeness checking.
