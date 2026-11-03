# B11 browser suggestion retry evidence — 2026-11-03

Repository: `/Users/palatis/Room in the Cart`. Source hashes: `source-sha256.txt`.

Changed source:
- `web/src/api.ts`: frozen original intent/body, current session/grant/shop/actor checks, original-byte POST, typed receipt, own-status exact proposal/base/text/resolution validation. Status text matches the existing server trim contract; original input/POST bytes remain unchanged.
- `web/src/app.ts`: memory-only original envelope survives page Refresh/render, explicit uncertain/confirmed/status states, frozen original review, explicit fresh review after rejected stale base, no silent rebasing, generation/expiry/revocation fencing.
- `web/src/i18n.ts`: US English/Spanish state and memory-only notices. Human translation review remains a release gate.
- `web/tests/client.test.mjs`: ten additional regression tests, including response loss, refreshed revisions, stale/key-reused outcomes, actor/grant/shop/role changes, late and render-time expiry, status failures and normalization.
- `service/tests/helper-review.integration.mjs:111`: opt-in real web client/API wire test, `RITC_TEST_WEB_WIRE=1`.

Results:
- `ritc-b11-web-tests.log`: TypeScript/Vite build and full web suite, **61 passed, 0 failed, 0 skipped**.
- `ritc-b11-web-wire.log`: real PostgreSQL helper-review integration suite, **10 passed, 0 failed, 0 skipped**, including the actual compiled WebApp/API wire case.
- `ritc-b11-service-build.log`: service TypeScript build passed.
- `ritc-b11-web-migrate.log`: dedicated fixture migrations succeeded.
- `git diff --check` on all five changed source/test files passed.

Actual wire test uses real compiled WebApp+API, JSDOM rendering, same-origin credentials/CSRF semantics through a loopback HTTP transport adapter, real Node HTTP/BFF/auth/grant/command routes, and real local PostgreSQL under a non-owner runtime login. It drops the first successful proposal response only after actual server commit. Owner then replaces projection revision1→2. Page Refresh keeps original suggestion base1; retry bytes and client key are exactly identical, the original receipt is recovered, and SQL proves exactly one proposal with original base and service-defined normalized text. Subsequent explicit owner review is observed through the own-proposal endpoint. Revocation clears private content and blocks replay.

A fresh WebApp instance is also exercised: it has a blank local correction and sends no automatic duplicate. No helper text is written to browser storage because the existing service reports queueConsent=false. Consequently full tab/browser recreation does NOT restore a pending local suggestion, and receipt/status recovery after recreation is not claimed. UI explicitly warns that closing/reloading loses the local copy. This bounded fix resolves exact replay during the active page lifetime; durable browser draft recovery remains unsupported until separately authorized storage policy/capability exists.

This is **not** a deployed-service, supported-browser-engine, physical Android/iPhone, live email/provider, or production TLS acceptance run. JSDOM plus real API/database is stated explicitly; no remote provider/backend was used.

Disposable fixture: local Unix socket `/tmp`, port55432, database `ritc_b11_web_20261103`, role `ritc_b11_web_runtime` inheriting ritc_app. Both removed after evidence copied; existing cluster/roles/data preserved.

Reproduction (with independently created isolated fixture and both DB URLs explicitly set): build web, build service, create fixture auth.sessions, run service/scripts/migrate.mjs for that DB, then `RITC_TEST_WEB_WIRE=1 node --test tests/helper-review.integration.mjs` from service. The opt-in flag avoids requiring web/JSDOM in unrelated service-only runs.
