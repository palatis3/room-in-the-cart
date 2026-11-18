import test from 'node:test';
import assert from 'node:assert/strict';
import { createRemoteJWKSet, customFetch, exportJWK, generateKeyPair, SignJWT } from 'jose';
import { DenyIdentityVerifier, JWTIdentityVerifier } from '../dist/auth.js';
import { canonical, digest } from '../dist/database.js';

test('unconfigured authentication denies every identity', async () => {
  await assert.rejects(new DenyIdentityVerifier().verify('anything'), error => error.code === 'session_needed');
});

test('JWT configuration requires HTTPS and an explicit audience', () => {
  assert.throws(() => new JWTIdentityVerifier({ issuer: 'http://example.test', audience: 'a', jwksUrl: 'https://example.test/keys' }));
  assert.throws(() => new JWTIdentityVerifier({ issuer: 'https://example.test', audience: '', jwksUrl: 'https://example.test/keys' }));
});

test('a signing-key service outage is retryable with the same signed session', async () => {
  const issuer = 'https://identity.fixture.invalid';
  const config = { issuer, audience: 'authenticated', jwksUrl: issuer + '/keys' };
  const { publicKey, privateKey } = await generateKeyPair('ES256');
  const key = { ...await exportJWK(publicKey), kid: 'session-key' };
  const token = await new SignJWT({ session_id: 'current-session' })
    .setProtectedHeader({ alg: 'ES256', kid: key.kid }).setIssuer(issuer)
    .setAudience(config.audience).setSubject('member').setIssuedAt().setExpirationTime('1h').sign(privateKey);
  const responses = [
    () => { throw new TypeError('connection interrupted'); },
    () => new Response(null, { status: 503 }),
    () => Response.json({ keys: [key] }),
  ];
  const resolver = createRemoteJWKSet(new URL(config.jwksUrl), { [customFetch]: async () => responses.shift()() });
  const verifier = new JWTIdentityVerifier(config, resolver);
  for (let attempt = 0; attempt < 2; attempt++) {
    await assert.rejects(verifier.verify(token), error => error.status === 503 && error.code === 'login_unavailable');
  }
  assert.equal((await verifier.verify(token)).sessionId, 'current-session');
  const missingKey = createRemoteJWKSet(new URL(config.jwksUrl), { [customFetch]: async () => Response.json({ keys: [] }) });
  await assert.rejects(new JWTIdentityVerifier(config, missingKey).verify(token), error => error.status === 401);
});

test('canonical receipts bind all ordered array and scalar values independent of object key order', () => {
  assert.equal(digest({ b: 2, a: 1 }), digest({ a: 1, b: 2 }));
  assert.notEqual(digest({ quantity: null }), digest({ quantity: 0 }));
  assert.notEqual(digest([1, 2]), digest([2, 1]));
  assert.equal(canonical(new Date('2026-01-01T00:00:00Z')), '"2026-01-01T00:00:00.000Z"');
});
