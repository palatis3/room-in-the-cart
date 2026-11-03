import test from'node:test';import assert from'node:assert/strict';import{randomUUID}from'node:crypto';import{generateKeyPair,exportJWK,createLocalJWKSet,SignJWT}from'jose';import{JWTIdentityVerifier}from'../dist/auth.js';
const issuer='https://auth-journal.fixture.invalid',audience='authenticated',{publicKey,privateKey}=await generateKeyPair('ES256'),jwk=await exportJWK(publicKey);jwk.kid='auth-journal';const verifier=new JWTIdentityVerifier({issuer,audience,jwksUrl:issuer+'/jwks'},createLocalJWKSet({keys:[jwk]}));
async function identity(amr){const token=await new SignJWT({session_id:randomUUID(),amr}).setProtectedHeader({alg:'ES256',kid:jwk.kid}).setIssuer(issuer).setAudience(audience).setSubject(randomUUID()).setIssuedAt().setExpirationTime('1h').sign(privateKey);return verifier.verify(token);}
for(const method of['otp','password','oauth','sso/saml'])test('retains exact permitted signed method '+method,async()=>{const timestamp=Math.floor(Date.now()/1000)-2,result=await identity([{method,timestamp}]);assert.equal(result.authenticatedAt.getTime(),timestamp*1000);assert.equal(result.authenticatedMethod,method);assert.equal(result.emailOTPAuthenticatedAt?.getTime(),method==='otp'?timestamp*1000:undefined);});
test('method comes from the same latest valid event, not earlier OTP or JWT iat',async()=>{const t=Math.floor(Date.now()/1000)-3,result=await identity([{method:'otp',timestamp:t-10},{method:'password',timestamp:t},{method:'unknown',timestamp:t+1},{method:'oauth',timestamp:t+600}]);assert.equal(result.authenticatedAt.getTime(),t*1000);assert.equal(result.authenticatedMethod,'password');assert.equal(result.emailOTPAuthenticatedAt.getTime(),(t-10)*1000);});
test('equal-time events retain original order while timestamp remains identical',async()=>{const t=Math.floor(Date.now()/1000)-2;for(const methods of[['otp','password'],['password','otp']]){const result=await identity(methods.map(method=>({method,timestamp:t})));assert.equal(result.authenticatedAt.getTime(),t*1000);assert.equal(result.authenticatedMethod,methods[0]);assert.equal(result.emailOTPAuthenticatedAt.getTime(),t*1000);}});
test('absent or invalid permitted evidence does not invent a method/time',async()=>{const t=Math.floor(Date.now()/1000);for(const amr of[[],[{method:'refresh',timestamp:t}],[{method:'otp',timestamp:'1'}],[{method:'oauth',timestamp:t+600}]]){const result=await identity(amr);assert.equal(result.authenticatedAt,undefined);assert.equal(result.authenticatedMethod,undefined);assert.equal(result.emailOTPAuthenticatedAt,undefined);}});

test('literal allowed method is required; signed arrays and objects cannot become method evidence',async()=>{
 const timestamp=Math.floor(Date.now()/1000)-2;
 for(const method of [['otp'],['password'],['oauth'],['sso/saml'],null,1,{method:'otp'}]){
  const result=await identity([{method,timestamp}]);
  assert.equal(result.authenticatedAt,undefined);assert.equal(result.authenticatedMethod,undefined);assert.equal(result.emailOTPAuthenticatedAt,undefined);
 }
});
test('malformed and out-of-window timestamps cannot stamp any allowed method',async()=>{
 const now=Math.floor(Date.now()/1000);
 for(const method of ['otp','password','oauth','sso/saml'])for(const timestamp of [String(now),now-0.5,0,-1,null,Number.MAX_SAFE_INTEGER,now+600]){
  const result=await identity([{method,timestamp}]);
  assert.equal(result.authenticatedAt,undefined);assert.equal(result.authenticatedMethod,undefined);assert.equal(result.emailOTPAuthenticatedAt,undefined);
 }
});
test('fresh JWT iat and user metadata never substitute for an actual signed AMR event',async()=>{
 const timestamp=Math.floor(Date.now()/1000)-3600,old=await identity([{method:'otp',timestamp}]);
 assert.equal(old.authenticatedAt.getTime(),timestamp*1000);assert.equal(old.authenticatedMethod,'otp');assert.equal(old.emailOTPAuthenticatedAt.getTime(),timestamp*1000);
 const token=await new SignJWT({session_id:randomUUID(),user_metadata:{amr:[{method:'otp',timestamp:Math.floor(Date.now()/1000)}],authenticatedMethod:'otp',authenticatedAt:new Date().toISOString()}}).setProtectedHeader({alg:'ES256',kid:jwk.kid}).setIssuer(issuer).setAudience(audience).setSubject(randomUUID()).setIssuedAt().setExpirationTime('1h').sign(privateKey);
 const result=await verifier.verify(token);assert.equal(result.authenticatedAt,undefined);assert.equal(result.authenticatedMethod,undefined);assert.equal(result.emailOTPAuthenticatedAt,undefined);assert.equal(Object.isFrozen(result),true);
});
