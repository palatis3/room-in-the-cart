// Real local PostgreSQL evidence for the fixed-source boundary. All identifiers,
// events and authority keys are synthetic; private keys stay only in memory.
import test from 'node:test';
import assert from 'node:assert/strict';
import {randomUUID,sign,createHash} from 'node:crypto';
import {setTimeout as delay} from 'node:timers/promises';
import pg from 'pg';
import {createPostgresCommittedSource} from '../dist/privacy-journal-pg-source.js';
import {acceptedEvent,progressEvent,canonical,digest,keys,clone,call,zero} from './durable-independent-fixture.mjs';

const adminURL=new URL(process.env.TEST_ADMIN_DATABASE_URL),wrongURL=new URL(process.env.TEST_JOURNAL_WRONG_DATABASE_URL);
const observer=process.env.TEST_JOURNAL_OBSERVER_ROLE;
if(adminURL.searchParams.get('host')!=='/tmp'||adminURL.searchParams.get('port')!=='55432'||!adminURL.pathname.startsWith('/ritc_journal_pg_source_')||!wrongURL.pathname.startsWith('/ritc_journal_pg_wrong_'))throw Error('Dedicated disposable local databases required');
const owner=new pg.Client({connectionString:adminURL.toString()}),wrongOwner=new pg.Client({connectionString:wrongURL.toString()});
await owner.connect();await wrongOwner.connect();
const ownerRole=(await owner.query('SELECT current_user AS name,(SELECT oid::text FROM pg_roles WHERE rolname=current_user) AS oid')).rows[0];
const observerRole=(await owner.query('SELECT oid::text FROM pg_roles WHERE rolname=$1',[observer])).rows[0];
const databaseOid=(await owner.query('SELECT oid::text FROM pg_database WHERE datname=current_database()')).rows[0].oid;
const writer=keys(),authority=keys(),schemaDigest=digest((await owner.query('SELECT version,checksum FROM public.ritc_schema_migration ORDER BY version')).rows);
const origin={lineage:randomUUID(),schemaDigest,configurationId:'synthetic-postgres-source-proposal-v1'};
const pins={...origin,keyId:'synthetic-writer-v1',publicKeyFingerprint:writer.fingerprint,sourceIdentity:'synthetic-fixed-postgres-source-v1',recordStoreIdentity:'synthetic-record-store-v1',recordNamespace:'synthetic-record-namespace-v1',checkpointAuthority:'synthetic-authority-v1',deploymentPrincipal:'synthetic-deployment-v1',authorityKeyId:'synthetic-authority-key-v1',authorityPublicKeyFingerprint:authority.fingerprint};
for(const client of [owner,wrongOwner]){
 await client.query('INSERT INTO ritc.privacy_journal_origin(lineage,schema_digest,configuration_id) VALUES($1,$2,$3)',[origin.lineage,origin.schemaDigest,origin.configurationId]);
 await client.query('INSERT INTO ritc.privacy_journal_source_registration(source_identity,database_oid,observer_oid) VALUES($1,$2::oid,$3::oid)',[pins.sourceIdentity,databaseOid,observerRole.oid]);
}
const common=[pins.sourceIdentity,pins.lineage,pins.schemaDigest,pins.configurationId,databaseOid];
const signatures=['binding(text,uuid,text,text,oid)','event(text,uuid,text,text,oid,uuid)','acceptance(text,uuid,text,text,oid,uuid)','unacknowledged(text,uuid,text,text,oid,uuid,integer)','acknowledge(text,uuid,text,text,oid,uuid,text,bigint,text)'];
const openHandles=new Set();
function configuration(changes={}){
 return {pins:clone(pins),authorityPublicKey:authority.publicKey,connection:{host:'/tmp',port:55432,database:adminURL.pathname.slice(1),user:observer},databaseOid,observerRoleOid:observerRole.oid,ownerRole:ownerRole.name,ownerRoleOid:ownerRole.oid,applicationName:'journal-source-test-'+randomUUID(),maxConnections:1,...changes};
}
function adapter(changes={}){const config=configuration(changes),handle={...createPostgresCommittedSource(config),config};openHandles.add(handle);return handle;}
async function stop(handle){await handle.close();openHandles.delete(handle);}
async function connection(role=observer,url=adminURL){const u=new URL(url);u.username=role;u.password='';const c=new pg.Client({connectionString:u.toString()});await c.connect();return c;}
async function insert(event,client=owner,createdAt='2026-11-03T12:00:00Z'){
 await client.query('INSERT INTO ritc.privacy_journal_outbox(event_id,lineage,job_id,kind,payload,payload_digest,created_at)VALUES($1,$2,$3,$4,$5::jsonb,$6,$7)',[event.eventId,event.payload.lineage,event.payload.jobId,event.payload.kind,JSON.stringify(event.payload),event.payloadDigest,createdAt]);return event;
}
async function acceptance(){return insert(acceptedEvent(origin));}
function receipt(event,seq=1){
 const unsigned={version:1,keyId:pins.keyId,seq,previousHash:zero,kind:'commit',event};
 const record={...unsigned,signature:sign(null,Buffer.from(canonical(unsigned)),writer.privateKey).toString('base64url')};
 const recordHash=digest(record),byteLength=Buffer.byteLength(canonical(record)+'\n'),scopeDigest=digest({version:1,...pins});
 const identity={seq,previousHash:zero,recordHash,byteLength,eventId:event.eventId,payloadDigest:event.payloadDigest,jobId:event.payload.jobId,transition:'commit'};
 const body={version:1,domain:'ritc-privacy-journal-admission-v1',scopeDigest,authorityKeyId:pins.authorityKeyId,operationId:digest({version:1,scopeDigest,eventId:event.eventId,payloadDigest:event.payloadDigest,transition:'commit'}),admitted:{head:{version:1,...origin,seq,hash:recordHash,fenced:false},generation:1,authorityRevision:1,mode:'active',pendingOperation:null,totalBytes:byteLength},record:identity,stored:{objectKey:`${scopeDigest}/${seq}/${recordHash}`,immutableVersion:'synthetic-exact-version',recordHash,byteLength}};
 return {...body,authoritySignature:sign(null,Buffer.from(canonical(body)),authority.privateKey).toString('base64url')};
}
function resign(proof){const {authoritySignature,...body}=proof;return {...body,authoritySignature:sign(null,Buffer.from(canonical(body)),authority.privateKey).toString('base64url')};}
const acknowledge=(source,event,proof=receipt(event),c=call())=>source.acknowledge(event.eventId,event.payloadDigest,proof.record.seq,proof.record.recordHash,proof,c);
const ackRows=async event=>(await owner.query('SELECT event_id::text,payload_digest,head_seq::text,head_hash FROM ritc.privacy_journal_ack WHERE event_id=$1',[event.eventId])).rows;
const activities=async name=>(await owner.query('SELECT pid,state,wait_event_type,wait_event,query FROM pg_stat_activity WHERE datname=current_database() AND application_name=$1 ORDER BY pid',[name])).rows;
async function until(check,label,ms=6000){const end=Date.now()+ms;while(Date.now()<end){const value=await check();if(value)return value;await delay(15);}throw Error('Timed out observing '+label);}
async function blocked(name,c){const tag=createHash('sha256').update(c.attemptId).digest('hex');return until(async()=>{const rows=await activities(name);return rows.find(x=>x.wait_event_type==='Lock'&&x.query.includes(tag));},'actual blocked backend');}
async function backendGone(pid,ms=6000){await until(async()=>!(await owner.query('SELECT 1 FROM pg_stat_activity WHERE pid=$1',[pid])).rowCount,'backend rollback/removal',ms);}
async function blocker(sql){const c=await connection(ownerRole.name);await c.query('BEGIN');await c.query(sql);return c;}
async function unlock(c){await c.query('ROLLBACK').catch(()=>{});await c.end().catch(()=>{});}

