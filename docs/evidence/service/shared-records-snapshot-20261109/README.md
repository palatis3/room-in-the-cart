# Shared Records current snapshot

The assigned shopper can read one authorized, atomic current-shop snapshot without changing domain records. It preserves the full food graph, exact quantities and original wording, accepted usable-pack basis, current basket and quote, meals, request quantity text and lineage. Unknown amounts remain unknown. Read time is separate from the stable content digest. Erasure clears old request words, quantity text, pack acknowledgment and affected digests; unrelated sources survive.

All **639 offline and 306 PostgreSQL tests pass**, including six new authenticated HTTP cases and the eight existing Undo cases. One offline database-only test and three optional browser scenarios are explicitly skipped. The tests verify authorization before content reads, a real concurrent write blocked by the household read lock, repeated reads without domain writes, existing server-only price refresh, and real worker-authorized erasure. The private test database stopped and the original journal harness fenced.

The first integrated offline run found scratch-only import paths in the new pure tests. Only those imports and the fixture path changed; the verified production build was reused for the successful run. Original failure evidence is preserved. [Verification and hashes](verification.json).

This endpoint is a current authorized read, not an export grant or recovery token. Portable shared Records UI, guardian-aware export authorization and lossless recovery remain unfinished. No staging deployment occurred.
