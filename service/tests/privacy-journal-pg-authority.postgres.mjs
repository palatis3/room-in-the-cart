import assert from 'node:assert/strict';
import {createHash,randomUUID,randomBytes,sign} from 'node:crypto';
import {execFileSync,spawn} from 'node:child_process';
import {once} from 'node:events';
import {chmod,mkdir,mkdtemp,readFile,rm,writeFile} from 'node:fs/promises';
import {join,resolve} from 'node:path';
import {createInterface} from 'node:readline';
import {setTimeout as delay} from 'node:timers/promises';
import {fileURLToPath} from 'node:url';
import test,{before,after} from 'node:test';
import pg from 'pg';
import {exportJWK,generateKeyPair,SignJWT} from 'jose';
import {migrate} from '../scripts/migrate.mjs';
import {createPostgresJournalAuthority} from '../dist/privacy-journal-pg-authority.js';
import {createPostgresCommittedSource} from '../dist/privacy-journal-pg-source.js';
import {durableJournalScopeDigest,verifyDurableAdmissionReceipt} from '../dist/privacy-journal-durable.js';
import {createHTTPSJournalAuthority} from '../dist/privacy-journal-https.js';
import {activateIndependentSuccessor,createIndependentRecovery,registerIndependentSuccessor,verifyIndependentArchiveWindow,verifyIndependentRecovery} from '../dist/privacy-journal-recovery.js';
import {validatePrivacyRestoreEvents,verifyPrivacyJournal} from '../dist/privacy-journal.js';
import {MAX_JOURNAL_BYTES,MAX_JOURNAL_RECORDS,MAX_INTENT_RESOLUTION_OVERHEAD,MAX_SOURCE_EVENT_BYTES} from '../dist/privacy-journal-limits.js';
import {PrivacyMaintenance,PrivacyService} from '../dist/privacy.js';
import {HouseholdRepository} from '../dist/repository.js';
import {SupabaseSessionVerifier} from '../dist/auth.js';
import {createRuntime} from '../dist/runtime.js';
import {createOperationsRuntime} from '../dist/operations-runtime.js';
import {privacyDeploymentConfigurationId} from '../dist/privacy-runtime.js';
import {fixture} from './durable-authority-fixture.mjs';
import {call,canonical,digest,gate,progressEvent,zero} from './durable-independent-fixture.mjs';

if(!process.env.TEST_POSTGRES_BIN)throw Error('Set TEST_POSTGRES_BIN to the directory containing PostgreSQL executables');
const bin=resolve(process.env.TEST_POSTGRES_BIN),dir=await mkdtemp('/tmp/ritc-jca-');
const data=join(dir,'data'),ownerRole='ritc_fixture_owner',objectRole='ritc_fixture_records',checkpointRole='ritc_fixture_checkpoint';
const storeIdentity='fixture-record-store-v1';
const environment={PATH:'/usr/bin:/bin',LANG:'C',LC_ALL:'C'};
let running=false,owner,tls;
const pool=user=>new pg.Pool({host:dir,port:55433,database:'postgres',user,password:()=>'',ssl:false,connectionTimeoutMillis:1500,max:2});
const pgTool=(tool,args)=>execFileSync(join(bin,tool),args,{env:environment,stdio:['ignore','pipe','pipe'],timeout:20_000});
function start(){pgTool('pg_ctl',['-D',data,'-l',join(dir,'postgres.log'),'-o',`-h '' -k ${dir} -p 55433 -c unix_socket_permissions=0700`,'-w','start']);running=true;}
function stop(mode){pgTool('pg_ctl',['-D',data,'-m',mode,'-w','stop']);running=false;}
before(async()=>{
 pgTool('initdb',['-D',data,'-A','trust','-U',ownerRole,'--no-locale','-E','UTF8']);start();
 owner=pool(ownerRole);
 await owner.query(`CREATE ROLE ritc_checkpoint_runtime NOLOGIN; CREATE ROLE ritc_record_runtime NOLOGIN;
  CREATE ROLE ${objectRole} LOGIN; CREATE ROLE ${checkpointRole} LOGIN;
  GRANT ritc_checkpoint_runtime TO ${checkpointRole}; GRANT ritc_record_runtime TO ${objectRole}`);
 await owner.query(await readFile(new URL('../journal-authority/001_checkpoint.sql',import.meta.url),'utf8'));
 await owner.query(await readFile(new URL('../journal-authority/002_recovery.sql',import.meta.url),'utf8'));
 await owner.query(await readFile(new URL('../journal-authority/003_worker_capacity.sql',import.meta.url),'utf8'));
 await owner.query(await readFile(new URL('../journal-authority/004_successor.sql',import.meta.url),'utf8'));
 await owner.query('INSERT INTO ritc_records.store(identity) VALUES($1)',[storeIdentity]);
 const config=join(dir,'tls.cnf'),keyPath=join(dir,'tls.key'),certPath=join(dir,'tls.crt');
 await writeFile(config,'[req]\nprompt=no\ndistinguished_name=dn\nx509_extensions=ext\n[dn]\nCN=127.0.0.1\n[ext]\nbasicConstraints=critical,CA:TRUE\nsubjectAltName=IP:127.0.0.1\n');
 execFileSync('openssl',['req','-new','-x509','-nodes','-newkey','rsa:2048','-days','1','-config',config,'-keyout',keyPath,'-out',certPath],{env:environment,stdio:'pipe',timeout:10000});
 tls={key:await readFile(keyPath),cert:await readFile(certPath,'utf8')};
});
after(async()=>{
 await owner?.end();
 if(running)stop('fast');
 await rm(dir,{recursive:true,force:true});
});

const nonce=context=>({...context,requestNonce:randomBytes(32).toString('hex')});
const time=()=>call({deadlineUnixMs:Date.now()+5000});
async function openAuthority(f,changes={}){
 const checkpointPool=pool(checkpointRole),recordPool=pool(objectRole);
 try{
  const ports=await createPostgresJournalAuthority({pins:f.pins,writerPublicKey:f.writerKeys.publicKey,
   authorityPrivateKey:f.authorityKeys.privateKey,checkpointPool,recordPool,...changes});
  return {...ports,checkpointPool,recordPool,close:()=>Promise.all([checkpointPool.end(),recordPool.end()])};
 }catch(error){await Promise.all([checkpointPool.end(),recordPool.end()]);throw error;}
}
async function register(pins){
 const f=fixture(pins),scope=durableJournalScopeDigest(f.pins);
 const head={head:{version:1,...f.origin,seq:0,hash:zero,fenced:false},generation:1,authorityRevision:0,mode:'active',pendingOperation:null,totalBytes:0};
 await owner.query('INSERT INTO ritc_checkpoint.origin(lineage,scope_digest,head) VALUES($1,$2,$3)',[f.pins.lineage,scope,head]);
 return {f,head,scope,open:changes=>openAuthority(f,changes)};
}
function signed(f,head,event,transition){
 const body={version:1,keyId:f.pins.keyId,seq:head.head.seq+1,previousHash:head.head.hash,kind:transition,event};
 const record={...body,signature:sign(null,Buffer.from(canonical(body)),f.writerKeys.privateKey).toString('base64url')};
 const content=Buffer.from(canonical(record)+'\n');
 return {content,identity:{seq:record.seq,previousHash:record.previousHash,recordHash:digest(record),byteLength:content.length,eventId:event.eventId,payloadDigest:event.payloadDigest,jobId:event.payload.jobId,transition}};
}
async function reserve(fixture,service,event,transition,context){
 const {authority,uncertainty}=service,{scope,f}=fixture;
 const claim=await uncertainty.begin({scopeDigest:scope,eventId:event.eventId,transition},context);
 const {value:head}=await authority.readCurrent(nonce(context));
 const {content,identity}=signed(f,head,event,transition);
 const {value:ticket}=await authority.reserve(head,identity,nonce(context));
 return {ticket,claim,content};
}
async function startAuthority(configPath){
 const child=spawn(process.execPath,[fileURLToPath(new URL('../scripts/journal-authority.mjs',import.meta.url)),configPath],
  {env:environment,stdio:['ignore','pipe','pipe']});
 const finished=once(child,'exit');finished.catch(()=>{});
 const reader=createInterface({input:child.stdout});
 child.stderr.resume();
 const stop=async()=>{if(child.exitCode===null&&child.signalCode===null)child.kill('SIGTERM');await finished;};
 try{
  const [line]=await Promise.race([once(reader,'line',{signal:AbortSignal.timeout(4000)}),finished.then(()=>{throw Error('Authority process exited before listening');})]);
  const message=JSON.parse(line);assert.equal(message.event,'journal_authority_listening');
  return {origin:`https://127.0.0.1:${message.port}`,stop};
 }catch(error){await stop();throw error;}finally{reader.close();}
}
async function sourceCluster(){
 const socket=await mkdtemp('/tmp/ritc-jcs-'),cluster=join(socket,'data');
 const runtime='ritc_fixture_app',worker='ritc_fixture_worker',observer='ritc_fixture_observer';
 const sourcePool=(user,database='postgres')=>new pg.Pool({host:socket,port:55434,database,user,password:()=>'',ssl:false,connectionTimeoutMillis:1500,max:2});
 let sourceOwner,started=false;
 const close=async()=>{
  await sourceOwner?.end();
  if(started)pgTool('pg_ctl',['-D',cluster,'-m','fast','-w','stop']);
  await rm(socket,{recursive:true,force:true});
 };
 try{
  pgTool('initdb',['-D',cluster,'-A','trust','-U',ownerRole,'--no-locale','-E','UTF8']);
  pgTool('pg_ctl',['-D',cluster,'-l',join(socket,'postgres.log'),'-o',`-h '' -k ${socket} -p 55434 -c unix_socket_permissions=0700`,'-w','start']);started=true;
  sourceOwner=sourcePool(ownerRole);
  await sourceOwner.query('CREATE SCHEMA auth; CREATE TABLE auth.users(id uuid PRIMARY KEY,email text,email_confirmed_at timestamptz); CREATE TABLE auth.sessions(id uuid PRIMARY KEY,user_id uuid NOT NULL,not_after timestamptz)');
  await migrate(`postgresql://${ownerRole}@localhost/postgres?host=${encodeURIComponent(socket)}&port=55434`);
  await sourceOwner.query(`CREATE ROLE ${runtime} LOGIN; CREATE ROLE ${worker} LOGIN; CREATE ROLE ${observer} LOGIN;
   GRANT ritc_app TO ${runtime}; GRANT ritc_worker TO ${worker};
   REVOKE ALL ON DATABASE postgres FROM PUBLIC;
   GRANT CONNECT ON DATABASE postgres TO ${runtime},${worker},${observer};
   REVOKE CREATE ON SCHEMA public FROM PUBLIC;
   REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA ritc FROM PUBLIC;
   GRANT USAGE ON SCHEMA ritc TO ${observer};
   GRANT EXECUTE ON FUNCTION ritc.privacy_journal_source_binding(text,uuid,text,text,oid),
    ritc.privacy_journal_source_event(text,uuid,text,text,oid,uuid),
    ritc.privacy_journal_source_acceptance(text,uuid,text,text,oid,uuid),
    ritc.privacy_journal_source_unacknowledged(text,uuid,text,text,oid,uuid,integer),
    ritc.privacy_journal_source_acknowledge(text,uuid,text,text,oid,uuid,text,bigint,text) TO ${observer}`);
  const schemaDigest=digest((await sourceOwner.query('SELECT version,checksum FROM public.ritc_schema_migration ORDER BY version')).rows);
  const {database_oid,owner_oid,observer_oid}=(await sourceOwner.query(`SELECT
   (SELECT oid::text FROM pg_database WHERE datname=current_database()) AS database_oid,
   (SELECT oid::text FROM pg_roles WHERE rolname=current_user) AS owner_oid,
   (SELECT oid::text FROM pg_roles WHERE rolname=$1) AS observer_oid`,[observer])).rows[0];
  return {owner:sourceOwner,close,schemaDigest,pool:sourcePool,runtime,worker,observer,
   configuration:{databaseOid:database_oid,observerRoleOid:observer_oid,ownerRoleOid:owner_oid,ownerRole,
    connection:{host:socket,port:55434,database:'postgres',user:observer},applicationName:'ritc-independent-source-fixture'}};
 }catch(error){await close();throw error;}
}

