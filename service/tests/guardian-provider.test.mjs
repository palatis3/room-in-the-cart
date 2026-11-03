import test from 'node:test';
import assert from 'node:assert/strict';
import {randomUUID,createHmac} from 'node:crypto';
import {KWSWebhookVerifier,KWSParentVerificationGateway,KWSClientCredentials} from '../dist/guardian-provider.js';
const configuration={organizationId:randomUUID(),scope:'product',productId:randomUUID(),environment:'test'},secret='fixture-only-provider-signing-secret';
function body(config=configuration){return JSON.stringify({name:'parent-verified',time:new Date().toISOString(),orgId:config.organizationId,productId:config.productId,payload:{parentEmail:'guardian@fixture.invalid',externalPayload:JSON.stringify({v:1,h:randomUUID(),a:randomUUID(),n:Buffer.alloc(32,1).toString('base64url')}),status:{verified:true,transactionId:randomUUID()}}});}
function signed(raw,key=secret,stamp=Date.now()){return't='+stamp+',v1='+createHmac('sha256',key).update(String(stamp)+'.').update(raw).digest('hex');}
test('KWS authenticates original UTF-8 bytes, exact scope and rotating secrets',()=>{
 const raw=body(),verifier=new KWSWebhookVerifier(configuration,['previous-fixture-secret',secret]),valid=signed(raw);
 assert.equal(verifier.verify(Buffer.from(raw),valid).parentEmail,'guardian@fixture.invalid');
 const rotated=valid+',v1='+'0'.repeat(64);assert.ok(verifier.verify(Buffer.from(raw),rotated));
 for(const [text,header]of [[raw+' ',valid],[raw,signed(raw,'wrong-fixture-secret')],[raw,valid+',t='+Date.now()],[raw,signed(raw,secret,Date.now()+600_000)]])assert.throws(()=>verifier.verify(Buffer.from(text),header),e=>e.code==='provider_signature_invalid');
 const other=body({...configuration,productId:randomUUID()});assert.throws(()=>verifier.verify(Buffer.from(other),signed(other)));
});
test('organization webhook scope accepts only null product, product scope only its exact product',()=>{
 const org={...configuration,scope:'organization',productId:null},raw=body(org),verify=new KWSWebhookVerifier(org,[secret]);assert.equal(verify.verify(Buffer.from(raw),signed(raw)).productId,null);
 const product=body();assert.throws(()=>verify.verify(Buffer.from(product),signed(product)));
 const productVerifier=new KWSWebhookVerifier(configuration,[secret]);assert.throws(()=>productVerifier.verify(Buffer.from(raw),signed(raw)));
});
test('documented OAuth token and PV request use fixed origins, Basic/Bearer and strict accepted response',async()=>{
 const calls=[];const request=async(url,options)=>{calls.push({url,options});return new Response(JSON.stringify(url.includes('/token')?{access_token:'fixture-token',expires_in:3600}:{response:{trustEmailRequestAccepted:true},meta:{timestamp:'fixture-date',requestId:'fixture-request'}}),{status:url.includes('/token')?200:202});};
 const gateway=new KWSParentVerificationGateway(configuration,{clientId:'fixture-client',apiKey:'fixture-key',userAgent:'Room-in-the-Cart-fixture/1',serviceOrigin:'https://api.kidswebservices.com'},request);
 const input={email:'guardian@fixture.invalid',location:'US-NY',language:'es',userContext:'parent',externalPayload:'opaque'};await gateway.start(input);await gateway.start(input);
 assert.equal(calls.length,3);assert.equal(calls[0].url,'https://auth.kidswebservices.com/auth/realms/kws/protocol/openid-connect/token');
 assert.equal(calls[0].options.headers.Authorization,'Basic '+Buffer.from('fixture-client:fixture-key').toString('base64'));assert.equal(calls[0].options.body.toString(),'grant_type=client_credentials&scope=verification');
 assert.equal(calls[1].url,'https://api.kidswebservices.com/v1/verifications/send-email');assert.deepEqual(JSON.parse(calls[1].options.body),input);assert.equal(calls[1].options.headers.Authorization,'Bearer fixture-token');assert.ok(calls[1].options.headers['User-Agent']);
 assert.throws(()=>new KWSParentVerificationGateway(configuration,{clientId:'fixture',apiKey:'fixture',userAgent:'fixture',serviceOrigin:'https://api.kidswebservices.com.evil.invalid'},request));
});
test('ambiguous PV reply is never retried and 202 is never considered verified proof',async()=>{
 let sends=0;const request=async url=>{if(url.includes('/token'))return new Response(JSON.stringify({access_token:'fixture',expires_in:3600}),{status:200});sends++;throw new Error('lost response');};
 const gateway=new KWSParentVerificationGateway(configuration,{clientId:'fixture',apiKey:'fixture',userAgent:'fixture',serviceOrigin:'https://api.kidswebservices.com'},request);
 await assert.rejects(gateway.start({email:'guardian@fixture.invalid',location:'US',language:'en',userContext:'parent',externalPayload:'opaque'}),e=>e.code==='verification_uncertain');assert.equal(sends,1);
});
test('OAuth rejects oversized/invalid token replies without returning provider content',async()=>{
 const token=new KWSClientCredentials('fixture','fixture','fixture',async()=>new Response('x'.repeat(20_000),{status:200}));await assert.rejects(token.token(),e=>e.code==='verification_provider_unavailable'&&!e.message.includes('xxxx'));
});
test('definitive KWS 401 renews token once, while ambiguous responses never trigger retries',async()=>{
 let tokens=0,sends=0;const request=async url=>{if(url.includes('/token'))return new Response(JSON.stringify({access_token:'fixture-'+(++tokens),expires_in:3600}),{status:200});sends++;return sends===1?new Response('',{status:401}):new Response(JSON.stringify({response:{trustEmailRequestAccepted:true},meta:{timestamp:'fixture',requestId:'fixture'}}),{status:202});};
 const gateway=new KWSParentVerificationGateway(configuration,{clientId:'fixture',apiKey:'fixture',userAgent:'fixture',serviceOrigin:'https://api.kidswebservices.com'},request);await gateway.start({email:'guardian@fixture.invalid',location:'US',language:'en',userContext:'parent',externalPayload:'opaque'});assert.equal(tokens,2);assert.equal(sends,2);
});
