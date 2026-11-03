import { spawn } from 'node:child_process';
import { readdir,mkdtemp,chmod } from 'node:fs/promises';
import { preparePrivacyJournalFixture,fencePrivacyJournalFixture } from '../tests/privacy-journal-fixture.mjs';
import pg from 'pg';
import { migrate } from './migrate.mjs';
const {TEST_DATABASE_URL,TEST_ADMIN_DATABASE_URL}=process.env;
if(!TEST_DATABASE_URL||!TEST_ADMIN_DATABASE_URL)throw new Error('Real PostgreSQL tests require TEST_DATABASE_URL and TEST_ADMIN_DATABASE_URL.');
const fixtureAdmin=new pg.Client({connectionString:TEST_ADMIN_DATABASE_URL});await fixtureAdmin.connect();
try{await fixtureAdmin.query('CREATE SCHEMA IF NOT EXISTS auth; CREATE TABLE IF NOT EXISTS auth.users(id uuid PRIMARY KEY,email text,email_confirmed_at timestamptz); CREATE TABLE IF NOT EXISTS auth.sessions(id uuid PRIMARY KEY,user_id uuid NOT NULL,not_after timestamptz)');}finally{await fixtureAdmin.end();}
await migrate(TEST_ADMIN_DATABASE_URL);
const verifierAdmin=new pg.Client({connectionString:TEST_ADMIN_DATABASE_URL});await verifierAdmin.connect();try{
 const role=(await verifierAdmin.query("SELECT rolcanlogin,rolsuper,rolbypassrls,pg_has_role(oid,'ritc_guardian_verifier','MEMBER') AS verifier,pg_has_role(oid,'ritc_app','MEMBER') AS app,pg_has_role(oid,'ritc_worker','MEMBER') AS worker FROM pg_roles WHERE rolname='ritc_guardian_test_verifier'")).rows[0];
 if(!role?.rolcanlogin||!role.verifier||role.app||role.worker||role.rolsuper||role.rolbypassrls)throw Error('Configure the distinct local guardian verifier before running this disposable-database suite; no role or membership changes are performed.');
}finally{await verifierAdmin.end();}
const verifierURL=new URL(TEST_DATABASE_URL);verifierURL.username='ritc_guardian_test_verifier';
const files=(await readdir(new URL('../tests/',import.meta.url))).filter(name=>name.endsWith('.integration.mjs')).map(name=>'tests/'+name);
files.push('src/billing/tests/postgres.test.mjs');
const journalRoot=await mkdtemp('/tmp/ritc-integration-journal-evidence-');await chmod(journalRoot,0o700);
const journalOwner=new pg.Client({connectionString:TEST_ADMIN_DATABASE_URL});await journalOwner.connect();
const journalConfiguration=await preparePrivacyJournalFixture(journalOwner,journalRoot);
console.log('Synthetic journal fixture retained at '+journalRoot+'; private key is separately held outside evidence.');
const child=spawn(process.execPath,['--test','--test-concurrency=1',...files],{stdio:'inherit',cwd:new URL('../',import.meta.url),env:{...process.env,PRIVACY_JOURNAL_TEST_CONFIGURATION:journalConfiguration,TEST_GUARDIAN_VERIFIER_DATABASE_URL:process.env.TEST_GUARDIAN_VERIFIER_DATABASE_URL??verifierURL.toString(),BILLING_TEST_DATABASE_URL:process.env.BILLING_TEST_DATABASE_URL??TEST_DATABASE_URL,BILLING_TEST_ADMIN_DATABASE_URL:process.env.BILLING_TEST_ADMIN_DATABASE_URL??TEST_ADMIN_DATABASE_URL}});
try{
 const [code,signal]=await new Promise((resolve,reject)=>{child.once('error',reject);child.once('exit',(code,signal)=>resolve([code,signal]));});
 process.exitCode=code??(signal?1:0);
 await fencePrivacyJournalFixture(journalOwner,journalConfiguration);
}finally{await journalOwner.end();}
