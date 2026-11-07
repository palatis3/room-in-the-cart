# Permanent browser regression and 401 recovery follow-up

The original lifecycle proposal remains retained as `history-privacy.patch` with its original126-test/four-scenario results. Root review identified a real recovery regression: after BFCache return, `/v1/session`401 clears the private projection and loads available browser auth, but the v1 history gate continued to render only Refresh. A retained scope cookie can keep returning401 indefinitely, making sign-in inaccessible.

The production path is explicit: `service/src/http.ts:115–118` catches browser `session_needed`, then still resolves an existing household cookie; `service/src/repository.ts:493` throws401 for a browser-bound session without fresh identity. `service/tests/browser-auth.integration.mjs:86` already asserts scope-only `/v1/session`401. It is not safe to assume every expired identity yields200 `{authenticated:false}`.

`history-privacy-401-followup.patch` is the minimal delta from v1 already installed by root. It releases concealment after401 clears the private projection and authState finishes, provided another pagehide did not occur during that await. The public sign-in shell can then handle email/code recovery even though verification calls load() inside a mutation run. Private content stays absent until a fresh session authorizes it. `history-privacy-corrected.patch` is the complete alternative from the original source; apply only one route, not both.

Reproduction and validation:

- `candidate-401-recovery-negative.log`: all3 new401 expectations fail against v1 (immediate login, same-actor recovery, changed-actor recovery).
- `corrected-web-tests-recovery.log`:129/129 pass (existing120 + original6 lifecycle +3 new401 checks).
- `permanent-fixed-recovery-browser.log`: the two actual persisted401 recovery cases fail on v1; the other10 subcases pass. Parent test failure adds one to Node's failed-test total.
- `permanent-corrected-recovery-browser.log`:12/12 subcases pass,13/13 including the parent, about12seconds locally. Six cases observe real same-document `pageshow.persisted=true`; the no-store controls report cold navigation/BFCache unavailable. After401 the real browser submits synthetic email and123456, then checks the same actor's draft survives or the changed actor's draft is cleared. This is synthetic authorization, not live provider or production account switching acceptance.
- `history-mutation-review.log`:3 additional review probes pass for an explicit send already in flight when history suspension occurs, expired identity concealment, and cook grant expiry while away. The send remained single and no private content reappeared after revocation. The old identity probe deliberately described the extra-Refresh behavior; it is superseded for recovery acceptance by the new failing/passing tests.

## Permanent integration

`permanent-browser-regression.patch` contains:

1. `web/tests/browser/history-privacy.test.mjs`: private local fixture and new profile per subcase; original four cases plus same/changed actor401 recovery; genuine Back → Forward → Back; actual persisted-event guard; no route interception or invented lifecycle events. Eligible HTML must actually use BFCache or the test fails with navigation reasons. The no-store lane names its observed mode and never substitutes a cold reload for a BFCache pass. Only explicit synthetic email/code actions may write; history traversal cannot send commands.
2. `web/package.json`: include this file alongside existing outbox-eviction in `test:browser`, sequentially, retaining45second per-file timeout.
3. `.github/workflows/ci.yml`: rename the existing browser step to match its broader check. Same web matrix job, same2minute step timeout, no new job or browser installation step.

The existing convention is full Chrome via `channel:'chrome'`, optionally `CHROME_BIN`. The regression removes Playwright's default `--disable-back-forward-cache` flag. Full headless Chrome158.0.8127.18/Playwright1.65.0 is tested locally; other runner versions must demonstrate persisted restoration. An unsupported browser is a visible failure, not a skipped/passing privacy check. No browser download occurs in the test. The already-installed CI Chrome is reused. If CI lacks compatible BFCache support, investigate that capability and retain the failure rather than weakening the guard.

`corrected-source-manifest.json` binds corrected sources, bundle and production401 contract sources. Original manifests/evidence remain separate. Scope remains local Chromium and synthetic authority, not hosted/physical-device/full S22/full V1 release acceptance.

Final combined command verification: `corrected-combined-browser.log` runs the proposed unchanged2-minute CI step command locally:14/14 pass (outbox + parent +12 history subcases), exit0, about13seconds.
