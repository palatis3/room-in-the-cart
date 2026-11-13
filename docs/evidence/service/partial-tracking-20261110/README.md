# Partial tracking backend qualification

November 10, 2026. Fresh strict TypeScript build, 979 offline passes (one database-only skip), and 412 PostgreSQL passes (three existing browser-only skips). All 18 new HTTP scenarios pass. The original seven failed cases now pass on the same successor. Root independently checked 300 current/executed source inputs, phase log hashes, exact scenarios and signed restore evidence. See [verification](verification.json).

This adds partial-state store price review, authoritative meal-action sources, explicit edits to transferred commitments, full before/after meal disclosures, and whole-meal Undo with immutable history and privacy/replay checks. A genuinely older V1 snapshot receives a transactional before-state capture for a new operation; historical snapshots are not rewritten.

The first integration run found that internal store adoption still required complete V1 food coverage. The corrected price-only path authenticates the current V2 partition, preserves food identities and keeps checkout blocked for a separate store review. Eight focused checks cover the allowed reset and rejected pack/name/identity/meal, review-required, stale-price and corrupt-state changes. Ordinary V1 admission remains fenced. The forged-origin regression now checks the established 422 `source_identity_changed` response rather than expecting 409; mutation remains rejected.

The original failed run and its private fixture remain in `.build/SharedDemandGraphNov09/root-partial-backend-r1`. The successful successor is `root-partial-backend-r2`; PostgreSQL is stopped. Original migration/restricted-role/restore harnesses were retained. The signed 048 restore and authorized erasure replay passed with runtime quarantined.

This is backend evidence only. The matching Swift client, new screens, real native wire scenarios and combined CI still need qualification. No staging deployment or release is claimed; existing approval extends through migration 041.