test.after(async()=>{for(const h of openHandles)await h.close().catch(()=>{});await wrongOwner.end();await owner.end();});

test('024 uses fixed definer/search_path, PUBLIC/app/worker denied, observer raw journal and helper access denied',async()=>{
 const funcs=(await owner.query("SELECT p.proname,p.prosecdef,p.proconfig,pg_get_userbyid(p.proowner) AS owner,EXISTS(SELECT 1 FROM aclexplode(COALESCE(p.proacl,acldefault('f',p.proowner))) a WHERE a.grantee=0 AND a.privilege_type='EXECUTE') AS public_execute FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='ritc' AND p.proname LIKE 'privacy_journal_source_%' ORDER BY p.proname")).rows;
 assert.equal(funcs.length,6);for(const f of funcs){assert.equal(f.prosecdef,true);assert.deepEqual(f.proconfig,['search_path=pg_catalog']);assert.equal(f.owner,ownerRole.name);assert.equal(f.public_execute,false);}
 for(const role of ['ritc_test_runtime','ritc_test_worker',observer]){
  const c=await connection(role);try{
   for(const table of ['privacy_journal_origin','privacy_journal_outbox','privacy_journal_target','privacy_journal_ack','privacy_journal_source_registration'])await assert.rejects(async()=>c.query('SELECT * FROM ritc.'+table),{code:'42501'});
   await assert.rejects(async()=>c.query('SELECT ritc.privacy_journal_acknowledge($1,$2,1,$3)',[randomUUID(),'a'.repeat(64),'b'.repeat(64)]),{code:'42501'});
   await assert.rejects(async()=>c.query('SELECT ritc.privacy_journal_source_guard($1,$2,$3,$4,$5::oid)',common),{code:'42501'});
   if(role!==observer)for(const sig of signatures)assert.equal((await c.query('SELECT has_function_privilege(current_user,$1,\'EXECUTE\') AS allowed',['ritc.privacy_journal_source_'+sig])).rows[0].allowed,false);
  }finally{await c.end();}
 }
 const h=adapter();try{let registered;try{registered=await h.source.readOrigin(call());}catch(error){console.error('Synthetic fixture cause:',error.cause?.code??'',error.cause?.message??'');throw error;}assert.deepEqual(registered,{...origin,sourceIdentity:pins.sourceIdentity,fenced:false});}finally{await stop(h);}
});

