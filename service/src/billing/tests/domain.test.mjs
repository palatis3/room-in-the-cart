import test from 'node:test';
import assert from 'node:assert/strict';
import { effectiveStatus, validityEnd, supersedes, hasPaidSeat, BILLING_CACHE_MS } from '../../../dist/billing/domain.js';
import { appleGatewaysFromEnvironment, OfficialAppleBillingGateway } from '../../../dist/billing/apple.js';
import { billingSeatsSchema, billingVerifySchema, BillingService } from '../../../dist/billing/service.js';
import { createHTTPServer } from '../../../dist/http.js';

const now = Date.parse('2026-11-03T10:00:00Z');
const base = { environment: 'Sandbox', originalTransactionID: '100', transactionID: '101',
  appAccountToken: '00000000-0000-4000-8000-000000000001', productID: 'test-only.household',
  purchasedAt: now - 1000, signedAt: now, expiresAt: now + 10000, graceExpiresAt: null, status: 'active' };

test('renewal order uses purchase and signature authority rather than longest expiry', () => {
  const latest = { ...base, status: 'revoked', signedAt: now + 10 };
  assert.equal(supersedes({ ...base, expiresAt: now + 1e10 }, latest), false);
  assert.equal(supersedes({ ...base, purchasedAt: now - 2000, signedAt: now + 99 }, latest), false);
  assert.equal(supersedes(latest, base), true);
  assert.equal(supersedes({ ...base, status: 'revoked' }, base), true);
  assert.equal(supersedes(base, { ...base, status: 'revoked' }), false);
});
test('expiry, grace, retry and revoked access are evaluated against the trusted clock', () => {
  assert.equal(effectiveStatus(base, now), 'active');
  assert.equal(effectiveStatus(base, base.expiresAt), 'expired');
  assert.equal(effectiveStatus({ ...base, status: 'grace', graceExpiresAt: now + 20 }, now), 'grace');
  assert.equal(effectiveStatus({ ...base, status: 'grace', graceExpiresAt: now }, now), 'expired');
  for (const status of ['revoked','billingRetry','expired']) assert.equal(effectiveStatus({ ...base,status },now), status);
});
test('offline cache never exceeds subscription end or five-minute verified lease', () => {
  assert.equal(validityEnd(base,now,now),base.expiresAt);
  assert.equal(validityEnd({ ...base,expiresAt: now+1e9 },now,now),now+BILLING_CACHE_MS);
  const snapshot = { status:'active',validUntil:new Date(now+10).toISOString(),seats:[{userID:'adult',isAdult:true}] };
  assert.equal(hasPaidSeat(snapshot,'adult',new Date(now)),true);
  assert.equal(hasPaidSeat(snapshot,'other',new Date(now)),false);
  assert.equal(hasPaidSeat(snapshot,'adult',new Date(now+10)),false);
  assert.equal(hasPaidSeat({...snapshot,status:'billingRetry'},'adult',new Date(now)),false);
});
test('server configuration is absent by default and incomplete / local-Xcode configuration fails closed', async () => {
  assert.deepEqual(appleGatewaysFromEnvironment({}),{primary:null});
  assert.throws(()=>appleGatewaysFromEnvironment({APPLE_PRODUCT_ID:'test-only.household'}));
  for(const [environment,ids] of [['Sandbox',base.appAccountToken], ['Production','*'], ['Production',base.appAccountToken+',']]) {
    assert.throws(()=>appleGatewaysFromEnvironment({APPLE_ENVIRONMENT:environment,APPLE_REVIEW_HOUSEHOLD_IDS:ids}),/APPLE_REVIEW_HOUSEHOLD_IDS/);
  }
  assert.throws(()=>new OfficialAppleBillingGateway({bundleID:'test',productID:'test',environment:'Xcode',rootCertificates:[],signingKey:'test',keyID:'test',issuerID:base.appAccountToken}));
  const service = new BillingService(null);
  await assert.rejects(()=>service.prepare({member:{kind:'adult'}}),error=>error.code==='billing_unavailable');
});
test('seat command rejects more than two, duplicates, extras and invalid revision; verify rejects client purchaser claims', () => {
  const one=base.appAccountToken,two='00000000-0000-4000-8000-000000000002',three='00000000-0000-4000-8000-000000000003';
  assert.equal(billingSeatsSchema.safeParse({revision:1,userIDs:[one,two]}).success,true);
  for (const data of [{revision:1,userIDs:[one,one]},{revision:1,userIDs:[one,two,three]},{revision:0,userIDs:[]},{revision:1,userIDs:[],isAdult:true}]) assert.equal(billingSeatsSchema.safeParse(data).success,false);
  assert.equal(billingVerifySchema.safeParse({householdId:one,signedTransactionInfo:'test-fixture-jws-body',purchaserID:two}).success,false);
});

test('the two Apple notification URLs pin signed TEST delivery to the designated verifier', async t => {
  const calls = [];
  const gateway = environment => ({
    async verifyNotification(payload) {
      calls.push([environment, payload]);
      return { kind:'TEST', notificationID:base.appAccountToken };
    },
  });
  const billing = new BillingService(gateway('Production'), { householdIDs:new Set([base.appAccountToken]), sandbox:gateway('Sandbox') });
  const server = createHTTPServer({ repository:{}, billing });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(() => new Promise(resolve => server.close(resolve)));
  const origin = 'http://127.0.0.1:'+server.address().port;
  const signedPayload = 'fixture-test-notification';
  for (const path of ['/v1/apple/notifications', '/v1/apple/notifications/sandbox']) {
    const result = await fetch(origin+path, { method:'POST', headers:{'Content-Type':'application/json'}, body:JSON.stringify({signedPayload}) });
    assert.equal(result.status, 200);
    assert.deepEqual(await result.json(), {accepted:true});
  }
  assert.deepEqual(calls, [['Production',signedPayload],['Sandbox',signedPayload]]);
});

test('a consent-only service receives both Apple routes with purchases disabled', async t => {
  const writes = [];
  const repository = {pool:{async query(statement, values) {
    assert.match(statement, /INSERT INTO ritc\.apple_consent_notification/);
    writes.push(values);
  }}};
  const gateway = environment => ({async verifyNotification(payload) {
    assert.equal(payload, 'consent-from-the-fixture');
    return {kind:'RESCIND_CONSENT', notificationID:base.appAccountToken, environment, signedAt:now};
  }});
  const billing = new BillingService(null, undefined, {primary:gateway('Production'),sandbox:gateway('Sandbox')});
  const server = createHTTPServer({repository, billing});
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(() => new Promise(resolve => server.close(resolve)));
  for (const path of ['/v1/apple/notifications','/v1/apple/notifications/sandbox']) {
    const response = await fetch('http://127.0.0.1:'+server.address().port+path, {method:'POST',
      headers:{'Content-Type':'application/json'},body:JSON.stringify({signedPayload:'consent-from-the-fixture'})});
    assert.equal(response.status, 200);
    assert.deepEqual(await response.json(), {accepted:true});
  }
  assert.deepEqual(writes, ['Production','Sandbox'].map(env=>[env,base.appAccountToken,new Date(now)]));
  await assert.rejects(()=>billing.prepare({member:{kind:'adult'}, householdId:'test-household'}),error=>error.code==='billing_unavailable');
});
