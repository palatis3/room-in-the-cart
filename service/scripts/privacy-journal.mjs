#!/usr/bin/env node
// Owner-only local operator tool. Plans are derived from signed journal records.
import {createHash,createPublicKey,randomUUID} from 'node:crypto';
import {constants} from 'node:fs';
import {open} from 'node:fs/promises';
import {isAbsolute} from 'node:path';
import pg from 'pg';
import {z} from 'zod';
import {verifyPrivacyJournal,validatePrivacyRestoreEvents,journalHash} from '../dist/privacy-journal.js';
import {assertWorkerRole} from '../dist/maintenance.js';
import {inspectIndependentArchiveWindow,verifyIndependentRecovery} from '../dist/privacy-journal-recovery.js';
import {MAX_JOURNAL_BYTES} from '../dist/privacy-journal-limits.js';
import {readPrivateFile} from './journal-authority-config.mjs';
import {jsonFile,readArchive,readArchives,windowSettings} from './journal-archive-window.mjs';

const [command,configurationPath]=process.argv.slice(2);
if(!['verify','plan','replay','gate'].includes(command)||!configurationPath||process.argv.length!==4)
 throw Error('Usage: privacy-journal.mjs verify|plan|replay|gate OWNER_CONFIGURATION');
const configuration=await jsonFile(configurationPath);
const isWindow=Object.hasOwn(configuration,'archiveWindowPath');
const journalKeys=['headPath','journalPath','trust',...(Object.hasOwn(configuration,'authoritySeal')?['authoritySeal']:[])];
const expectedKeys=['destination','dumpPath','dumpSHA256','runId','worker',...(isWindow?['archiveWindowPath','segmentRunIds']:journalKeys)];
if(Object.keys(configuration).sort().join()!==expectedKeys.sort().join())throw Error('Unknown or missing operator configuration');
z.string().uuid().parse(configuration.runId);

async function dumpDigest(path){
 const file=await open(path,constants.O_RDONLY|constants.O_NOFOLLOW);
 try{
  const stat=await file.stat();
  if(!stat.isFile()||stat.uid!==process.getuid()||(stat.mode&0o077)!==0)throw Error('Owner-only regular dump required');
  const digest=createHash('sha256');
  for await(const part of file.createReadStream({autoClose:false}))digest.update(part);
  return digest.digest('hex');
 }finally{await file.close();}
}

async function inspectSingle(){
 const head=await jsonFile(configuration.headPath,8192);
 const bytes=await readPrivateFile(configuration.journalPath,MAX_JOURNAL_BYTES);
 const verified=verifyPrivacyJournal(bytes,{...configuration.trust,head});
 validatePrivacyRestoreEvents(verified.events);
 if(!configuration.authoritySeal)return {verified};
 const {path,pins,authorityPublicKey}=configuration.authoritySeal;
 if(Object.keys(configuration.authoritySeal).sort().join()!=='authorityPublicKey,path,pins'||
  !/^-----BEGIN PUBLIC KEY-----\r?\n/.test(authorityPublicKey)||!/^-----BEGIN PUBLIC KEY-----\r?\n/.test(configuration.trust.publicKey))
  throw Error('Pinned public keys and a private authority seal are required');
 const independent=verifyIndependentRecovery(bytes,await jsonFile(path,8192),pins,createPublicKey(configuration.trust.publicKey),createPublicKey(authorityPublicKey));
 if(journalHash(independent.head)!==journalHash(verified.head))throw Error('Independent seal and restore head disagree');
 return {verified,binding:{sourceIdentity:pins.sourceIdentity,sourceDatabaseOid:independent.proof.sourceDatabaseOid}};
}

async function inspectWindow(){
 const {segments,...trust}=windowSettings.parse(await jsonFile(configuration.archiveWindowPath));
 const checked=await inspectIndependentArchiveWindow(readArchives(segments),trust);
 const runIds=z.array(z.string().uuid()).length(segments.length).parse(configuration.segmentRunIds);
 if(new Set([configuration.runId,...runIds]).size!==runIds.length+1)throw Error('Distinct window and segment run IDs required');
 const entries=checked.archives.map((segment,index)=>({...segment,runId:runIds[index],position:index+1}));
 const digest=journalHash({version:1,windowId:configuration.runId,dumpSHA256:configuration.dumpSHA256,...trust,entries});
 return {entries,segments,events:checked.events,digest,binding:{sourceIdentity:checked.sourceIdentity,sourceDatabaseOid:checked.sourceDatabaseOid}};
}

