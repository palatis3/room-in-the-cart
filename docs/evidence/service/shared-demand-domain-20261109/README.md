# Shared-demand domain groundwork — November 9, 2026

Added versioned shared-demand contracts and a pure reducer separating typed food quantities from priced packs. Manual, import, request, meal and protected-reservation sources retain their original wording and identities. Explicit duplicate and within-existing links conserve finite supply; removal and receipt-bound Undo preserve unrelated additions. Unknown conversions stay unresolved.

Focused review corrected aggregate exclusions across three sources, conflicting conversion bases, missing request provenance, partial links converging on a surviving duplicate, and temporary-sum overflow before allocation subtraction. Timestamped confirmation is required for ingredient-specific conversions.

The full TypeScript service compiles into isolated output, and all **50 focused Node tests pass**, with zero failures or skips. Root reviewed the source, regression cases and exact source/log hashes. Existing `npm test` discovers the new test file; no additional CI job is required. The agent's before/after inventory reports canonical compiled service output unchanged.

This is groundwork, not completed shared F01/F02 behavior. Database/API persistence, authorization, atomic replay, package projection, native review and Apply/Undo, protected transfer, existing writers, privacy and original cross-client acceptance remain required. Nothing was migrated or deployed.

[Verification and retained originals](verification.json) bind the six source files and local build/test evidence. Earlier failed build/test logs remain in `.build/SharedDemandGraphNov09/domain-r1/`; no successful result replaces them.
