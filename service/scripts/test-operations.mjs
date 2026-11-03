import {spawn} from 'node:child_process';
import pg from 'pg';
import {migrate} from './migrate.mjs';
const runtime=process.env.OPERATIONS_TEST_DATABASE_URL,admin=process.env.OPERATIONS_TEST_ADMIN_DATABASE_URL;
if(!runtime||!admin)throw Error('Operations tests require a dedicated disposable PostgreSQL database through OPERATIONS_TEST_DATABASE_URL and OPERATIONS_TEST_ADMIN_DATABASE_URL');
if(runtime===process.env.TEST_DATABASE_URL||admin===process.env.TEST_ADMIN_DATABASE_URL)throw Error('Do not run broad cleanup tests in the parallel application fixture database');
const fixture=new pg.Client({connectionString:admin});await fixture.connect();
try{await fixture.query('CREATE SCHEMA IF NOT EXISTS auth; CREATE TABLE IF NOT EXISTS auth.sessions(id uuid PRIMARY KEY,user_id uuid NOT NULL,not_after timestamptz)');}finally{await fixture.end();}
await migrate(admin);
const child=spawn(process.execPath,['--test','tests/maintenance.operations.mjs'],{stdio:'inherit',cwd:new URL('../',import.meta.url),env:{...process.env,TEST_DATABASE_URL:runtime,TEST_ADMIN_DATABASE_URL:admin}});
child.on('error',error=>{throw error;});child.on('exit',(code,signal)=>{process.exitCode=code??(signal?1:0);});