async function recoveryFixture(source,configurationId){
 const r=await register({schemaDigest:source.schemaDigest,...(configurationId?{configurationId}:{})});
 const pins=r.f.pins;
 await source.owner.query('INSERT INTO ritc.privacy_journal_origin(lineage,schema_digest,configuration_id) VALUES($1,$2,$3)',[pins.lineage,pins.schemaDigest,pins.configurationId]);
 await source.owner.query('INSERT INTO ritc.privacy_journal_source_registration(source_identity,database_oid,observer_oid) VALUES($1,$2,$3)',
  [pins.sourceIdentity,source.configuration.databaseOid,source.configuration.observerRoleOid]);
 const {database_oid,owner_oid}=(await owner.query(`SELECT
  (SELECT oid::text FROM pg_database WHERE datname=current_database()) AS database_oid,
  (SELECT oid::text FROM pg_roles WHERE rolname=current_user) AS owner_oid`)).rows[0];
 const config={pins,writerPrivateKey:r.f.writerKeys.privateKey,authorityPrivateKey:r.f.authorityKeys.privateKey,
  source:{pool:source.owner,identity:{database:'postgres',databaseOid:source.configuration.databaseOid,owner:ownerRole,ownerOid:source.configuration.ownerRoleOid}},
  checkpoint:{pool:owner,identity:{database:'postgres',databaseOid:database_oid,owner:ownerRole,ownerOid:owner_oid}}};
 return {r,config,operator:createIndependentRecovery(config)};
}
const pem=key=>key.export({format:'pem',type:'pkcs8'}).toString();
function cli(script,...args){
 return JSON.parse(execFileSync(process.execPath,[fileURLToPath(new URL('../scripts/'+script,import.meta.url)),...args],
  {env:environment,stdio:['ignore','pipe','pipe'],timeout:15000}).toString());
}

test('the two runtime roles cannot replace, delete, or impersonate retained records and admissions',async()=>{
 const registration=await register(),ports=await registration.open();
 try{
  await assert.rejects(ports.recordPool.query('SELECT * FROM ritc_checkpoint.origin'),{code:'42501'});
  await assert.rejects(ports.recordPool.query('UPDATE ritc_records.object SET content=content'),{code:'42501'});
  await assert.rejects(ports.recordPool.query('DELETE FROM ritc_records.object'),{code:'42501'});
  await assert.rejects(ports.checkpointPool.query('UPDATE ritc_checkpoint.admission SET receipt=receipt'),{code:'42501'});
  await assert.rejects(ports.checkpointPool.query('DELETE FROM ritc_checkpoint.origin'),{code:'42501'});
  await assert.rejects(ports.checkpointPool.query('INSERT INTO ritc_records.object DEFAULT VALUES'),{code:'42501'});
  await assert.rejects(registration.open({checkpointPool:ports.recordPool}),/Separate journal runtime role/);
  await assert.rejects(registration.open({pins:{...registration.f.pins,recordStoreIdentity:'another-store'}}),/registered authority database/);
  await owner.query('GRANT UPDATE(content) ON ritc_records.object TO ritc_record_runtime');
  try{await assert.rejects(registration.open(),/Separate journal runtime role/);}
  finally{await owner.query('REVOKE UPDATE(content) ON ritc_records.object FROM ritc_record_runtime');}
 }finally{await ports.close();}
});

test('one claim wins across independent clients and cannot be removed by a different attempt or deployment scope',async()=>{
 const r=await register(),first=await r.open(),second=await r.open();
 try{
  const input={scopeDigest:r.scope,eventId:r.f.event().eventId,transition:'intent'};
  const calls=[time(),time()];
  const results=await Promise.allSettled([first.uncertainty.begin(input,calls[0]),second.uncertainty.begin(input,calls[1])]);
  assert.equal(results.filter(result=>result.status==='fulfilled').length,1);
  assert.equal(results.find(result=>result.status==='rejected').reason.code,'deletion_journal_busy');
  const competing=await r.open({pins:{...r.f.pins,deploymentPrincipal:'rotated-writer'}});
  try{await assert.rejects(competing.authority.readCurrent(nonce(time())),/pinned to another deployment/);}finally{await competing.close();}
  const winner=results.findIndex(result=>result.status==='fulfilled');
  const event=r.f.event({eventId:input.eventId}),{identity}=signed(r.f,r.head,event,'intent');
  await assert.rejects(second.authority.reserve(r.head,identity,nonce(calls[1-winner])),/does not cover this attempt/);
 }finally{await Promise.all([first.close(),second.close()]);}
});

test('immutable create checks bytes, CAS rejects forks, and admitted retry returns the original signed receipt',async()=>{
 const r=await register(),ports=await r.open(),context=time(),event=r.f.event();
 try{
  const {ticket,claim,content}=await reserve(r,ports,event,'intent',context);
  const changed=Buffer.from(content);changed[30]^=1;
  await assert.rejects(ports.records.putExact(ticket,changed,context));
  const stored=await ports.records.putExact(ticket,content,context);
  assert.deepEqual(await ports.records.putExact(ticket,content,context),stored);
  await assert.rejects(ports.authority.publish(ticket,{...stored,immutableVersion:randomUUID()},nonce(context)),/Exact immutable record version/);
  const proof=await ports.authority.publish(ticket,stored,nonce(context));
  assert.deepEqual(verifyDurableAdmissionReceipt(proof,r.f.pins,r.f.authorityKeys.publicKey),proof);
  assert.deepEqual(await ports.authority.publish(ticket,stored,nonce(time())),proof);
  assert.deepEqual((await ports.authority.inspectOperation(ticket.operationId,nonce(time()))).value.receipt,proof);
  await assert.rejects(ports.uncertainty.complete(claim,proof,time()),/claim changed/);
  await ports.uncertainty.complete(claim,proof,context);
  const next=time();
  await ports.uncertainty.begin({scopeDigest:r.scope,eventId:event.eventId,transition:'commit'},next);
  await assert.rejects(ports.authority.reserve(r.head,{...ticket.record,transition:'commit'},nonce(next)),/compare-and-set conflict/);
 }finally{await ports.close();}
});

test('progress without the original admitted acceptance is rejected before any record is stored',async()=>{
 const r=await register(),ports=await r.open(),context=time();
 try{
  const {ticket,content}=await reserve(r,ports,progressEvent(r.f.event()),'commit',context);
  await assert.rejects(ports.records.putExact(ticket,content,context),/original accepted authorization/);
  assert.equal((await ports.recordPool.query('SELECT 1 FROM ritc_records.object WHERE object_key=$1',[ticket.objectKey])).rowCount,0);
  assert.equal((await ports.authority.readCurrent(nonce(context))).value.head.seq,0);
 }finally{await ports.close();}
});

test('checkpoint keeps count and byte capacity for the exact resolution of an admitted intent',async()=>{
 const remaining=async(count,over=0)=>{
  const r=await register(),event=r.f.event();
  const head={...r.head,head:{...r.head.head,seq:MAX_JOURNAL_RECORDS-count,hash:'1'.repeat(64)}};
  const size=signed(r.f,head,event,'intent').identity.byteLength;
  head.totalBytes=MAX_JOURNAL_BYTES-size*2-MAX_INTENT_RESOLUTION_OVERHEAD+over;
  // Seed only a high-water checkpoint for this admission boundary test. The
  // separately verified recovery tests exercise a complete authenticated chain.
  await owner.query('UPDATE ritc_checkpoint.origin SET head=$2 WHERE lineage=$1',[r.f.pins.lineage,head]);
  return {r,event,head,ports:await r.open()};
 };
 for(const [count,over] of [[1,0],[2,1]]){
  const {r,event,head,ports}=await remaining(count,over);
  try{
   await assert.rejects(reserve(r,ports,event,'intent',time()),/cover intent resolution/);
   const result=(await ports.authority.readCurrent(nonce(time()))).value;
   assert.deepEqual(result,head);
  }finally{await ports.close();}
 }
 for(const commit of [false,true]){
  const {r,event,ports}=await remaining(2);
  try{
   const context=time(),intent=await reserve(r,ports,event,'intent',context);
   const stored=await ports.records.putExact(intent.ticket,intent.content,context);
   const proof=await ports.authority.publish(intent.ticket,stored,nonce(context));
   await ports.uncertainty.complete(intent.claim,proof,context);
   const followup=time();
   if(commit){
    const next=await reserve(r,ports,event,'commit',followup);
    const record=await ports.records.putExact(next.ticket,next.content,followup);
    const finished=await ports.authority.publish(next.ticket,record,nonce(followup));
    await ports.uncertainty.complete(next.claim,finished,followup);
    assert.equal(finished.admitted.head.seq,MAX_JOURNAL_RECORDS);
    assert.ok(finished.admitted.totalBytes<=MAX_JOURNAL_BYTES);
   }else{
    await assert.rejects(reserve(r,ports,progressEvent(event),'commit',followup),/cover intent resolution/);
    assert.equal((await ports.authority.readCurrent(nonce(time()))).value.head.seq,MAX_JOURNAL_RECORDS-1);
   }
  }finally{await ports.close();}
 }
});