test('real committed visibility, exact original acceptance and deterministic bounded job list',async()=>{
 const h=adapter(),a=acceptedEvent(origin),transaction=await connection(ownerRole.name);
 try{
  await transaction.query('BEGIN');await insert(a,transaction);
  await assert.rejects(async()=>h.source.readCommittedEvent(a.eventId,call()));
  await transaction.query('COMMIT');assert.deepEqual(await h.source.readCommittedEvent(a.eventId,call()),a);
  const p=await insert(progressEvent(a,'source_pending'),owner,'2026-11-03T11:59:59Z');
  assert.deepEqual(await h.source.readCommittedAcceptance(a.payload.jobId,call()),a);
  assert.deepEqual(await h.source.listUnacknowledgedJobEvents(a.payload.jobId,call()),[a.eventId,p.eventId]);
  const c=await connection();try{
   await assert.rejects(async()=>c.query('SELECT ritc.privacy_journal_source_unacknowledged($1,$2,$3,$4,$5::oid,$6,1)',[...common,a.payload.jobId]),/too_large/);
   for(const n of [0,-1,10001,null])await assert.rejects(async()=>c.query('SELECT ritc.privacy_journal_source_unacknowledged($1,$2,$3,$4,$5::oid,$6,$7)',[...common,a.payload.jobId,n]),/bound/);
   await assert.rejects(async()=>c.query('SELECT ritc.privacy_journal_source_unacknowledged($1,$2,$3,$4,$5::oid,$6,10000)',[...common,randomUUID()]),/acceptance_missing/);
  }finally{await c.end();}
  await acknowledge(h.source,a);assert.deepEqual(await h.source.listUnacknowledgedJobEvents(a.payload.jobId,call()),[p.eventId]);
  assert.deepEqual(await h.source.readCommittedAcceptance(a.payload.jobId,call()),a);
 }finally{await transaction.end();await stop(h);}
});

test('SQL event reads reject oversized payload and persisted digest or envelope conflicts',async()=>{
 const variants=[];
 const oversized=acceptedEvent(origin);oversized.payload.data.padding='x'.repeat(1048576);oversized.payloadDigest=digest(oversized.payload);variants.push(oversized);
 const wrongDigest=acceptedEvent(origin);wrongDigest.payloadDigest='e'.repeat(64);variants.push(wrongDigest);
 const wrongEnvelope=acceptedEvent(origin);wrongEnvelope.payload.eventId=randomUUID();wrongEnvelope.payloadDigest=digest(wrongEnvelope.payload);variants.push(wrongEnvelope);
 for(const event of variants){await insert(event);const c=await connection();try{await assert.rejects(async()=>c.query('SELECT ritc.privacy_journal_source_event($1,$2,$3,$4,$5::oid,$6)',[...common,event.eventId]));}finally{await c.end();}const h=adapter();try{await assert.rejects(async()=>h.source.readCommittedEvent(event.eventId,call()));assert.equal((await ackRows(event)).length,0);}finally{await stop(h);}}
});

