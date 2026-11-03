// Local-only disposable PostgreSQL harness; never touches staging or sends email.
import {randomUUID,createHash} from 'node:crypto';
import {readdir,readFile} from 'node:fs/promises';
import {spawn} from 'node:child_process';
import pg from 'pg';
const root=new URL('../',import.meta.url), adminURL=new URL(process.env.TEST_ADMIN_DATABASE_URL??'postgresql://palatis@localhost/postgres?host=/tmp&port=55432');
if(!['localhost','127.0.0.1'].includes(adminURL.hostname)||adminURL.searchParams.get('port')!=='55432'||adminURL.searchParams.get('host')!=='/tmp')throw new Error('Guardian harness requires the explicitly local /tmp:55432 PostgreSQL fixture');
const database='ritc_guardian_'+randomUUID().replaceAll('-','');
const admin=new pg.Client({connectionString:adminURL.toString()});await admin.connect();
try{
  await admin.query('CREATE DATABASE '+database);
  const dbURL=new URL(adminURL);dbURL.pathname='/'+database;const setup=new pg.Client({connectionString:dbURL.toString()});await setup.connect();
  try{
    await setup.query('CREATE SCHEMA auth; CREATE TABLE auth.users(id uuid PRIMARY KEY,email text,email_confirmed_at timestamptz); CREATE TABLE auth.sessions(id uuid PRIMARY KEY,user_id uuid NOT NULL,not_after timestamptz)');
    const files=(await readdir(new URL('migrations/',root))).filter(n=>/^\d+.*\.sql$/.test(n)&&Number(n.slice(0,3))<=21).sort();
    const frozen=await Promise.all(files.map(async n=>[n,await readFile(new URL('migrations/'+n,root),'utf8')]));
    await setup.query('CREATE TABLE public.ritc_schema_migration(version text PRIMARY KEY,checksum text NOT NULL,applied_at timestamptz NOT NULL DEFAULT now()); REVOKE ALL ON public.ritc_schema_migration FROM PUBLIC;ALTER TABLE public.ritc_schema_migration ENABLE ROW LEVEL SECURITY');
    for(const [name,sql]of frozen){await setup.query('BEGIN');try{await setup.query(sql);await setup.query('INSERT INTO public.ritc_schema_migration(version,checksum) VALUES($1,$2)',[name,createHash('sha256').update(sql).digest('hex')]);await setup.query('COMMIT');}catch(error){await setup.query('ROLLBACK');throw new Error(name+': '+error.message,{cause:error});}}
    await setup.query("DO $$ BEGIN IF NOT EXISTS(SELECT 1 FROM pg_roles WHERE rolname='ritc_guardian_test_verifier') THEN CREATE ROLE ritc_guardian_test_verifier LOGIN NOSUPERUSER NOBYPASSRLS;END IF;END $$; GRANT ritc_guardian_verifier TO ritc_guardian_test_verifier");
    await setup.query("DO $$ BEGIN IF NOT EXISTS(SELECT 1 FROM pg_roles WHERE rolname='ritc_test_worker') THEN CREATE ROLE ritc_test_worker LOGIN NOSUPERUSER NOBYPASSRLS;END IF;END $$;GRANT ritc_worker TO ritc_test_worker");
  }finally{await setup.end();}
  const appURL=new URL(dbURL);appURL.username='ritc_test_runtime';appURL.password='';const verifierURL=new URL(dbURL);verifierURL.username='ritc_guardian_test_verifier';verifierURL.password='';
  const workerURL=new URL(dbURL);workerURL.username='ritc_test_worker';workerURL.password='';workerURL.port='55432';
  const child=spawn(process.execPath,['--test','--test-concurrency=1',...(process.argv.length>2?process.argv.slice(2):['tests/guardian.integration.mjs','tests/guardian-provider.test.mjs'])],{cwd:root,stdio:'inherit',env:{...process.env,TEST_ADMIN_DATABASE_URL:dbURL.toString(),TEST_DATABASE_URL:appURL.toString(),TEST_GUARDIAN_VERIFIER_DATABASE_URL:verifierURL.toString(),TEST_WORKER_DATABASE_URL:workerURL.toString()}});
  const result=await new Promise(resolve=>child.on('exit',(code,signal)=>resolve(code??(signal?1:0))));process.exitCode=result;
}finally{
  await admin.query('SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname=$1 AND pid<>pg_backend_pid()',[database]);
  await admin.query('DROP DATABASE '+database);await admin.end();
}