test('worker allowances survive provider retry and lost completion observation across HTTPS authority restarts',async()=>{
 const source=await sourceCluster();
 const runtime=source.pool(source.runtime),worker=source.pool(source.worker);
 let server,remote,observer;
 try{
  const r=await register({schemaDigest:source.schemaDigest});
  await source.owner.query('INSERT INTO ritc.privacy_journal_origin(lineage,schema_digest,configuration_id) VALUES($1,$2,$3)',[r.f.pins.lineage,r.f.pins.schemaDigest,r.f.pins.configurationId]);
  await source.owner.query('INSERT INTO ritc.privacy_journal_source_registration(source_identity,database_oid,observer_oid) VALUES($1,$2,$3)',
   [r.f.pins.sourceIdentity,source.configuration.databaseOid,source.configuration.observerRoleOid]);
  observer=createPostgresCommittedSource({pins:r.f.pins,authorityPublicKey:r.f.authorityKeys.publicKey,...source.configuration});
  const writerToken=randomBytes(32).toString('base64url');
  const path=join(dir,'authority-config.json');
  const database=user=>({host:dir,port:55433,database:'postgres',user});
  await writeFile(path,JSON.stringify({pins:r.f.pins,writerToken,writerPublicKey:r.f.writerKeys.publicKeyPEM,
   authorityPrivateKey:r.f.authorityKeys.privateKey.export({format:'pem',type:'pkcs8'}).toString(),
   checkpointDatabase:database(checkpointRole),recordDatabase:database(objectRole),
   listen:{host:'127.0.0.1',port:0},tls:{key:tls.key.toString('utf8'),cert:tls.cert}}),{mode:0o600,flag:'wx'});
  server=await startAuthority(path);
  const configuration={pins:r.f.pins,origin:server.origin,writerToken,ca:tls.cert};
  remote=createHTTPSJournalAuthority(configuration);
  const wrong=createHTTPSJournalAuthority({...configuration,writerToken:randomBytes(32).toString('base64url')});
  const wrongScope=createHTTPSJournalAuthority({...configuration,pins:{...r.f.pins,deploymentPrincipal:'different-writer'}});
  const wrongTLS=createHTTPSJournalAuthority({...configuration,ca:undefined});
  try{
   await assert.rejects(wrong.authority.readCurrent(nonce(time())),/request rejected/);
   await assert.rejects(wrongScope.authority.readCurrent(nonce(time())),/request rejected/);
   await assert.rejects(wrongTLS.authority.readCurrent(nonce(time())),/self-signed certificate/);
  }finally{wrong.close();wrongScope.close();wrongTLS.close();}
  const {port}=r.f.adapter({source:observer.source,...remote});
  const subject=randomUUID(),sessionId=randomUUID(),issuer='https://durable.fixture.invalid';
  const identity={issuer,subject,sessionId,expiresAt:new Date(Date.now()+60_000),authenticatedAt:new Date(),authenticatedMethod:'otp'};
  await source.owner.query('INSERT INTO auth.sessions(id,user_id) VALUES($1,$2)',[sessionId,subject]);
  const householdId=randomUUID(),memberId=randomUUID();
  await source.owner.query("INSERT INTO ritc.household(household_id,label) VALUES($1,'Allowance fixture')",[householdId]);
  await source.owner.query("INSERT INTO ritc.member(household_id,member_id,issuer,subject,alias,kind,state,organizer) VALUES($1,$2,$3,$4,'Allowance fixture','adult','active',true)",[householdId,memberId,issuer,subject]);
  const input={clientKey:randomUUID(),statusToken:randomBytes(32).toString('base64url'),confirm:true,
   households:[{householdId,organizer:'archive',shops:[],eraseChildProfiles:[]}]};
  const repo=new HouseholdRepository(runtime,{allowChildNetwork:false,noticeVersion:'fixture',sessionStatus:new SupabaseSessionVerifier(issuer)});
  const policy={receiptRetentionDays:1,erasureMarkerRetentionDays:2,verifiedBackupRetentionDays:1};
  let attempts=0,deletionCalls=0;
  const allowances=async()=> (await owner.query('SELECT event_kind FROM ritc_checkpoint.worker_allowance WHERE lineage=$1 AND job_id=$2 ORDER BY event_kind',[r.f.pins.lineage,input.clientKey])).rows.map(row=>row.event_kind);
  const provider={assertAvailable:async()=>{},deleteAccount:async value=>{
   assert.equal(value,subject);
   assert.deepEqual(await allowances(),attempts===0?['source_completed','source_pending']:['source_completed']);
   if(++attempts<=2)throw Error('Synthetic provider outage');
   deletionCalls++;
   await source.owner.query('DELETE FROM auth.sessions WHERE id=$1 AND user_id=$2',[sessionId,subject]);
  }};
  const interrupted=new PrivacyService(repo,{policy,provider,journal:{...port,afterCommit:async()=>{throw Error('Synthetic interruption after app commit');}}});
  await assert.rejects(interrupted.request(identity,input),/Synthetic interruption/);
  assert.equal(deletionCalls,0);
  const intent=(await remote.authority.readCurrent(nonce(time()))).value;
  assert.equal(intent.head.seq,1);
  remote.close();await server.stop();server=await startAuthority(path);
  remote=createHTTPSJournalAuthority({...configuration,origin:server.origin});
  assert.deepEqual((await remote.authority.readCurrent(nonce(time()))).value,intent);
  const {port:journal}=r.f.adapter({source:observer.source,...remote});
  const maintenance=new PrivacyMaintenance(worker,{provider,journal});
  assert.equal((await maintenance.run({batchSize:1})).retryScheduled,1);
  assert.equal(deletionCalls,0);
  assert.deepEqual(await allowances(),['source_completed']);
  assert.ok((await source.owner.query('SELECT erased_at FROM ritc.member WHERE member_id=$1',[memberId])).rows[0].erased_at);
  const afterFirstFailure=(await remote.authority.readCurrent(nonce(time()))).value;
  await source.owner.query("UPDATE ritc.privacy_job SET next_at=clock_timestamp()-interval '1 second' WHERE job_id=$1",[input.clientKey]);
  assert.equal((await maintenance.run({batchSize:1})).retryScheduled,1);
  assert.deepEqual(await allowances(),['source_completed']);
  assert.deepEqual((await remote.authority.readCurrent(nonce(time()))).value,afterFirstFailure);
  await source.owner.query("UPDATE ritc.privacy_job SET next_at=clock_timestamp()-interval '1 second' WHERE job_id=$1",[input.clientKey]);
  const interruptedWorker=new PrivacyMaintenance(worker,{provider,journal:{...journal,acknowledgeJob:async(jobId,call)=>{
   const state=(await source.owner.query('SELECT state FROM ritc.privacy_job WHERE job_id=$1',[jobId])).rows[0].state;
   if(state==='complete')throw Error('Synthetic loss after completion commit');
   return journal.acknowledgeJob(jobId,call);
  }}});
  await assert.rejects(interruptedWorker.run({batchSize:1}),/Synthetic loss after completion/);
  assert.equal(deletionCalls,1);
  assert.deepEqual(await allowances(),['source_completed']);
  remote.close();await server.stop();server=await startAuthority(path);
  remote=createHTTPSJournalAuthority({...configuration,origin:server.origin});
  const {port:reopened}=r.f.adapter({source:observer.source,...remote});
  assert.equal((await new PrivacyMaintenance(worker,{provider,journal:reopened}).run({batchSize:1})).completed,0);
  assert.deepEqual(await allowances(),[]);
  const service=new PrivacyService(repo,{provider,policy,journal:reopened});
  assert.equal((await service.status(input.clientKey,input.statusToken)).status,'complete');
  assert.equal((await remote.authority.readCurrent(nonce(time()))).value.head.seq,5);
  assert.equal(attempts,3);
  assert.equal(deletionCalls,1);
  const rows=(await source.owner.query('SELECT a.head_seq::int AS seq,a.head_hash AS hash,e.kind FROM ritc.privacy_journal_outbox e JOIN ritc.privacy_journal_ack a USING(event_id) WHERE e.job_id=$1 ORDER BY a.head_seq',[input.clientKey])).rows;
  const admissions=(await owner.query("SELECT sequence AS seq,receipt->'record'->>'recordHash' AS hash,event_kind AS kind FROM ritc_checkpoint.admission WHERE lineage=$1 AND transition='commit' ORDER BY sequence",[r.f.pins.lineage])).rows;
  assert.deepEqual(rows,admissions);
  assert.deepEqual(rows.map(row=>row.kind),['acceptance','target_erased','source_pending','source_completed']);
 }finally{
  remote?.close();await server?.stop();await Promise.all([observer?.close(),runtime.end(),worker.end()]);await source.close();
 }
});

test('worker defers at capacity and can spend a held final slot after a new request is refused',async()=>{
 for(const {hasTarget,slots} of [{hasTarget:true,slots:0},{hasTarget:false,slots:1},{hasTarget:false,slots:2}]){
  const source=await sourceCluster(),runtime=source.pool(source.runtime),worker=source.pool(source.worker);
  let ports,observer;
  try{
   const {r}=await recoveryFixture(source),{pins}=r.f;
   // Keep room for the acceptance intent and commit. Give the no-target case
   // one spare slot so the two possible provider outcomes cannot be split.
   const head={...r.head,head:{...r.head.head,seq:MAX_JOURNAL_RECORDS-2-slots,hash:'1'.repeat(64)},totalBytes:4096};
   await owner.query('UPDATE ritc_checkpoint.origin SET head=$2 WHERE lineage=$1',[pins.lineage,head]);
   ports=await r.open();
   observer=createPostgresCommittedSource({pins,authorityPublicKey:r.f.authorityKeys.publicKey,...source.configuration});
   const {port:journal}=r.f.adapter({source:observer.source,authority:ports.authority,records:ports.records,uncertainty:ports.uncertainty});
   const subject=randomUUID(),sessionId=randomUUID(),issuer='https://capacity.fixture.invalid',householdId=randomUUID(),memberId=randomUUID();
   const identity={issuer,subject,sessionId,expiresAt:new Date(Date.now()+60_000),authenticatedAt:new Date(),authenticatedMethod:'otp'};
   await source.owner.query('INSERT INTO auth.sessions(id,user_id) VALUES($1,$2)',[sessionId,subject]);
   if(hasTarget){
    await source.owner.query("INSERT INTO ritc.household(household_id,label) VALUES($1,'Capacity fixture')",[householdId]);
    await source.owner.query("INSERT INTO ritc.member(household_id,member_id,issuer,subject,alias,kind,state,organizer) VALUES($1,$2,$3,$4,'Preserve this member','adult','active',true)",[householdId,memberId,issuer,subject]);
   }
   const input={clientKey:randomUUID(),statusToken:randomBytes(32).toString('base64url'),confirm:true,
    households:hasTarget?[{householdId,organizer:'archive',shops:[],eraseChildProfiles:[]}]:[]};
   const repository=new HouseholdRepository(runtime,{allowChildNetwork:false,noticeVersion:'fixture',sessionStatus:new SupabaseSessionVerifier(issuer)});
   const policy={receiptRetentionDays:1,erasureMarkerRetentionDays:2,verifiedBackupRetentionDays:1};
   let attempts=0,deletions=0;
   const provider={assertAvailable:async()=>{},deleteAccount:async()=>{
    if(++attempts===1&&slots===2)throw Error('Synthetic provider outage');deletions++;
   }};
   const privacy=new PrivacyService(repository,{provider,policy,journal});
   assert.equal((await privacy.request(identity,input)).status,'pending');
   await assert.rejects(runtime.query('SELECT * FROM ritc.privacy_worker_journal_needs($1,$2)',[input.clientKey,randomUUID()]),{code:'42501'});
   assert.equal((await worker.query('SELECT * FROM ritc.privacy_worker_journal_needs($1,$2)',[input.clientKey,randomUUID()])).rowCount,0);
   const maintenance=new PrivacyMaintenance(worker,{provider,journal}),result=await maintenance.run({batchSize:1});
   if(slots===2){
    assert.equal(result.retryScheduled,1);assert.equal(deletions,0);
    const allowance=(await owner.query('SELECT event_kind FROM ritc_checkpoint.worker_allowance WHERE lineage=$1',[pins.lineage])).rows;
    assert.deepEqual(allowance,[{event_kind:'source_completed'}]);
    const rejected={...identity,subject:randomUUID(),sessionId:randomUUID()},rejectedInput={...input,clientKey:randomUUID()};
    await source.owner.query('INSERT INTO auth.sessions(id,user_id) VALUES($1,$2)',[rejected.sessionId,rejected.subject]);
    await assert.rejects(privacy.request(rejected,rejectedInput),{code:'deletion_unavailable'});
    assert.equal((await source.owner.query('SELECT 1 FROM ritc.privacy_job WHERE job_id=$1',[rejectedInput.clientKey])).rowCount,0);
    assert.equal((await owner.query('SELECT claim FROM ritc_checkpoint.origin WHERE lineage=$1',[pins.lineage])).rows[0].claim,null);
    await source.owner.query("UPDATE ritc.privacy_job SET next_at=clock_timestamp()-interval '1 second' WHERE job_id=$1",[input.clientKey]);
    assert.equal((await maintenance.run({batchSize:1})).completed,1);
    assert.equal(deletions,1);
    assert.equal((await ports.authority.readCurrent(nonce(time()))).value.head.seq,MAX_JOURNAL_RECORDS);
    assert.equal((await privacy.status(input.clientKey,input.statusToken)).status,'complete');
    continue;
   }
   assert.equal(result.capacityDeferred,1);assert.equal(result.completed,0);assert.equal(deletions,0);
   if(hasTarget)assert.deepEqual((await source.owner.query('SELECT alias,erased_at FROM ritc.member WHERE member_id=$1',[memberId])).rows[0],{alias:'Preserve this member',erased_at:null});
   assert.deepEqual((await source.owner.query('SELECT kind FROM ritc.privacy_journal_outbox WHERE job_id=$1',[input.clientKey])).rows,[{kind:'acceptance'}]);
   assert.equal((await owner.query('SELECT 1 FROM ritc_checkpoint.worker_allowance WHERE lineage=$1',[pins.lineage])).rowCount,0);
   assert.equal((await privacy.status(input.clientKey,input.statusToken)).status,'pending');
  }finally{await Promise.all([ports?.close(),observer?.close(),runtime.end(),worker.end()]);await source.close();}
 }
});