test('SQL repeats exact source, origin and database pins and refuses SET ROLE or foreign login',async()=>{
 const c=await connection();try{
  for(const [index,value]of [[0,'wrong-source'],[1,randomUUID()],[2,'e'.repeat(64)],[3,'wrong-config'],[4,String(Number(databaseOid)+1)]]){
   const changed=[...common];changed[index]=value;
   await assert.rejects(async()=>c.query('SELECT ritc.privacy_journal_source_binding($1,$2,$3,$4,$5::oid)',changed),{code:'42501'});
  }
  await c.query('SET ROLE ritc_guardian_verifier');await assert.rejects(async()=>c.query('SELECT ritc.privacy_journal_source_binding($1,$2,$3,$4,$5::oid)',common),{code:'42501'});await c.query('RESET ROLE');
 }finally{await c.end();}
 const wrong=await connection(observer,wrongURL);try{await assert.rejects(async()=>wrong.query('SELECT ritc.privacy_journal_source_binding($1,$2,$3,$4,$5::oid)',common),{code:'42501'});}finally{await wrong.end();}
 await assert.rejects(async()=>owner.query('SELECT ritc.privacy_journal_source_binding($1,$2,$3,$4,$5::oid)',common),{code:'42501'});
 assert.throws(()=>adapter({connection:{host:'/tmp',port:55432,database:adminURL.pathname.slice(1),user:ownerRole.name}}),/Separate/);
 for(const changes of [{pins:{...pins,sourceIdentity:'wrong-source'}},{databaseOid:String(Number(databaseOid)+1)},{connection:{host:'/tmp',port:55432,database:wrongURL.pathname.slice(1),user:observer}},{connection:{host:'/tmp',port:55432,database:adminURL.pathname.slice(1),user:'ritc_test_runtime'}}]){
  const h=adapter(changes);try{await assert.rejects(async()=>h.source.readOrigin(call()));}finally{await stop(h);}
 }
});

test('every SQL wrapper rejects newly effective column/extra-function capabilities, including after a blocked checkout',async()=>{
 const a=await acceptance(),proof=receipt(a),c=await connection();
 const invocations=[['binding',[...common]],['event',[...common,a.eventId]],['acceptance',[...common,a.payload.jobId]],['unacknowledged',[...common,a.payload.jobId,10000]],['acknowledge',[...common,a.eventId,a.payloadDigest,proof.record.seq,proof.record.recordHash]]];
 try{
  for(const [grant,revoke] of [
   ['GRANT SELECT(event_id) ON ritc.privacy_journal_outbox TO '+observer,'REVOKE SELECT(event_id) ON ritc.privacy_journal_outbox FROM '+observer],
   ['GRANT EXECUTE ON FUNCTION ritc.privacy_journal_canonical(jsonb) TO '+observer,'REVOKE EXECUTE ON FUNCTION ritc.privacy_journal_canonical(jsonb) FROM '+observer],
   ...['PUBLIC','ritc_app','ritc_worker'].map(role=>['GRANT EXECUTE ON FUNCTION ritc.privacy_journal_source_acknowledge(text,uuid,text,text,oid,uuid,text,bigint,text) TO '+role,'REVOKE EXECUTE ON FUNCTION ritc.privacy_journal_source_acknowledge(text,uuid,text,text,oid,uuid,text,bigint,text) FROM '+role]),
   ["CREATE SCHEMA pga;CREATE FUNCTION pga.synthetic_source_extra() RETURNS boolean LANGUAGE sql AS 'SELECT true';REVOKE ALL ON FUNCTION pga.synthetic_source_extra() FROM PUBLIC;GRANT USAGE ON SCHEMA pga TO "+observer+';GRANT EXECUTE ON FUNCTION pga.synthetic_source_extra() TO '+observer,'DROP SCHEMA pga CASCADE'],
  ]){
   await owner.query(grant);
   try{
    for(const [name,args]of invocations){const placeholders=args.map((_,i)=>'$'+(i+1)+(i===4?'::oid':'')).join(',');await assert.rejects(async()=>c.query('SELECT ritc.privacy_journal_source_'+name+'('+placeholders+')',args),{code:'42501'});}
    const h=adapter();try{await assert.rejects(async()=>h.source.readOrigin(call()));}finally{await stop(h);}
   }finally{await owner.query(revoke);}
  }
  // Block inside the SQL guard after the Node checkout preflight. A grant made
  // during that wait must still fail the SQL boundary after the lock releases.
  const h=adapter(),held=await blocker('LOCK TABLE ritc.privacy_journal_origin IN ACCESS EXCLUSIVE MODE'),request=call();
  let pending;try{
   pending=h.source.readCommittedEvent(a.eventId,request);pending.catch(()=>{});await blocked(h.config.applicationName,request);
   await owner.query('GRANT SELECT(event_id) ON ritc.privacy_journal_outbox TO '+observer);
   await unlock(held);await assert.rejects(async()=>pending);
  }finally{await unlock(held);await owner.query('REVOKE SELECT(event_id) ON ritc.privacy_journal_outbox FROM '+observer);await stop(h);}
  assert.equal((await ackRows(a)).length,0);
 }finally{await c.end();}
});

