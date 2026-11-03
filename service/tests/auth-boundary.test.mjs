import test from 'node:test';
import assert from 'node:assert/strict';
import { DenyIdentityVerifier, JWTIdentityVerifier } from '../dist/auth.js';
import { canonical, digest } from '../dist/database.js';

test('unconfigured authentication denies every identity', async () => {
  await assert.rejects(new DenyIdentityVerifier().verify('anything'), error => error.code === 'session_needed');
});

test('JWT configuration requires HTTPS and an explicit audience', () => {
  assert.throws(() => new JWTIdentityVerifier({ issuer: 'http://example.test', audience: 'a', jwksUrl: 'https://example.test/keys' }));
  assert.throws(() => new JWTIdentityVerifier({ issuer: 'https://example.test', audience: '', jwksUrl: 'https://example.test/keys' }));
});

test('canonical receipts bind all ordered array and scalar values independent of object key order', () => {
  assert.equal(digest({ b: 2, a: 1 }), digest({ a: 1, b: 2 }));
  assert.notEqual(digest({ quantity: null }), digest({ quantity: 0 }));
  assert.notEqual(digest([1, 2]), digest([2, 1]));
  assert.equal(canonical(new Date('2026-01-01T00:00:00Z')), '"2026-01-01T00:00:00.000Z"');
});