test('crash restart preserves exact admitted versions, claims, and expired reservations',async()=>{
 const admitted=await register(),uncertain=await register();
 const first=await admitted.open(),second=await uncertain.open(),context=time();
 const {ticket,content}=await reserve(admitted,first,admitted.f.event(),'intent',context);
 const stored=await first.records.putExact(ticket,content,context);
 const proof=await first.authority.publish(ticket,stored,nonce(context));
 const pendingCall=call({deadlineUnixMs:Date.now()+650});
 const pending=await reserve(uncertain,second,uncertain.f.event(),'intent',pendingCall);
 const orphan=await second.records.putExact(pending.ticket,pending.content,pendingCall);
 await Promise.all([first.close(),second.close()]);await owner.end();
 stop('immediate');start();owner=pool(ownerRole);
 const reopened=await admitted.open(),blocked=await uncertain.open();
 try{
  const observed=await reopened.authority.inspectOperation(ticket.operationId,nonce(time()));
  assert.deepEqual(observed.value.receipt,proof);
  assert.deepEqual(await reopened.records.readExact(stored,time()),content);
  await assert.rejects(reopened.uncertainty.begin({scopeDigest:admitted.scope,eventId:ticket.record.eventId,transition:'intent'},time()),{code:'deletion_journal_busy'});
  await delay(Math.max(0,pending.ticket.authorityExpiresAtUnixMs-Date.now()+10));
  assert.equal((await blocked.authority.inspectOperation(pending.ticket.operationId,nonce(time()))).value.state,'blocked');
  assert.equal((await blocked.authority.readCurrent(nonce(time()))).value.head.seq,0);
  assert.deepEqual(await blocked.records.readExact(orphan,time()),pending.content);
  const sameAttempt=call({attemptId:pendingCall.attemptId,deadlineUnixMs:Date.now()+4000});
  await assert.rejects(blocked.authority.publish(pending.ticket,orphan,nonce(sameAttempt)),/reservation expired/);
  await assert.rejects(blocked.uncertainty.begin({scopeDigest:uncertain.scope,eventId:uncertain.f.event().eventId,transition:'intent'},time()),/origin is blocked/);
 }finally{await Promise.all([reopened.close(),blocked.close()]);}
});

test('operator waits for the source, seals exact intents, replays a prior backup, and exports after source loss',async()=>{
 const source=await sourceCluster(),runtime=source.pool(source.runtime);
 let ports,observer,destination,recovery,requestPending;
 let sourceClosed=false;
 const entered=gate(),resume=gate();
 try{
  const {r,config,operator}=await recoveryFixture(source);
  const keys=r.f,pins=keys.pins;
  ports=await r.open();
  observer=createPostgresCommittedSource({pins,authorityPublicKey:keys.authorityKeys.publicKey,...source.configuration});
  const {port:journal}=keys.adapter({source:observer.source,authority:ports.authority,records:ports.records,uncertainty:ports.uncertainty});
  const issuer='https://restore.fixture.invalid';
  const actor=async()=>{
   const subject=randomUUID(),sessionId=randomUUID();
   await source.owner.query('INSERT INTO auth.sessions(id,user_id) VALUES($1,$2)',[sessionId,subject]);
   return {subject,sessionId,issuer,expiresAt:new Date(Date.now()+60000),authenticatedAt:new Date(),authenticatedMethod:'otp'};
  };
  const committed=await actor(),rolledBack=await actor(),retained=await actor();
  const householdId=randomUUID(),otherHousehold=randomUUID(),memberId=randomUUID(),otherMember=randomUUID();
  await source.owner.query("INSERT INTO ritc.household(household_id,label) VALUES($1,'Restore fixture'),($2,'Retained fixture')",[householdId,otherHousehold]);
  await source.owner.query(`INSERT INTO ritc.member(household_id,member_id,issuer,subject,alias,kind,state,organizer,can_contribute)
   VALUES($1,$2,$5,$6,'Remove this member','adult','active',true,true),($3,$4,$5,$7,'Retain this member','adult','active',true,true)`,
   [householdId,memberId,otherHousehold,otherMember,issuer,committed.subject,retained.subject]);
  const deviceId=randomUUID(),grant=randomUUID();
  await source.owner.query('INSERT INTO ritc.device(household_id,member_id,device_id,token_hash,session_id) VALUES($1,$2,$3,$4,$5)',
   [otherHousehold,otherMember,deviceId,createHash('sha256').update(randomUUID()).digest('hex'),retained.sessionId]);
  await source.owner.query("INSERT INTO ritc.request_queue_permission VALUES($1,$2,$3,$4,now(),now()+interval '1 hour')",[otherHousehold,otherMember,deviceId,grant]);
  const socket=source.configuration.connection.host,dump=join(dir,'before-deletion.dump');
  pgTool('pg_dump',['-h',socket,'-p','55434','-U',ownerRole,'-d','postgres','-Fc','-f',dump]);await chmod(dump,0o600);
  await source.owner.query('DELETE FROM ritc.request_queue_permission WHERE grant_id=$1',[grant]); // After the backup.
  const repo=new HouseholdRepository(runtime,{allowChildNetwork:false,noticeVersion:'fixture',sessionStatus:new SupabaseSessionVerifier(issuer)});
  let providerDeletes=0;
  const provider={assertAvailable:async()=>{},deleteAccount:async()=>{providerDeletes++;}};
  const policy={receiptRetentionDays:1,erasureMarkerRetentionDays:2,verifiedBackupRetentionDays:1};
  const input=households=>({clientKey:randomUUID(),statusToken:randomBytes(32).toString('base64url'),confirm:true,households});
  const rolledInput=input([]),committedInput=input([{householdId,organizer:'archive',shops:[],eraseChildProfiles:[]}]);
  const aborting=new PrivacyService(repo,{provider,policy,journal:{...journal,beforeCommit:async(event,context)=>{
   await journal.beforeCommit(event,context);throw Error('Synthetic abort after durable intent');
  }}});
  await assert.rejects(aborting.request(rolledBack,rolledInput),/Synthetic abort/);
  const held=new PrivacyService(repo,{provider,policy,journal:{...journal,beforeCommit:async(event,context)=>{
   await journal.beforeCommit(event,context);entered.resolve();await resume.promise;
  },afterCommit:async()=>{throw Error('Synthetic lost observation');}}});
  requestPending=held.request(committed,committedInput);requestPending.catch(()=>{});
  await Promise.race([entered.promise,requestPending,delay(2000).then(()=>{throw Error('Source never entered held transaction');})]);
  const uncertainCall=time(),uncertain=await reserve(r,ports,keys.event(),'intent',uncertainCall);
  const orphan=await ports.records.putExact(uncertain.ticket,uncertain.content,uncertainCall);
  const wrong=createIndependentRecovery({...config,source:{...config.source,identity:{...config.source.identity,databaseOid:'999999'}}});
  await assert.rejects(wrong.fence(time()),/Fixed recovery database/);
  assert.equal((await ports.authority.readCurrent(nonce(time()))).value.mode,'pending');
  recovery=operator.recover(call({deadlineUnixMs:Date.now()+12000}));recovery.catch(()=>{});
  const started=Date.now();
  while((await ports.authority.readCurrent(nonce(time()))).value.mode!=='recovery'){
   if(Date.now()-started>2000)throw Error('Checkpoint fence did not arrive');await delay(10);
  }
  assert.equal((await source.owner.query('SELECT fenced FROM ritc.privacy_journal_origin')).rows[0].fenced,false);
  await assert.rejects(ports.authority.publish(uncertain.ticket,orphan,nonce(uncertainCall)),/reservation expired or changed/);
  await assert.rejects(ports.checkpointPool.query('UPDATE ritc_checkpoint.origin SET claim=NULL WHERE lineage=$1',[pins.lineage]),{code:'42501'});
  resume.resolve();
  await assert.rejects(requestPending,/Synthetic lost observation/);
  const bundle=await recovery;
  const checked=verifyIndependentRecovery(bundle.bytes,bundle.proof,pins,keys.writerKeys.publicKey,keys.authorityKeys.publicKey);
  assert.equal(checked.events.length,1);
  assert.equal(checked.events[0].payload.jobId,committedInput.clientKey);
  assert.deepEqual(bundle.bytes.toString().trim().split('\n').map(line=>JSON.parse(line).kind),['intent','intent','commit','rollback']);
  assert.equal(bundle.proof.retiredReservation,uncertain.ticket.operationId);
  assert.equal(bundle.proof.retiredClaim,uncertain.claim.claimId);
  assert.equal((await ports.authority.readCurrent(nonce(time()))).value.mode,'sealed');
  await assert.rejects(ports.checkpointPool.query('SELECT proof FROM ritc_checkpoint.recovery_seal WHERE lineage=$1',[pins.lineage]),{code:'42501'});
  assert.throws(()=>verifyIndependentRecovery(bundle.bytes,{...bundle.proof,sourceDatabaseOid:'42'},pins,keys.writerKeys.publicKey,keys.authorityKeys.publicKey),/signature or scope conflict/);
  assert.throws(()=>verifyIndependentRecovery(bundle.bytes.subarray(0,bundle.bytes.lastIndexOf(10,bundle.bytes.length-2)+1),bundle.proof,pins,keys.writerKeys.publicKey,keys.authorityKeys.publicKey),/head conflict/);
  assert.equal((await source.owner.query('SELECT count(*)::int AS n FROM ritc.privacy_journal_ack')).rows[0].n,0);
  assert.equal(providerDeletes,0);

  const exportDirectory=join(dir,'recovery-export'),operatorPath=join(dir,'operator.json');
  await mkdir(exportDirectory,{mode:0o700});
  const endpoint=(identity,host,port)=>({connection:{host,port,database:identity.database,user:identity.owner},databaseOid:identity.databaseOid,ownerOid:identity.ownerOid});
  await writeFile(operatorPath,JSON.stringify({pins,writerPrivateKey:pem(config.writerPrivateKey),authorityPrivateKey:pem(config.authorityPrivateKey),
   checkpoint:endpoint(config.checkpoint.identity,dir,55433),source:endpoint(config.source.identity,socket,55434),exportDirectory}),{mode:0o600});
  const exported=cli('journal-recovery.mjs','recover',operatorPath);
  assert.equal(exported.bundleDigest,bundle.proof.bundleDigest);
  assert.deepEqual(await readFile(join(exportDirectory,'journal.ndjson')),bundle.bytes);
  assert.deepEqual(cli('journal-recovery.mjs','recover',operatorPath),exported);

  const quarantine='ritc_quarantine_'+randomUUID().replaceAll('-','').slice(0,12);
  await source.owner.query('CREATE DATABASE '+quarantine+' TEMPLATE template0');
  await source.owner.query('REVOKE CONNECT ON DATABASE '+quarantine+' FROM PUBLIC');
  await source.owner.query('GRANT CONNECT ON DATABASE '+quarantine+' TO '+source.worker);
  pgTool('pg_restore',['--exit-on-error','--no-owner','-h',socket,'-p','55434','-U',ownerRole,'-d',quarantine,dump]);
  destination=source.pool(ownerRole,quarantine);
  const {oid}=(await destination.query('SELECT oid FROM pg_database WHERE datname=current_database()')).rows[0];
  const restorePath=join(dir,'restore.json'),binding={database:quarantine,oid,port:55434,socketDirectory:socket};
  const configuration={destination:{...binding,user:ownerRole},worker:{...binding,user:source.worker},runId:randomUUID(),dumpPath:dump,
   dumpSHA256:createHash('sha256').update(await readFile(dump)).digest('hex'),headPath:join(exportDirectory,'head.json'),journalPath:join(exportDirectory,'journal.ndjson'),
   trust:{...keys.origin,keyId:pins.keyId,publicKey:keys.writerKeys.publicKeyPEM},authoritySeal:{path:join(exportDirectory,'seal.json'),pins,authorityPublicKey:keys.authorityKeys.publicKeyPEM}};
  await writeFile(restorePath,JSON.stringify(configuration),{mode:0o600});
  assert.equal(cli('privacy-journal.mjs','verify',restorePath).events,1);
  assert.equal((await destination.query('SELECT grant_id FROM ritc.request_queue_permission WHERE grant_id=$1',[grant])).rowCount,1);
  assert.equal(cli('privacy-journal.mjs','plan',restorePath).quarantined,true);
  assert.equal((await destination.query('SELECT 1 FROM ritc.request_queue_permission')).rowCount,0);

  assert.throws(()=>cli('privacy-journal.mjs','gate',restorePath));
  assert.equal(cli('privacy-journal.mjs','replay',restorePath).targetsApplied,1);
  assert.equal(cli('privacy-journal.mjs','replay',restorePath).targetsApplied,0);
  // A positive permission introduced in an already registered clone must not pass its release gate.
  await destination.query("INSERT INTO ritc.request_queue_permission VALUES($1,$2,$3,$4,now(),now()+interval '1 hour')",[otherHousehold,otherMember,deviceId,randomUUID()]);
  assert.throws(()=>cli('privacy-journal.mjs','gate',restorePath),/Restored device queue permissions/);
  assert.equal(cli('privacy-journal.mjs','plan',restorePath).quarantined,true);
  assert.deepEqual(cli('privacy-journal.mjs','gate',restorePath),{runId:configuration.runId,localAppErasureApplied:true,syntheticProbePermitted:true,providerReconciliationRequired:true,productionReady:false});
  const members=(await destination.query('SELECT member_id,alias,erased_at FROM ritc.member WHERE member_id IN ($1,$2)',[memberId,otherMember])).rows;
  assert.equal(members.find(member=>member.member_id===memberId).alias,'Removed member');
  assert.ok(members.find(member=>member.member_id===memberId).erased_at);
  assert.equal(members.find(member=>member.member_id===otherMember).alias,'Retain this member');
  assert.equal(members.find(member=>member.member_id===otherMember).erased_at,null);
  const blocked=(await destination.query('SELECT ritc.identity_blocked($1,$2) AS blocked',[issuer,committed.subject])).rows[0];
  assert.equal(blocked.blocked,true);
  await Promise.all([destination.end(),observer.close(),runtime.end()]);await source.close();sourceClosed=true;
  const exportOnly=join(dir,'independent-export'),exportPath=join(dir,'export.json');
  await mkdir(exportOnly,{mode:0o700});
  await writeFile(exportPath,JSON.stringify({pins,writerPublicKey:keys.writerKeys.publicKeyPEM,authorityPublicKey:keys.authorityKeys.publicKeyPEM,
   sourceDatabaseOid:config.source.identity.databaseOid,checkpoint:endpoint(config.checkpoint.identity,dir,55433),exportDirectory:exportOnly}),{mode:0o600});
  assert.deepEqual(cli('journal-recovery.mjs','export',exportPath),exported);
  assert.deepEqual(await readFile(join(exportOnly,'journal.ndjson')),bundle.bytes);
  assert.deepEqual(JSON.parse(await readFile(join(exportOnly,'seal.json'),'utf8')),bundle.proof);
 }finally{
  resume.resolve();await requestPending?.catch(()=>{});await recovery?.catch(()=>{});
  if(!sourceClosed){await Promise.all([destination?.end(),observer?.close(),runtime.end()]);await source.close();}
  await ports?.close();
 }
});

