# Canonical shared-food totals

Shared-demand reads now return `totals`, and previews return `beforeTotals` and
`afterTotals`. Each active line identifies its unit, exact reduced food quantity
or explicit unknown, and its active contribution IDs. The existing server
calculator remains the arithmetic authority. This lets native review show food
needs alongside whole packs without implementing another allocation engine.

Pack verification consumes the same batch of totals. It no longer revalidates the
entire graph separately for each basket line. Duplicate/within-existing rules,
exclusions, unknown acceptance and insufficient-pack rejection remain unchanged.
These are additive service fields, not a migration or hosted deployment.

An isolated TypeScript build and all 63 focused tests pass: 54 existing domain
cases plus nine summary cases. The original full PostgreSQL suite passes 281
cases, with three existing optional browser skips. Its disposable database is
stopped. Actual native decoding and HTTPS tests for the new fields remain part of
the pending Swift-client boundary; this checkpoint does not claim native UI or
combined-app acceptance.

In three same-process observations of a synthetic 50-line/500-source graph,
repeated per-line validation took 372–510 ms and batch calculation took 11–19 ms.
Results were identical and the input was unchanged. This is a computation
comparison, not endpoint latency, a production-capacity claim or an approved
performance baseline.

The retained first test invocation failed because isolated compiled output could
not resolve `zod`. A dependency symlink to the unchanged installed service modules
corrected that setup; no application source or build was repeated. Canonical
`service/dist` remains unchanged. [verification.json](verification.json) binds the
source and retained evidence under `.build/SharedDemandGraphNov09/`. Private
database and journal state is not included in public evidence.
