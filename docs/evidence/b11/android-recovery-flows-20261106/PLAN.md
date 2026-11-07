# Actual Android Chrome acceptance preparation

Prepared only. No browser/emulator connection, server launch, native operation, source edit, or hosted action was performed. Root owns emulator `5554` and its actual Chrome CDP endpoint `http://127.0.0.1:52889`; these are context, not an instruction to acquire another device/browser.

## Launch only when root is ready

From `/Users/palatis/Room in the Cart`, use the existing Node 22.23.4 binary:

```sh
.tools/node-v22.23.4-darwin-arm64/bin/node .build/AndroidBrowserAcceptance20261106/verify-pin.mjs
.tools/node-v22.23.4-darwin-arm64/bin/node .build/AndroidBrowserAcceptance20261106/server.mjs
```

The server binds **only `127.0.0.1`, port `0`**. Read its actual `port`, `origin`, and PID from the first JSON line or `ready-PID.json`. Root may then add one exact `adb -s emulator-5554 reverse tcp:PORT tcp:PORT` mapping and open that origin on the existing Android Chrome. Keep the server alive for all reload/browser-restart checks in that scenario. After testing, send `stop` on server stdin and remove only that exact reverse mapping. No fixed public port, wildcard bind, service proxy, external network API, or SMTP/provider call exists.

Use separate server launches/origins for independent scenarios. Adult fresh is default. `--prime-contributor`, `--prime-helper`, or `--prime-editor` seeds **one initial synthetic cookie session only**; cookie loss must not silently reauthenticate. `--child` delegates all child API behavior directly to committed `web/tests/fixtures/child-invitation.mjs`. `--child --unconfigured` preserves the provider-unavailable path. Server startup refuses any pinned source/module/bundle drift.

Actual current engine identity must be recorded from the root-owned Chrome connection/package provenance before claiming acceptance: expected installed Google Play Chrome is `156.0.8078.79` per root's observation. Record `navigator.userAgent`, `isSecureContext`, viewport, Android OS/device, and full browser version. Do not use desktop Chromium, a different channel, or a user-agent override as Android proof. An Android emulator run is not a physical-device run.

## Controls and evidence

Send one line to the fixture's stdin; output is a synthetic state/counter snapshot. No HTTP control endpoint is exposed.

| Command | Effect |
|---|---|
| `status` | Current counters and method/path/body SHA-256 events; no browser mutation |
| `mode offline-api` / `mode online` | Drop all API sockets / restore API; static app shell remains available |
| `mode offline-delete` | Drop DELETE before sign-out takes effect; other reads remain reachable |
| `mode revoked` | Deny scoped reads/operations; returns access-ended |
| `lose command` / `lose proposal` | Next accepted operation returns malformed JSON; receipt unconfirmed, one stored effect |
| `lose activation` | Next activation fails before effect; reuse existing redemption on explicit retry |
| `lose logout` | Sign-out takes effect, response lost; subsequent session read is anonymous |
| `rotate-csrf` | Rotate current synthetic identity authorization for sign-out recovery |
| `change-actor`, `change-grant`, `revoke-queue` | Fence private/pending data on a subsequent refresh or retry |
| `advance-view`, `expire-view` | Advance helper projection / expire access |
| `child approve`, `child withdraw`, `child generic`, `child wrong-scope` | Existing committed child-fixture controls |
| `child lose-claim`, `child lose-finish-cookie`, `child lose-finish-no-cookie-body` | Existing committed uncertain child response scenarios |

`observations-PID.json` retains API event digests and effect counts after each request/control. Capture visible page text, screenshots, user actions, origin, and counters before/after each step. Browser retries may produce duplicate POSTs; record actual counts, never infer a user retry solely from duplicated requests. `maxRequestsPerSocket=1` retains the committed browser-eviction safeguard. Only `lose command/proposal` guarantees a complete but unusable response body, avoiding conflating it with a wire disconnect.

`browser-probes.mjs` exports optional `describeBrowserState(page, origin)` and `evictOnlyFixtureOutbox(page, origin)`. Root supplies its existing actual-Chrome page. Both guard the exact task-owned loopback origin; neither automatically connects or navigates. The eviction probe deletes only `room-in-the-cart-own-outbox-v1`. It does not clear Google/Play cookies or other origins.

## Reviewed scenario matrix

