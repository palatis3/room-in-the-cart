# Shared tracking-state domain integration

The pure tracking-state contract and 38 regressions are installed in the service. Strict service TypeScript compilation passes. The full offline service suite passes 691 tests, with one expected database-only skip and zero failures. [Receipt](verification.json).

The contract partitions authoritative sources and basket rows into tracked and explicitly unbound facts, preserving exact protected-source identity, quantity, restrictions and used IDs. Complete first-adoption compensation reverses its assertions while retaining independent later facts. Partial state cannot be admitted to the old v1 client contract. Authority and evidence must come from trusted repository storage; these pure functions do not authorize a request.

Independent review found whole-row basket restoration incorrectly rejected a later untouched price edit. The added regression failed on r1 (37 passes, one failure) and all 38 pass after touched-field restoration. Undo now restores packs from 3 to 2 while preserving a later price change from 100 to 120. Touched-pack and target-added-row conflicts still reject. Original failures and frozen proposals remain under `.build/SharedDemandGraphNov09/mixed-adoption-domain-r1` and `mixed-adoption-domain-r2`.

This is an integrated domain layer only. No endpoint uses the new envelope yet. Database state/lineage, all reader/writer admission, privacy erasure and restore, exact operation replay, typed client and native review remain to implement and verify. No migration/deployment, full D08 acceptance or release qualification is claimed.
