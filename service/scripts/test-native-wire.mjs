import assert from 'node:assert/strict';
import { run } from 'node:test';
import { tap } from 'node:test/reporters';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import pg from 'pg';
import { migrate } from './migrate.mjs';
import { fencePrivacyJournalFixture, preparePrivacyJournalFixture } from '../tests/privacy-journal-fixture.mjs';
import { nativeWirePassPrefix } from '../tests/run-native-wire-test.mjs';

const { RITC_NATIVE_WIRE_STATE: state, RITC_NATIVE_WIRE_PORT: port } = process.env;
assert.ok(state && /^\d+$/.test(port ?? '') && Number(port) > 0 && Number(port) <= 65535,
  'Use scripts/run_ios_native_wire.sh to provision an isolated local database');
const database = `127.0.0.1:${port}/ritc_native_wire`;
const adminURL = `postgresql://postgres:fixture-only@${database}`;
process.env.TEST_ADMIN_DATABASE_URL = adminURL;
process.env.TEST_DATABASE_URL = `postgresql://ritc_runtime:fixture-only@${database}`;
process.env.TEST_WORKER_DATABASE_URL = `postgresql://ritc_test_worker:fixture-only@${database}`;
process.env.RITC_TEST_NATIVE_WIRE = '1';

const history = paid => `Swift household client records meals and price history over HTTPS and PostgreSQL (paid=${paid})`;
const cases = [
  'assigned iPhone shopper carries a prior request and reprices it over pinned HTTPS',
  'assigned iPhone shopper confirms and corrects a placed request over pinned HTTPS',
  history(false),
  history(true),
  'actual Swift planner proposal and separate shopper review travel over pinned loopback HTTPS and PostgreSQL',
  'actual Swift undated selection survives process restart and schedules once over PostgreSQL',
  'actual Swift source removal preserves other meals and manual lines across authorized clients',
  'real Swift adult proposal and separate shopper adoption use pinned loopback HTTPS and PostgreSQL',
  'actual Swift shared demand preserves typed sources and exact durable operations over HTTPS and PostgreSQL',
  'actual Swift meal action catalog preserves Cancel, protected quantification, conversion reconfirmation and revoked proposal authority over HTTPS and PostgreSQL',
  'actual Swift complete operation Undo preserves durable replay, later facts and privacy authority over HTTPS and PostgreSQL',
  'actual Swift meal Undo preserves accepted change provenance and grouped protected bindings over HTTPS and PostgreSQL',
  'actual Swift meal Undo preserves accepted move provenance and grouped protected bindings over HTTPS and PostgreSQL',
  'actual Swift skipped meal Undo restores exact meals with lost reply restart retry and privacy authority over HTTPS and PostgreSQL',
  'actual Swift same-store Undo binds selected quote authority through Cancel lost reply retry revocation and erasure',
  'actual Swift created meal Undo removes only the new occurrence across Cancel lost reply retry and privacy authority',
  'actual Swift tracking adoption and first Undo preserve protected unknown facts through Cancel lost reply restart and same-ID rebind',
  'actual Swift tracking request uses explicit current preview revision and distinct frozen review before exact placement',
  'actual Swift tracking erasure preserves independent sources through recovery and refuses revoked shopper replay',
  'actual Swift request acceptance Undo preserves author quantity wording and exact replay across later acceptance generations',
  'actual Swift compound meal adoption Undo binds complete inverse and explicit overage consent through lost reply restart',
  'actual Swift partial store re-review preserves detached unknowns through Cancel lost reply and exact restart retry',
  'actual Swift partial meal fresh conversion keeps allocation through whole Undo Cancel lost reply and exact restart retry',
  'actual Swift protected transferred unit change keeps equivalent reviewed quantity detached from all supply',
];
const swiftRuns = [
  'deferred-request HouseholdClientTests.NativeServiceWireTests/testNativeClientAgainstPostgres',
  'purchase-author HouseholdClientTests.NativeServiceWireTests/testNativeClientAgainstPostgres',
  'request-purchase HouseholdClientTests.NativeServiceWireTests/testNativeClientAgainstPostgres',
  'history-free HouseholdClientTests.NativeServiceWireTests/testNativeClientAgainstPostgres',
  'history-paid HouseholdClientTests.NativeServiceWireTests/testNativeClientAgainstPostgres',
  'meal-planner HouseholdClientTests.SharedMealNativeWireTests/testSharedMealClientAgainstPostgres',
  'meal-shopper HouseholdClientTests.SharedMealNativeWireTests/testSharedMealClientAgainstPostgres',
  'meal-fallback HouseholdClientTests.SharedMealNativeWireTests/testSharedMealClientAgainstPostgres',
  'meal-undated-select HouseholdClientTests.SharedMealNativeWireTests/testSharedMealClientAgainstPostgres',
  'meal-undated-schedule HouseholdClientTests.SharedMealNativeWireTests/testSharedMealClientAgainstPostgres',
  'meal-removal-cancel HouseholdClientTests.SharedMealNativeWireTests/testSharedMealClientAgainstPostgres',
  'meal-removal-remove HouseholdClientTests.SharedMealNativeWireTests/testSharedMealClientAgainstPostgres',
  'meal-removal-read HouseholdClientTests.SharedMealNativeWireTests/testSharedMealClientAgainstPostgres',
  'quote-adult HouseholdClientTests.StoreQuoteNativeWireTests/testStoreQuoteClientAgainstPostgres',
  'quote-shopper HouseholdClientTests.StoreQuoteNativeWireTests/testStoreQuoteClientAgainstPostgres',
  'demand-adopt-cancel HouseholdClientTests.SharedMealNativeWireTests/testSharedMealClientAgainstPostgres',
  'demand-adopt-apply HouseholdClientTests.SharedMealNativeWireTests/testSharedMealClientAgainstPostgres',
  'demand-stale-device HouseholdClientTests.SharedMealNativeWireTests/testSharedMealClientAgainstPostgres',
  'demand-remove HouseholdClientTests.SharedMealNativeWireTests/testSharedMealClientAgainstPostgres',
  'demand-undo HouseholdClientTests.SharedMealNativeWireTests/testSharedMealClientAgainstPostgres',
  'demand-request HouseholdClientTests.SharedMealNativeWireTests/testSharedMealClientAgainstPostgres',
  'demand-denied HouseholdClientTests.SharedMealNativeWireTests/testSharedMealClientAgainstPostgres',
  'demand-privacy HouseholdClientTests.SharedMealNativeWireTests/testSharedMealClientAgainstPostgres',
  'demand-meal-catalog-cancel HouseholdClientTests.SharedMealNativeWireTests/testSharedMealClientAgainstPostgres',
  'demand-meal-protected-apply HouseholdClientTests.SharedMealNativeWireTests/testSharedMealClientAgainstPostgres',
  'demand-meal-proposal-revoked HouseholdClientTests.SharedMealNativeWireTests/testSharedMealClientAgainstPostgres',
  'demand-meal-conversion-apply HouseholdClientTests.SharedMealNativeWireTests/testSharedMealClientAgainstPostgres',
  'operation-undo-cancel HouseholdClientTests.SharedMealNativeWireTests/testSharedMealClientAgainstPostgres',
  'operation-undo-apply-lost HouseholdClientTests.SharedMealNativeWireTests/testSharedMealClientAgainstPostgres',
  'operation-undo-retry HouseholdClientTests.SharedMealNativeWireTests/testSharedMealClientAgainstPostgres',
  'operation-undo-stale HouseholdClientTests.SharedMealNativeWireTests/testSharedMealClientAgainstPostgres',
  'operation-undo-privacy HouseholdClientTests.SharedMealNativeWireTests/testSharedMealClientAgainstPostgres',
  'operation-undo-revoked HouseholdClientTests.SharedMealNativeWireTests/testSharedMealClientAgainstPostgres',
  'operation-undo-meal-change HouseholdClientTests.SharedMealNativeWireTests/testSharedMealClientAgainstPostgres',
  'operation-undo-meal-move HouseholdClientTests.SharedMealNativeWireTests/testSharedMealClientAgainstPostgres',
  'operation-undo-meal-skip-cancel HouseholdClientTests.SharedMealNativeWireTests/testSharedMealClientAgainstPostgres',
  'operation-undo-meal-skip-apply-lost HouseholdClientTests.SharedMealNativeWireTests/testSharedMealClientAgainstPostgres',
  'operation-undo-meal-skip-retry HouseholdClientTests.SharedMealNativeWireTests/testSharedMealClientAgainstPostgres',
  'operation-undo-meal-skip-privacy HouseholdClientTests.SharedMealNativeWireTests/testSharedMealClientAgainstPostgres',
  'operation-undo-meal-skip-revoked HouseholdClientTests.SharedMealNativeWireTests/testSharedMealClientAgainstPostgres',
  'operation-undo-store-cancel HouseholdClientTests.SharedMealNativeWireTests/testSharedMealClientAgainstPostgres',
  'operation-undo-store-apply-lost HouseholdClientTests.SharedMealNativeWireTests/testSharedMealClientAgainstPostgres',
  'operation-undo-store-retry HouseholdClientTests.SharedMealNativeWireTests/testSharedMealClientAgainstPostgres',
  'operation-undo-store-erased HouseholdClientTests.SharedMealNativeWireTests/testSharedMealClientAgainstPostgres',
  'operation-undo-store-revoked-apply HouseholdClientTests.SharedMealNativeWireTests/testSharedMealClientAgainstPostgres',
  'operation-undo-meal-create-cancel HouseholdClientTests.SharedMealNativeWireTests/testSharedMealClientAgainstPostgres',
  'operation-undo-meal-create-apply-lost HouseholdClientTests.SharedMealNativeWireTests/testSharedMealClientAgainstPostgres',
  'operation-undo-meal-create-retry HouseholdClientTests.SharedMealNativeWireTests/testSharedMealClientAgainstPostgres',
  'operation-undo-meal-create-privacy HouseholdClientTests.SharedMealNativeWireTests/testSharedMealClientAgainstPostgres',
  'operation-undo-meal-create-revoked HouseholdClientTests.SharedMealNativeWireTests/testSharedMealClientAgainstPostgres',

  'tracking-adopt-cancel HouseholdClientTests.SharedMealNativeWireTests/testSharedMealClientAgainstPostgres',
  'tracking-adopt-lost HouseholdClientTests.SharedMealNativeWireTests/testSharedMealClientAgainstPostgres',
  'tracking-adopt-retry HouseholdClientTests.SharedMealNativeWireTests/testSharedMealClientAgainstPostgres',
  'tracking-first-undo HouseholdClientTests.SharedMealNativeWireTests/testSharedMealClientAgainstPostgres',
  'tracking-rebind HouseholdClientTests.SharedMealNativeWireTests/testSharedMealClientAgainstPostgres',
  'tracking-request HouseholdClientTests.SharedMealNativeWireTests/testSharedMealClientAgainstPostgres',
  'tracking-freeze-place HouseholdClientTests.SharedMealNativeWireTests/testSharedMealClientAgainstPostgres',
  'tracking-privacy-adopt HouseholdClientTests.SharedMealNativeWireTests/testSharedMealClientAgainstPostgres',
  'tracking-recover HouseholdClientTests.SharedMealNativeWireTests/testSharedMealClientAgainstPostgres',
  'tracking-revoked HouseholdClientTests.SharedMealNativeWireTests/testSharedMealClientAgainstPostgres',
  'tracking-request-undo-accept HouseholdClientTests.SharedMealNativeWireTests/testSharedMealClientAgainstPostgres',
  'tracking-request-undo-cancel HouseholdClientTests.SharedMealNativeWireTests/testSharedMealClientAgainstPostgres',
  'tracking-request-undo-lost HouseholdClientTests.SharedMealNativeWireTests/testSharedMealClientAgainstPostgres',
  'tracking-request-undo-retry HouseholdClientTests.SharedMealNativeWireTests/testSharedMealClientAgainstPostgres',
  'tracking-request-undo-reaccept HouseholdClientTests.SharedMealNativeWireTests/testSharedMealClientAgainstPostgres',
  'tracking-request-undo-replay-after-reaccept HouseholdClientTests.SharedMealNativeWireTests/testSharedMealClientAgainstPostgres',
  'tracking-compound-adopt HouseholdClientTests.SharedMealNativeWireTests/testSharedMealClientAgainstPostgres',
  'tracking-compound-undo-cancel HouseholdClientTests.SharedMealNativeWireTests/testSharedMealClientAgainstPostgres',
  'tracking-compound-undo-lost HouseholdClientTests.SharedMealNativeWireTests/testSharedMealClientAgainstPostgres',
  'tracking-compound-undo-retry HouseholdClientTests.SharedMealNativeWireTests/testSharedMealClientAgainstPostgres',
  'tracking-partial-store-cancel HouseholdClientTests.SharedMealNativeWireTests/testSharedMealClientAgainstPostgres',
  'tracking-partial-store-lost HouseholdClientTests.SharedMealNativeWireTests/testSharedMealClientAgainstPostgres',
  'tracking-partial-store-retry HouseholdClientTests.SharedMealNativeWireTests/testSharedMealClientAgainstPostgres',
  'tracking-partial-meal-cancel HouseholdClientTests.SharedMealNativeWireTests/testSharedMealClientAgainstPostgres',
  'tracking-partial-meal-lost HouseholdClientTests.SharedMealNativeWireTests/testSharedMealClientAgainstPostgres',
  'tracking-partial-meal-retry HouseholdClientTests.SharedMealNativeWireTests/testSharedMealClientAgainstPostgres',
  'tracking-partial-meal-undo-cancel HouseholdClientTests.SharedMealNativeWireTests/testSharedMealClientAgainstPostgres',
  'tracking-partial-meal-undo-lost HouseholdClientTests.SharedMealNativeWireTests/testSharedMealClientAgainstPostgres',
  'tracking-partial-meal-undo-retry HouseholdClientTests.SharedMealNativeWireTests/testSharedMealClientAgainstPostgres',
  'tracking-partial-protected-apply HouseholdClientTests.SharedMealNativeWireTests/testSharedMealClientAgainstPostgres',
];
const files = ['history', 'shared-meal-changes', 'shared-store-quotes', 'service', 'shared-demand']
  .map(name => fileURLToPath(new URL(`../tests/${name}.integration.mjs`, import.meta.url)));