test('a persisted commit claim without its source event cannot seal or reopen the fenced lineage',async()=>{
 const source=await sourceCluster();let ports;
 try{
  const {r,operator}=await recoveryFixture(source);ports=await r.open();
  await ports.uncertainty.begin({scopeDigest:r.scope,eventId:r.f.event().eventId,transition:'commit'},time());
  await assert.rejects(operator.recover(time()),/Uncertain commit is absent/);
  assert.equal((await ports.authority.readCurrent(nonce(time()))).value.mode,'recovery');
  assert.equal((await owner.query('SELECT 1 FROM ritc_checkpoint.recovery_seal WHERE lineage=$1',[r.f.pins.lineage])).rowCount,0);
  assert.equal((await source.owner.query('SELECT fenced FROM ritc.privacy_journal_origin')).rows[0].fenced,true);
 }finally{await ports?.close();await source.close();}
});

test('a verified restore projection can exceed both former SQL limits without dropping observations or retired purchases',async()=>{
 const source=await sourceCluster();
 try{
  const {r,config}=await recoveryFixture(source),{f}=r;
  const accepted=f.event();
  const targets=Array.from({length:24},()=>f.event().payload.data.targets[0]);
  accepted.payload.data.targets=targets;accepted.payload.data.effects=[];accepted.payloadDigest=digest(accepted.payload);
  const events=[accepted];
  for(const [index,target] of targets.entries()){
   const retiredPurchases=Array.from({length:9000},(_,n)=>({originalHash:createHash('sha256').update(`${index}/${n}`).digest('hex')}));
   events.push(progressEvent(accepted,'target_erased',{data:{householdId:target.householdId,memberId:target.memberId,retiredPurchases,erasedAt:'2026-11-03T12:01:00.000Z'}}));
  }
  while(events.length<1001)events.push(progressEvent(accepted,'source_pending'));
  const head={...r.head,head:{...r.head.head,fenced:true}},parts=[];
  for(const [transition,event] of [['intent',accepted],...events.map(event=>['commit',event])]){
   const record=signed(f,head,event,transition);
   parts.push(record.content);head.head.seq++;head.head.hash=record.identity.recordHash;
  }
  const archive=Buffer.concat(parts);
  assert.ok(archive.length<=MAX_JOURNAL_BYTES);
  const verified=verifyPrivacyJournal(archive,{...f.origin,keyId:f.pins.keyId,publicKey:f.writerKeys.publicKeyPEM,head:head.head});
  validatePrivacyRestoreEvents(verified.events);
  const projected=JSON.stringify(verified.events);
  assert.ok(verified.events.length>1000&&Buffer.byteLength(projected)>16*1024*1024);
  const sql='SELECT ritc.privacy_restore_register($1,$2,$3,$4::jsonb,$5::jsonb) AS run';
  const input=[randomUUID(),config.source.identity.databaseOid,verified.bundleDigest,JSON.stringify(verified.head)];
  await assert.rejects(source.owner.query(sql,[...input,JSON.stringify(Array.from({length:MAX_JOURNAL_RECORDS+1},()=>({})))]),/journal_too_large/);
  await assert.rejects(source.owner.query(sql,[...input,JSON.stringify([{payload:{padding:'x'.repeat(MAX_SOURCE_EVENT_BYTES)}}])]),/journal_source_event_too_large/);
  assert.equal((await source.owner.query('SELECT count(*)::int AS n FROM ritc.privacy_restore_run')).rows[0].n,0);
  assert.equal((await source.owner.query(sql,[...input,projected])).rows[0].run,input[0]);
  const facts=(await source.owner.query(`SELECT (SELECT jsonb_array_length(source_observations) FROM ritc.privacy_restore_job WHERE job_id=$1) AS observations,
   (SELECT count(*)::int FROM ritc.retired_purchase) AS markers,
   (SELECT count(*)::int FROM ritc.privacy_restore_receipt WHERE result='absent_no_effect') AS absent`,[accepted.payload.jobId])).rows[0];
  assert.deepEqual(facts,{observations:1000,markers:216000,absent:24});
 }finally{await source.close();}
});

