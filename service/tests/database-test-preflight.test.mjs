import test from 'node:test';
import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
import {integrationTestEnvironment,preflightIntegrationDatabase} from '../scripts/database-test-preflight.mjs';
const url=user=>`postgresql://${user}:fixture-only@127.0.0.1:5432/ritc_test`;
const environment=()=>({TEST_ADMIN_DATABASE_URL:url('owner'),TEST_DATABASE_URL:url('runtime'),TEST_WORKER_DATABASE_URL:url('ritc_test_worker')});
const roles=()=>[
 ['runtime',['ritc_app']],['ritc_test_worker',['ritc_worker']],['ritc_guardian_test_verifier',['ritc_guardian_verifier']],
 ['ritc_guardian_combined_worker',['ritc_worker','ritc_guardian_verifier']],
].map(([rolname,memberships])=>({rolname,memberships,rolcanlogin:true,rolsuper:false,rolbypassrls:false}));
function catalog({rows=roles(),present=false,origin=false}={}){
 const queries=[];
 return {queries,async query(sql){
  queries.push(sql);assert.match(sql,/^SELECT\b/);assert.doesNotMatch(sql,/\b(INSERT|UPDATE|DELETE|CREATE|ALTER|DROP|TRUNCATE)\b/);
  if(sql.includes('FROM pg_roles r'))return {rows};
  if(sql.includes('to_regclass'))return {rows:[{present}]};
  if(sql.includes('FROM ritc.privacy_journal_origin'))return {rowCount:origin?1:0,rows:origin?[{}]:[]};
  throw Error('Unexpected preflight query');
 }};
}

test('CI environment keeps verifier and billing defaults and optional execution flags',()=>{
 const env={...environment(),RITC_TEST_WEB_WIRE:'1',RITC_TEST_NATIVE_WIRE:'1'};
 const configuration=integrationTestEnvironment(env);
 assert.equal(new URL(configuration.environment.TEST_GUARDIAN_VERIFIER_DATABASE_URL).username,'ritc_guardian_test_verifier');
 assert.equal(configuration.environment.BILLING_TEST_DATABASE_URL,env.TEST_DATABASE_URL);
 assert.equal(configuration.environment.BILLING_TEST_ADMIN_DATABASE_URL,env.TEST_ADMIN_DATABASE_URL);
 assert.equal(configuration.environment.RITC_TEST_WEB_WIRE,'1');assert.equal(configuration.environment.RITC_TEST_NATIVE_WIRE,'1');
});

test('explicit verifier and separate local billing database remain supported',()=>{
 const env={...environment(),TEST_GUARDIAN_VERIFIER_DATABASE_URL:url('custom_verifier'),
  BILLING_TEST_DATABASE_URL:url('billing_runtime').replace('/ritc_test','/ritc_billing'),
  BILLING_TEST_ADMIN_DATABASE_URL:url('owner').replace('/ritc_test','/ritc_billing')};
 assert.deepEqual(integrationTestEnvironment(env).environment,env);
});

test('local socket URLs retain effective port and fixture identity',()=>{
 const env=Object.fromEntries(Object.entries(environment()).map(([key,value])=>[key,value+'?host=/tmp&port=55432']));
 assert.doesNotThrow(()=>integrationTestEnvironment(env));
});

for(const key of ['TEST_ADMIN_DATABASE_URL','TEST_DATABASE_URL','TEST_WORKER_DATABASE_URL'])test('missing '+key+' fails before connecting',()=>{
 const env=environment();delete env[key];assert.throws(()=>integrationTestEnvironment(env),new RegExp(key+' is required'));
});

test('remote host, query-host override, wrong database, malformed URL and implicit login are rejected without secrets',()=>{
 for(const value of ['postgresql://owner:PRIVATE_PASSWORD@remote.invalid/ritc_test',url('owner')+'?host=remote.invalid',
  url('owner').replace('/ritc_test','/production'),'PRIVATE_PASSWORD',
  'postgresql://127.0.0.1/ritc_test']){
  assert.throws(()=>integrationTestEnvironment({...environment(),TEST_ADMIN_DATABASE_URL:value}),error=>{
   assert.doesNotMatch(error.message,/PRIVATE_PASSWORD|fixture-only|remote\.invalid/);return true;
  });
 }
});

test('cross-database worker, verifier and mismatched billing pairs fail closed',()=>{
 for(const key of ['TEST_WORKER_DATABASE_URL','TEST_GUARDIAN_VERIFIER_DATABASE_URL','BILLING_TEST_DATABASE_URL'])
  assert.throws(()=>integrationTestEnvironment({...environment(),[key]:url('ritc_test_worker').replace(/\/ritc_test$/,'/ritc_other')}),/same fixture database/);
});

test('fresh unmigrated and migrated empty-origin fixtures pass with read-only queries',async()=>{
 for(const present of [false,true]){
  const db=catalog({present});await preflightIntegrationDatabase(db,integrationTestEnvironment(environment()));
  assert.equal(db.queries.length,present?3:2);
 }
});

test('already provisioned journal fails before any fixture mutation even when fenced',async()=>{
 const db=catalog({present:true,origin:true});
 await assert.rejects(preflightIntegrationDatabase(db,integrationTestEnvironment(environment())),/fresh disposable database/);
 assert.equal(db.queries.length,3);
});