| Scenario | Root actions | Required observed outcome |
|---|---|---|
| Fresh adult contributor invitation | New default origin; `/invite#token=fixture-contributor`; synthetic `adult@example.invalid`, code `123456`; explicitly attest adult review, join | Token removed from address/history before API/render; no request form before authenticated, reviewed redemption and exact scoped activation; one redeem effect; own-request UI only |
| Fresh helper invitation | New default origin; `/invite#token=fixture-helper`; same explicit synthetic sign-in/review | Exact grant activation; read-only “Reserve two for lunch”; no contributor form, proposal control, owner/admin/basket mutation |
| Primed contributor | `--prime-contributor`, `/requests`; enter fictional item/quantity, review, send | Review preserves wording/quantity; one command effect; own receipt/status visible; no external household data |
| Offline before command | Primed contributor; explicitly check save-pending consent; `mode offline-api`; review/send | Pending wording says waiting, never received; IndexedDB has one scoped command; zero command POSTs/effects; no queue without explicit consent |
| Reload/reconnect queued request | While API-offline reload the same origin; restore `mode online`, refresh | Offline cold page hides private queued wording. Fresh authorized load recovers same pending row without automatic send. Explicit Retry produces one effect and removes pending row |
| Browser restart | Preserve server and reverse mapping; root restarts only owned Chrome at a chosen checkpoint, then reconnects | Record actual cookie preservation. If session survives, fresh auth required before pending recovery; no automatic command. If cookie is lost, anonymous/sign-in screen and no private recovery. Do not prime again or change origins to manufacture recovery |
| Uncertain accepted own request | `lose command`; send; inspect count; repeat original Send request (memory-only) or pending Retry (with consent) | Same command body SHA/client key; one stored effect; no silent replacement; receipt recovery is explicit |
| IndexedDB eviction | Create a durable pending request with consent + `lose command`; verify pending row; invoke only-outbox eviction; Refresh | Pending copy and Retry disappear; notice says local pending copy lost; received own status may still show committed request; no additional command POST/effect. This is targeted deletion, not proof of spontaneous OS eviction |
| Actor/permission change | Queue own request, then `change-actor` or `revoke-queue`, explicit Retry/Refresh | Previous private wording removed/fenced; no command delivered as another actor or without queue authority |
| Primed read-only helper | `--prime-helper`, `/view`; reload; then `mode revoked` + Refresh | Projection limited to permitted instruction; no own-request route fallback; access-ended removes private projection |
| Editor suggestion scope | `--prime-editor`; draft suggestion; `lose proposal`; send; `advance-view`; explicitly Retry original suggestion | Original bytes/client key/base remain frozen; one proposal effect; current server status recovers. No basket mutation is implemented or claimed |
| Editor reload distinction | Reload after unsent draft; separately reload after server-accepted proposal | Unsent local draft is gone (memory-only). Current production UI may recover **received suggestions from the API** without local intent or new POST. This supersedes the narrower historical 2026-11-03 recovery limitation |
| Interrupted sign-out | Primed private screen; `mode offline-delete`; Sign out; reload; `rotate-csrf`, `mode online`; Retry sign-out | Immediate private clearing and only `ritc.sign-out.pending=1`; reload must not repopulate data. Retry uses current session/CSRF; confirmed logout clears marker. Loss-after-effect variant must not create an extra logout effect |
| Fresh child enrollment | `--child`, `/child-invite#token=TOKEN` from ready JSON; `child@example.invalid`, `123456`; claim; `child approve`; check status; Finish | Original committed pairing/claim logic, explicit fixture approval, exact scoped own-request handoff. Inspect counts; never label synthetic approval as live KWS/guardian authority |
| Primed child admission/cold page | Same child origin after pending/approved stage, reload; separately reload after successful scoped Finish | Pending/approved page cannot reconstruct in-memory pairing or create replacement POST. Active scoped cookie can recover own-request link; missing scoped cookie cannot infer authority |
| Child malformed Finish / wrong scope | Use committed `child lose-finish-no-cookie-body` or `child wrong-scope` before Finish | No own-request link or silent replacement Finish on cold reload; wrong household denied. `--child --unconfigured` displays unavailable setup, never successful enrollment |

Repeat visible key pages in English and Spanish using the existing language control. Root should also record real 360–412 CSS-pixel viewport layout, focus/keyboard behavior, tap targets, and horizontal overflow during actual interaction. Do not replace actual UI actions with DOM value mutations for the primary browser journey; the probes are supporting readback/fault injection only.

## Reuse, pinning and limits

- Child protocol is imported unchanged from the committed fixture. Adult adapter reuses production `validateOwnCommand`, current API/WebApp/Outbox in offline tests, and the retained WebOffline/BrowserSignOut fixture response/control patterns. No production implementation or backend is forked.
- `source-manifest.json` pins 53 current source/compiled/test inputs and the five frozen `bundle/` files. Frozen bundle matches `docs/evidence/b11/staging-rollout-20261106/web-build-manifest.json`; no build was executed. Source/compiled files are pinned independently, not claimed newly rebuilt.
- Session/auth, invitation redemption, command receipt, proposal storage, CSRF rotation and guardian approval are **synthetic**. `providerRevoked:true` is a fixture response, not live provider revocation proof. SMTP delivery, hosted auth, KWS, production TLS, PostgreSQL constraints, live membership authority, and provider activation remain deferred.
- API-offline mode leaves HTML/assets available so actual Chrome can cold-reload and exercise authorized recovery; it does not prove a fully network-offline app shell or PWA. The current app has no claimed service-worker offline shell. A separate actual radio/CDP disconnection should be labeled distinctly, with navigation failure recorded honestly.
- Fixture server state is memory-only. Keep it running for browser-restart checks; killing it is a fixture reset, not backend durability evidence. The child fixture only covers enrollment and empty own-request handoff, not child request CRUD/sign-out from the own-request page; use its child page for enrollment sign-out and the adult contributor lane for queue/sign-out acceptance.
- No listener or browser was opened during preparation. Syntax and in-process API/JSDOM tests do not establish Android success. Root must retain failures rather than relax expected counts, roles, persistence, or consent rules.