test('independently signed receipt is verified before any SQL: malformed/wrong event/job/digest/transition/head/scope/key rejected',async()=>{
 const a=await acceptance(),original=receipt(a);
 const variants=[null,{}, {...original,authoritySignature:'A'.repeat(86)}];
 for(const change of [p=>p.record.eventId=randomUUID(),p=>p.record.payloadDigest='f'.repeat(64),p=>p.record.transition='intent',p=>p.record.seq++,p=>p.record.recordHash='e'.repeat(64),p=>p.scopeDigest='e'.repeat(64),p=>p.authorityKeyId='wrong-key',p=>p.extra=true]){const p=clone(original);change(p);variants.push(resign(p));}
 for(const proof of variants){const h=adapter();try{assert.equal((await activities(h.config.applicationName)).length,0);await assert.rejects(async()=>h.source.acknowledge(a.eventId,a.payloadDigest,original.record.seq,original.record.recordHash,proof,call()));assert.equal((await activities(h.config.applicationName)).length,0);assert.equal((await ackRows(a)).length,0);}finally{await stop(h);}}
 const wrongJob=clone(original);wrongJob.record.jobId=randomUUID();
 const bound=adapter();try{await assert.rejects(async()=>acknowledge(bound.source,a,resign(wrongJob)));assert.equal((await ackRows(a)).length,0);}finally{await stop(bound);}
 const h=adapter();try{
  await acknowledge(h.source,a,original);await acknowledge(h.source,a,original);
  assert.deepEqual(await ackRows(a),[{event_id:a.eventId,payload_digest:a.payloadDigest,head_seq:String(original.record.seq),head_hash:original.record.recordHash}]);
  await assert.rejects(async()=>acknowledge(h.source,a,receipt(a,2)));
  assert.equal((await ackRows(a))[0].head_seq,String(original.record.seq));
 }finally{await stop(h);}
});

test('preaborted and expired calls start no backend or SQL; queued abort starts no later acknowledgement',async()=>{
 const a=await acceptance();
 for(const variant of ['abort','deadline']){const h=adapter(),c=call();if(variant==='abort')c.controller.abort();else c.deadlineUnixMs=Date.now()-1;
  try{await assert.rejects(async()=>h.source.readOrigin(c));await assert.rejects(async()=>acknowledge(h.source,a,receipt(a),c));assert.equal((await activities(h.config.applicationName)).length,0);assert.equal((await ackRows(a)).length,0);}finally{await stop(h);}}
 const h=adapter(),held=await blocker('LOCK TABLE ritc.privacy_journal_outbox IN ACCESS EXCLUSIVE MODE'),first=call(),second=call();
 let pending;try{
  pending=h.source.readCommittedEvent(a.eventId,first);pending.catch(()=>{});const active=await blocked(h.config.applicationName,first);
  const queued=acknowledge(h.source,a,receipt(a),second);queued.catch(()=>{});await delay(30);second.controller.abort();await assert.rejects(async()=>queued);
  const tag=createHash('sha256').update(second.attemptId).digest('hex');assert(!(await activities(h.config.applicationName)).some(x=>x.query.includes(tag)));
  await unlock(held);assert.deepEqual(await pending,a);await delay(60);
  assert.equal((await ackRows(a)).length,0);assert(!(await activities(h.config.applicationName)).some(x=>x.query.includes(tag)));
  await backendGone(active.pid);assert.deepEqual(await h.source.readCommittedEvent(a.eventId,call()),a);assert.notEqual((await activities(h.config.applicationName))[0].pid,active.pid);
 }finally{await unlock(held);await stop(h);}
});

