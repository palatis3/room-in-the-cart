# Shared recovery ordering — November 9, 2026

A real PostgreSQL/HTTP negative control reproduced a valid dinner repair returning
409 `meal_recovery_review_required`: household coverage and recovery assigned six
available portions to two four-portion dinners in different orders. Reversing the
occurrence order made the otherwise identical request pass.

The service now uses one consistent allocation order, preserving protected
portions, named reservations and existing connected-shop precedence. Within a
shop, known deadlines precede unknown ones, with stable reviewed need identities
breaking ties. The original UUID generation and strict projection verifier remain
unchanged. PostgreSQL's exact shop order is retained as an ordinal; no JavaScript
timestamp conversion can discard microseconds and reverse an existing commitment.

Validation on the final compiled source:

- 7 focused PostgreSQL/HTTP cases and 93 allocation/recovery cases pass.
- Fast service: 452 pass, one database-only skip (covered in integration).
- Full PostgreSQL/HTTP: 257 pass, three browser-only skips.
- TypeScript compilation and diff checks pass.

The HTTP cases cover distinct/equal/unknown deadlines, reversed occurrences,
three coverage routes, Apply and exact retries. Other regressions cover protected
portions, reservations, conservation, older-shop precedence, actual database
microseconds and exact-timestamp UUID ties. Existing cross-shop checks caught an
intermediate regression; review also reproduced the timestamp precision bug.
Both failures are retained with the original negative control. An intermediate
check overlapping compilation is excluded from final acceptance.

[Source and log hashes](verification.json) bind eight changed files and the
retained originals under `/Users/palatis/Room in the Cart/.build/SharedRecoveryOrderNov09/`.
The coordinator independently verified every listed digest and exact preservation
of the extracted UUID function. The disposable database is stopped and removed.
No migration, hosted deployment or new native acceptance is included.
