// Read-only fixture verifier. Run from the retained frozen snapshot; never production.
import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {writeFile,readFile} from 'node:fs/promises';
import {verify019Runtime} from './verify019-runtime.mjs';
import pg from '../service/node_modules/pg/lib/index.js';
import {assertWorkerRole} from '../service/dist/maintenance.js';

const database=process.argv[2],output=process.argv[3];
assert.ok(['ritc_b11_ops019_20261103','ritc_b11_ops019_restore_20261103'].includes(database));
assert.ok(output);
const pool=user=>new pg.Pool({host:'/tmp',port:55432,database,user,max:1,application_name:'b11_operations_restore_verifier'});
const admin=pool('palatis'),app=pool('ritc_b11_ops019_app_20261103'),worker=pool('ritc_b11_ops019_worker_20261103');
const hash=value=>createHash('sha256').update(value).digest('hex');
const quote=value=>'"'+value.replaceAll('"','""')+'"';
const summary={database,verifiedAt:new Date().toISOString(),tableData:[],schema:{},semantic:{},permissions:{}};
try{
  // Read-only transaction keeps the complete snapshot internally consistent.
  await admin.query('BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY');
  const tables=(await admin.query("SELECT schemaname,tablename FROM pg_tables WHERE schemaname IN ('ritc','auth','public') ORDER BY schemaname,tablename")).rows;
  for(const {schemaname,tablename} of tables){
    const rows=(await admin.query(`SELECT to_jsonb(t)::text AS row FROM ${quote(schemaname)}.${quote(tablename)} t ORDER BY to_jsonb(t)::text COLLATE "C"`)).rows;
    summary.tableData.push({schema:schemaname,table:tablename,rows:rows.length,sha256:hash(rows.map(r=>r.row+'\n').join(''))});
  }
  const definitions={
    // PostgreSQL may restore an explicit owner-only ACL as NULL (the same default).
    // Compare effective ACL entries, preserving raw initial diagnostics separately.
    relations:(await admin.query(`SELECT n.nspname,c.relname,c.relkind,c.relrowsecurity,c.relforcerowsecurity,
      ARRAY(SELECT x::text FROM unnest(COALESCE(c.relacl,acldefault(CASE WHEN c.relkind='S' THEN 'S'::"char" ELSE 'r'::"char" END,c.relowner))) x ORDER BY x::text) AS effective_acl,
      pg_get_userbyid(c.relowner) AS owner FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname IN ('ritc','auth','public') AND c.relkind IN ('r','p','S','v','m') ORDER BY n.nspname,c.relname`)).rows,
    columns:(await admin.query("SELECT table_schema,table_name,column_name,ordinal_position,data_type,udt_name,is_nullable,column_default FROM information_schema.columns WHERE table_schema IN ('ritc','auth','public') ORDER BY table_schema,table_name,ordinal_position")).rows,
    constraints:(await admin.query("SELECT n.nspname,c.relname,k.conname,pg_get_constraintdef(k.oid) AS definition FROM pg_constraint k JOIN pg_class c ON c.oid=k.conrelid JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname IN ('ritc','auth','public') ORDER BY n.nspname,c.relname,k.conname")).rows,
    indexes:(await admin.query("SELECT schemaname,tablename,indexname,indexdef FROM pg_indexes WHERE schemaname IN ('ritc','auth','public') ORDER BY schemaname,tablename,indexname")).rows,
    functions:(await admin.query("SELECT n.nspname,p.proname,pg_get_function_identity_arguments(p.oid) AS args,pg_get_functiondef(p.oid) AS definition,p.proacl::text,pg_get_userbyid(p.proowner) AS owner FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname IN ('ritc','auth','public') ORDER BY n.nspname,p.proname,pg_get_function_identity_arguments(p.oid)")).rows,
    views:(await admin.query("SELECT n.nspname,c.relname,c.reloptions,pg_get_viewdef(c.oid,true) AS definition FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname IN ('ritc','auth','public') AND c.relkind='v' ORDER BY n.nspname,c.relname")).rows,
    triggers:(await admin.query("SELECT n.nspname,c.relname,t.tgname,t.tgenabled,pg_get_triggerdef(t.oid,true) AS definition FROM pg_trigger t JOIN pg_class c ON c.oid=t.tgrelid JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname IN ('ritc','auth','public') AND NOT t.tgisinternal ORDER BY n.nspname,c.relname,t.tgname")).rows,
    columnACL:(await admin.query("SELECT n.nspname,c.relname,a.attname,ARRAY(SELECT x::text FROM unnest(COALESCE(a.attacl,'{}'::aclitem[])) x ORDER BY x::text) AS acl FROM pg_attribute a JOIN pg_class c ON c.oid=a.attrelid JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname IN ('ritc','auth','public') AND a.attnum>0 AND NOT a.attisdropped AND c.relkind IN ('r','p','v') ORDER BY n.nspname,c.relname,a.attnum")).rows,
    databaseACL:(await admin.query("SELECT pg_get_userbyid(datdba) AS owner,ARRAY(SELECT x::text FROM unnest(COALESCE(datacl,acldefault('d'::\"char\",datdba))) x ORDER BY x::text) AS effective_acl FROM pg_database WHERE datname=current_database()")).rows,
    policies:(await admin.query("SELECT schemaname,tablename,policyname,permissive,roles,cmd,qual,with_check FROM pg_policies WHERE schemaname IN ('ritc','auth','public') ORDER BY schemaname,tablename,policyname")).rows
  };
  summary.schemaDefinitions=definitions;
  for(const [kind,rows] of Object.entries(definitions))summary.schema[kind]={count:rows.length,sha256:hash(JSON.stringify(rows))};
  const one=async sql=>(await admin.query(sql)).rows[0];
  summary.semantic.privacy=await one("SELECT (SELECT count(*)::int FROM ritc.privacy_job WHERE state='complete' AND issuer IS NULL AND subject IS NULL AND app_erased_at IS NOT NULL AND provider_erased_at IS NOT NULL) AS complete_jobs,(SELECT count(*)::int FROM ritc.identity_erasure) AS identity_markers,(SELECT count(*)::int FROM ritc.privacy_target WHERE erased_at IS NOT NULL) AS erased_targets,(SELECT count(*)::int FROM ritc.member WHERE erased_at IS NOT NULL AND alias='Removed member' AND state='revoked') AS erased_profiles,(SELECT count(*)::int FROM ritc.retired_purchase) AS retired_purchase_markers");
  assert.ok(summary.semantic.privacy.complete_jobs>0);
  assert.ok(summary.semantic.privacy.identity_markers>0);
  assert.ok(summary.semantic.privacy.erased_targets>0);
  assert.ok(summary.semantic.privacy.erased_profiles>0);
  assert.ok(summary.semantic.privacy.retired_purchase_markers>0);
  summary.semantic.retainedEvidence=await one("SELECT (SELECT count(*)::int FROM ritc.request WHERE original_item='Other retained private request') AS other_author_requests,(SELECT count(*)::int FROM ritc.financial_entry WHERE amount_minor=1234 AND source_text='Removed financial evidence') AS redacted_accounting_entries,(SELECT count(*)::int FROM ritc.financial_head WHERE revision=2) AS accounting_heads_at_revision_two");
  assert.equal(summary.semantic.retainedEvidence.other_author_requests,1);
  assert.equal(summary.semantic.retainedEvidence.redacted_accounting_entries,1);
  assert.ok(summary.semantic.retainedEvidence.accounting_heads_at_revision_two>0);
  summary.semantic.migrations=(await admin.query('SELECT version,checksum FROM public.ritc_schema_migration ORDER BY version')).rows;
  assert.equal(summary.semantic.migrations.length,19);
  summary.semantic.authRowsAfterOperations=await one('SELECT count(*)::int AS browser_auth_rows FROM ritc.browser_auth');
  assert.equal(summary.semantic.authRowsAfterOperations.browser_auth_rows,0);
  await admin.query('COMMIT');
  await assertWorkerRole(worker);
  await assert.rejects(()=>assertWorkerRole(app),/separate/);
  for(const [name,db,sql] of [
    ['app_raw_privacy_denied',app,'SELECT * FROM ritc.privacy_job'],
    ['app_worker_operation_denied',app,'SELECT ritc.maintenance_prepare_auth(1)'],
    ['worker_raw_privacy_denied',worker,'SELECT * FROM ritc.privacy_job'],
    ['worker_raw_browser_auth_denied',worker,'SELECT * FROM ritc.browser_auth'],
    ['worker_raw_provider_session_denied',worker,'SELECT * FROM auth.sessions']
  ]){
    await assert.rejects(()=>db.query(sql),e=>e.code==='42501');summary.permissions[name]=true;
  }
  summary.permissions.worker_role_verified=true;
  summary.permissions.application_role_rejected_as_worker=true;
  summary.permissions.worker_functions=(await worker.query("SELECT has_function_privilege(current_user,'ritc.privacy_claim(uuid)','EXECUTE') AS privacy_claim,has_function_privilege(current_user,'ritc.maintenance_prepare_auth(integer)','EXECUTE') AS auth_prepare")).rows[0];
  assert.deepEqual(summary.permissions.worker_functions,{privacy_claim:true,auth_prepare:true});
  const ids=JSON.parse(await readFile(new URL('controlled-fixture-identities.json',import.meta.url),'utf8'));
  summary.currentSchemaRuntime=await verify019Runtime({database,admin,app,worker,ids});
  await writeFile(output,JSON.stringify(summary,null,2)+'\n');
  console.log(JSON.stringify({database,tables:summary.tableData.length,rows:summary.tableData.reduce((n,t)=>n+t.rows,0),semantic:summary.semantic.privacy,permissions:summary.permissions}));
}finally{await Promise.all([admin.end(),app.end(),worker.end()]);}
