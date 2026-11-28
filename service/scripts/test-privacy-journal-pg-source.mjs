// Dedicated local-only runner. Requires a previously reviewed existing observer.
// It never creates/changes a cluster role, password, membership or role setting.
import {randomUUID,createHash} from 'node:crypto';
import assert from 'node:assert/strict';
import {readFile,readdir} from 'node:fs/promises';
import {spawn} from 'node:child_process';
import pg from 'pg';
import {sourceFixtureConnection} from '../tests/source-postgres-fixture.mjs';

const base=new URL(process.env.TEST_ADMIN_DATABASE_URL??'postgresql://palatis@localhost/postgres?host=/tmp&port=55432');
sourceFixtureConnection(base);
if(!['/postgres','/ritc_test'].includes(base.pathname))throw Error('Expected dedicated local fixture admin database');
const observer=process.env.TEST_JOURNAL_OBSERVER_ROLE;
if(!observer||!/^[_a-z][_a-z0-9]*$/.test(observer))throw Error('TEST_JOURNAL_OBSERVER_ROLE must name the reviewed existing observer');
const admin=new pg.Client(sourceFixtureConnection(base));await admin.connect();
const gatewayRole=process.env.TEST_JOURNAL_GATEWAY_ROLE;
if(gatewayRole!==undefined && gatewayRole!=='ritc_journal_gateway_test')throw Error('Expected isolated test-only gateway login');
const databases=[],roleSnapshot=async()=>({roles:(await admin.query('SELECT oid,rolname,rolsuper,rolinherit,rolcreaterole,rolcreatedb,rolcanlogin,rolreplication,rolbypassrls FROM pg_roles ORDER BY oid')).rows,memberships:(await admin.query('SELECT roleid,member,grantor,admin_option,inherit_option,set_option FROM pg_auth_members ORDER BY roleid,member,grantor')).rows});
const before=await roleSnapshot();
try{
 const existing=(await admin.query('SELECT oid::text,rolcanlogin,rolinherit,rolsuper,rolcreaterole,rolcreatedb,rolreplication,rolbypassrls FROM pg_roles WHERE rolname=$1',[observer])).rows[0];
 if(observer!=='ritc_guardian_test_verifier'||!existing||!existing.rolcanlogin||existing.rolsuper||existing.rolcreaterole||existing.rolcreatedb||existing.rolreplication||existing.rolbypassrls)throw Error('Reviewed existing observer login required; no role changes performed');
 const reachable=(await admin.query("SELECT rolname,rolsuper,rolcreaterole,rolcreatedb,rolreplication,rolbypassrls FROM pg_roles WHERE pg_has_role($1::oid,oid,'MEMBER') ORDER BY rolname",[existing.oid])).rows;
 if(reachable.some(x=>x.rolsuper||x.rolcreaterole||x.rolcreatedb||x.rolreplication||x.rolbypassrls)||reachable.some(x=>!['ritc_guardian_test_verifier','ritc_guardian_verifier'].includes(x.rolname)))throw Error('Unexpected inherited observer capabilities; no membership changes performed');
 for(const required of ['ritc_app','ritc_worker','ritc_guardian_verifier','ritc_test_runtime','ritc_test_worker'])if(!(await admin.query('SELECT 1 FROM pg_roles WHERE rolname=$1',[required])).rowCount)throw Error('Existing fixture roles required; no role creation permitted');
 const migrations=(await readdir(new URL('../migrations/',import.meta.url))).filter(x=>/^\d+.*\.sql$/.test(x)).sort();
 if(migrations.length<24||migrations.some((name,index)=>!name.startsWith(String(index+1).padStart(3,'0')+'_')))throw Error('Continuous migrations through the journal observer are required');
 const frozen=await Promise.all(migrations.map(async name=>({name,sql:await readFile(new URL('../migrations/'+name,import.meta.url),'utf8')})));
 if(gatewayRole){
  const eligible=await admin.query('SELECT 1 FROM pg_roles WHERE rolname=$1 AND rolcanlogin AND NOT (rolsuper OR rolbypassrls OR rolcreaterole OR rolcreatedb OR rolreplication) AND NOT EXISTS(SELECT FROM pg_auth_members WHERE member=pg_roles.oid)',[gatewayRole]);
  if(eligible.rowCount!==1)throw Error('Reviewed dedicated gateway fixture login without memberships required');
 }
 for(const kind of gatewayRole?['source','wrong','gateway']:['source','wrong']){
  const name='ritc_journal_pg_'+kind+'_'+randomUUID().replaceAll('-','');
  await admin.query('CREATE DATABASE '+name+' TEMPLATE template0');databases.push(name);
  const {oid}= (await admin.query('SELECT oid::text FROM pg_database WHERE datname=$1',[name])).rows[0];
  console.log(`Created disposable PostgreSQL fixture ${name} (OID ${oid}).`);
  if(kind!=='gateway')await admin.query('REVOKE ALL ON DATABASE '+name+' FROM PUBLIC');
  await admin.query('GRANT CONNECT ON DATABASE '+name+' TO '+observer+',ritc_test_runtime,ritc_test_worker');
  const url=new URL(base);url.pathname='/'+name;
  const client=new pg.Client(sourceFixtureConnection(url));await client.connect();
  try{
   await client.query('CREATE SCHEMA auth;CREATE TABLE auth.users(id uuid PRIMARY KEY,email text,email_confirmed_at timestamptz);CREATE TABLE auth.sessions(id uuid PRIMARY KEY,user_id uuid NOT NULL,not_after timestamptz)');
   await client.query('CREATE TABLE public.ritc_schema_migration(version text PRIMARY KEY,checksum text NOT NULL,applied_at timestamptz NOT NULL DEFAULT now());REVOKE ALL ON public.ritc_schema_migration FROM PUBLIC');
   const defaultACLs=async()=>(await client.query('SELECT defaclrole::text,defaclnamespace::text,defaclobjtype,defaclacl::text FROM pg_default_acl ORDER BY 1,2,3')).rows;
   let providerDefaults;
   for(const {name,sql}of frozen){
    if(kind==='gateway'&&name==='087_private_journal_source_gateway.sql'){
     // Model provider ACLs in force *when* the new namespace is created.
     await client.query(`ALTER DEFAULT PRIVILEGES GRANT EXECUTE ON FUNCTIONS TO ritc_test_runtime;
      ALTER DEFAULT PRIVILEGES GRANT SELECT ON TABLES TO ritc_test_runtime;
      ALTER DEFAULT PRIVILEGES GRANT USAGE ON SCHEMAS TO ritc_test_runtime;
      CREATE SCHEMA managed_fixture;
      CREATE TABLE managed_fixture.monitor_stats(n bigint);
      GRANT SELECT ON managed_fixture.monitor_stats TO PUBLIC;
      CREATE FUNCTION managed_fixture.format_monitor() RETURNS integer LANGUAGE sql AS 'SELECT 1'`);
     providerDefaults=await defaultACLs();
    }
    await client.query('BEGIN');
    try{
     await client.query(sql);
     await client.query('INSERT INTO public.ritc_schema_migration(version,checksum)VALUES($1,$2)',[name,createHash('sha256').update(sql).digest('hex')]);
     await client.query('COMMIT');
    }catch(error){await client.query('ROLLBACK');throw Error(name+': '+error.message,{cause:error});}
    if(kind==='gateway'&&name==='087_private_journal_source_gateway.sql'){
     assert.deepEqual(await defaultACLs(),providerDefaults);
     await client.query("CREATE TABLE managed_fixture.after_table(n bigint);CREATE FUNCTION managed_fixture.after_function() RETURNS integer LANGUAGE sql AS 'SELECT 1'");
     const grants=await client.query(`SELECT has_table_privilege('ritc_test_runtime','managed_fixture.monitor_stats','SELECT') AND
      has_function_privilege('ritc_test_runtime','managed_fixture.format_monitor()','EXECUTE') AND
      has_table_privilege('ritc_test_runtime','managed_fixture.after_table','SELECT') AND
      has_function_privilege('ritc_test_runtime','managed_fixture.after_function()','EXECUTE') AND
      NOT has_schema_privilege('ritc_test_runtime','ritc_journal_source','USAGE') AND
      NOT EXISTS(SELECT FROM pg_proc WHERE pronamespace='ritc_journal_source'::regnamespace AND
       has_function_privilege('ritc_test_runtime',oid,'EXECUTE')) AS correct`);
     assert.equal(grants.rows[0].correct,true,'existing grants and future provider defaults must survive; new gateway stays isolated');
    }
   }
   if(kind==='gateway'){
    // This database keeps real PUBLIC TEMP, the application's raw PUBLIC helper
    // ACLs and a provider-shaped raw relation grant in an inaccessible schema.
    await client.query('GRANT USAGE ON SCHEMA ritc_journal_source TO '+gatewayRole);
    for(const signature of ['binding(text,uuid,text,text,oid)','event(text,uuid,text,text,oid,uuid)','acceptance(text,uuid,text,text,oid,uuid)','unacknowledged(text,uuid,text,text,oid,uuid,integer)','acknowledge(text,uuid,text,text,oid,uuid,text,bigint,text)'])await client.query('GRANT EXECUTE ON FUNCTION ritc_journal_source.privacy_journal_source_'+signature+' TO '+gatewayRole);
    continue;
   }
   await client.query('REVOKE ALL ON ALL TABLES IN SCHEMA ritc FROM ritc_guardian_verifier');
   await client.query('REVOKE ALL ON ALL SEQUENCES IN SCHEMA ritc FROM ritc_guardian_verifier');
   await client.query('REVOKE ALL ON ALL FUNCTIONS IN SCHEMA ritc FROM PUBLIC,ritc_guardian_verifier');
   await client.query('GRANT USAGE ON SCHEMA ritc TO '+observer);
   for(const signature of ['binding(text,uuid,text,text,oid)','event(text,uuid,text,text,oid,uuid)','acceptance(text,uuid,text,text,oid,uuid)','unacknowledged(text,uuid,text,text,oid,uuid,integer)','acknowledge(text,uuid,text,text,oid,uuid,text,bigint,text)'])await client.query('GRANT EXECUTE ON FUNCTION ritc.privacy_journal_source_'+signature+' TO '+observer);
  }finally{await client.end();}
 }
 const sourceURL=new URL(base);sourceURL.pathname='/'+databases[0];
 const wrongURL=new URL(base);wrongURL.pathname='/'+databases[1];
 const child=spawn(process.execPath,['--test','--test-concurrency=1','tests/privacy-journal-pg-source.postgres.mjs',...(gatewayRole?['tests/privacy-journal-source-gateway.postgres.mjs']:[])],{cwd:new URL('../',import.meta.url),stdio:'inherit',env:{...process.env,TEST_ADMIN_DATABASE_URL:sourceURL.toString(),TEST_JOURNAL_WRONG_DATABASE_URL:wrongURL.toString(),TEST_JOURNAL_OBSERVER_ROLE:observer,...(gatewayRole?{TEST_JOURNAL_GATEWAY_DATABASE:databases[2]}:{})}});
 const watchdog=setTimeout(()=>{console.error('Disposable fixture exceeded bounded 120-second run; terminating test child for cleanup');child.kill('SIGTERM');},120000);
 try{process.exitCode=await new Promise((resolve,reject)=>{child.once('error',reject);child.once('exit',(code,signal)=>resolve(code??(signal?1:0)));});}finally{clearTimeout(watchdog);}
}finally{
 for(const name of databases){await admin.query('SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname=$1 AND pid<>pg_backend_pid()',[name]);await admin.query('DROP DATABASE '+name);console.log(`Removed disposable PostgreSQL fixture ${name}.`);}
 const after=await roleSnapshot();
 if(JSON.stringify(before)!==JSON.stringify(after)){process.exitCode=1;console.error('Cluster role or membership snapshot changed during the runner');}
 else console.log('Verified unchanged cluster roles and memberships; all disposable databases removed.');
 await admin.end();
}
