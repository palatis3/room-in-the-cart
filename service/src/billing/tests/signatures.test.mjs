import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { execFileSync } from 'node:child_process';
import { OfficialAppleBillingGateway, appleGatewaysFromEnvironment } from '../../../dist/billing/apple.js';

function createTestCredentials(dir) {
  // Ephemeral test-only CA. It is never deployed or accepted as a production Apple root.
  execFileSync('openssl',['req','-x509','-newkey','ec','-pkeyopt','ec_paramgen_curve:P-256','-nodes','-days','1',
    '-subj','/CN=RITC test fixture CA','-addext','basicConstraints=critical,CA:TRUE',
    '-keyout',join(dir,'key.pem'),'-out',join(dir,'root.pem')],{stdio:'ignore'});
}

test('official Apple verifier rejects unsigned and forged JWS instead of trusting payload fields', async () => {
  const dir=mkdtempSync(join(tmpdir(),'ritc-billing-certificate-test-'));
  try {
    createTestCredentials(dir);
    const gateway=new OfficialAppleBillingGateway({bundleID:'test.only.ritc',productID:'test.only.household',environment:'Sandbox',
      rootCertificates:[readFileSync(join(dir,'root.pem'))],signingKey:readFileSync(join(dir,'key.pem'),'utf8'),
      keyID:'TESTONLY',issuerID:'00000000-0000-4000-8000-000000000001'});
    const payload=Buffer.from(JSON.stringify({bundleId:'test.only.ritc',productId:'test.only.household',environment:'Sandbox',originalTransactionId:'100',transactionId:'101',appAccountToken:'00000000-0000-4000-8000-000000000001',expiresDate:Date.now()+1e8})).toString('base64url');
    for(const alg of ['none','ES256','HS256']) {
      const header=Buffer.from(JSON.stringify({alg})).toString('base64url');
      const jws=`${header}.${payload}.forged-signature`;
      await assert.rejects(()=>gateway.verifyTransaction(jws),error=>error.code==='billing_verification_failed');
      await assert.rejects(()=>gateway.verifyNotification(jws),error=>error.code==='billing_verification_failed');
    }
  } finally { rmSync(dir,{recursive:true,force:true}); }
});

test('official Apple gateway refuses the Xcode StoreKit fixture in both Apple environments', () => {
  const dir = mkdtempSync(join(tmpdir(), 'ritc-billing-product-test-'));
  try {
    createTestCredentials(dir);
    for (const environment of ['Production', 'Sandbox']) {
      const env = {
        APPLE_BUNDLE_ID: 'test.only.ritc', APPLE_PRODUCT_ID: 'test.only.household', APPLE_ENVIRONMENT: environment,
        APPLE_APP_ID: '12345', APPLE_ROOT_CA_PATHS: join(dir, 'root.pem'), APPLE_SIGNING_KEY_PATH: join(dir, 'key.pem'),
        APPLE_KEY_ID: 'TESTONLY', APPLE_ISSUER_ID: '00000000-0000-4000-8000-000000000001',
      };
      const routes = appleGatewaysFromEnvironment(env);
      assert.ok(routes.primary instanceof OfficialAppleBillingGateway);
      assert.equal(routes.review, undefined);
      if (environment === 'Production') {
        const id = 'aaaaaaaa-0000-4000-8000-000000000001';
        const { review } = appleGatewaysFromEnvironment({ ...env, APPLE_REVIEW_HOUSEHOLD_IDS: id.toUpperCase() });
        assert.deepEqual([...review.householdIDs], [id]);
        assert.ok(review.sandbox instanceof OfficialAppleBillingGateway);
      }
      assert.throws(() => appleGatewaysFromEnvironment({ ...env, APPLE_PRODUCT_ID: 'local.testing.household.annual' }),
        /local StoreKit fixture/);
    }
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('consent delivery verifies appData and any nested app download using the designated environment', async t => {
  const dir = mkdtempSync(join(tmpdir(), 'ritc-consent-notification-'));
  t.after(() => rmSync(dir, {recursive:true, force:true}));
  createTestCredentials(dir);
  const bundleId = 'test.only.ritc', appAppleId = 12345;
  const config = { APPLE_BUNDLE_ID:bundleId, APPLE_APP_ID:String(appAppleId),
    APPLE_ROOT_CA_PATHS:join(dir, 'root.pem'), APPLE_ENVIRONMENT:'Production' };
  const {primary, notifications} = appleGatewaysFromEnvironment(config);
  assert.equal(primary, null);
  const notificationUUID = '22222222-0000-4000-8000-000000000001';
  const signedDate = Date.now(), outer = 'fixture-after-signature-verification';
  const expectedFailure = error => error.code === 'billing_verification_failed';
  for (const [environment, gateway] of [['Production',notifications.primary], ['Sandbox',notifications.sandbox]]) {
    const base = { version:'2.0', notificationType:'RESCIND_CONSENT', notificationUUID, signedDate };
    const appData = { bundleId, environment, appAppleId };
    let payload = {...base, appData};
    await assert.rejects(() => gateway.verifyNotification(outer), expectedFailure);
    // Substitute only Apple's outer JWS decoder to exercise the verified-payload contract.
    t.mock.method(gateway.verifier, 'verifyAndDecodeNotification', async () => payload);
    const receipt = {kind:'RESCIND_CONSENT', notificationID:notificationUUID, environment, signedAt:signedDate};
    assert.deepEqual(await gateway.verifyNotification(outer), receipt);
    const nested = 'fixture-signed-app-download-transaction';
    payload = {...base, appData:{...appData, signedAppTransactionInfo:nested}};
    await assert.rejects(() => gateway.verifyNotification(outer), expectedFailure);
    const decode = t.mock.method(gateway.verifier, 'verifyAndDecodeAppTransaction', async () => ({appTransactionId:'123456789'}));
    assert.deepEqual(await gateway.verifyNotification(outer), receipt);
    assert.deepEqual(decode.mock.calls[0].arguments, [nested]);
    for (const candidate of [
      {...base}, {...base, data:{signedTransactionInfo:nested}}, {...base, appData, data:{}},
      {...base, appData, summary:{}}, {...base, appData:{...appData, bundleId:'other.app'}},
      {...base, appData:{...appData, environment:environment==='Production'?'Sandbox':'Production'}},
      ...(environment==='Production' ? [{...base, appData:{...appData, appAppleId:999}}] : []),
    ]) {
      payload = candidate;
      await assert.rejects(() => gateway.verifyNotification(outer), expectedFailure);
    }
    payload = {...base, notificationType:'DID_RENEW', data:{signedTransactionInfo:nested}};
    await assert.rejects(() => gateway.verifyNotification(outer), error=>error.code==='billing_unavailable');
  }
});
