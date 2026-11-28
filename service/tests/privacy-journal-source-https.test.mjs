import {after,before,test} from 'node:test';
import assert from 'node:assert/strict';
import {randomBytes,randomUUID} from 'node:crypto';
import {request} from 'node:https';
import {createHTTPSCommittedSource} from '../dist/privacy-journal-source-https.js';
import {createPrivacyRuntime,privacyDeploymentConfigurationId} from '../dist/privacy-runtime.js';
import {fixture} from './durable-authority-fixture.mjs';
import {call,digest,gate} from './durable-independent-fixture.mjs';
import {startSourceGateway} from './source-gateway-fixture.mjs';

const f=fixture();
let gateway,receivedHeaders;
before(async()=>{
 gateway=await startSourceGateway({pins:f.pins,source:f.source,observeRequest:req=>{receivedHeaders=req.headers;}});
});
after(async()=>{await gateway?.close();});

function post(body,{token=gateway.applicationToken,path='/v1/source',type='application/json'}={}){
 const bytes=JSON.stringify(body);
 return new Promise((resolve,reject)=>{
  const req=request(new URL(path,gateway.origin),{ca:gateway.ca,method:'POST',headers:{
   Authorization:'Bearer '+token,'Content-Type':type,'Content-Length':Buffer.byteLength(bytes),
  }},res=>{
   res.resume();res.on('end',()=>resolve(res.statusCode));
  });
  req.once('error',reject);req.end(bytes);
 });
}
function envelope(command={action:'origin'}){
 return {version:1,requestId:randomUUID(),scopeDigest:f.scopeDigest,databaseBinding:gateway.databaseBinding,attemptId:randomUUID(),deadlineUnixMs:Date.now()+5000,command};
}
function openClient(options={}){
 return createHTTPSCommittedSource({pins:f.pins,origin:gateway.origin,ca:gateway.ca,token:gateway.operationsToken,databaseBinding:gateway.databaseBinding,...options});
}

test('scope, destination, bearer, input bounds and command shape are checked before the source is called',async()=>{
 const before=f.logs.length;
 assert.equal(await post(envelope(),{token:randomBytes(32).toString('base64url')}),401);
 assert.equal(await post(envelope(),{path:'/v1/source/other'}),404);
 assert.equal(await post(envelope(),{type:'text/plain'}),415);
 assert.equal(await post({...envelope(),scopeDigest:'a'.repeat(64)}),403);
 assert.equal(await post({...envelope(),databaseBinding:{...gateway.databaseBinding,observerRoleOid:'44'}}),403);
 for(const input of [envelope({action:'other'}),envelope({action:'origin',query:'unused'}),envelope({action:'event',eventId:'invalid'}),
  envelope({action:'acknowledge',eventId:randomUUID()}),{...envelope(),deadlineUnixMs:1},{...envelope(),padding:'x'.repeat(17*1024)}]){
  assert.equal(await post(input),503);
 }
 assert.equal(f.logs.length,before);
});

test('all fixed operations send committed data and acknowledge the authoritative receipt over TLS',async()=>{
 const event=f.event(),source=gateway.source;
 await assert.rejects(()=>source.readCommittedEvent(event.eventId,call()));
 const journal=f.adapter({source});
 await journal.port.beforeCommit(event,call());
 f.commit(event);
 assert.deepEqual(await source.readCommittedAcceptance(event.payload.jobId,call()),event);
 assert.deepEqual(await source.listUnacknowledgedJobEvents(event.payload.jobId,call()),[event.eventId]);
 await journal.port.afterCommit(event.eventId,call());
 assert.equal(f.acknowledgements.length,1);
 assert.deepEqual(await source.listUnacknowledgedJobEvents(event.payload.jobId,call()),[]);
 const proof=f.receiptFor(event.eventId,'commit');
 await assert.rejects(()=>source.acknowledge(event.eventId,event.payloadDigest,proof.record.seq,proof.record.recordHash,
  {...proof,authoritySignature:'A'.repeat(86)},call()));
 assert.equal(f.acknowledgements.length,1);
});

test('operations identity is explicit, missing workload identity stops before network, and TLS is verified',async()=>{
 const oidc='synthetic.workload.signature';
 const client=openClient({getVercelTrustedSourceToken:async()=>oidc});
 try{assert.equal((await client.source.readOrigin(call())).lineage,f.pins.lineage);assert.equal(receivedHeaders['x-vercel-trusted-oidc-idp-token'],oidc);}
 finally{await client.close();}
 const before=f.logs.length;
 for(const options of [{ca:undefined},{getVercelTrustedSourceToken:async()=>''}]){
  const client=openClient(options);
  try{await assert.rejects(()=>client.source.readOrigin(call()));}finally{await client.close();}
 }
 assert.equal(f.logs.length,before);
});

test('an aborted caller or an expired OIDC exchange cannot dispatch a source operation later',async()=>{
 const ready=gate(),supply=gate(),before=f.logs.length;
 const client=openClient({getVercelTrustedSourceToken:async()=>{ready.resolve();return supply.promise;}});
 try{
  const context=call();
  const reading=client.source.readOrigin(context);
  await ready.promise;context.controller.abort();
  await assert.rejects(reading);supply.resolve('late.workload.signature');
  await new Promise(resolve=>setImmediate(resolve));assert.equal(f.logs.length,before);
 }finally{await client.close();}
});


