// Dedicated local-only runner. Requires a previously reviewed existing observer.
// It never creates/changes a cluster role, password, membership or role setting.
import {randomUUID,createHash} from 'node:crypto';
import {readFile,readdir} from 'node:fs/promises';
import {spawn} from 'node:child_process';
import pg from 'pg';

const base=new URL(process.env.TEST_ADMIN_DATABASE_URL??'postgresql://palatis@localhost/postgres?host=/tmp&port=55432');
if(!['localhost','127.0.0.1'].includes(base.hostname)||base.searchParams.get('host')!=='/tmp'||base.searchParams.get('port')!=='55432')throw Error('Only explicitly local /tmp:55432 PostgreSQL is permitted');
const observer=process.env.TEST_JOURNAL_OBSERVER_ROLE;
if(!observer||!/^[_a-z][_a-z0-9]*$/.test(observer))throw Error('TEST_JOURNAL_OBSERVER_ROLE must name the reviewed existing observer');
const admin=new pg.Client({connectionString:base.toString()});await admin.connect();
const databases=[],roleSnapshot=async()=>({roles:(await admin.query('SELECT oid,rolname,rolsuper,rolinherit,rolcreaterole,rolcreatedb,rolcanlogin,rolreplication,rolbypassrls FROM pg_roles ORDER BY oid')).rows,memberships:(await admin.query('SELECT roleid,member,grantor,admin_option,inherit_option,set_option FROM pg_auth_members ORDER BY roleid,member,grantor')).rows});
const before=await roleSnapshot();
try{
 const existing=(await admin.query('SELECT oid::text,rolcanlogin,rolinherit,rolsuper,rolcreaterole,rolcreatedb,rolreplication,rolbypassrls FROM pg_roles WHERE rolname=$1',[observer])).rows[0];
 if(observer!=='ritc_guardian_test_verifier'||!existing||!existing.rolcanlogin||existing.rolsuper||existing.rolcreaterole||existing.rolcreatedb||existing.rolreplication||existing.rolbypassrls)throw Error('Reviewed existing observer login required; no role changes performed');
 const reachable=(await admin.query("SELECT rolname,rolsuper,rolcreaterole,rolcreatedb,rolreplication,rolbypassrls FROM pg_roles WHERE pg_has_role($1::oid,oid,'MEMBER') ORDER BY rolname",[existing.oid])).rows;
 if(reachable.some(x=>x.rolsuper||x.rolcreaterole||x.rolcreatedb||x.rolreplication||x.rolbypassrls)||reachable.some(x=>!['ritc_guardian_test_verifier','ritc_guardian_verifier'].includes(x.rolname)))throw Error('Unexpected inherited observer capabilities; no membership changes performed');
 for(const required of ['ritc_app','ritc_worker','ritc_guardian_verifier','ritc_test_runtime','ritc_test_worker'])if(!(await admin.query('SELECT 1 FROM pg_roles WHERE rolname=$1',[required])).rowCount)throw Error('Existing fixture roles required; no role creation permitted');
 const migrations=(await readdir(new URL('../migrations/',import.meta.url))).filter(x=>/^\d+.*\.sql$/.test(x)).sort();
 if(migrations.length!==24||!migrations.at(-1).startsWith('024_'))throw Error('Exact migrations 001–024 required');
 const frozen=await Promise.all(migrations.map(async name=>({name,sql:await readFile(new URL('../migrations/'+name,import.meta.url),'utf8')})));
 for(const kind of ['source','wrong']){
  const name='ritc_journal_pg_'+kind+'_'+randomUUID().replaceAll('-','');
  await admin.query('CREATE DATABASE '+name+' TEMPLATE template0');databases.push(name);
  const {oid}= (await admin.query('SELECT oid::text FROM pg_database WHERE datname=$1',[name])).rows[0];
  console.log(`Created disposable PostgreSQL fixture ${name} (OID ${oid}).`);
  await admin.query('REVOKE ALL ON DATABASE '+name+' FROM PUBLIC');
  await admin.query('GRANT CONNECT ON DATABASE '+name+' TO '+observer+',ritc_test_runtime,ritc_test_worker');
  const url=new URL(base);url.pathname='/'+name;
  const client=new pg.Client({connectionString:url.toString()});await client.connect();
  try{
   await client.query('CREATE SCHEMA auth;CREATE TABLE auth.users(id uuid PRIMARY KEY,email text,email_confirmed_at timestamptz);CREATE TABLE auth.sessions(id uuid PRIMARY KEY,user_id uuid NOT NULL,not_after timestamptz)');
   await client.query('CREATE TABLE public.ritc_schema_migration(version text PRIMARY KEY,checksum text NOT NULL,applied_at timestamptz NOT NULL DEFAULT now());REVOKE ALL ON public.ritc_schema_migration FROM PUBLIC');
   for(const {name,sql}of frozen){await client.query('BEGIN');try{await client.query(sql);await client.query('INSERT INTO public.ritc_schema_migration(version,checksum)VALUES($1,$2)',[name,createHash('sha256').update(sql).digest('hex')]);await client.query('COMMIT');}catch(error){await client.query('ROLLBACK');throw Error(name+': '+error.message,{cause:error});}}
   await client.query('REVOKE CREATE ON SCHEMA public FROM PUBLIC');
   await client.query('REVOKE ALL ON ALL TABLES IN SCHEMA ritc FROM ritc_guardian_verifier');
   await client.query('REVOKE ALL ON ALL SEQUENCES IN SCHEMA ritc FROM ritc_guardian_verifier');
   await client.query('REVOKE ALL ON ALL FUNCTIONS IN SCHEMA ritc FROM PUBLIC,ritc_guardian_verifier');
   await client.query('GRANT USAGE ON SCHEMA ritc TO '+observer);
   for(const signature of ['binding(text,uuid,text,text,oid)','event(text,uuid,text,text,oid,uuid)','acceptance(text,uuid,text,text,oid,uuid)','unacknowledged(text,uuid,text,text,oid,uuid,integer)','acknowledge(text,uuid,text,text,oid,uuid,text,bigint,text)'])await client.query('GRANT EXECUTE ON FUNCTION ritc.privacy_journal_source_'+signature+' TO '+observer);
  }finally{await client.end();}
 }
 const sourceURL=new URL(base);sourceURL.pathname='/'+databases[0];
 const wrongURL=new URL(base);wrongURL.pathname='/'+databases[1];
 const child=spawn(process.execPath,['--test','--test-concurrency=1','tests/privacy-journal-pg-source.postgres.mjs'],{cwd:new URL('../',import.meta.url),stdio:'inherit',env:{...process.env,TEST_ADMIN_DATABASE_URL:sourceURL.toString(),TEST_JOURNAL_WRONG_DATABASE_URL:wrongURL.toString(),TEST_JOURNAL_OBSERVER_ROLE:observer}});
 const watchdog=setTimeout(()=>{console.error('Disposable fixture exceeded bounded 120-second run; terminating test child for cleanup');child.kill('SIGTERM');},120000);
 try{process.exitCode=await new Promise((resolve,reject)=>{child.once('error',reject);child.once('exit',(code,signal)=>resolve(code??(signal?1:0)));});}finally{clearTimeout(watchdog);}
}finally{
 for(const name of databases){await admin.query('SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname=$1 AND pid<>pg_backend_pid()',[name]);await admin.query('DROP DATABASE '+name);console.log(`Removed disposable PostgreSQL fixture ${name}.`);}
 const after=await roleSnapshot();
 if(JSON.stringify(before)!==JSON.stringify(after)){process.exitCode=1;console.error('Cluster role or membership snapshot changed during the runner');}
 else console.log('Verified unchanged cluster roles and memberships; both disposable databases removed.');
 await admin.end();
}
