import test from 'node:test';
import assert from 'node:assert/strict';
import {randomUUID,randomBytes} from 'node:crypto';
import pg from 'pg';
import {sourceFixtureConnection} from './source-postgres-fixture.mjs';
import {createGatewayPostgresCommittedSource,createPostgresCommittedSource} from '../dist/privacy-journal-pg-source.js';
import {startSourceGateway} from './source-gateway-fixture.mjs';
import {fixture} from './durable-authority-fixture.mjs';
import {call,digest} from './durable-independent-fixture.mjs';
import {verifyPrivacyJournal,validatePrivacyRestoreEvents} from '../dist/privacy-journal.js';
import {HouseholdRepository} from '../dist/repository.js';
import {SupabaseSessionVerifier} from '../dist/auth.js';
import {PrivacyService,PrivacyMaintenance} from '../dist/privacy.js';

const database=process.env.TEST_JOURNAL_GATEWAY_DATABASE;
const role='ritc_journal_gateway_test';
assert.match(database,/^ritc_journal_pg_gateway_[a-f0-9]{32}$/);
const adminURL=new URL(process.env.TEST_ADMIN_DATABASE_URL);
const adminName=adminURL.username;
const pgOptions=(user,db=database)=>sourceFixtureConnection(adminURL,user,db);
const pool=(user,db)=>new pg.Pool(pgOptions(user,db));
const oid=async db=>(await db.query('SELECT oid::text FROM pg_catalog.pg_database WHERE datname=current_database()')).rows[0].oid;
const roleOid=async(db,name)=>(await db.query('SELECT oid::text FROM pg_catalog.pg_roles WHERE rolname=$1',[name])).rows[0].oid;

