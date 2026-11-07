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
process.env.RITC_TEST_NATIVE_WIRE = '1';

const history = paid => `Swift household client records meals and price history over HTTPS and PostgreSQL (paid=${paid})`;
const cases = [
  history(false),
  history(true),
  'actual Swift planner proposal and separate shopper review travel over pinned loopback HTTPS and PostgreSQL',
  'real Swift adult proposal and separate shopper adoption use pinned loopback HTTPS and PostgreSQL',
];
const swiftRuns = [
  'history-free HouseholdClientTests.NativeServiceWireTests/testNativeClientAgainstPostgres',
  'history-paid HouseholdClientTests.NativeServiceWireTests/testNativeClientAgainstPostgres',
  'meal-planner HouseholdClientTests.SharedMealNativeWireTests/testSharedMealClientAgainstPostgres',
  'meal-shopper HouseholdClientTests.SharedMealNativeWireTests/testSharedMealClientAgainstPostgres',
  'meal-fallback HouseholdClientTests.SharedMealNativeWireTests/testSharedMealClientAgainstPostgres',
  'quote-adult HouseholdClientTests.StoreQuoteNativeWireTests/testStoreQuoteClientAgainstPostgres',
  'quote-shopper HouseholdClientTests.StoreQuoteNativeWireTests/testStoreQuoteClientAgainstPostgres',
];
const files = ['history', 'shared-meal-changes', 'shared-store-quotes']
  .map(name => fileURLToPath(new URL(`../tests/${name}.integration.mjs`, import.meta.url)));
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
      'Expected exactly four passing Node integration cases');
    assert.deepEqual(passed.sort(), cases.sort(), 'Unexpected, missing or skipped Node cases');
    assert.deepEqual(observedSwiftRuns.sort(), swiftRuns.sort(), 'Unexpected, missing or repeated Swift wire cases');
    console.log('Verified four Node integration cases and seven exact XCTest scenario results.');
  } finally {
    await fencePrivacyJournalFixture(admin, journal);
  }
} finally {
  await admin.end();
}