test('deployed runtime entry points bind deletion to the registered source and report signed capacity',async()=>{
 const source=await sourceCluster();
 const runtimes=[],workers=[];
 const originalFetch=globalThis.fetch;
 let authority;
 const databaseURL=user=>`postgresql://${user}@localhost:55434/postgres?host=${encodeURIComponent(source.configuration.connection.host)}`;
 try{
  const providerOrigin='https://runtime.fixture.invalid';
  const issuer=providerOrigin+'/auth/v1',audience='authenticated',jwks=issuer+'/.well-known/jwks.json';
  const subject=randomUUID(),sessionId=randomUUID(),jobId=randomUUID();
  const statusToken=randomBytes(32).toString('base64url'),key='sb_secret_'+randomBytes(32).toString('base64url');
  const {privateKey,publicKey}=await generateKeyPair('ES256');
  const signatureKey={...await exportJWK(publicKey),kid:'runtime-test'};
  const timestamp=Math.floor(Date.now()/1000);
  const token=await new SignJWT({session_id:sessionId,amr:[{method:'otp',timestamp}]})
   .setProtectedHeader({alg:'ES256',kid:signatureKey.kid}).setIssuer(issuer).setAudience(audience)
   .setSubject(subject).setIssuedAt(timestamp).setExpirationTime(timestamp+300).sign(privateKey);
  const policy={receiptRetentionDays:1,erasureMarkerRetentionDays:2,verifiedBackupRetentionDays:1};
  const retentionApprovalReference='synthetic-retention-review';
  const restoreApprovalReference='synthetic-restore-drill';
  const configurationId=privacyDeploymentConfigurationId({issuer,policy,retentionApprovalReference,restoreApprovalReference});
  const {r}=await recoveryFixture(source,configurationId);
  const writerToken=randomBytes(32).toString('base64url'),path=join(dir,'runtime-authority.json');
  const database=user=>({host:dir,port:55433,database:'postgres',user});
  await writeFile(path,JSON.stringify({pins:r.f.pins,writerToken,writerPublicKey:r.f.writerKeys.publicKeyPEM,
   authorityPrivateKey:pem(r.f.authorityKeys.privateKey),checkpointDatabase:database(checkpointRole),
   recordDatabase:database(objectRole),listen:{host:'127.0.0.1',port:0},tls:{key:tls.key.toString(),cert:tls.cert}}),
   {mode:0o600,flag:'wx'});
  authority=await startAuthority(path);
  const {applicationName,...observer}=source.configuration;
  const config={version:1,pins:r.f.pins,writerPrivateKey:pem(r.f.writerKeys.privateKey),
   authorityPublicKey:r.f.authorityKeys.publicKeyPEM,authority:{origin:authority.origin,writerToken,ca:tls.cert},observer,
   retentionPolicy:policy,retentionApprovalReference,restoreApprovalReference};
  const environment={DATABASE_URL:databaseURL(source.runtime),WORKER_DATABASE_URL:databaseURL(source.worker),
   JWT_ISSUER:issuer,JWT_AUDIENCE:audience,JWT_JWKS_URL:jwks,SUPABASE_URL:providerOrigin,
   PRIVACY_SUPABASE_ADMIN_KEY:key,PRIVACY_DELETION_JSON:JSON.stringify(config),
   PRIVACY_DELETION_ACCEPTANCE:'true',PRIVACY_DELETION_PROCESSING:'true'};

  const requests=[];
  let providerDeleted=false;
  globalThis.fetch=async(input,init)=>{
   const url=String(input);
   if(url===jwks)return Response.json({keys:[signatureKey]});
   if(!url.startsWith(providerOrigin+'/'))return originalFetch(input,init);
   assert.equal(url,issuer+'/admin/users/'+subject);
   assert.equal(init.headers.apikey,key);
   assert.equal(init.headers.Authorization,undefined);
   requests.push(init.method);
   if(init.method==='DELETE'){
    assert.deepEqual(JSON.parse(init.body),{should_soft_delete:false});
    providerDeleted=true;
    await source.owner.query('DELETE FROM auth.sessions WHERE user_id=$1',[subject]);
    return new Response(null,{status:204});
   }
   return providerDeleted?new Response(null,{status:404}):Response.json({id:subject,identities:[{provider:'email'}]});
  };
  await source.owner.query('INSERT INTO auth.sessions(id,user_id) VALUES($1,$2)',[sessionId,subject]);
  async function startApplication(overrides={}){
   const runtime=await createRuntime({...environment,...overrides});
   runtimes.push(runtime);
   runtime.server.listen(0,'127.0.0.1');
   await once(runtime.server,'listening');
   return 'http://127.0.0.1:'+runtime.server.address().port;
  }
  const auth={authorization:'Bearer '+token};
  const preview=base=>originalFetch(base+'/v1/privacy/deletion-preview',{headers:auth}).then(response=>{
   assert.equal(response.status,200);
   return response.json();
  });
  const request=base=>originalFetch(base+'/v1/privacy/deletions',{method:'POST',headers:{...auth,'content-type':'application/json'},
   body:JSON.stringify({clientKey:jobId,statusToken,confirm:true,households:[]})});

  const badConfig=await startApplication({PRIVACY_DELETION_JSON:JSON.stringify({...config,restoreApprovalReference:'different-review'})});
  assert.equal((await preview(badConfig)).deletionAvailable,false);
  const badSource=await startApplication({PRIVACY_DELETION_JSON:JSON.stringify({...config,observer:{...observer,databaseOid:'999999999'}})});
  assert.equal((await preview(badSource)).deletionAvailable,false);
  assert.equal((await request(badSource)).status,503);
  assert.deepEqual(requests,[]);
  assert.equal((await source.owner.query('SELECT count(*)::int AS count FROM ritc.privacy_job')).rows[0].count,0);

  const base=await startApplication();
  const operations=createOperationsRuntime(environment);
  workers.push(operations);
  const disabled=createOperationsRuntime({...environment,PRIVACY_DELETION_PROCESSING:'false'});
  workers.push(disabled);
  assert.equal((await preview(base)).deletionAvailable,true);
  const ready=await operations.run('status');
  assert.equal(ready.privacyJobProcessingEnabled,true);
  assert.deepEqual(ready.privacyJournal,{state:'ready',capacity:{mode:'active',uncertain:false,
   usedRecords:0,reservedRecords:0,usedBytes:0,reservedBytes:0,nearLimit:false}});

  const localAuthority=await r.open();
  try{
   const context=time();
   await localAuthority.uncertainty.begin({scopeDigest:r.scope,eventId:randomUUID(),transition:'intent'},context);
   const blocked=await operations.run('status');
   assert.equal(blocked.privacyJournal.state,'blocked');
   assert.equal(blocked.privacyJournal.capacity.uncertain,true);
   assert.equal(blocked.attentionRequired,true);
   assert.equal((await preview(base)).deletionAvailable,false);
   assert.deepEqual(requests,[]);
   // The fixture opened this synthetic claim without dispatching a source write.
   await owner.query('UPDATE ritc_checkpoint.origin SET claim=NULL WHERE lineage=$1',[r.f.pins.lineage]);
  }finally{await localAuthority.close();}

  const accepted=await request(base);
  const receipt=await accepted.json();
  assert.equal(accepted.status,202,JSON.stringify(receipt));
  assert.equal(receipt.status,'pending');
  assert.deepEqual(requests,['GET']);
  const off=await disabled.run();
  assert.equal(off.privacyJobProcessingEnabled,false);
  assert.equal(off.privacyJournal.state,'disabled');
  assert.deepEqual(requests,['GET']);

  await source.owner.query('UPDATE ritc.privacy_job SET issuer=$2 WHERE job_id=$1',[jobId,'https://other.fixture.invalid/auth/v1']);
  const mismatch=await operations.run();
  assert.equal(mismatch.privacy.issuerMismatch,1);
  assert.equal(mismatch.attentionRequired,true);
  assert.deepEqual(requests,['GET']);
  await source.owner.query('UPDATE ritc.privacy_job SET issuer=$2,lease_until=NULL,lease_id=NULL WHERE job_id=$1',[jobId,issuer]);

  const done=await operations.run();
  assert.equal(done.privacy.completed,1);
  assert.deepEqual(requests,['GET','GET','DELETE','GET']);
  const receiptResponse=await originalFetch(base+'/v1/privacy/jobs/'+jobId,{headers:{'x-deletion-token':statusToken}});
  assert.equal(receiptResponse.status,200);
  const completed=await receiptResponse.json();
  assert.equal(completed.status,'complete');
  assert.equal(completed.providerAccountDeleted,true);
  const healthy=await operations.run('status');
  assert.equal(healthy.privacyJournal.capacity.usedRecords,3);
  assert.equal(healthy.privacyJournal.capacity.reservedRecords,0);
  for(const secret of [key,writerToken,statusToken,jobId,subject,sessionId,issuer]){
   assert.ok(!JSON.stringify(healthy).includes(secret));
  }

  // Artificial high-water mark in the disposable authority. No more appends.
  await owner.query("UPDATE ritc_checkpoint.origin SET head=jsonb_set(head,'{totalBytes}',to_jsonb($2::int)) WHERE lineage=$1",
   [r.f.pins.lineage,Math.ceil(MAX_JOURNAL_BYTES*0.8)]);
  const high=await operations.run('status');
  assert.equal(high.privacyJournal.capacity.nearLimit,true);
  assert.equal(high.attentionRequired,true);

  await authority.stop();
  const unavailable=await operations.run('status');
  assert.deepEqual(unavailable.privacyJournal,{state:'authority_unavailable',capacity:null});
  assert.equal(unavailable.privacyJobProcessingEnabled,false);
  assert.equal((await originalFetch(base+'/health')).status,200);
 }finally{
  globalThis.fetch=originalFetch;
  await Promise.all(runtimes.map(async({server,pool})=>{
   await new Promise(resolve=>server.close(resolve));
   await pool.end();
  }));
  await Promise.all(workers.map(worker=>worker.close()));
  await authority?.stop();
  await source.close();
 }
});

test('overlapping HTTPS writers defer without poisoning the losing app or worker',async()=>{
 const source=await sourceCluster(),runtime=source.pool(source.runtime),workerPool=source.pool(source.worker);
 const writing=gate(),resume=gate();
 let server,remote,observer,winnerWrite;
 try{
  const {r}=await recoveryFixture(source);
  const {pins}=r.f,writerToken=randomBytes(32).toString('base64url');
  const path=join(dir,'contention-authority.json');
  const database=user=>({host:dir,port:55433,database:'postgres',user});
  await writeFile(path,JSON.stringify({pins,writerToken,writerPublicKey:r.f.writerKeys.publicKeyPEM,
   authorityPrivateKey:pem(r.f.authorityKeys.privateKey),checkpointDatabase:database(checkpointRole),
   recordDatabase:database(objectRole),listen:{host:'127.0.0.1',port:0},tls:{key:tls.key.toString(),cert:tls.cert}}),
   {mode:0o600,flag:'wx'});
  server=await startAuthority(path);
  remote=createHTTPSJournalAuthority({pins,origin:server.origin,writerToken,ca:tls.cert});
  observer=createPostgresCommittedSource({pins,authorityPublicKey:r.f.authorityKeys.publicKey,...source.configuration});
  const ports={...remote,source:observer.source};
  const app=r.f.adapter(ports),worker=r.f.adapter(ports);
  const winner=r.f.adapter({...ports,records:{...remote.records,async putExact(...args){
   writing.resolve();
   await resume.promise;
   return remote.records.putExact(...args);
  }}});

  const issuer='https://contention.fixture.invalid/auth/v1',subject=randomUUID(),sessionId=randomUUID();
  const identity={issuer,subject,sessionId,expiresAt:new Date(Date.now()+60_000),authenticatedAt:new Date(),authenticatedMethod:'otp'};
  const input={clientKey:randomUUID(),statusToken:randomBytes(32).toString('base64url'),confirm:true,households:[]};
  await source.owner.query('INSERT INTO auth.sessions(id,user_id) VALUES($1,$2)',[sessionId,subject]);
  const repository=new HouseholdRepository(runtime,{allowChildNetwork:false,noticeVersion:'fixture',sessionStatus:new SupabaseSessionVerifier(issuer)});
  const policy={receiptRetentionDays:1,erasureMarkerRetentionDays:2,verifiedBackupRetentionDays:1};
  let providerDeletes=0;
  const provider={assertAvailable:async()=>{},deleteAccount:async candidate=>{
   assert.equal(candidate,subject);
   providerDeletes++;
  }};
  const privacy=new PrivacyService(repository,{provider,policy,journal:app.port});
  const maintenance=new PrivacyMaintenance(workerPool,{provider,journal:worker.port,issuer});
  // Leave a genuine committed acceptance for the reconciliation worker, as
  // when the accepting process exits after COMMIT and before observing it.
  const interrupted=new PrivacyService(repository,{provider,policy,journal:{...app.port,
   afterCommit:async()=>{throw Error('fixture stopped before observation');}}});
  await assert.rejects(interrupted.request(identity,input),/fixture stopped before observation/);

  const busy={code:'deletion_journal_busy'};
  const blocker=await owner.connect();
  try{
   await blocker.query('BEGIN');
   await blocker.query('SELECT 1 FROM ritc_checkpoint.origin WHERE lineage=$1 FOR UPDATE',[pins.lineage]);
   await assert.rejects(app.port.beforeCommit(r.f.event(),time()),busy);
   assert.equal(app.isPoisoned(),false);
  }finally{
   await blocker.query('ROLLBACK');
   blocker.release();
  }

  winnerWrite=winner.port.beforeCommit(r.f.event(),time());
  winnerWrite.catch(()=>{});
  await Promise.race([writing.promise,winnerWrite.then(()=>{throw Error('Fixture did not reach its write gate');})]);
  assert.equal((await app.capacity(time())).mode,'pending');
  const other={...identity,subject:randomUUID(),sessionId:randomUUID()};
  const another={...input,clientKey:randomUUID(),statusToken:randomBytes(32).toString('base64url')};
  await source.owner.query('INSERT INTO auth.sessions(id,user_id) VALUES($1,$2)',[other.sessionId,other.subject]);
  await assert.rejects(privacy.request(other,another),busy);
  assert.equal((await source.owner.query('SELECT 1 FROM ritc.privacy_job WHERE job_id=$1',[another.clientKey])).rowCount,0);
  await assert.rejects(privacy.status(input.clientKey,input.statusToken),busy);
  await assert.rejects(worker.port.reserveWorkerCapacity(input.clientKey,['source_completed'],time()),busy);
  const deferred=await maintenance.run({batchSize:1});
  assert.equal(deferred.journalDeferred,1);
  assert.equal(deferred.retryScheduled,0);
  assert.equal(providerDeletes,0);
  assert.equal((await source.owner.query('SELECT lease_id FROM ritc.privacy_job WHERE job_id=$1',[input.clientKey])).rows[0].lease_id,null);
  assert.equal(app.isPoisoned(),false);
  assert.equal(worker.isPoisoned(),false);

  resume.resolve();
  await winnerWrite;
  const done=await maintenance.run({batchSize:1});
  assert.equal(done.completed,1);
  assert.equal(done.journalDeferred,0);
  assert.equal(providerDeletes,1);
  const receipt=await privacy.status(input.clientKey,input.statusToken);
  assert.equal(receipt.status,'complete');
  assert.equal(receipt.providerAccountDeleted,true);
  assert.equal((await app.capacity(time())).usedRecords,4);

  const context=time();
  const pending=await reserve(r,remote,r.f.event(),'intent',context);
  await assert.rejects(privacy.status(input.clientKey,input.statusToken),busy);
  assert.equal(app.isPoisoned(),false);
  const stored=await remote.records.putExact(pending.ticket,pending.content,context);
  const proof=await remote.authority.publish(pending.ticket,stored,nonce(context));
  await remote.uncertainty.complete(pending.claim,proof,context);
  assert.equal((await privacy.status(input.clientKey,input.statusToken)).status,'complete');
  assert.equal((await privacy.request(other,another)).status,'pending');
 }finally{
  resume.resolve();
  await winnerWrite?.catch(()=>{});
  remote?.close();
  await server?.stop();
  await Promise.all([observer?.close(),runtime.end(),workerPool.end()]);
  await source.close();
 }
});

