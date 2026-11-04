#!/usr/bin/env node
// Owner-only local operator tool. No signing JSON or accepting target lists.
import{readFile,lstat}from'node:fs/promises';
import{createHash,createPublicKey,randomUUID}from'node:crypto';
import{isAbsolute}from'node:path';
import pg from'pg';
import{verifyPrivacyJournal,validatePrivacyRestoreEvents,journalHash}from'../dist/privacy-journal.js';
import{assertWorkerRole}from'../dist/maintenance.js';
import{verifyIndependentRecovery}from'../dist/privacy-journal-recovery.js';
const[command,configurationPath]=process.argv.slice(2);
if(!['verify','plan','replay','gate'].includes(command)||!configurationPath||process.argv.length!==4)throw Error('Usage: privacy-journal.mjs verify|plan|replay|gate OWNER_CONFIGURATION');
async function privateFile(path){const s=await lstat(path);if(!s.isFile()||s.isSymbolicLink()||(s.mode&0o077)!==0||s.uid!==process.getuid())throw Error('Owner-only regular configuration/evidence required');return readFile(path);}
const configuration=JSON.parse((await privateFile(configurationPath)).toString('utf8'));
const expectedKeys=['destination','dumpPath','dumpSHA256','headPath','journalPath','runId','trust','worker',...('authoritySeal' in configuration?['authoritySeal']:[])];
if(Object.keys(configuration).sort().join()!==expectedKeys.sort().join())throw Error('Unknown or missing operator configuration');
const head=JSON.parse((await privateFile(configuration.headPath)).toString('utf8'));
const bytes=await privateFile(configuration.journalPath),verified=verifyPrivacyJournal(bytes,{...configuration.trust,head});
validatePrivacyRestoreEvents(verified.events);
let independent;
if('authoritySeal' in configuration){
 const {path,pins,authorityPublicKey}=configuration.authoritySeal;
 if(Object.keys(configuration.authoritySeal).sort().join()!=='authorityPublicKey,path,pins'||
  !/^-----BEGIN PUBLIC KEY-----\r?\n/.test(authorityPublicKey)||!/^-----BEGIN PUBLIC KEY-----\r?\n/.test(configuration.trust.publicKey))throw Error('Pinned public keys and a private authority seal are required');
 const proof=JSON.parse((await privateFile(path)).toString('utf8'));
 independent=verifyIndependentRecovery(bytes,proof,pins,createPublicKey(configuration.trust.publicKey),createPublicKey(authorityPublicKey));
 if(journalHash(independent.head)!==journalHash(verified.head))throw Error('Independent seal and restore head disagree');
}
const dumpHash=createHash('sha256').update(await privateFile(configuration.dumpPath)).digest('hex');if(dumpHash!==configuration.dumpSHA256)throw Error('Dump manifest hash conflict');
if(command==='verify'){console.log(JSON.stringify({verified:true,events:verified.events.length,bundleDigest:verified.bundleDigest,head:verified.head,providerReconciliationRequired:true}));process.exit(0);}
function pool(settings,kind){
 if(!Number.isSafeInteger(settings.oid)||settings.oid<=0||typeof settings.user!=='string'||!settings.user)throw Error('Explicit newly owned quarantine destination required');
 let host='/tmp',port=55432;
 if(independent){
  if(Object.keys(settings).sort().join()!=='database,oid,port,socketDirectory,user'||!/^ritc_quarantine_[a-f0-9]{8,32}$/.test(settings.database)||
   typeof settings.socketDirectory!=='string'||!isAbsolute(settings.socketDirectory)||!Number.isSafeInteger(settings.port)||settings.port<1||settings.port>65535||
   independent.proof.sourceDatabaseOid===String(settings.oid))throw Error('Independent replay requires a distinct local quarantine database');
  host=settings.socketDirectory;port=settings.port;
 }else{
  if(Object.keys(settings).sort().join()!=='database,oid,user'||!/^ritc_b11_j022_restore_20261103(?:_[a-z0-9]+)*$/.test(settings.database)||
   kind==='worker'&&settings.user!=='ritc_b11_j022_worker'||kind==='owner'&&settings.user!=='palatis')throw Error('Separate fixed owner/worker identities required');
 }
 return new pg.Pool({host,port,database:settings.database,user:settings.user,password:()=>'',ssl:false,max:1,connectionTimeoutMillis:3000,statement_timeout:10000,lock_timeout:2000,query_timeout:12000,application_name:'ritc-local-privacy-journal'});
}
const owner=pool(configuration.destination,'owner');let worker;
try{
 const identity=(await owner.query("SELECT d.oid,d.datname,pg_get_userbyid(d.datdba) AS owner,session_user,inet_server_addr() AS address,current_setting('port') AS port FROM pg_database d WHERE d.datname=current_database()")).rows[0];
 if(identity.oid!==configuration.destination.oid||identity.owner!==identity.session_user||identity.address!==null||identity.port!==String(configuration.destination.port??55432))throw Error('Destination OID, owner, or local socket mismatch');
 if(configuration.worker.database!==configuration.destination.database||configuration.worker.oid!==configuration.destination.oid||configuration.worker.user===configuration.destination.user||
  configuration.worker.socketDirectory!==configuration.destination.socketDirectory||configuration.worker.port!==configuration.destination.port)throw Error('Worker destination mismatch');
 if(independent){
  const binding=(await owner.query('SELECT source_identity,database_oid::text FROM ritc.privacy_journal_source_registration WHERE singleton')).rows[0];
  if(!binding||binding.source_identity!==configuration.authoritySeal.pins.sourceIdentity||binding.database_oid!==independent.proof.sourceDatabaseOid)throw Error('Quarantine backup source does not match the seal');
 }
 if(command==='plan'){
  const db=await owner.connect();try{await db.query('BEGIN');await db.query('SELECT ritc.privacy_restore_register($1,$2,$3,$4::jsonb,$5::jsonb)',[configuration.runId,configuration.destination.oid,verified.bundleDigest,JSON.stringify(verified.head),JSON.stringify(verified.events)]);await db.query('COMMIT');}catch(error){await db.query('ROLLBACK');throw error;}finally{db.release();}
  console.log(JSON.stringify({runId:configuration.runId,registered:true,quarantined:true,providerReconciliationRequired:true}));
 }else if(command==='replay'){
  worker=pool(configuration.worker,'worker');await assertWorkerRole(worker);const started=Date.now();let applied=0;
  while(Date.now()-started<25000){const lease=randomUUID(),job=(await worker.query('SELECT ritc.privacy_restore_claim($1,$2) AS job',[configuration.runId,lease])).rows[0].job;if(!job)break;
   for(let n=0;n<100&&Date.now()-started<25000;n++){const value=(await worker.query('SELECT ritc.privacy_restore_erase_next($1,$2,$3) AS value',[configuration.runId,job,lease])).rows[0].value;if(value.applied)applied++;if(!value.applied||value.done)break;}
  }
  console.log(JSON.stringify({runId:configuration.runId,targetsApplied:applied,providerReconciliationRequired:true}));
 }else{
  const run=(await owner.query('SELECT phase,bundle_digest,head FROM ritc.privacy_restore_run WHERE run_id=$1 AND destination_oid=$2',[configuration.runId,configuration.destination.oid])).rows[0];
  if(!run||run.phase!=='local_app_erased'||run.bundle_digest!==verified.bundleDigest||journalHash(run.head)!==journalHash(verified.head))throw Error('Restore remains quarantined');
  const incomplete=(await owner.query('SELECT count(*)::int AS n FROM ritc.privacy_restore_target t WHERE run_id=$1 AND NOT EXISTS(SELECT 1 FROM ritc.privacy_restore_receipt q WHERE q.event_id=t.event_id AND q.household_id=t.household_id AND q.member_id=t.member_id AND q.target_digest=t.target_digest)',[configuration.runId])).rows[0].n;
  const bad=(await owner.query("SELECT count(*)::int AS n FROM ritc.privacy_restore_job v JOIN ritc.privacy_job j USING(job_id) WHERE v.run_id=$1 AND (j.provider_erased_at IS NOT NULL OR j.completed_at IS NOT NULL OR NOT EXISTS(SELECT 1 FROM ritc.identity_erasure e WHERE e.identity_hash=v.identity_hash AND e.job_id=v.job_id) OR EXISTS(SELECT 1 FROM ritc.browser_auth b WHERE encode(sha256(convert_to(b.issuer||E'\\n'||b.subject,'utf8')),'hex')=v.identity_hash))",[configuration.runId])).rows[0].n;
  if(incomplete||bad)throw Error('Restore scope or receipt verification pending');
  console.log(JSON.stringify({runId:configuration.runId,localAppErasureApplied:true,syntheticProbePermitted:true,providerReconciliationRequired:true,productionReady:false}));
 }
}finally{await worker?.end();await owner.end();}
