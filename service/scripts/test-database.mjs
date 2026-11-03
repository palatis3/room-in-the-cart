import { spawn } from 'node:child_process';
import { readdir } from 'node:fs/promises';
import pg from 'pg';
import { migrate } from './migrate.mjs';
const {TEST_DATABASE_URL,TEST_ADMIN_DATABASE_URL}=process.env;
if(!TEST_DATABASE_URL||!TEST_ADMIN_DATABASE_URL)throw new Error('Real PostgreSQL tests require TEST_DATABASE_URL and TEST_ADMIN_DATABASE_URL.');
const fixtureAdmin=new pg.Client({connectionString:TEST_ADMIN_DATABASE_URL});await fixtureAdmin.connect();
try{await fixtureAdmin.query('CREATE SCHEMA IF NOT EXISTS auth; CREATE TABLE IF NOT EXISTS auth.sessions(id uuid PRIMARY KEY,user_id uuid NOT NULL,not_after timestamptz)');}finally{await fixtureAdmin.end();}
await migrate(TEST_ADMIN_DATABASE_URL);
const files=(await readdir(new URL('../tests/',import.meta.url))).filter(name=>name.endsWith('.integration.mjs')).map(name=>'tests/'+name);
files.push('src/billing/tests/postgres.test.mjs');
const child=spawn(process.execPath,['--test',...files],{stdio:'inherit',cwd:new URL('../',import.meta.url),env:{...process.env,BILLING_TEST_DATABASE_URL:process.env.BILLING_TEST_DATABASE_URL??TEST_DATABASE_URL,BILLING_TEST_ADMIN_DATABASE_URL:process.env.BILLING_TEST_ADMIN_DATABASE_URL??TEST_ADMIN_DATABASE_URL}});
child.on('error',error=>{throw error;});
child.on('exit',(code,signal)=>{process.exitCode=code??(signal?1:0);});
