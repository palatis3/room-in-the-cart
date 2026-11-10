import test, {before, after, mock} from 'node:test';
import assert from 'node:assert/strict';
import {randomUUID, randomBytes} from 'node:crypto';
import pg from 'pg';
import {generateKeyPair, exportJWK, createLocalJWKSet, SignJWT} from 'jose';
import {createRuntime} from '../dist/runtime.js';
import {JWTIdentityVerifier} from '../dist/auth.js';
import {tokenHash} from '../dist/database.js';

const admin = new pg.Pool({connectionString: process.env.TEST_ADMIN_DATABASE_URL});
const issuer = 'https://runtime-privacy.fixture.invalid', audience = 'authenticated';
const {publicKey, privateKey} = await generateKeyPair('ES256'), jwk = await exportJWK(publicKey);
jwk.kid = 'runtime-privacy';
// Only remote JWKS retrieval is replaced. Tokens still undergo the production
// JOSE signature/claims checks, and runtime Supabase session checks use real SQL.
const fixtureVerifier = new JWTIdentityVerifier({issuer, audience, jwksUrl: issuer + '/jwks'}, createLocalJWKSet({keys: [jwk]}));
const verifyFixtureToken = fixtureVerifier.verify.bind(fixtureVerifier);
let runtime, origin;
before(async () => {
  mock.method(JWTIdentityVerifier.prototype, 'verify', verifyFixtureToken);
  runtime = await createRuntime({DATABASE_URL: process.env.TEST_DATABASE_URL,
    JWT_ISSUER: issuer, JWT_AUDIENCE: audience, JWT_JWKS_URL: issuer + '/jwks'});
  await new Promise(resolve => runtime.server.listen(0, '127.0.0.1', resolve));
  origin = 'http://127.0.0.1:' + runtime.server.address().port;
});
after(async () => {
  if (runtime) { await new Promise(resolve => runtime.server.close(resolve)); await runtime.pool.end(); }
  await admin.end(); mock.restoreAll();
});
async function actor(age = 0) {
  const subject = randomUUID(), session = randomUUID();
  await admin.query('INSERT INTO auth.sessions(id,user_id) VALUES($1,$2)', [session, subject]);
  const token = await new SignJWT({session_id: session, amr: [{method: 'otp', timestamp: Math.floor(Date.now() / 1000) - age}]})
    .setProtectedHeader({alg: 'ES256', kid: jwk.kid}).setIssuer(issuer).setSubject(subject).setAudience(audience)
    .setIssuedAt().setExpirationTime('1h').sign(privateKey);
  return {subject, session, token};
}
async function call(person, path, method = 'GET', body, headers = {}) {
  const response = await fetch(origin + path, {method, headers: {
    ...(person ? {Authorization: 'Bearer ' + person.token} : {}),
    ...(body === undefined ? {} : {'Content-Type': 'application/json'}), ...headers},
    ...(body === undefined ? {} : {body: JSON.stringify(body)})});
  return {status: response.status, data: await response.json()};
}
function ok(result, status = 200) { assert.equal(result.status, status, JSON.stringify(result.data)); return result.data; }
async function household(person, label) {
  return ok(await call(person, '/v1/households', 'POST', {clientKey: randomUUID(), label, alias: 'Fictional adult', adultAttestation: true}), 201);
}

test('production runtime exposes current tracking without adopting food or weakening session access', async () => {
  const person = await actor(), created = await household(person, 'Runtime tracking household');
  const base = `/v1/households/${created.householdId}`, shopId = randomUUID();
  const device = ok(await call(person, base + '/devices', 'POST', {}), 201);
  const headers = {'X-Device-Token': device.deviceToken};
  const replay = ok(await call(person, base + '/replay-windows', 'POST', {}, headers));
  const quote = {currency: 'USD', scope: 'wholeCheckout', complete: true, capMinor: 10000,
    capScope: 'wholeCheckout', fee: {kind: 'fixed', amountMinor: 0}, taxesMinor: 0,
    depositsMinor: 0, discountsMinor: 0, observedAt: new Date(Date.now() - 60000).toISOString(),
    expiresAt: new Date(Date.now() + 3600000).toISOString()};
  ok(await call(person, base + '/commands', 'POST', {v: 1, replayWindow: replay.id,
    clientKey: randomUUID(), shopId, kind: 'shop.create', base: {shopRevision: 0, authorityEpoch: 0},
    body: {quote, lines: []}}, headers));
  const path = base + `/shops/${shopId}/demand/tracking`;
  const tracking = ok(await call(person, path, 'GET', undefined, headers));
  assert.equal(tracking.schemaVersion, 2); assert.equal(tracking.shopId, shopId);
  assert.equal(tracking.status, 'legacy'); assert.equal(tracking.shopRevision, 1);
  assert.equal((await admin.query('SELECT count(*)::int AS n FROM ritc.shared_tracking_revision WHERE household_id=$1 AND shop_id=$2', [created.householdId, shopId])).rows[0].n, 0);
  assert.equal((await call(null, path, 'GET', undefined, headers)).status, 401);
  await admin.query('DELETE FROM auth.sessions WHERE id=$1', [person.session]);
  assert.equal((await call(person, path, 'GET', undefined, headers)).status, 401);
});

