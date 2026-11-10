# Existing-meal operation Undo backend

The complete backend suite passes **650 offline tests and 315 PostgreSQL tests**, with one database-only offline skip and three optional browser skips. All eleven new pure meal controls and nine new real HTTP/database cases pass, together with the eight prior Undo and six Records cases. The owned PostgreSQL fixture stopped cleanly. [Verification](backend-verification.json).

Eligible recorded edits and skipped occurrences can be restored through one reviewed operation. Later untouched meal details, other meals, manual staples and protected reservations survive. Current revision/tombstone conflicts reject the whole operation. Accepted move/change proposals remain consumed; replay cannot restore erased private history or bypass current authority. Migration045 adds content-free immutable lineage; it does not backfill older events.

A fresh strict TypeScript build from the first attempt was reused only after exact production, dependency, tool and product verification. Two later changes corrected test setup: empty graph edits use review mode, and expired previews shift both timestamps while preserving their database constraint. Original failed attempts, logs and receipts remain intact. All251 execution inputs were unchanged through the successful full run.

This qualifies the backend slice only. Native meal Undo and actual Swift-to-service meal scenarios are in separate qualification. New-meal creation, first adoption, request acceptance, store inverses, inverse-of-inverse and historical events without lineage remain explicitly unsupported. Staging remains approved through041; local042–045 are not deployed.
