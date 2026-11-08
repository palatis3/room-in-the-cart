# Shared retailer-confirmed order changes

An assigned adult shopper can review and record changes already confirmed by the retailer. Original checkout evidence remains visible beside the current confirmed order. Cancellation and replacement do not create physical arrivals, usable food, payments or refunds. A lost reply can recover the same confirmation after restarting the app.

The final local run passed 693 native model tests and the full cancellation/restart/retry walkthrough on iOS 17. The same walkthrough passed on iOS 26.2. Both strict checks recorded zero runtime warnings and zero skipped tests. The generic arm64 Release build and bundle checks passed, unsigned.

The real Swift-to-HTTPS/PostgreSQL run passed six Node integration cases and ten exact Swift scenarios. The client package passed 105 tests with three declared wire skips; the final reference-validation follow-up passed its four cases. Backend checks passed 443 unit tests and 242 PostgreSQL cases, with existing declared skips recorded separately. A populated 042 restore preserved 103 tables, 9,534 synthetic rows, 42 migration checksums and effective access policies. All 219 Python tooling tests passed.

The first UI attempt exposed an offscreen retry action after restart; pending recovery now appears above the history. New model regressions cover erased evidence, uncertain reads and switching shops. Earlier fixture and postcondition failures remain identified in the verification record; they are not relabeled as passes.

[Exact scopes, artifact hashes and source hashes](verification.json). [Backend restore and test evidence](backend/verification.json). [iOS 17 strict receipt](native-strict.txt). [iOS 26.2 strict receipt](modern-strict.txt).

Migration 042 and this service update remain local. The approved staging deployment is through 041. Hosted CI, signed distribution, physical-device checks, provider setup and human language review remain separate release gates.
