import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {execFile} from 'node:child_process';
import {promisify} from 'node:util';
import {mkdtemp, readFile, rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import pg from 'pg';
import {integrationTestEnvironment} from '../scripts/database-test-preflight.mjs';
import {migrate} from '../scripts/migrate.mjs';
import {verifyPrivacyJournal, validatePrivacyRestoreEvents} from '../dist/privacy-journal.js';
import {preparePrivacyJournalFixture} from './privacy-journal-fixture.mjs';

const execute=promisify(execFile);
export const restoreTestName='verified guardian child erasure replays into a quarantined backup';
const databaseURL=(url,name)=>{const dst=new URL(url);dst.pathname='/'+name;return dst.toString();};

export async function runIsolatedChildRestore(){
 integrationTestEnvironment(process.env);
 const adminURL=new URL(process.env.TEST_ADMIN_DATABASE_URL);
 assert.ok(['localhost','127.0.0.1','[::1]'].includes(adminURL.hostname)&&adminURL.pathname.startsWith('/ritc_'));
 const suffix=randomUUID().replaceAll('-',''),sourceName='ritc_child_source_'+suffix,destinationName='ritc_child_restore_'+suffix;
 const control=new pg.Client({connectionString:adminURL.toString()});
 await control.connect();
 const src=databaseURL(adminURL,sourceName);
 const dir=await mkdtemp(join(tmpdir(),'ritc-child-restore-'));
 try {
 await control.query('CREATE DATABASE '+sourceName);
 const source=new pg.Client({connectionString:src});
 await source.connect();
 let config;
 try{
  await source.query('CREATE SCHEMA auth; CREATE TABLE auth.users(id uuid PRIMARY KEY,email text,email_confirmed_at timestamptz); CREATE TABLE auth.sessions(id uuid PRIMARY KEY,user_id uuid NOT NULL,not_after timestamptz)');
  await migrate(src);
  config=await preparePrivacyJournalFixture(source,dir,dir);
 }finally{await source.end();}
 const env={...process.env,RITC_CHILD_RESTORE_DIRECTORY:dir,PRIVACY_JOURNAL_TEST_CONFIGURATION:config};
 // This is a separate test process with its own source and journal. Node suppresses
 // nested test discovery when the parent runner's internal context is inherited.
 delete env.NODE_TEST_CONTEXT;
 for(const key of ['TEST_ADMIN_DATABASE_URL','TEST_DATABASE_URL','TEST_WORKER_DATABASE_URL','TEST_GUARDIAN_VERIFIER_DATABASE_URL']){
  env[key]=databaseURL(process.env[key],sourceName);
 }
 const result=await execute(process.execPath,['--test','--test-name-pattern='+restoreTestName,'tests/guardian.integration.mjs'],{cwd:new URL('../',import.meta.url),env}).catch(error=>{
  throw Error('Isolated child restore failed: '+(adminURL.password?String(error.stdout||error.stderr).replaceAll(adminURL.password,'[redacted]'):String(error.stdout||error.stderr)));
 });
 assert.match(result.stdout,/# pass 1\b/);
 } finally {
  try {
   await control.query('DROP DATABASE IF EXISTS '+destinationName+' WITH (FORCE)');
   await control.query('DROP DATABASE IF EXISTS '+sourceName+' WITH (FORCE)');
  } finally {
   await control.end();
   await rm(dir,{recursive:true,force:true});
  }
 }
}

export async function verifyChildBackup({family,unjoined,childMemberId,journal,accept}){
 const sourceURL=new URL(process.env.TEST_ADMIN_DATABASE_URL);
 assert.match(sourceURL.pathname,/^\/ritc_child_source_[0-9a-f]+$/);
 const params=new pg.Client({connectionString:sourceURL.toString()}).connectionParameters;
 const authArgs=['--host',params.host,'--port',String(params.port),'--username',params.user];
 const env={...process.env,PGPASSWORD:params.password??''};
 const dir=process.env.RITC_CHILD_RESTORE_DIRECTORY;
 const dump=join(dir,'before-acceptance.dump');
 const tool=name=>process.env.RITC_TEST_PG_BIN?join(process.env.RITC_TEST_PG_BIN,name):name;
 await execute(tool('pg_dump'),[...authArgs,'--format=custom','--file',dump,'--dbname',sourceURL.pathname.slice(1)],{env});
 const jobs=await accept();
 const config=JSON.parse(await readFile(process.env.PRIVACY_JOURNAL_TEST_CONFIGURATION,'utf8'));
 const head=await journal.fence();
 const verified=verifyPrivacyJournal(await readFile(join(config.directory,'journal.ndjson')),{...config,publicKey:journal.publicKey,head});
 validatePrivacyRestoreEvents(verified.events);
 const accepts=verified.events.filter(e=>e.payload.kind==='acceptance');
 assert.equal(accepts.length,2);
 assert.deepEqual(accepts.find(e=>e.payload.jobId===jobs.unjoined).payload.data.targets,[]);
 assert.deepEqual(accepts.find(e=>e.payload.jobId===jobs.member).payload.data.targets.map(t=>[t.kind,t.memberId]),[['guardian_child_account',childMemberId]]);
 const dest=sourceURL.pathname.slice(1).replace('ritc_child_source_','ritc_child_restore_');
 const runtimeRole=new URL(process.env.TEST_DATABASE_URL).username,workerRole=new URL(process.env.TEST_WORKER_DATABASE_URL).username;
 assert.match(runtimeRole,/^[a-z_]+$/);assert.match(workerRole,/^[a-z_]+$/);
 const owner=new pg.Client({connectionString:sourceURL.toString()});await owner.connect();
 try{
  await owner.query('CREATE DATABASE '+dest);
  await owner.query('REVOKE CONNECT ON DATABASE '+dest+' FROM PUBLIC,'+runtimeRole+',ritc_app');
  await owner.query('GRANT CONNECT ON DATABASE '+dest+' TO '+workerRole);
  assert.equal((await owner.query("SELECT has_database_privilege($1,$2,'CONNECT') AS allowed",[runtimeRole,dest])).rows[0].allowed,false);
 }finally{await owner.end();}
 await execute(tool('pg_restore'),[...authArgs,'--exit-on-error','--dbname',dest,dump],{env});
 const restored=new pg.Client({connectionString:databaseURL(sourceURL,dest)}),worker=new pg.Client({connectionString:databaseURL(process.env.TEST_WORKER_DATABASE_URL,dest)});
 await restored.connect();await worker.connect();
 try{
  const before=(await restored.query('SELECT subject,alias FROM ritc.member WHERE member_id=$1',[childMemberId])).rows[0];
  assert.equal(before.subject,family.child.subject);
  assert.equal((await restored.query('SELECT 1 FROM ritc.guardian_child_signin WHERE subject=$1',[unjoined.child.subject])).rowCount,1);
  const oid=(await restored.query('SELECT oid FROM pg_database WHERE datname=current_database()')).rows[0].oid;
  const run=randomUUID(),lease=randomUUID();
  await restored.query('SELECT ritc.privacy_restore_register($1,$2,$3,$4::jsonb,$5::jsonb)',[run,oid,verified.bundleDigest,JSON.stringify(verified.head),JSON.stringify(verified.events)]);
  assert.equal((await worker.query('SELECT ritc.privacy_restore_claim($1,$2) AS job',[run,lease])).rows[0].job,jobs.member);
  const result=(await worker.query('SELECT ritc.privacy_restore_erase_next($1,$2,$3) AS v',[run,jobs.member,lease])).rows[0].v;
  assert.equal(result.localAppErasureApplied,true);
  const memberships=(await restored.query('SELECT alias,subject,state,erased_at FROM ritc.member WHERE household_id=$1',[family.house.householdId])).rows;
  assert.equal(memberships.find(m=>m.subject===family.adult.subject).state,'active');
  assert.equal(memberships.some(m=>m.subject===family.child.subject),false);
  assert.ok(memberships.find(m=>m.alias==='Removed member').erased_at);
  assert.equal((await restored.query('SELECT 1 FROM ritc.guardian_child_signin WHERE subject=$1',[family.child.subject])).rowCount,0);
  const pendingState=await restored.query('SELECT ritc.identity_blocked($1,$2) AS blocked, EXISTS(SELECT 1 FROM ritc.guardian_child_signin WHERE subject=$2) AS admitted',['https://guardian.fixture.invalid',unjoined.child.subject]);
  assert.deepEqual(pendingState.rows[0],{blocked:true,admitted:false});
  assert.equal((await restored.query("SELECT 1 FROM ritc.member WHERE subject=$1 AND state='active'",[unjoined.adult.subject])).rowCount,1);
  // Provider reconciliation is separate from quarantined app-data replay.
  assert.equal((await restored.query('SELECT 1 FROM auth.users WHERE id IN($1,$2)',[family.child.subject,family.adult.subject])).rowCount,2);
 }finally{await worker.end();await restored.end();}
}
