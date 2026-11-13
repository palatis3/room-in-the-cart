import { spawn } from 'node:child_process';
import { readdir,mkdtemp,chmod } from 'node:fs/promises';
import { preparePrivacyJournalFixture,fencePrivacyJournalFixture } from '../tests/privacy-journal-fixture.mjs';
import pg from 'pg';
import { migrate } from './migrate.mjs';
import { integrationTestEnvironment,preflightIntegrationAssets,preflightIntegrationDatabase,preflightIntegrationConnections } from './database-test-preflight.mjs';
const configuration=integrationTestEnvironment(process.env);
await preflightIntegrationAssets();
const {TEST_ADMIN_DATABASE_URL}=configuration.environment;
const fixtureAdmin=new pg.Client({connectionString:TEST_ADMIN_DATABASE_URL,connectionTimeoutMillis:5000,query_timeout:5000});
try{await fixtureAdmin.connect();}catch{await fixtureAdmin.end().catch(()=>{});throw Error('Database test preflight: Cannot verify admin fixture connection; check its local endpoint and credentials.');}
try{await preflightIntegrationDatabase(fixtureAdmin,configuration);await preflightIntegrationConnections(configuration);await fixtureAdmin.query('CREATE SCHEMA IF NOT EXISTS auth; CREATE TABLE IF NOT EXISTS auth.users(id uuid PRIMARY KEY,email text,email_confirmed_at timestamptz); CREATE TABLE IF NOT EXISTS auth.sessions(id uuid PRIMARY KEY,user_id uuid NOT NULL,not_after timestamptz)');}finally{await fixtureAdmin.end();}
await migrate(TEST_ADMIN_DATABASE_URL);
const files=(await readdir(new URL('../tests/',import.meta.url))).filter(name=>name.endsWith('.integration.mjs')).map(name=>'tests/'+name);
files.push('src/billing/tests/postgres.test.mjs');
const journalRoot=await mkdtemp('/tmp/ritc-integration-journal-evidence-');await chmod(journalRoot,0o700);
const journalOwner=new pg.Client({connectionString:TEST_ADMIN_DATABASE_URL});await journalOwner.connect();
const journalConfiguration=await preparePrivacyJournalFixture(journalOwner,journalRoot);
console.log('Synthetic journal fixture retained at '+journalRoot+'; private key is separately held outside evidence.');
const child=spawn(process.execPath,['--test','--test-concurrency=1',...files],{stdio:'inherit',cwd:new URL('../',import.meta.url),env:{...configuration.environment,PRIVACY_JOURNAL_TEST_CONFIGURATION:journalConfiguration}});
try{
 const [code,signal]=await new Promise((resolve,reject)=>{child.once('error',reject);child.once('exit',(code,signal)=>resolve([code,signal]));});
 process.exitCode=code??(signal?1:0);
 await fencePrivacyJournalFixture(journalOwner,journalConfiguration);
}finally{await journalOwner.end();}
