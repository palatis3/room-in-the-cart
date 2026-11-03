import test from 'node:test';
import assert from 'node:assert/strict';
import { effectiveStatus, validityEnd, supersedes, hasPaidSeat, BILLING_CACHE_MS } from '../../../dist/billing/domain.js';
import { appleGatewayFromEnvironment, OfficialAppleBillingGateway } from '../../../dist/billing/apple.js';
import { billingSeatsSchema, billingVerifySchema, BillingService } from '../../../dist/billing/service.js';

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
  assert.equal(appleGatewayFromEnvironment({}),null);
  assert.throws(()=>appleGatewayFromEnvironment({APPLE_PRODUCT_ID:'test-only.household'}));
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