// Exercise the live HTTP handler, the independent verifier and the real five
// SQL routines. Only Auth deletion and the external records/authority are fakes.
test('fixed HTTPS operations on managed defaults recover a deletion and replay it into a pre-deletion database copy',async()=>{
 let owner=pool(adminName);const admin=pool(adminName,'postgres');
 const quarantine='ritc_gateway_quarantine_'+randomUUID().replaceAll('-','');
 const runtime=pool('ritc_test_runtime'),worker=pool('ritc_test_worker');
 let restored,restoreWorker,gateway,connector,strict,cloneMade=false;
 const h=randomUUID(),member=randomUUID(),other=randomUUID(),otherSubject=randomUUID(),subject=randomUUID(),sessionId=randomUUID(),issuer='https://managed.fixture.invalid';
 const identity={issuer,subject,sessionId,expiresAt:new Date(Date.now()+60000),authenticatedAt:new Date(),authenticatedMethod:'otp'};
 const input={clientKey:randomUUID(),statusToken:randomBytes(32).toString('base64url'),confirm:true,households:[{householdId:h,organizer:'none',shops:[],eraseChildProfiles:[]}]};
 try{
  const databaseOid=await oid(owner),ownerRoleOid=await roleOid(owner,adminName),observerRoleOid=await roleOid(owner,role);
  const schemaDigest=digest((await owner.query('SELECT version,checksum FROM public.ritc_schema_migration ORDER BY version')).rows);
  const backing=fixture({schemaDigest}),pins=backing.pins;
  await owner.query('INSERT INTO ritc.privacy_journal_origin(lineage,schema_digest,configuration_id) VALUES($1,$2,$3)',[pins.lineage,schemaDigest,pins.configurationId]);
  await owner.query('INSERT INTO ritc.privacy_journal_source_registration(source_identity,database_oid,observer_oid) VALUES($1,$2,$3)',[pins.sourceIdentity,databaseOid,observerRoleOid]);
  await owner.query('INSERT INTO auth.users(id) VALUES($1)',[subject]);
  await owner.query('INSERT INTO auth.sessions(id,user_id) VALUES($1,$2)',[sessionId,subject]);
  await owner.query("INSERT INTO ritc.household(household_id,label) VALUES($1,'Gateway household')",[h]);
  await owner.query("INSERT INTO ritc.member(household_id,member_id,issuer,subject,alias,kind,state,organizer,can_contribute) VALUES($1,$2,$3,$4,'Fixture contributor','adult','active',false,true),($1,$5,$3,$6,'Unrelated organizer','adult','active',true,true)",[h,member,issuer,subject,other,otherSubject]);
  const baseline=await owner.query("SELECT has_database_privilege($1,current_database(),'TEMP') AS temp,has_table_privilege($1,'managed_fixture.monitor_stats','SELECT') AS raw_rel,has_function_privilege($1,'managed_fixture.format_monitor()','EXECUTE') AS raw_fn,has_schema_privilege($1,'managed_fixture','USAGE') AS provider_access,has_schema_privilege($1,'ritc','USAGE') AS app_schema_access",[role]);
  assert.deepEqual(baseline.rows[0],{temp:true,raw_rel:true,raw_fn:true,provider_access:false,app_schema_access:false});
  await owner.end();owner=undefined;
  await admin.query('CREATE DATABASE '+quarantine+' TEMPLATE '+database);cloneMade=true;
  owner=pool(adminName);restored=pool(adminName,quarantine);restoreWorker=pool('ritc_test_worker',quarantine);
  const observer={connection:pgOptions(role),databaseOid,observerRole:role,observerRoleOid,ownerRole:adminName,ownerRoleOid};
  const config={pins,authorityPublicKey:backing.authorityKeys.publicKey,...observer,applicationName:'gateway-source-verification'};
  connector=createGatewayPostgresCommittedSource(config);strict=createPostgresCommittedSource(config);
  await assert.rejects(()=>strict.source.readOrigin(call()));
  assert.equal((await connector.source.readOrigin(call())).sourceIdentity,pins.sourceIdentity);
  const mistaken=createGatewayPostgresCommittedSource({...config,connection:pgOptions(role,quarantine),databaseOid:await oid(restored)});
  try{await assert.rejects(()=>mistaken.source.readOrigin(call()));}finally{await mistaken.close();}
  const restorable=await restored.query('SELECT alias,subject FROM ritc.member WHERE member_id=$1',[member]);
  assert.deepEqual(restorable.rows[0],{alias:'Fixture contributor',subject});

  for(const [grant,revoke] of [
   ['GRANT USAGE ON SCHEMA managed_fixture TO '+role,'REVOKE USAGE ON SCHEMA managed_fixture FROM '+role],
   ['GRANT SELECT(n) ON managed_fixture.monitor_stats TO '+role,'REVOKE SELECT(n) ON managed_fixture.monitor_stats FROM '+role],
   ['GRANT EXECUTE ON FUNCTION managed_fixture.format_monitor() TO '+role,'REVOKE EXECUTE ON FUNCTION managed_fixture.format_monitor() FROM '+role],
   ['GRANT USAGE ON SCHEMA ritc TO '+role,'REVOKE USAGE ON SCHEMA ritc FROM '+role],
   ['GRANT EXECUTE ON FUNCTION ritc_journal_source.privacy_journal_source_binding(text,uuid,text,text,oid) TO ritc_app','REVOKE EXECUTE ON FUNCTION ritc_journal_source.privacy_journal_source_binding(text,uuid,text,text,oid) FROM ritc_app'],
  ]){
   await owner.query(grant);
   try{await assert.rejects(()=>connector.source.readOrigin(call()));}finally{await owner.query(revoke);}
  }
  const raw=await new pg.Client(pgOptions(role)).connect();
  try{
   await raw.query('CREATE TEMP TABLE fixture_session_state(n int)');
   await assert.rejects(()=>raw.query('SELECT ritc_journal_source.privacy_journal_source_binding($1,$2,$3,$4,$5)',[pins.sourceIdentity,pins.lineage,schemaDigest,pins.configurationId,databaseOid]),{code:'42501'});
  }finally{await raw.end();}
  gateway=await startSourceGateway({pins,observer,authorityPublicKey:backing.authorityKeys.publicKeyPEM});
  assert.equal((await gateway.source.readOrigin(call())).lineage,pins.lineage);
  const journal=backing.adapter({source:gateway.source}).port;
  const repo=new HouseholdRepository(runtime,{allowChildNetwork:false,noticeVersion:'fixture',sessionStatus:new SupabaseSessionVerifier(issuer)});
  let providerCalls=0;
  const provider={assertAvailable:async()=>{},deleteAccount:async id=>{
   assert.equal(id,subject);assert.equal((await owner.query("SELECT 1 FROM ritc.privacy_journal_outbox e JOIN ritc.privacy_journal_ack a USING(event_id) WHERE e.job_id=$1 AND e.kind='acceptance'",[input.clientKey])).rowCount,1);
   await owner.query('DELETE FROM auth.sessions WHERE user_id=$1',[id]);await owner.query('DELETE FROM auth.users WHERE id=$1',[id]);providerCalls++;
  }};
  const policy={receiptRetentionDays:30,erasureMarkerRetentionDays:90,verifiedBackupRetentionDays:30};
  const request=new PrivacyService(repo,{provider,policy,journal:{...journal,afterCommit:async()=>{throw Error('Fixture lost acknowledgement');}}});
  await assert.rejects(request.request(identity,input),/Fixture lost acknowledgement/);
  const acceptance=await gateway.source.readCommittedAcceptance(input.clientKey,call());
  assert.deepEqual(await gateway.source.readCommittedEvent(acceptance.eventId,call()),acceptance);
  assert.deepEqual(await gateway.source.listUnacknowledgedJobEvents(input.clientKey,call()),[acceptance.eventId]);
  const maintenance=new PrivacyMaintenance(worker,{provider,journal});
  assert.equal((await maintenance.run({batchSize:1})).completed,1);assert.equal(providerCalls,1);
  const receipt=backing.receiptFor(acceptance.eventId,'commit');
  const ack=(proof)=>gateway.source.acknowledge(acceptance.eventId,acceptance.payloadDigest,receipt.record.seq,receipt.record.recordHash,proof,call());
  await assert.rejects(()=>ack({...receipt,authoritySignature:'A'.repeat(86)}));await ack(receipt);await ack(receipt);
  assert.deepEqual(await gateway.source.listUnacknowledgedJobEvents(input.clientKey,call()),[]);
  assert.equal((await owner.query('SELECT count(*)::int AS n FROM ritc.privacy_journal_ack WHERE event_id=$1',[acceptance.eventId])).rows[0].n,1);
  const verified=verifyPrivacyJournal(backing.exportBytes(),backing.sealedTrust());validatePrivacyRestoreEvents(verified.events);
  const restoreRun=randomUUID(),destinationOid=await oid(restored),lease=randomUUID();
  await restored.query('SELECT ritc.privacy_restore_register($1,$2,$3,$4::jsonb,$5::jsonb)',[restoreRun,destinationOid,verified.bundleDigest,JSON.stringify(verified.head),JSON.stringify(verified.events)]);
  const job=(await restoreWorker.query('SELECT ritc.privacy_restore_claim($1,$2) AS job',[restoreRun,lease])).rows[0].job;assert.equal(job,input.clientKey);
  const result=(await restoreWorker.query('SELECT ritc.privacy_restore_erase_next($1,$2,$3) AS v',[restoreRun,job,lease])).rows[0].v;assert.equal(result.applied,true);
  for(const db of [owner,restored]){
   const result=await db.query('SELECT alias,subject FROM ritc.member WHERE member_id=$1',[member]);assert.equal(result.rows[0].alias,'Removed member');assert.notEqual(result.rows[0].subject,subject);
   assert.deepEqual((await db.query('SELECT alias,subject FROM ritc.member WHERE member_id=$1',[other])).rows[0],{alias:'Unrelated organizer',subject:otherSubject});
  }
 }finally{
  await Promise.all([gateway?.close(),connector?.close(),strict?.close(),runtime.end(),worker.end(),owner?.end(),restored?.end(),restoreWorker?.end()]);
  if(cloneMade)await admin.query('DROP DATABASE '+quarantine);await admin.end();
 }
});
