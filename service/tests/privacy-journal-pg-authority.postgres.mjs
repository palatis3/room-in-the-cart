import assert from 'node:assert/strict';
import {randomUUID,randomBytes,sign} from 'node:crypto';
import {execFileSync,spawn} from 'node:child_process';
import {once} from 'node:events';
import {mkdtemp,readFile,rm,writeFile} from 'node:fs/promises';
import {join,resolve} from 'node:path';
import {createInterface} from 'node:readline';
import {setTimeout as delay} from 'node:timers/promises';
import {fileURLToPath} from 'node:url';
import test,{before,after} from 'node:test';
import pg from 'pg';
import {migrate} from '../scripts/migrate.mjs';
import {createPostgresJournalAuthority} from '../dist/privacy-journal-pg-authority.js';
import {createPostgresCommittedSource} from '../dist/privacy-journal-pg-source.js';
import {durableJournalScopeDigest,verifyDurableAdmissionReceipt} from '../dist/privacy-journal-durable.js';
import {createHTTPSJournalAuthority} from '../dist/privacy-journal-https.js';
import {PrivacyMaintenance,PrivacyService} from '../dist/privacy.js';
import {HouseholdRepository} from '../dist/repository.js';
import {SupabaseSessionVerifier} from '../dist/auth.js';
import {fixture} from './durable-authority-fixture.mjs';
import {call,canonical,digest,progressEvent,zero} from './durable-independent-fixture.mjs';

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
async function register(pins){
 const f=fixture(pins),scope=durableJournalScopeDigest(f.pins);
 const head={head:{version:1,...f.origin,seq:0,hash:zero,fenced:false},generation:1,authorityRevision:0,mode:'active',pendingOperation:null,totalBytes:0};
 await owner.query('INSERT INTO ritc_checkpoint.origin(lineage,scope_digest,head) VALUES($1,$2,$3)',[f.pins.lineage,scope,head]);
 const configuration={pins:f.pins,writerPublicKey:f.writerKeys.publicKey,authorityPrivateKey:f.authorityKeys.privateKey};
 async function open(changes={}){
  const checkpointPool=pool(checkpointRole),recordPool=pool(objectRole);
  try{
   const ports=await createPostgresJournalAuthority({...configuration,checkpointPool,recordPool,...changes});
   return {...ports,checkpointPool,recordPool,close:()=>Promise.all([checkpointPool.end(),recordPool.end()])};
  }catch(error){await Promise.all([checkpointPool.end(),recordPool.end()]);throw error;}
 }
 return {f,head,scope,open};
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
 const sourcePool=user=>new pg.Pool({host:socket,port:55434,database:'postgres',user,password:()=>'',ssl:false,connectionTimeoutMillis:1500,max:2});
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
  assert.match(results.find(result=>result.status==='rejected').reason.message,/Outstanding journal uncertainty claim/);
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

test('app and worker recover one request through a restarted HTTPS authority on a separate PostgreSQL cluster',async()=>{
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
  const input={clientKey:randomUUID(),statusToken:randomBytes(32).toString('base64url'),confirm:true,households:[]};
  const repo=new HouseholdRepository(runtime,{allowChildNetwork:false,noticeVersion:'fixture',sessionStatus:new SupabaseSessionVerifier(issuer)});
  const policy={receiptRetentionDays:1,erasureMarkerRetentionDays:2,verifiedBackupRetentionDays:1};
  let deletionCalls=0;
  const provider={assertAvailable:async()=>{},deleteAccount:async value=>{
   assert.equal(value,subject);deletionCalls++;
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
  assert.equal((await maintenance.run({batchSize:1})).completed,1);
  assert.equal(deletionCalls,1);
  const service=new PrivacyService(repo,{provider,policy,journal});
  assert.equal((await service.status(input.clientKey,input.statusToken)).status,'complete');
  assert.equal((await remote.authority.readCurrent(nonce(time()))).value.head.seq,3);
  assert.equal((await maintenance.run({batchSize:1})).completed,0);
  assert.equal(deletionCalls,1);
  const rows=(await source.owner.query('SELECT a.head_seq::int AS seq,a.head_hash AS hash,e.kind FROM ritc.privacy_journal_outbox e JOIN ritc.privacy_journal_ack a USING(event_id) WHERE e.job_id=$1 ORDER BY a.head_seq',[input.clientKey])).rows;
  const admissions=(await owner.query("SELECT sequence AS seq,receipt->'record'->>'recordHash' AS hash,event_kind AS kind FROM ritc_checkpoint.admission WHERE lineage=$1 AND transition='commit' ORDER BY sequence",[r.f.pins.lineage])).rows;
  assert.deepEqual(rows,admissions);
  assert.deepEqual(rows.map(row=>row.kind),['acceptance','source_completed']);
 }finally{
  remote?.close();await server?.stop();await Promise.all([observer?.close(),runtime.end(),worker.end()]);await source.close();
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
  await assert.rejects(reopened.uncertainty.begin({scopeDigest:admitted.scope,eventId:ticket.record.eventId,transition:'intent'},time()),/Outstanding journal uncertainty claim/);
  await delay(Math.max(0,pending.ticket.authorityExpiresAtUnixMs-Date.now()+10));
  assert.equal((await blocked.authority.inspectOperation(pending.ticket.operationId,nonce(time()))).value.state,'blocked');
  assert.equal((await blocked.authority.readCurrent(nonce(time()))).value.head.seq,0);
  assert.deepEqual(await blocked.records.readExact(orphan,time()),pending.content);
  const sameAttempt=call({attemptId:pendingCall.attemptId,deadlineUnixMs:Date.now()+4000});
  await assert.rejects(blocked.authority.publish(pending.ticket,orphan,nonce(sameAttempt)),/reservation expired/);
  await assert.rejects(blocked.uncertainty.begin({scopeDigest:uncertain.scope,eventId:uncertain.f.event().eventId,transition:'intent'},time()),/origin is blocked/);
 }finally{await Promise.all([reopened.close(),blocked.close()]);}
});
