# Connected S27 service acceptance — 2026-11-03

Installed service code, migration 018, native wire contract, and API documentation replace the uninstalled archived draft described in `../checkpoints/connected-s27/README.md`. That archive remains historical evidence.

Verified with the repository's pinned Node 22.14.0 and local PostgreSQL 17.11 on loopback port 55432, isolated database `ritc_s27_wire`. The runtime role is `ritc_test_runtime`, inheriting `ritc_app`, with no superuser, table ownership, or RLS bypass. The dedicated suite also exercises the separate `ritc_test_worker` privacy role and a purely local provider fixture. `local-migrations.log` records the migration set applied to this isolated database, including 001–018 and the concurrently developed 019.

Passing evidence:

- `service-build.log`: complete TypeScript service compiles.
- `quote-math.tap`: 10/10 comparison cases pass.
- `postgres-http-native.tap`: 15/15 real PostgreSQL/authenticated HTTP cases pass, including actual Swift HouseholdClient calls through a pinned loopback HTTPS fixture.
- `budget-discovery-regression.tap`: the focused oldest-third-shop regression passes independently. An adult contributor with a cook link can discover their separate budget grant outside the two newest bootstrap candidates, select the oldest shop, and save a private comparison. Explicit cook-link scope remains restricted.
- `source-sha256.txt`: source hashes for migration, service module, and dedicated tests at this checkpoint.

The fixture proves the $38/$35 checkout, $0/$4 incremental trips, +18 minutes and unknown-trip $3 break-even behavior; it preserves partial/unknown values and withholds an unsupported winner. The native adult privately saves two pairs, explicitly proposes one, and the shopper sees only that submitted pair. The shopper adopts the selected West branch exactly once; old line prices and checkout charges become unknown.

Permission and state cases include Free adult budget scope independent of contribution, administration and meal roles; explicit cook-link denial even for a separately granted adult; tenant and cross-shop cursor isolation; children; member revocation; authority transfer; grant revocation/regrant; per-adult private proof pagination; frozen/placed read-only proof and draft-only basket actions; allowed post-freeze budget revocation; stale request previews; explicit basis-bound repricing before freeze; concurrent retries; a revoke/adopt race; SQL update/delete denial; and complete rollback when durable receipt insertion fails.

The matching-basis regression case saves a draft with unknown item prices and tax, then a fully priced but expired quote, preserving the freeze guard in both cases. A wrong basis token still fails without saving. Only a matching token with complete, known, unexpired pricing clears the guard and allows freeze.

The account deletion case uses the real PrivacyService acceptance route and leased worker. It removes a proposed and adopted adult-owned pair, all cascaded copies, grants and actor receipts. Invalidated old prices stay unknown. The remaining shopper can explicitly enter a fresh complete quote and freeze, using the retained content-free review revision; erasure cannot strand the draft or restore personal proof.

Reproduce from the repository root after creating an isolated local database and its fixture `auth.sessions` table (the test's `before` hook creates that table and applies migrations):

```sh
PATH="$PWD/.tools/node-v22.14.0-darwin-arm64/bin:$PATH" npm --prefix service run build
.tools/node-v22.14.0-darwin-arm64/bin/node --test service/tests/shared-store-quotes-math.test.mjs
TEST_ADMIN_DATABASE_URL='postgresql://palatis@localhost:55432/ritc_s27_wire?host=/tmp' \
TEST_DATABASE_URL='postgresql://ritc_test_runtime@localhost:55432/ritc_s27_wire?host=/tmp' \
RITC_TEST_NATIVE_WIRE=1 \
.tools/node-v22.14.0-darwin-arm64/bin/node --test service/tests/shared-store-quotes.integration.mjs
```

The integration test refuses non-loopback URLs and databases without the `ritc_` prefix. No deployment, external provider, live database migration, retailer action, location lookup or payment occurred. Host wire tests do not establish iPhone UI, VoiceOver, Dynamic Type or device-language acceptance; the native lane owns those checks.
