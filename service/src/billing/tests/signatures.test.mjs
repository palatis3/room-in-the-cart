import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { execFileSync } from 'node:child_process';
import { OfficialAppleBillingGateway, appleGatewayFromEnvironment } from '../../../dist/billing/apple.js';

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
      assert.ok(appleGatewayFromEnvironment(env) instanceof OfficialAppleBillingGateway);
      assert.throws(() => appleGatewayFromEnvironment({ ...env, APPLE_PRODUCT_ID: 'local.testing.household.annual' }),
        /local StoreKit fixture/);
    }
  } finally { rmSync(dir, { recursive: true, force: true }); }
});