files.push(fileURLToPath(new URL('../tests/shared-operation-undo.wire.mjs', import.meta.url)));
files.push(fileURLToPath(new URL('../tests/shared-tracking.wire.mjs', import.meta.url)));
const admin = new pg.Client({ connectionString: adminURL });
await admin.connect();
try {
  await admin.query(`
    CREATE SCHEMA auth;
    CREATE TABLE auth.users(id uuid PRIMARY KEY, email text, email_confirmed_at timestamptz);
    CREATE TABLE auth.sessions(id uuid PRIMARY KEY, user_id uuid NOT NULL, not_after timestamptz);
  `);
  await migrate(adminURL);
  await admin.query(`
    CREATE ROLE ritc_runtime LOGIN PASSWORD 'fixture-only' NOSUPERUSER NOBYPASSRLS;
    GRANT ritc_app TO ritc_runtime;
    CREATE ROLE ritc_test_worker LOGIN PASSWORD 'fixture-only' NOSUPERUSER NOBYPASSRLS;
    GRANT ritc_worker TO ritc_test_worker;
  `);
  const journal = await preparePrivacyJournalFixture(admin, join(state, 'journal-fixture'), state);
  process.env.PRIVACY_JOURNAL_TEST_CONFIGURATION = journal;
  try {
    const tests = run({
      files,
      concurrency: 1,
      testNamePatterns: cases.map(name => new RegExp(`^${name.replace(/[.*+?^$${}()|[\]\\]/g, '\\$&')}$`)),
    });
    const passed = [], stdout = [];
    let summary;
    tests.on('test:pass', ({ name, skip, todo }) => { if (!skip && !todo) passed.push(name); });
    tests.on('test:stdout', ({ message }) => stdout.push(message));
    tests.on('test:summary', result => { if (!result.file) summary = result; });
    for await (const output of tests.compose(tap)) process.stdout.write(output);
    const observedSwiftRuns = stdout.join('').split(/\r?\n/)
      .filter(line => line.startsWith(nativeWirePassPrefix))
      .map(line => line.slice(nativeWirePassPrefix.length));
    assert.ok(summary?.success && summary.counts.tests === cases.length && summary.counts.passed === cases.length,
      'Expected every selected Node integration case to pass');
    assert.deepEqual(passed.sort(), cases.sort(), 'Unexpected, missing or skipped Node cases');
    assert.deepEqual(observedSwiftRuns.sort(), swiftRuns.sort(), 'Unexpected, missing or repeated Swift wire cases');
    console.log(`Verified ${cases.length} Node integration cases and ${swiftRuns.length} exact XCTest scenario results.`);
  } finally {
    await fencePrivacyJournalFixture(admin, journal);
  }
} finally {
  await admin.end();
}