if(await dumpDigest(configuration.dumpPath)!==configuration.dumpSHA256)throw Error('Dump manifest hash conflict');
const evidence=await (isWindow?inspectWindow():inspectSingle());
const binding=evidence.binding;
if(command==='verify'){
 const summary=isWindow?{events:evidence.events,segments:evidence.entries.length,manifestDigest:evidence.digest}:
  {events:evidence.verified.events.length,bundleDigest:evidence.verified.bundleDigest,head:evidence.verified.head};
 console.log(JSON.stringify({verified:true,...summary,providerReconciliationRequired:true}));
 process.exit(0);
}

function pool(settings,kind){
 if(!Number.isSafeInteger(settings.oid)||settings.oid<=0||typeof settings.user!=='string'||!settings.user)
  throw Error('Explicit newly owned quarantine destination required');
 let host='/tmp',port=55432;
 if(binding){
  if(Object.keys(settings).sort().join()!=='database,oid,port,socketDirectory,user'||!/^ritc_quarantine_[a-f0-9]{8,32}$/.test(settings.database)||
   typeof settings.socketDirectory!=='string'||!isAbsolute(settings.socketDirectory)||!Number.isSafeInteger(settings.port)||settings.port<1||settings.port>65535||
   binding.sourceDatabaseOid===String(settings.oid))throw Error('Independent replay requires a distinct local quarantine database');
  host=settings.socketDirectory;port=settings.port;
 }else{
  if(Object.keys(settings).sort().join()!=='database,oid,user'||!/^ritc_b11_j022_restore_20261103(?:_[a-z0-9]+)*$/.test(settings.database)||
   kind==='worker'&&settings.user!=='ritc_b11_j022_worker'||kind==='owner'&&settings.user!=='palatis')
   throw Error('Separate fixed owner/worker identities required');
 }
 return new pg.Pool({host,port,database:settings.database,user:settings.user,password:()=>'',ssl:false,max:1,
  connectionTimeoutMillis:3000,statement_timeout:10000,lock_timeout:2000,query_timeout:12000,application_name:'ritc-local-privacy-journal'});
}

const {destination,worker:workerSettings,runId}=configuration;
const owner=pool(destination,'owner');
let worker;
async function transaction(work){
 const db=await owner.connect();
 try{await db.query('BEGIN');const result=await work(db);await db.query('COMMIT');return result;}
 catch(error){await db.query('ROLLBACK').catch(()=>{});throw error;}
 finally{db.release();}
}

async function assertDestination(){
 const identity=(await owner.query(`SELECT d.oid,d.datname,pg_get_userbyid(d.datdba) AS owner,session_user,inet_server_addr() AS address,
  current_setting('port') AS port FROM pg_database d WHERE d.datname=current_database()`)).rows[0];
 if(identity.oid!==destination.oid||identity.owner!==identity.session_user||identity.address!==null||identity.port!==String(destination.port??55432))
  throw Error('Destination OID, owner, or local socket mismatch');
 if(workerSettings.database!==destination.database||workerSettings.oid!==destination.oid||workerSettings.user===destination.user||
  workerSettings.socketDirectory!==destination.socketDirectory||workerSettings.port!==destination.port)throw Error('Worker destination mismatch');
 if(binding){
  const source=(await owner.query('SELECT source_identity,database_oid::text FROM ritc.privacy_journal_source_registration WHERE singleton')).rows[0];
  if(!source||source.source_identity!==binding.sourceIdentity||source.database_oid!==binding.sourceDatabaseOid)
   throw Error('Quarantine backup source does not match the seal');
 }
 if(isWindow){
  const row=(await owner.query(`SELECT EXISTS(SELECT 1 FROM pg_roles r
   WHERE r.rolcanlogin AND NOT r.rolsuper AND pg_has_role(r.oid,'ritc_app','MEMBER')
   AND (has_database_privilege(r.oid,$1::oid,'CONNECT') OR EXISTS(
    SELECT 1 FROM pg_stat_activity a WHERE a.datid=$1::oid AND a.usesysid=r.oid))) AS exposed`,[destination.oid])).rows[0];
  if(row.exposed)throw Error('Quarantine database is accessible to the application role');
 }
}