test('each missing required fixture role fails before journal access',async()=>{
 for(const missing of roles()){
  const db=catalog({rows:roles().filter(row=>row.rolname!==missing.rolname)});
  await assert.rejects(preflightIntegrationDatabase(db,integrationTestEnvironment(environment())),/restricted app, worker, verifier/);
  assert.equal(db.queries.length,1);
 }
});

test('privilege escalation, combined worker and invalid negative-role composition are rejected',async()=>{
 for(const change of [rows=>rows[0].rolsuper=true,rows=>rows[1].rolbypassrls=true,rows=>rows[2].rolcanlogin=false,
  rows=>rows[1].memberships.push('ritc_app'),rows=>rows[2].memberships.push('ritc_worker'),
  rows=>rows[3].memberships=['ritc_worker']]){
  const rows=roles();change(rows);
  await assert.rejects(preflightIntegrationDatabase(catalog({rows}),integrationTestEnvironment(environment())),/restricted app, worker, verifier/);
 }
});

test('explicit custom worker and verifier logins are checked in addition to named test fixtures',async()=>{
 const env={...environment(),TEST_WORKER_DATABASE_URL:url('custom_worker'),TEST_GUARDIAN_VERIFIER_DATABASE_URL:url('custom_verifier')};
 const config=integrationTestEnvironment(env),rows=roles();
 await assert.rejects(preflightIntegrationDatabase(catalog({rows}),config),/restricted app, worker, verifier/);
 rows.push({...rows[1],rolname:'custom_worker'},{...rows[2],rolname:'custom_verifier'});
 await preflightIntegrationDatabase(catalog({rows}),config);
});

test('actual harness entrypoint refuses missing worker before opening the deliberately unavailable database',()=>{
 const env={...process.env,...environment(),TEST_ADMIN_DATABASE_URL:url('owner').replace(':5432/',':1/')};delete env.TEST_WORKER_DATABASE_URL;
 const result=spawnSync(process.execPath,['scripts/test-database.mjs'],{cwd:new URL('../',import.meta.url),env,encoding:'utf8',timeout:5000});
 assert.equal(result.status,1);assert.match(result.stderr,/TEST_WORKER_DATABASE_URL is required/);
 assert.doesNotMatch(result.stderr,/ECONNREFUSED|fixture-only/);
});

const {preflightIntegrationConnections}=await import('../scripts/database-test-preflight.mjs');
function clients(configuration,mutate=()=>{}){
 const closed=[];
 return {closed,makeClient(target){
  const label=['admin','runtime','worker','verifier','billing','billingAdmin'].find(key=>configuration[key]===target);
  return {async connect(){},async query(sql){
   assert.match(sql,/^SELECT\b/);
   const identity={login:target.user,database:target.database,database_oid:'1',server_started:'2026-11-09T12:00:00Z',port:5432,
    rolcanlogin:true,rolsuper:false,rolbypassrls:false,memberships:label==='runtime'||label==='billing'?['ritc_app']:label==='worker'?['ritc_worker']:label==='verifier'?['ritc_guardian_verifier']:[]};
   mutate(label,identity);return {rows:[identity]};
  },async end(){closed.push(label);}};
 }};
}

test('connection preflight reads current identities for admin, runtime, worker and verifier and closes clients',async()=>{
 const config=integrationTestEnvironment(environment()),fixture=clients(config);
 await preflightIntegrationConnections(config,fixture.makeClient);
 assert.deepEqual(fixture.closed,['admin','runtime','worker','verifier']);
});

test('wrong connected user, database, server and combined runtime role are rejected',async()=>{
 const config=integrationTestEnvironment(environment());
 for(const mutate of [row=>row.login='wrong',row=>row.database='ritc_other',row=>row.server_started='different-server',
  row=>row.database_oid='2',row=>row.memberships.push('ritc_worker')]){
  const fixture=clients(config,(label,row)=>{if(label==='runtime')mutate(row);});
  await assert.rejects(preflightIntegrationConnections(config,fixture.makeClient),/fixture/);
  assert.deepEqual(fixture.closed,['admin','runtime']);
 }
});

test('failed actual login is closed and the diagnostic never exposes connection errors or credentials',async()=>{
 const config=integrationTestEnvironment(environment());let closed=false;
 await assert.rejects(preflightIntegrationConnections(config,()=>({
  async connect(){throw Error('postgresql://owner:PRIVATE_PASSWORD@unapproved.invalid/secret');},
  async end(){closed=true;},
 })),error=>{assert.match(error.message,/Cannot verify admin fixture connection/);assert.doesNotMatch(error.message,/PRIVATE_PASSWORD|unapproved|secret/);return true;});
 assert.equal(closed,true);
});

test('separate billing fixture connects and validates both its admin and restricted runtime',async()=>{
 const config=integrationTestEnvironment({...environment(),BILLING_TEST_DATABASE_URL:url('billing_runtime').replace(/\/ritc_test$/,'/ritc_billing'),
  BILLING_TEST_ADMIN_DATABASE_URL:url('owner').replace(/\/ritc_test$/,'/ritc_billing')});
 const fixture=clients(config);await preflightIntegrationConnections(config,fixture.makeClient);
 assert.deepEqual(fixture.closed,['admin','runtime','worker','verifier','billingAdmin','billing']);
});