test('application and operations compose a scoped gateway source and compare their own database binding',async()=>{
 const provider='https://provider.fixture.invalid',issuer=provider+'/auth/v1';
 const policy={receiptRetentionDays:1,erasureMarkerRetentionDays:2,verifiedBackupRetentionDays:1};
 const approvals={retentionApprovalReference:'fixture-retention',restoreApprovalReference:'fixture-restore'};
 const configurationId=privacyDeploymentConfigurationId({issuer,policy,...approvals});
 const f=fixture({configurationId});
 const gateway=await startSourceGateway({pins:f.pins,source:f.source});
 const environment={PRIVACY_DELETION_ACCEPTANCE:'true',PRIVACY_DELETION_PROCESSING:'true',SUPABASE_URL:provider,
  PRIVACY_SUPABASE_ADMIN_KEY:'sb_secret_'+randomBytes(32).toString('base64url'),JWT_ISSUER:issuer,
  JWT_AUDIENCE:'authenticated',JWT_JWKS_URL:issuer+'/.well-known/jwks.json'};
 const config={version:1,pins:f.pins,writerPrivateKey:f.writerKeys.privateKey.export({type:'pkcs8',format:'pem'}),
  authorityPublicKey:f.authorityKeys.publicKeyPEM,authority:{origin:'https://authority.fixture.invalid',writerToken:randomBytes(32).toString('base64url')},
  retentionPolicy:policy,...approvals};
 const binding={...f.origin,...gateway.databaseBinding,sourceIdentity:f.pins.sourceIdentity,fenced:false};
 try{
  for(const [role,token] of [['application',gateway.applicationToken],['operations',gateway.operationsToken]]){
   const observer={mode:'gateway',origin:gateway.origin,ca:gateway.ca,token,...gateway.databaseBinding};
   const create=(changes={},extra={})=>createPrivacyRuntime(pool,{...environment,...extra,
    PRIVACY_DELETION_JSON:JSON.stringify({...config,observer:{...observer,...changes}})},role);
   const allowed=role==='application'?'ritc_app':'ritc_worker';
   const pool={async connect(){return {release(){},async query(_,args){assert.equal(args[0],allowed);
    return {rows:[{binding,permitted:true,rotation_schema:true}]};}};}};
   const runtime=create();
   try{await runtime.options.assertSource(call());}finally{await runtime.close();}
   const mismatch=create({databaseOid:'44'});
   try{assert.equal((await mismatch.health(call())).state,'source_unavailable');}finally{await mismatch.close();}
   for(const invalid of [create({connection:{}}),create({token:config.authority.writerToken}),create({origin:config.authority.origin}),create({}, {VERCEL:'1'})]){
    try{assert.equal((await invalid.health(call())).state,'configuration_required');}
    finally{await invalid.close();}
   }
  }
 }finally{await gateway.close();}
});


test('fixed destination excludes caller paths; maximum source payload and the full 10,000-ID page fit the wire budget',async()=>{
 for(const origin of [gateway.origin+'/other',gateway.origin+'/?other',gateway.origin+'/#other',gateway.origin.replace('https:','http:')]){
  assert.throws(()=>openClient({origin}),/Fixed HTTPS/);
 }
 const f=fixture(),event=f.event(),jobId=event.payload.jobId;
 event.payload.data.padding='';
 event.payload.data.padding='x'.repeat(1024*1024-Buffer.byteLength(JSON.stringify(event.payload)));
 assert.equal(Buffer.byteLength(JSON.stringify(event.payload)),1024*1024);
 event.payloadDigest=digest(event.payload);f.commit(event);
 const ids=Array.from({length:10000},()=>randomUUID());
 const transport=await startSourceGateway({pins:f.pins,source:{...f.source,async listUnacknowledgedJobEvents(){return ids;}}});
 try{
  assert.equal((await transport.source.readCommittedEvent(event.eventId,call())).payloadDigest,event.payloadDigest);
  assert.deepEqual(await transport.source.listUnacknowledgedJobEvents(jobId,call()),ids);
 }finally{await transport.close();}
});


test('a prior valid response for the same operation, scope, database and parent attempt cannot satisfy a new request',async()=>{
 const f=fixture(),parent=call();
 let saved;
 const transport=await startSourceGateway({pins:f.pins,source:f.source,wrapHandler:handler=>(req,res)=>{
  if(saved){
   const body=saved;saved=undefined;req.resume();
   res.writeHead(200,{'Content-Type':'application/json','Content-Length':Buffer.byteLength(body)});
   res.end(body);return;
  }
  const end=res.end.bind(res);
  res.end=body=>{saved=body;return end(body);};
  return handler(req,res);
 }});
 try{
  assert.equal((await transport.source.readOrigin(parent)).lineage,f.pins.lineage);
  await assert.rejects(()=>transport.source.readOrigin(parent));
  assert.equal((await transport.source.readOrigin(parent)).lineage,f.pins.lineage);
 }finally{await transport.close();}
});