test('actual blocked read cancellation destroys connection; backend terminates within SQL timeout and a fresh call succeeds',async()=>{
 const a=await acceptance(),h=adapter(),held=await blocker('LOCK TABLE ritc.privacy_journal_outbox IN ACCESS EXCLUSIVE MODE'),c=call({deadlineUnixMs:Date.now()+800});
 let unlocked=false;try{
  const pending=h.source.readCommittedEvent(a.eventId,c);pending.catch(()=>{});const active=await blocked(h.config.applicationName,c),start=Date.now();c.controller.abort();await assert.rejects(async()=>pending);assert(Date.now()-start<500);
  // A disconnected blocked backend may remain until its actual statement_timeout.
  await backendGone(active.pid,4000);await unlock(held);unlocked=true;
  assert.deepEqual(await h.source.readCommittedEvent(a.eventId,call()),a);assert.equal((await ackRows(a)).length,0);
 }finally{if(!unlocked)await unlock(held);await stop(h);}
});

test('blocked acknowledgement abort rolls back: no late acknowledgement after unblock or actual statement timeout',async()=>{
 const a=await acceptance(),h=adapter(),held=await blocker('LOCK TABLE ritc.privacy_journal_ack IN ACCESS EXCLUSIVE MODE'),c=call({deadlineUnixMs:Date.now()+900});
 let unlocked=false;try{
  const pending=acknowledge(h.source,a,receipt(a),c);pending.catch(()=>{});const active=await blocked(h.config.applicationName,c);c.controller.abort();await assert.rejects(async()=>pending);
  await unlock(held);unlocked=true;await backendGone(active.pid,4000);assert.equal((await ackRows(a)).length,0);await delay(80);assert.equal((await ackRows(a)).length,0);
  await acknowledge(h.source,a);assert.equal((await ackRows(a)).length,1);
 }finally{if(!unlocked)await unlock(held);await stop(h);}
});

test('actual deadline bounds blocked SQL and leaves no acknowledgement or idle transaction',async()=>{
 const a=await acceptance(),h=adapter(),held=await blocker('LOCK TABLE ritc.privacy_journal_ack IN ACCESS EXCLUSIVE MODE'),c=call({deadlineUnixMs:Date.now()+450});
 let unlocked=false;try{
  const pending=acknowledge(h.source,a,receipt(a),c);pending.catch(()=>{});const active=await blocked(h.config.applicationName,c);await assert.rejects(async()=>pending);
  await backendGone(active.pid,4000);await unlock(held);unlocked=true;assert.equal((await ackRows(a)).length,0);
  assert(!(await activities(h.config.applicationName)).some(x=>x.state==='idle in transaction'));
 }finally{if(!unlocked)await unlock(held);await stop(h);}
});

test('real COMMIT response loss reports uncertainty; late committed acknowledgement remains exact and retryable',async()=>{
 const a=await acceptance(),proof=receipt(a),h=adapter(),c=call();
 await owner.query("CREATE FUNCTION ritc.synthetic_ack_commit_delay() RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog AS $$ BEGIN PERFORM pg_sleep(0.65);RETURN NEW;END $$; REVOKE ALL ON FUNCTION ritc.synthetic_ack_commit_delay() FROM PUBLIC,ritc_app,ritc_worker,ritc_guardian_verifier");
 await owner.query('CREATE CONSTRAINT TRIGGER synthetic_ack_commit_delay AFTER INSERT ON ritc.privacy_journal_ack DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION ritc.synthetic_ack_commit_delay()');
 try{
  const pending=acknowledge(h.source,a,proof,c);pending.catch(()=>{});
  const active=await until(async()=>{const rows=await activities(h.config.applicationName);return rows.find(x=>x.query.includes('COMMIT')&&x.wait_event==='PgSleep');},'real COMMIT deferred trigger executing');
  assert.equal((await ackRows(a)).length,0);c.controller.abort();
  await assert.rejects(async()=>pending,error=>error.acknowledgementMayHaveCommitted===true&&error.sqlDispatched===true);
  await backendGone(active.pid,5000);
  assert.deepEqual(await ackRows(a),[{event_id:a.eventId,payload_digest:a.payloadDigest,head_seq:String(proof.record.seq),head_hash:proof.record.recordHash}]);
  await stop(h);const retry=adapter();try{await acknowledge(retry.source,a,proof);assert.equal((await ackRows(a)).length,1);}finally{await stop(retry);}
 }finally{
  await stop(h);await owner.query('DROP TRIGGER synthetic_ack_commit_delay ON ritc.privacy_journal_ack');await owner.query('DROP FUNCTION ritc.synthetic_ack_commit_delay()');
 }
});
