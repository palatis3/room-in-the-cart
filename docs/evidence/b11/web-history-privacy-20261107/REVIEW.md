# S22 companion-web history privacy regression

Confirmed bounded defect in the original exact web source pinned to `8d1a79b22981148839c6e3d0827c6710f877a369`: a real Chromium Back navigation restored the prior contributor document from BFCache (`pageshow.persisted=true`, same per-document UUID, visibility `visible`). Its previous actor's own request and unsent draft remained visible while changed/revoked authority was delayed; a failed API connection left that content visible after revocation. The synthetic fixture's budget, other-author, and private-note markers never entered any response, DOM, URL, or history.state. This is stale previously authorized content at a browser-history boundary, not evidence that the production service discloses forbidden projection fields.

## Exact scope

- Local headless Chrome for Testing 158.0.8127.18, Playwright 1.65.0 Chromium revision1254, ARM64 macOS. Official matching private download; new isolated context/profile per scenario; loopback server with an OS-assigned port. Default Playwright `--disable-back-forward-cache` was omitted. No user browser/profile, live authority, hosted service, native build, simulator or OS installation was used.
- Exact original Vite bundle `assets/index-DyqgPDmw.js` built from copied source. Fixed bundle and every source/build/test input are hashed in `source-manifest.json`; runtime executable hashes and launch options are in each `*-runtime.json`.
- Browser-eligible fixture HTML: `Cache-Control: private, max-age=0`; API: `Cache-Control: no-store`; neutral page: `Cache-Control: max-age=0`. The repository's `vercel.json` does not set an HTML Cache-Control value. This experiment does not assert any current hosted response headers or hosted BFCache behavior.
- Separate HTML `Cache-Control: no-store` lane is retained. Chromium declined BFCache with `response-cache-control-no-store` and `response-cache-control-no-store-with-js-network-request`. Its cold history navigation results are not a BFCache pass.
- The server stores synthetic own requests for A and B and an excluded third author, budget marker and private note. Its projection is deliberately narrow. Production server projection remains covered by the previously retained service tests, not this fixture.

## Regression and scratch fix

`history-browser.mjs` runs real Back → Forward → Back for unchanged, changed-delayed, revoked-delayed and revoked-offline scenarios. It keeps a server-side authentication promise unresolved while recording visible DOM, form value, URL, history.state, lifecycle events and screenshot. Actual response/payload/request records, including zero commands, are retained in result JSON. No route interception or emulated lifecycle events are used.

Original BFCache lane exits1 with the regression reproduced. Fixed lane exits0, observes BFCache in all4 scenarios and passes all assertions. The unchanged control recovers its own request and draft after fresh authority; changed authority clears the old draft; revoked/offline content stays concealed. The second Back is also checked. Every pending screenshot is synthetic.

Minimal proposed patch: `history-privacy.patch` modifies only `web/src/app.ts`, `web/src/main.ts`, and adds `web/tests/history-lifecycle.test.mjs`. It synchronously conceals private DOM on pagehide, requires successful reauthorization before revealing a restored document, and waits for any in-progress operation before revalidating. The same actor's unsent in-memory draft is preserved; ordinary non-history mutation recovery behavior is unchanged. Six lifecycle checks cover delayed authority, failure/recovery, changed actor, an in-flight load, and helper/editor revocation.

`fixed-web-tests-complete.log`:126/126 pass (existing120 +6). The earlier `fixed-web-tests.log` has118/120: two fixture-copy omissions (`vercel.json` and `config/public-contact.json`), corrected before the complete run. No production code failure is being hidden by the rerun.

## Limits and handoff

This closes the reproduced local Chromium BFCache defect with a proposed patch and bounded regression, not complete S22 acceptance, hosted/mobile/physical-device acceptance, or full V1 release readiness. The patch is only in scratch; root must review/install and bind retained evidence to the installed source. Plain no-store history traversal remains explicitly classified BFCache-unavailable.

Each runner closes its own browser/context and fixture server in finally. Profiles are Playwright-owned temporary profiles; downloaded matching browser and scratch evidence remain for reproduction. No existing `.build` evidence was changed.
