import test from 'node:test';
import assert from 'node:assert/strict';
import { databaseConfiguration, deploymentClientAddress } from '../dist/runtime.js';

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

test('forwarded addresses are trusted only within the Vercel runtime and malformed metadata fails closed', () => {
  assert.equal(deploymentClientAddress({}), undefined);
  assert.equal(deploymentClientAddress({ VERCEL: 'true' }), undefined);
  const address = deploymentClientAddress({ VERCEL: '1' });
  assert.equal(address({ headers: { 'x-vercel-forwarded-for': '192.0.2.8' } }), '192.0.2.8');
  assert.equal(address({ headers: { 'x-vercel-forwarded-for': '2001:db8::1' } }), '2001:db8::1');
  for (const supplied of [undefined, 'invalid', '192.0.2.8, 192.0.2.9', ['192.0.2.8'], 'fe80::1%eth0']) {
    assert.equal(address({ headers: { 'x-vercel-forwarded-for': supplied, 'x-forwarded-for': '192.0.2.9', 'x-real-ip': '192.0.2.10' } }), undefined);
  }
});
