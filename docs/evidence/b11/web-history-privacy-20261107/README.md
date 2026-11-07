# Conceal private browser history until access is checked

A real Chromium Back navigation restored a contributor’s old request and draft while current access was delayed or revoked. The app now removes private DOM on pagehide and rechecks access before displaying a restored document. Unchanged authorized users retain their unsent draft; changed accounts lose the previous account’s draft. An expired sign-in exposes email/code recovery without a Refresh loop.

Root integrated and rehashed the reviewed sources and built bundle. **129/129 unit checks and 14/14 browser checks pass** (the browser total includes one parent, twelve history scenarios and the existing outbox case). Six eligible-history cases require actual same-document persisted restores. Six no-store controls used cold navigation and are not counted as BFCache passes. Real browser email/code actions recover the same actor’s draft and clear it for a changed actor. Only those explicit synthetic authentication actions write; history navigation sends no command.

The permanent regression runs in the existing web CI job, retaining its two-minute step limit and a 45-second test timeout. Root’s combined browser run took9.65seconds. All17workflow checker tests and the repository workflow validator pass. The validator retains its existing explicit treatment of14known actionlint queue-schema diagnostics; this is not a raw actionlint success claim. The first root test-loader command used an unsuitable module import path; its failure is retained alongside the successful canonical script invocation.

## Evidence and boundaries

`root-verification.json` binds integration. `REVIEW.md` and the original results preserve the reproduced BFCache failure and first proposed fix. `FOLLOWUP-REVIEW.md` records the subsequent401 recovery defect found during root review and its correction. The first candidate’s three new unit expectations and two persisted recovery scenarios fail; their original logs remain included. The two screenshots show the initial before/after concealment demonstration with synthetic data.

All43 original and11 corrected scratch evidence files were rehashed before this publication. Their manifests retain the complete local evidence inventory; this directory publishes the relevant subset. `freeze.json` hashes the published files. The implementation and permanent tests are in the repository itself.

This is local full Chrome158.0.8127.18, Playwright1.65.0 and synthetic loopback authority. Fixture HTML was either private,max-age=0 or no-store; API responses were no-store. It does not assert hosted cache policy, live identity-provider behavior, Safari/mobile/physical-device acceptance, server projection correctness beyond existing separate tests, complete S22 acceptance or full V1 readiness. No hosted deployment, database, provider, account or policy configuration changed.
