# Existing-meal operation Undo backend

The complete backend suite passes **650 offline tests and 315 PostgreSQL tests**, with one database-only offline skip and three optional browser skips. All eleven new pure meal controls and nine new real HTTP/database cases pass, together with the eight prior Undo and six Records cases. The owned PostgreSQL fixture stopped cleanly. [Verification](backend-verification.json).

Eligible recorded edits and skipped occurrences can be restored through one reviewed operation. Later untouched meal details, other meals, manual staples and protected reservations survive. Current revision/tombstone conflicts reject the whole operation. Accepted move/change proposals remain consumed; replay cannot restore erased private history or bypass current authority. Migration045 adds content-free immutable lineage; it does not backfill older events.

A fresh strict TypeScript build from the first attempt was reused only after exact production, dependency, tool and product verification. Two later changes corrected test setup: empty graph edits use review mode, and expired previews shift both timestamps while preserving their database constraint. Original failed attempts, logs and receipts remain intact. All251 execution inputs were unchanged through the successful full run.

This qualifies the backend slice only. Actual Swift-to-service meal scenarios now pass the separate full wire lane; native model/UI qualification remains in progress. New-meal creation, first adoption, request acceptance, store inverses, inverse-of-inverse and historical events without lineage remain explicitly unsupported. Staging remains approved through041; local042–045 are not deployed.

## Real typed-client boundary

The expanded lane passes **14 Node integration cases and 40 exact Swift scenarios**, with no failures or skips. All original 11/33 cases remain. Added cases exercise accepted change/move provenance, protected grouped ingredient bindings, skipped-dinner Cancel, lost reply, a separate-process exact retry, privacy erasure and revoked authority. The database stopped and successful private fixture state was removed. [Wire proof](native-wire-verification.json).

Independent preparation found and corrected a strict Undo DTO roundtrip mismatch for mixed-letter nested UUIDs. Only strict Undo response/action encoding now emits canonical identifier spelling; user text and the existing command/outbox bytes remain unchanged. The real wire run verifies the corrected encoding, complete mealEdit and exact retry. The dedicated package regression is qualified separately.

The first wire attempt retained 12 passing Node cases and 37 passing Swift phases. Two new Node assertions assumed construction order for rows that the service stores by stable identity/update order. The correction still compares every field and rejects duplicate IDs, while asserting meaningful graph line order and nested meal order separately. Three later phases were explicitly unexecuted then; the final full 14/40 run executed them.
