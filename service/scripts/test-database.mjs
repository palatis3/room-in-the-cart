import { spawn } from 'node:child_process';
import { readdir } from 'node:fs/promises';
import pg from 'pg';
import { migrate } from './migrate.mjs';
const {TEST_DATABASE_URL,TEST_ADMIN_DATABASE_URL}=process.env;
if(!TEST_DATABASE_URL||!TEST_ADMIN_DATABASE_URL)throw new Error('Real PostgreSQL tests require TEST_DATABASE_URL and TEST_ADMIN_DATABASE_URL.');
const fixtureAdmin=new pg.Client({connectionString:TEST_ADMIN_DATABASE_URL});await fixtureAdmin.connect();
try{await fixtureAdmin.query('CREATE SCHEMA IF NOT EXISTS auth; CREATE TABLE IF NOT EXISTS auth.users(id uuid PRIMARY KEY,email text,email_confirmed_at timestamptz); CREATE TABLE IF NOT EXISTS auth.sessions(id uuid PRIMARY KEY,user_id uuid NOT NULL,not_after timestamptz)');}finally{await fixtureAdmin.end();}
await migrate(TEST_ADMIN_DATABASE_URL);
const verifierAdmin=new pg.Client({connectionString:TEST_ADMIN_DATABASE_URL});await verifierAdmin.connect();try{await verifierAdmin.query("DO $$ BEGIN IF NOT EXISTS(SELECT 1 FROM pg_roles WHERE rolname='ritc_guardian_test_verifier') THEN CREATE ROLE ritc_guardian_test_verifier LOGIN NOSUPERUSER NOBYPASSRLS; END IF; END $$; GRANT ritc_guardian_verifier TO ritc_guardian_test_verifier");}finally{await verifierAdmin.end();}
const verifierURL=new URL(TEST_DATABASE_URL);verifierURL.username='ritc_guardian_test_verifier';
const files=(await readdir(new URL('../tests/',import.meta.url))).filter(name=>name.endsWith('.integration.mjs')).map(name=>'tests/'+name);
files.push('src/billing/tests/postgres.test.mjs');
const child=spawn(process.execPath,['--test',...files],{stdio:'inherit',cwd:new URL('../',import.meta.url),env:{...process.env,TEST_GUARDIAN_VERIFIER_DATABASE_URL:process.env.TEST_GUARDIAN_VERIFIER_DATABASE_URL??verifierURL.toString(),BILLING_TEST_DATABASE_URL:process.env.BILLING_TEST_DATABASE_URL??TEST_DATABASE_URL,BILLING_TEST_ADMIN_DATABASE_URL:process.env.BILLING_TEST_ADMIN_DATABASE_URL??TEST_ADMIN_DATABASE_URL}});
child.on('error',error=>{throw error;});
child.on('exit',(code,signal)=>{process.exitCode=code??(signal?1:0);});