async function register(db,id,verified){
 await db.query('SELECT ritc.privacy_restore_register($1,$2,$3,$4::jsonb,$5::jsonb)',
  [id,destination.oid,verified.bundleDigest,JSON.stringify(verified.head),JSON.stringify(verified.events)]);
 // A device could have opted out after the backup. Only a fresh opt-in in the
 // recovered database may authorize additional queued sends.
 if((await db.query("SELECT to_regclass('ritc.request_queue_permission') IS NOT NULL AS installed")).rows[0].installed)
  await db.query('TRUNCATE ritc.request_queue_permission');
}

async function replay(id){
 worker=pool(workerSettings,'worker');
 await assertWorkerRole(worker);
 const started=Date.now();let applied=0;
 while(Date.now()-started<25000){
  const lease=randomUUID();
  const job=(await worker.query('SELECT ritc.privacy_restore_claim($1,$2) AS job',[id,lease])).rows[0].job;
  if(!job)break;
  for(let n=0;n<100&&Date.now()-started<25000;n++){
   const value=(await worker.query('SELECT ritc.privacy_restore_erase_next($1,$2,$3) AS value',[id,job,lease])).rows[0].value;
   if(value.applied)applied++;
   if(!value.applied||value.done)break;
  }
 }
 return applied;
}

function matchesRun(run,expected){
 return run&&run.destination_oid===destination.oid&&run.bundle_digest===expected.bundleDigest&&journalHash(run.head)===journalHash(expected.head);
}
async function checkReplayed(id,expected,run){
 if(!matchesRun(run,expected)||run.phase!=='local_app_erased')throw Error('Restore remains quarantined');
 const {incomplete,bad,jobs}=(await owner.query(`SELECT
  (SELECT count(*)::int FROM ritc.privacy_restore_target t WHERE run_id=$1 AND NOT EXISTS(
   SELECT 1 FROM ritc.privacy_restore_receipt q WHERE q.event_id=t.event_id AND q.household_id=t.household_id AND
    q.member_id=t.member_id AND q.target_digest=t.target_digest)) AS incomplete,
  (SELECT count(*)::int FROM ritc.privacy_restore_job v JOIN ritc.privacy_job j USING(job_id) WHERE v.run_id=$1 AND (
   j.provider_erased_at IS NOT NULL OR j.completed_at IS NOT NULL OR NOT EXISTS(
    SELECT 1 FROM ritc.identity_erasure e WHERE e.identity_hash=v.identity_hash AND e.job_id=v.job_id) OR EXISTS(
    SELECT 1 FROM ritc.browser_auth b WHERE encode(sha256(convert_to(b.issuer||E'\\n'||b.subject,'utf8')),'hex')=v.identity_hash))) AS bad,
  (SELECT count(*)::int FROM ritc.privacy_restore_job WHERE run_id=$1) AS jobs`,[id])).rows[0];
 if(incomplete||bad||expected.jobs!==undefined&&expected.jobs!==jobs)throw Error('Restore scope or receipt verification pending');
}

async function readRuns(ids){
 return new Map((await owner.query('SELECT * FROM ritc.privacy_restore_run WHERE run_id=ANY($1::uuid[])',[ids])).rows.map(row=>[row.run_id,row]));
}
async function reportGate(extra={}){
 if((await owner.query("SELECT to_regclass('ritc.request_queue_permission') IS NOT NULL AS installed")).rows[0].installed &&
    (await owner.query('SELECT 1 FROM ritc.request_queue_permission LIMIT 1')).rowCount)
  throw Error('Restored device queue permissions must be cleared in quarantine');
 console.log(JSON.stringify({runId,localAppErasureApplied:true,syntheticProbePermitted:true,providerReconciliationRequired:true,productionReady:false,...extra}));
}