test('a backup from before rollover replays both journals in order and preserves unrelated members',async()=>{
 const source=await sourceCluster();
 let sourceClosed=false,quarantine;
 const issuer='https://archive.fixture.invalid/auth/v1';
 const actor=async alias=>{
  const subject=randomUUID(),sessionId=randomUUID(),householdId=randomUUID(),memberId=randomUUID();
  await source.owner.query('INSERT INTO auth.sessions(id,user_id) VALUES($1,$2)',[sessionId,subject]);
  await source.owner.query('INSERT INTO ritc.household(household_id,label) VALUES($1,$2)',[householdId,alias]);
  await source.owner.query(`INSERT INTO ritc.member(household_id,member_id,issuer,subject,alias,kind,state,organizer)
   VALUES($1,$2,$3,$4,$5,'adult','active',true)`,[householdId,memberId,issuer,subject,alias]);
  return {subject,sessionId,householdId,memberId};
 };
 const publicKeys=f=>({pins:f.pins,writerPublicKey:f.writerKeys.publicKey,authorityPublicKey:f.authorityKeys.publicKey});
 const publicSettings=f=>({pins:f.pins,writerPublicKey:f.writerKeys.publicKeyPEM,authorityPublicKey:f.authorityKeys.publicKeyPEM});
 const append=async(f,{subject,sessionId,householdId},{afterAcceptance,beforeAcceptance,afterInterruptedCompletion}={})=>{
  const ports=await openAuthority(f),runtime=source.pool(source.runtime),worker=source.pool(source.worker);
  const observer=createPostgresCommittedSource({pins:f.pins,authorityPublicKey:f.authorityKeys.publicKey,...source.configuration});
  try{
   const {port:journal}=f.adapter({...ports,source:observer.source});
   const repo=new HouseholdRepository(runtime,{allowChildNetwork:false,noticeVersion:'fixture',sessionStatus:new SupabaseSessionVerifier(issuer)});
   let providerCalls=0;
   const provider={assertAvailable:async()=>{},deleteAccount:async target=>{assert.equal(target,subject);providerCalls++;}};
   const policy={receiptRetentionDays:1,erasureMarkerRetentionDays:2,verifiedBackupRetentionDays:1};
   const privacy=new PrivacyService(repo,{provider,policy,journal});
   const identity={issuer,subject,sessionId,expiresAt:new Date(Date.now()+60_000),authenticatedAt:new Date(),authenticatedMethod:'otp'};
   await beforeAcceptance?.(privacy);
   const statusToken=randomBytes(32).toString('base64url');
   const households=[{householdId,organizer:'archive',shops:[],eraseChildProfiles:[]}];
   const receipt=await privacy.request(identity,{clientKey:randomUUID(),statusToken,confirm:true,households});
   assert.equal(receipt.status,'pending');
   await afterAcceptance?.(receipt.jobId);
   const maintenance=new PrivacyMaintenance(worker,{provider,journal,issuer});
   if(afterInterruptedCompletion){
    const interrupted=new PrivacyMaintenance(worker,{provider,issuer,journal:{...journal,async acknowledgeJob(jobId,context){
     const {state}=(await source.owner.query('SELECT state FROM ritc.privacy_job WHERE job_id=$1',[jobId])).rows[0];
     if(state==='complete')throw Error('Fixture lost the completion acknowledgement');
     return journal.acknowledgeJob(jobId,context);
    }}});
    await assert.rejects(interrupted.run({batchSize:1}),/lost the completion acknowledgement/);
    await afterInterruptedCompletion();
    assert.equal((await maintenance.run({batchSize:1})).completed,0);
    assert.equal((await privacy.status(receipt.jobId,statusToken)).status,'complete');
   }else assert.equal((await maintenance.run({batchSize:1})).completed,1);
   assert.equal(providerCalls,1);
   return {jobId:receipt.jobId,statusToken};
  }finally{await Promise.all([ports.close(),observer.close(),runtime.end(),worker.end()]);}
 };
 try{
  const {r,config,operator}=await recoveryFixture(source);
  const firstActor=await actor('Predecessor fixture'),secondActor=await actor('Successor fixture'),unrelated=await actor('Unrelated fixture');
  const dumpPath=join(dir,'pre-rollover.dump'),socketDirectory=source.configuration.connection.host;
  pgTool('pg_dump',['-h',socketDirectory,'-p','55434','-U',ownerRole,'-d','postgres','-Fc','-f',dumpPath]);
  await chmod(dumpPath,0o600);
  const next=fixture({schemaDigest:source.schemaDigest,sourceIdentity:r.f.pins.sourceIdentity,keyId:'fixture-writer-next',
   authorityKeyId:'fixture-authority-next',recordNamespace:'fixture-namespace-next'});
  const fork=fixture({schemaDigest:source.schemaDigest,sourceIdentity:r.f.pins.sourceIdentity});
  const linkInput={...publicKeys(r.f),authorityPrivateKey:r.f.authorityKeys.privateKey,
   sourceDatabaseOid:config.source.identity.databaseOid,checkpoint:config.checkpoint,successor:publicKeys(next)};
  await assert.rejects(registerIndependentSuccessor(linkInput,time()),/no sealed archive/);
  const badEndpoint=createIndependentRecovery({...config,checkpoint:{...config.checkpoint,identity:{...config.checkpoint.identity,databaseOid:'999999999'}}});
  await assert.rejects(badEndpoint.sealForRollover(time()),/Fixed recovery database/);
  assert.equal((await source.owner.query('SELECT fenced FROM ritc.privacy_journal_origin')).rows[0].fenced,false);
  const assertDrainBlocked=async()=>{
   await assert.rejects(operator.sealForRollover(time()),/unfinished jobs/);
   assert.equal((await source.owner.query('SELECT fenced FROM ritc.privacy_journal_origin')).rows[0].fenced,false);
   assert.equal((await owner.query("SELECT head->>'mode' AS mode FROM ritc_checkpoint.origin WHERE lineage=$1",[r.f.pins.lineage])).rows[0].mode,'active');
  };
  const firstJob=await append(r.f,firstActor,{afterAcceptance:assertDrainBlocked,afterInterruptedCompletion:async()=>{
   assert.equal((await source.owner.query("SELECT count(*)::int AS n FROM ritc.privacy_job WHERE state<>'complete'")).rows[0].n,0);
   await assertDrainBlocked();
  }});
  const first=await operator.sealForRollover(time());
  const links=await Promise.all([registerIndependentSuccessor(linkInput,time()),registerIndependentSuccessor(linkInput,time())]);
  const [link]=links;
  assert.deepEqual(links[1],link);
  assert.equal(link.predecessorSealDigest,digest(first.proof));
  assert.equal(link.successorScopeDigest,durableJournalScopeDigest(next.pins));
  await assert.rejects(registerIndependentSuccessor({...linkInput,successor:publicKeys(fork)},time()),/different successor/);
  assert.equal((await owner.query('SELECT 1 FROM ritc_checkpoint.origin WHERE lineage=$1',[fork.pins.lineage])).rowCount,0);
  await assert.rejects(owner.query('UPDATE ritc_checkpoint.successor SET proof=proof WHERE predecessor=$1',[r.f.pins.lineage]),/immutable journal successor/);

  const checkpointReader=pool(checkpointRole);
  try{await assert.rejects(checkpointReader.query('SELECT proof FROM ritc_checkpoint.successor'),{code:'42501'});}
  finally{await checkpointReader.end();}
  const previousBinding=(await source.owner.query('SELECT lineage,fenced FROM ritc.privacy_journal_origin')).rows[0];
  assert.deepEqual(previousBinding,{lineage:r.f.pins.lineage,fenced:true});
  const activation={...publicKeys(r.f),source:config.source,checkpoint:config.checkpoint,successor:next.pins};
  await assert.rejects(activateIndependentSuccessor({...activation,successor:fork.pins},time()),/archive continuity/);
  await assert.rejects(source.owner.query('UPDATE ritc.privacy_journal_origin SET fenced=false'),/immutable journal origin/);
  await assert.rejects(source.owner.query('UPDATE ritc.privacy_journal_origin SET lineage=$1,fenced=false',[next.pins.lineage]),/immutable journal origin/);
  assert.equal((await source.owner.query('SELECT 1 FROM ritc.privacy_journal_rotation')).rowCount,0);
  const runtime=source.pool(source.runtime),worker=source.pool(source.worker);
  try{
   await assert.rejects(runtime.query('SELECT proof FROM ritc.privacy_journal_rotation'),{code:'42501'});
   await assert.rejects(worker.query('SELECT ritc.privacy_journal_drained()'),{code:'42501'});
  }finally{await Promise.all([runtime.end(),worker.end()]);}

  const output=join(dir,'successor-fixture');
  await mkdir(output,{mode:0o700});
  const endpoint=(identity,host,port)=>({connection:{host,port,database:identity.database,user:identity.owner},
   databaseOid:identity.databaseOid,ownerOid:identity.ownerOid});
  const checkpoint=endpoint(config.checkpoint.identity,dir,55433);
  const sourceEndpoint=endpoint(config.source.identity,source.configuration.connection.host,55434);
  const operatorPath=join(output,'rollover-seal.json');
  await writeFile(operatorPath,JSON.stringify({pins:r.f.pins,writerPrivateKey:pem(config.writerPrivateKey),
   authorityPrivateKey:pem(config.authorityPrivateKey),checkpoint,source:sourceEndpoint,exportDirectory:output}),{mode:0o600});
  assert.equal(cli('journal-recovery.mjs','seal-for-rollover',operatorPath).sealDigest,link.predecessorSealDigest);
  const activationPath=join(output,'activate.json');
  await writeFile(activationPath,JSON.stringify({...publicSettings(r.f),checkpoint,source:sourceEndpoint,successor:next.pins}),{mode:0o600});
  assert.deepEqual(cli('journal-recovery.mjs','activate',activationPath),{event:'journal_successor_activated',changed:true,
   successorScopeDigest:link.successorScopeDigest});
  assert.deepEqual((await source.owner.query('SELECT lineage,fenced FROM ritc.privacy_journal_origin')).rows[0],{lineage:next.pins.lineage,fenced:false});
  await assert.rejects(source.owner.query('UPDATE ritc.privacy_journal_rotation SET proof=proof'),/immutable journal/);
  const oldObserver=createPostgresCommittedSource({pins:r.f.pins,authorityPublicKey:r.f.authorityKeys.publicKey,...source.configuration});
  try{await assert.rejects(oldObserver.source.readOrigin(time()),error=>error.cause?.code==='42501'&&error.cause?.message==='journal_source_origin_conflict');}
  finally{await oldObserver.close();}
  const secondJob=await append(next,secondActor,{
   beforeAcceptance:async privacy=>{
    const old=await privacy.status(firstJob.jobId,firstJob.statusToken);
    assert.equal(old.status,'complete');
    assert.equal(old.providerAccountDeleted,true);
    assert.equal(Object.hasOwn(old,'archived'),false);
    await assert.rejects(privacy.status(firstJob.jobId,randomBytes(32).toString('base64url')),{status:404});
   },
   afterAcceptance:async jobId=>{
    const stalePool=source.pool(source.worker);
    try{
     const stale=new PrivacyMaintenance(stalePool,{journal:r.f.adapter().port});
     assert.equal((await stale.run({batchSize:1})).completed,0);
     assert.deepEqual((await source.owner.query('SELECT state,lease_id,app_erased_at FROM ritc.privacy_job WHERE job_id=$1',[jobId])).rows[0],
      {state:'pending',lease_id:null,app_erased_at:null});
    }finally{await stalePool.end();}
   },
  });
  assert.notEqual(firstJob.jobId,secondJob.jobId);
  assert.equal(cli('journal-recovery.mjs','activate',activationPath).changed,false);
  assert.equal((await source.owner.query('SELECT count(*)::int AS n FROM ritc.privacy_journal_ack')).rows[0].n,6);
  const successorRecovery=createIndependentRecovery({...config,pins:next.pins,writerPrivateKey:next.writerKeys.privateKey,
   authorityPrivateKey:next.authorityKeys.privateKey});
  const second=await successorRecovery.sealForRollover(time());
  assert.equal(verifyIndependentRecovery(second.bytes,second.proof,next.pins,next.writerKeys.publicKey,next.authorityKeys.publicKey)
   .events.every(event=>event.payload.jobId===secondJob.jobId),true);

  const trust={startScopeDigest:r.scope,terminalSealDigest:digest(second.proof)};
  const a={...publicKeys(r.f),bytes:first.bytes,seal:first.proof};
  const b={...publicKeys(next),bytes:second.bytes,seal:second.proof,incomingLink:link};
  assert.deepEqual(await verifyIndependentArchiveWindow([a,b],trust),{...trust,segments:2,events:6});
  await assert.rejects(verifyIndependentArchiveWindow([a],trust),/trusted final seal/);
  await assert.rejects(verifyIndependentArchiveWindow([b,a],trust),/trusted backup scope/);
  await assert.rejects(verifyIndependentArchiveWindow([a,{...b,incomingLink:{...link,authoritySignature:'A'.repeat(86)}}],trust),/archive continuity/);
  await assert.rejects(verifyIndependentArchiveWindow([a,{...b,authorityPublicKey:r.f.authorityKeys.publicKey}],trust),/pinned public keys/);

  const linkPath=join(output,'register.json'),incomingLinkPath=join(output,'successor.json');
  await writeFile(linkPath,JSON.stringify({pins:r.f.pins,writerPublicKey:r.f.writerKeys.publicKeyPEM,authorityPrivateKey:pem(config.authorityPrivateKey),
   sourceDatabaseOid:config.source.identity.databaseOid,checkpoint,successor:publicSettings(next),exportDirectory:output}),{mode:0o600});
  assert.equal(cli('journal-recovery.mjs','link',linkPath).successorScopeDigest,link.successorScopeDigest);
  assert.deepEqual(JSON.parse(await readFile(incomingLinkPath,'utf8')),link);
  const segments=[];
  for(const [f,archive] of [[r.f,first],[next,second]]){
   const journalPath=join(output,f.pins.lineage+'.ndjson'),sealPath=join(output,f.pins.lineage+'.json');
   await writeFile(journalPath,archive.bytes,{mode:0o600});
   await writeFile(sealPath,JSON.stringify(archive.proof),{mode:0o600});
   segments.push({...publicSettings(f),journalPath,sealPath,...(f===next?{incomingLinkPath}:{})});
  }
  const windowPath=join(output,'window.json');
  await writeFile(windowPath,JSON.stringify({...trust,segments}),{mode:0o600});
  assert.deepEqual(cli('journal-recovery.mjs','verify-window',windowPath),{event:'journal_archive_window_verified',...trust,segments:2,events:6});
  await writeFile(windowPath,JSON.stringify({...trust,segments:segments.slice(0,1)}),{mode:0o600});
  assert.throws(()=>cli('journal-recovery.mjs','verify-window',windowPath),{status:1});

  const database='ritc_quarantine_'+randomBytes(6).toString('hex');
  await source.owner.query('CREATE DATABASE '+database+' TEMPLATE template0');
  await source.owner.query('REVOKE CONNECT ON DATABASE '+database+' FROM PUBLIC');
  await source.owner.query('GRANT CONNECT ON DATABASE '+database+' TO '+source.worker);
  pgTool('pg_restore',['--exit-on-error','--no-owner','-h',socketDirectory,'-p','55434','-U',ownerRole,'-d',database,dumpPath]);
  quarantine=source.pool(ownerRole,database);
  const {oid}=(await quarantine.query('SELECT oid FROM pg_database WHERE datname=current_database()')).rows[0];
  const destination={database,oid,user:ownerRole,socketDirectory,port:55434};
  const runId=randomUUID(),segmentRunIds=[randomUUID(),randomUUID()];
  const restorePath=join(output,'restore-window.json'),dumpSHA256=createHash('sha256').update(await readFile(dumpPath)).digest('hex');
  const workerSettings={...destination,user:source.worker};
  await writeFile(restorePath,JSON.stringify({destination,worker:workerSettings,runId,segmentRunIds,dumpPath,dumpSHA256,archiveWindowPath:windowPath}),{mode:0o600});
  const restore=command=>cli('privacy-journal.mjs',command,restorePath);
  assert.throws(()=>restore('plan'),{status:1});
  assert.equal((await quarantine.query('SELECT 1 FROM ritc.privacy_restore_window')).rowCount,0);
  await writeFile(windowPath,JSON.stringify({...trust,segments}),{mode:0o600});
  const verification=restore('verify');
  assert.equal(verification.events,6);
  await source.owner.query('GRANT CONNECT ON DATABASE '+database+' TO '+source.runtime);
  assert.throws(()=>restore('plan'),error=>error.status===1&&String(error.stderr).includes('accessible to the application role'));
  await source.owner.query('REVOKE CONNECT ON DATABASE '+database+' FROM '+source.runtime);
  assert.throws(()=>restore('gate'),{status:1});
  const planned=restore('plan');
  assert.equal(planned.segment,1);
  assert.deepEqual(restore('plan'),planned);
  await assert.rejects(quarantine.query('UPDATE ritc.privacy_restore_window SET manifest_digest=manifest_digest'),/immutable journal/);
  const checkedSecond=verifyIndependentRecovery(second.bytes,second.proof,next.pins,next.writerKeys.publicKey,next.authorityKeys.publicKey);
  await assert.rejects(quarantine.query('SELECT ritc.privacy_restore_register($1,$2,$3,$4::jsonb,$5::jsonb)',
   [segmentRunIds[1],oid,checkedSecond.bundleDigest,JSON.stringify(checkedSecond.head),JSON.stringify(checkedSecond.events)]),
   /restore_window_predecessor_pending/);
  assert.throws(()=>restore('gate'),{status:1});
  assert.equal(restore('replay').targetsApplied,1);
  assert.throws(()=>restore('gate'),{status:1});
  assert.throws(()=>restore('replay'),{status:1});
  const checkedFirst=verifyIndependentRecovery(first.bytes,first.proof,r.f.pins,r.f.writerKeys.publicKey,r.f.authorityKeys.publicKey);
  const singlePath=join(output,'single-restore.json');
  await writeFile(singlePath,JSON.stringify({destination,worker:workerSettings,runId:segmentRunIds[0],dumpPath,dumpSHA256,
   journalPath:segments[0].journalPath,headPath:join(output,'head.json'),
   trust:{lineage:r.f.pins.lineage,schemaDigest:r.f.pins.schemaDigest,configurationId:r.f.pins.configurationId,
    keyId:r.f.pins.keyId,publicKey:r.f.writerKeys.publicKeyPEM},
   authoritySeal:{path:segments[0].sealPath,pins:r.f.pins,authorityPublicKey:r.f.authorityKeys.publicKeyPEM}}),{mode:0o600});
  assert.equal(cli('privacy-journal.mjs','verify',singlePath).bundleDigest,checkedFirst.bundleDigest);
  assert.throws(()=>cli('privacy-journal.mjs','gate',singlePath),{status:1});
  assert.equal(restore('plan').segment,2);
  assert.equal(restore('replay').targetsApplied,1);
  assert.equal(restore('replay').targetsApplied,0);
  assert.equal(restore('plan').segment,null);
  assert.deepEqual(restore('gate'),{runId,localAppErasureApplied:true,syntheticProbePermitted:true,providerReconciliationRequired:true,
   productionReady:false,segments:2,manifestDigest:verification.manifestDigest});
  for(const target of [firstActor,secondActor]){
   const {erased_at}=(await quarantine.query('SELECT erased_at FROM ritc.member WHERE member_id=$1',[target.memberId])).rows[0];
   assert.ok(erased_at);
   assert.equal((await quarantine.query('SELECT ritc.identity_blocked($1,$2) AS blocked',[issuer,target.subject])).rows[0].blocked,true);
  }
  assert.deepEqual((await quarantine.query('SELECT alias,erased_at FROM ritc.member WHERE member_id=$1',[unrelated.memberId])).rows[0],
   {alias:'Unrelated fixture',erased_at:null});
  assert.equal((await quarantine.query('SELECT count(*)::int AS n FROM ritc.privacy_job WHERE provider_erased_at IS NOT NULL')).rows[0].n,0);
  assert.deepEqual((await quarantine.query('SELECT lineage,fenced FROM ritc.privacy_journal_origin')).rows[0],
   {lineage:r.f.pins.lineage,fenced:true});
  await quarantine.end();quarantine=undefined;

  await source.close();sourceClosed=true;
  const publicExport=join(dir,'public-successor-export');
  await mkdir(publicExport,{mode:0o700});
  const exportPath=join(publicExport,'config.json');
  await writeFile(exportPath,JSON.stringify({...publicSettings(r.f),checkpoint,includeSuccessor:true,
   sourceDatabaseOid:link.sourceDatabaseOid,exportDirectory:publicExport}),{mode:0o600});
  assert.equal(cli('journal-recovery.mjs','export',exportPath).sealDigest,link.predecessorSealDigest);
  assert.deepEqual(await readFile(join(publicExport,'journal.ndjson')),first.bytes);
  assert.deepEqual(await readFile(join(publicExport,'successor.json')),await readFile(incomingLinkPath));
 }finally{await quarantine?.end();if(!sourceClosed)await source.close();}
});
