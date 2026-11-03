import test from 'node:test';
import assert from 'node:assert/strict';
import { databaseConfiguration } from '../dist/runtime.js';

test('remote database configuration verifies TLS even if URL requests disabled SSL', () => {
  const value = databaseConfiguration({ DATABASE_URL: 'postgresql://fixture:fixture@db.example/test?sslmode=disable&ssl=false', DATABASE_CA_PEM: 'fixture CA' });
  assert.equal(value.ssl.rejectUnauthorized, true);
  assert.equal(value.ssl.ca, 'fixture CA');
  assert.equal(new URL(value.connectionString).searchParams.has('sslmode'), false);
  assert.equal(new URL(value.connectionString).searchParams.has('ssl'), false);
});

test('only loopback fixture databases can run without TLS', () => {
  assert.equal(databaseConfiguration({ DATABASE_URL: 'postgresql://fixture@127.0.0.1/test' }).ssl, undefined);
  assert.equal(databaseConfiguration({ DATABASE_URL: 'postgresql://fixture@127.0.0.1.evil.example/test' }).ssl.rejectUnauthorized, true);
  assert.throws(() => databaseConfiguration({}));
  assert.throws(() => databaseConfiguration({ DATABASE_URL: 'http://db.example/test' }));
});