async function readWindow(db){
 const stored=(await db.query('SELECT * FROM ritc.privacy_restore_window WHERE singleton')).rows[0];
 if(!stored)return false;
 if(stored.window_id!==runId||stored.destination_oid!==destination.oid||stored.manifest_digest!==evidence.digest||
  stored.source_identity!==binding.sourceIdentity||String(stored.source_database_oid)!==binding.sourceDatabaseOid||
  stored.segment_count!==evidence.entries.length)throw Error('Restore window conflicts with the staged manifest');
 const {rows}=await db.query('SELECT position,run_id,bundle_digest,head,jobs FROM ritc.privacy_restore_window_segment WHERE window_id=$1 ORDER BY position',[runId]);
 if(rows.length!==evidence.entries.length||rows.some((row,index)=>{
  const entry=evidence.entries[index];
  return row.position!==entry.position||row.run_id!==entry.runId||row.bundle_digest!==entry.bundleDigest||
   journalHash(row.head)!==journalHash(entry.head)||row.jobs!==entry.jobs;
 }))throw Error('Staged restore window segments changed');
 return true;
}
async function stageWindow(db){
 if(await readWindow(db))return;
 if((await db.query('SELECT 1 FROM ritc.privacy_restore_run LIMIT 1')).rowCount)throw Error('Quarantine has a previous restore plan');
 await db.query(`INSERT INTO ritc.privacy_restore_window(window_id,destination_oid,source_identity,source_database_oid,manifest_digest,segment_count)
  VALUES($1,$2,$3,$4,$5,$6)`,[runId,destination.oid,binding.sourceIdentity,binding.sourceDatabaseOid,evidence.digest,evidence.entries.length]);
 await db.query(`INSERT INTO ritc.privacy_restore_window_segment(window_id,position,run_id,bundle_digest,head,jobs)
  SELECT $1,x.position,x.run_id,x.bundle_digest,x.head,x.jobs FROM jsonb_to_recordset($2::jsonb)
  AS x(position int,run_id uuid,bundle_digest text,head jsonb,jobs int)`,[runId,JSON.stringify(evidence.entries.map(entry=>({
  position:entry.position,run_id:entry.runId,bundle_digest:entry.bundleDigest,head:entry.head,jobs:entry.jobs,
 })))]);
}

async function applyWindow(){
 const staged=await readWindow(owner);
 if(command!=='plan'&&!staged)throw Error('Plan the verified archive window first');
 const runs=await readRuns(evidence.entries.map(entry=>entry.runId));
 for(const entry of evidence.entries){
  const run=runs.get(entry.runId);
  if(run&&!matchesRun(run,entry))throw Error('Restore run conflicts with the archive window');
 }
 const next=evidence.entries.find(entry=>runs.get(entry.runId)?.phase!=='local_app_erased');
 if(command==='gate'){
  if(next||!(await owner.query('SELECT fenced FROM ritc.privacy_journal_origin WHERE singleton')).rows[0]?.fenced)
   throw Error('Restore window remains quarantined');
  for(const entry of evidence.entries)await checkReplayed(entry.runId,entry,runs.get(entry.runId));
  await reportGate({segments:evidence.entries.length,manifestDigest:evidence.digest});
  return;
 }
 if(command==='replay'){
  if(next&&!runs.has(next.runId))throw Error('Plan the next archive segment before replay');
  const targetsApplied=next?await replay(next.runId):0;
  console.log(JSON.stringify({runId,segment:next?.position??null,targetsApplied,providerReconciliationRequired:true}));
  return;
 }
 if(next){
  const archive=await readArchive(evidence.segments[next.position-1]);
  const verified=verifyIndependentRecovery(archive.bytes,archive.seal,archive.pins,archive.writerPublicKey,archive.authorityPublicKey);
  if(verified.bundleDigest!==next.bundleDigest||journalHash(verified.proof)!==next.sealDigest)throw Error('Archive changed after window verification');
  await transaction(async db=>{
   await db.query('SELECT 1 FROM ritc.privacy_journal_origin WHERE singleton FOR UPDATE');
   await stageWindow(db);
   await register(db,next.runId,verified);
  });
 }else if(!staged)throw Error('Missing restore window plan');
 console.log(JSON.stringify({runId,registered:true,quarantined:true,segment:next?.position??null,providerReconciliationRequired:true}));
}

try{
 await assertDestination();
 if(isWindow)await applyWindow();
 else{
  // A single archive cannot be used to open the gate for a staged window.
  const installed=(await owner.query("SELECT to_regclass('ritc.privacy_restore_window') IS NOT NULL AS ready")).rows[0].ready;
  if(installed&&(await owner.query('SELECT 1 FROM ritc.privacy_restore_window LIMIT 1')).rowCount)
   throw Error('Use the full archive window for this quarantine');
  const verified=evidence.verified;
  if(command==='plan'){
   await transaction(db=>register(db,runId,verified));
   console.log(JSON.stringify({runId,registered:true,quarantined:true,providerReconciliationRequired:true}));
  }else if(command==='replay'){
   console.log(JSON.stringify({runId,targetsApplied:await replay(runId),providerReconciliationRequired:true}));
  }else{
   await checkReplayed(runId,verified,(await readRuns([runId])).get(runId));
   await reportGate();
  }
 }
}finally{await worker?.end();await owner.end();}
