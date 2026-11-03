# Guardian backend local acceptance

The manifest pins the exact source and migrations exercised by the local suites. Each harness run creates and drops its own PostgreSQL database; separate runtime, verifier and worker logins enforce the real privilege boundaries. No real email, provider activation, deployment or provider deletion occurs.

- Focused: 29/29, including real HTTP/PG core, covered native/BFF signup, own-only requests, retries, revocation/reconsent, scheduled cleanup, worker erasure and deterministic races.
- Existing adult BFF/request/runtime-privacy regressions: 50/50.
- Dedicated operations regressions: 15/15.
- Service unit suite: 67 passed, one separately configured billing-PG fixture skipped.

The focused suite includes six KWS protocol tests. They exercise official token/send-email/HMAC contracts against fixture transport; live provider behavior is a release gate. Independent authority review/repro evidence is in the neighboring `guardian-authority-review` directory.

Reproduce with bundled Node 22.14 and `npm --prefix service run test:guardian`. Exact additional commands, source hashes and explicit limits are in `manifest.json`.