test('production runtime exposes authenticated responsibility preview while new provider deletion remains disabled', async () => {
  const person = await actor(), created = await household(person, 'Runtime preview household');
  const preview = ok(await call(person, '/v1/privacy/deletion-preview'));
  assert.equal(preview.deletionAvailable, false); assert.equal(preview.verifiedBackupRetentionDays, null);
  assert.equal(preview.reauthenticationRequired, false);
  assert.deepEqual(preview.households.map(value => value.householdId), [created.householdId]);
  const clientKey = randomUUID(), input = {clientKey, statusToken: randomBytes(32).toString('base64url'), confirm: true, households: []};
  const rejected = await call(person, '/v1/privacy/deletions', 'POST', input);
  assert.equal(rejected.status, 503); assert.equal(rejected.data.error.code, 'deletion_unavailable');
  assert.equal((await admin.query('SELECT count(*)::int AS n FROM ritc.privacy_job WHERE job_id=$1', [clientKey])).rows[0].n, 0);
  assert.equal((await admin.query('SELECT state FROM ritc.member WHERE household_id=$1 AND member_id=$2', [created.householdId, created.memberId])).rows[0].state, 'active');
  assert.equal((await call(null, '/v1/privacy/deletion-preview')).status, 401);
  await admin.query('DELETE FROM auth.sessions WHERE id=$1', [person.session]);
  assert.equal((await call(person, '/v1/privacy/deletion-preview')).status, 401);
});

test('production runtime can read an existing pending deletion receipt without accepting or claiming provider erasure', async () => {
  const job = randomUUID(), token = randomBytes(32).toString('base64url');
  await admin.query(`INSERT INTO ritc.privacy_job(job_id,identity_hash,receipt_hash,payload_digest,
    receipt_retention_days,marker_retention_days,receipt_until,marker_until,app_erased_at)
    VALUES($1,$2,$3,$4,1,2,clock_timestamp()+interval '1 day',clock_timestamp()+interval '2 days',clock_timestamp())`,
  [job, tokenHash(randomUUID()), tokenHash(token), tokenHash(randomUUID())]);
  const status = ok(await call(null, '/v1/privacy/jobs/' + job, 'GET', undefined, {'X-Deletion-Token': token}));
  assert.equal(status.jobId, job); assert.equal(status.status, 'pending');
  assert.equal(status.appDataErased, true); assert.equal(status.providerAccountDeleted, false); assert.equal(status.completedAt, null);
  const unknown = await call(null, '/v1/privacy/jobs/' + job, 'GET', undefined, {'X-Deletion-Token': randomBytes(32).toString('base64url')});
  assert.equal(unknown.status, 404); assert.equal(unknown.data.error.code, 'unavailable');
});

test('production runtime leaves only the reviewed household, retries once and still requires recent authentication', async () => {
  const person = await actor(), leaving = await household(person, 'Leave this runtime household'), retained = await household(person, 'Retain this runtime household');
  const input = {clientKey: randomUUID(), confirm: true, disposition: {householdId: leaving.householdId, organizer: 'archive', shops: [], eraseChildProfiles: []}};
  const path = `/v1/households/${leaving.householdId}/exit`, receipt = ok(await call(person, path, 'POST', input));
  assert.deepEqual(receipt, {householdId: leaving.householdId, left: true, accountDeleted: false});
  assert.deepEqual(ok(await call(person, path, 'POST', input)), receipt);
  assert.deepEqual(ok(await call(person, '/v1/me/workspaces')).workspaces.map(value => value.householdId), [retained.householdId]);
  assert.equal((await admin.query('SELECT count(*)::int AS n FROM auth.sessions WHERE id=$1', [person.session])).rows[0].n, 1);
  const stale = await actor(3600), own = await household(stale, 'Old authentication household');
  const rejected = await call(stale, `/v1/households/${own.householdId}/exit`, 'POST', {clientKey: randomUUID(), confirm: true,
    disposition: {householdId: own.householdId, organizer: 'archive', shops: [], eraseChildProfiles: []}});
  assert.equal(rejected.status, 401); assert.equal(rejected.data.error.code, 'reauthentication_required');
  assert.equal((await admin.query('SELECT state FROM ritc.member WHERE household_id=$1 AND member_id=$2', [own.householdId, own.memberId])).rows[0].state, 'active');
});
