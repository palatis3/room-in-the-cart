import test from 'node:test';
import assert from 'node:assert/strict';
import {generateKeyPair,exportJWK,createLocalJWKSet,SignJWT} from 'jose';
import {JWTIdentityVerifier} from '../dist/auth.js';
import {SupabaseAccountDeletionProvider} from '../dist/privacy.js';
const subject='b32f4377-9dc2-44c6-a6ea-deb06501d752',key='sb_secret_fictional_provider_test';
const json=value=>new Response(JSON.stringify(value),{headers:{'Content-Type':'application/json'}});
test('reauthentication derives only from a signed authentication method, never refreshed iat or user metadata',async()=>{
 const {publicKey,privateKey}=await generateKeyPair('ES256'),jwk=await exportJWK(publicKey);jwk.kid='reauth';
 const issuer='https://fixture.invalid',verifier=new JWTIdentityVerifier({issuer,audience:'authenticated',jwksUrl:issuer+'/keys'},createLocalJWKSet({keys:[jwk]})),now=Math.floor(Date.now()/1000);
 async function identity(claims){const token=await new SignJWT({session_id:subject,...claims}).setProtectedHeader({alg:'ES256',kid:'reauth'}).setIssuer(issuer).setSubject(subject).setAudience('authenticated').setIssuedAt(now).setExpirationTime(now+3600).sign(privateKey);return verifier.verify(token);}
 assert.equal((await identity({user_metadata:{amr:[{method:'otp',timestamp:now}]}})).authenticatedAt,undefined);
 assert.equal((await identity({amr:[{method:'token_refresh',timestamp:now}]})).authenticatedAt,undefined);
 assert.equal((await identity({amr:[{method:'otp',timestamp:now+3600}]})).authenticatedAt,undefined);
 assert.equal((await identity({amr:[{method:'otp',timestamp:now-3600}]})).authenticatedAt.getTime(),(now-3600)*1000);
 assert.equal((await identity({amr:[{method:'otp',timestamp:now}]})).authenticatedAt.getTime(),now*1000);
});
test('privileged account deletion is fixed-origin, exact-subject, hard delete and verifies absence',async()=>{
 const calls=[];let removed=false;
 const provider=new SupabaseAccountDeletionProvider({url:'https://fixture.invalid',secretKey:key},async(url,init)=>{
  calls.push({url,init});assert.equal(url,'https://fixture.invalid/auth/v1/admin/users/'+subject);assert.equal(init.redirect,'error');assert.equal(init.headers.apikey,key);
  if(init.method==='DELETE'){assert.deepEqual(JSON.parse(init.body),{should_soft_delete:false});removed=true;return json({id:subject});}
  return removed?Response.json({code:404,error_code:'user_not_found'},{status:404}):json({id:subject,identities:[{provider:'email'}]});
 });
 await provider.assertAvailable(subject);await provider.deleteAccount(subject);await provider.deleteAccount(subject);assert.equal(calls.filter(c=>c.init.method==='DELETE').length,1);
 assert.throws(()=>new SupabaseAccountDeletionProvider({url:'http://fixture.invalid',secretKey:key}));assert.throws(()=>new SupabaseAccountDeletionProvider({url:'https://fixture.invalid',secretKey:'sb_publishable_not_privileged'}));
});
test('only an explicit missing user confirms an idempotent erasure or a completed delete',async()=>{
 const config={url:'https://fixture.invalid',secretKey:key};
 for(const unknown of [
  ()=>new Response('Page not found',{status:404,headers:{'Content-Type':'text/html'}}),
  ()=>Response.json({code:'unexpected_failure'},{status:404}),
  ()=>Response.json({message:'Not found'},{status:404}),
  ()=>Response.json({code:'user_not_found'},{status:404,headers:{'x-sb-error-code':'unexpected_failure'}})
 ]){
  const missingRoute=new SupabaseAccountDeletionProvider(config,async()=>unknown());
  await assert.rejects(missingRoute.deleteAccount(subject),{code:'deletion_unavailable'});
  let sent=false;
  const missingConfirmation=new SupabaseAccountDeletionProvider(config,async(_url,init)=>{
   if(init.method==='DELETE'){sent=true;return new Response(null,{status:204});}
   return sent?unknown():json({id:subject,identities:[{provider:'email'}]});
  });
  await assert.rejects(missingConfirmation.deleteAccount(subject),{code:'deletion_unavailable'});
  assert.equal(sent,true);
 }
 const missingUser=new SupabaseAccountDeletionProvider(config,async(_url,init)=>{
  assert.equal(init.method,'GET');return Response.json({code:'user_not_found'},{status:404});
 });
 await missingUser.deleteAccount(subject);
});
test('missing Apple revocation or mismatched provider subjects never claim deletion',async()=>{
 let deleted=false;const provider=new SupabaseAccountDeletionProvider({url:'https://fixture.invalid',secretKey:key},async(_url,init)=>{if(init.method==='DELETE')deleted=true;return json({id:subject,identities:[{provider:'apple'}]});});
 await assert.rejects(()=>provider.assertAvailable(subject),e=>e.code==='deletion_unavailable');await assert.rejects(()=>provider.deleteAccount(subject));assert.equal(deleted,false);
 const mismatch=new SupabaseAccountDeletionProvider({url:'https://fixture.invalid',secretKey:key},async()=>json({id:'29e51374-b193-493e-a925-1e68ac0a2b80',identities:[]}));await assert.rejects(()=>mismatch.assertAvailable(subject));
});
