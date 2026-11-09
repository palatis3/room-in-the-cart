import pg from 'pg';

const groups=['ritc_app','ritc_worker','ritc_guardian_verifier'];
const fail=message=>{throw new Error('Database test preflight: '+message);};
function target(value,label){
 if(!value)fail(label+' is required.');
 let url,parameters;
 try{
  url=new URL(value);
  if(!['postgres:','postgresql:'].includes(url.protocol))throw Error();
  parameters=new pg.Client({connectionString:value}).connectionParameters;
 }catch{fail(label+' must be a PostgreSQL URL.');}
 // Check the driver's effective host as well: query parameters can override the URL host.
 const local=host=>['localhost','127.0.0.1','::1','[::1]'].includes(host)||host.startsWith('/');
 if(!local(parameters.host)||!['localhost','127.0.0.1','[::1]'].includes(url.hostname))fail(label+' must target a loopback or local socket fixture.');
 if(!parameters.database?.startsWith('ritc_'))fail(label+' requires a disposable ritc_ database.');
 if(!url.username&&!url.searchParams.get('user'))fail(label+' requires an explicit fixture login.');
 const host=parameters.host.startsWith('/')?parameters.host:'loopback';
 return {value,user:parameters.user,database:parameters.database,scope:JSON.stringify([host,parameters.port,parameters.database])};
}
export function integrationTestEnvironment(env){
 const admin=target(env.TEST_ADMIN_DATABASE_URL,'TEST_ADMIN_DATABASE_URL');
 const runtime=target(env.TEST_DATABASE_URL,'TEST_DATABASE_URL');
 const worker=target(env.TEST_WORKER_DATABASE_URL,'TEST_WORKER_DATABASE_URL');
 const fallback=new URL(runtime.value);fallback.username='ritc_guardian_test_verifier';
 const verifier=target(env.TEST_GUARDIAN_VERIFIER_DATABASE_URL??fallback.toString(),'TEST_GUARDIAN_VERIFIER_DATABASE_URL');
 for(const [label,value] of [['runtime',runtime],['worker',worker],['verifier',verifier]])
  if(value.scope!==admin.scope)fail(label+' must use the same fixture database as TEST_ADMIN_DATABASE_URL.');
 const billing=target(env.BILLING_TEST_DATABASE_URL??runtime.value,'BILLING_TEST_DATABASE_URL');
 const billingAdmin=target(env.BILLING_TEST_ADMIN_DATABASE_URL??admin.value,'BILLING_TEST_ADMIN_DATABASE_URL');
 if(billing.scope!==billingAdmin.scope)fail('Billing runtime and admin must use the same fixture database.');
 return {admin,runtime,worker,verifier,billing,billingAdmin,environment:{
  ...env,TEST_GUARDIAN_VERIFIER_DATABASE_URL:verifier.value,
  BILLING_TEST_DATABASE_URL:billing.value,BILLING_TEST_ADMIN_DATABASE_URL:billingAdmin.value,
 }};
}

/** Read-only, before auth DDL, migrations, journal provisioning or child test processes. */
export async function preflightIntegrationDatabase(admin,configuration){
 const requirements=[
  [configuration.runtime.user,['ritc_app']],
  ['ritc_test_worker',['ritc_worker']],[configuration.worker.user,['ritc_worker']],
  ['ritc_guardian_test_verifier',['ritc_guardian_verifier']],[configuration.verifier.user,['ritc_guardian_verifier']],
  ['ritc_guardian_combined_worker',['ritc_worker','ritc_guardian_verifier']],
 ];
 const names=[...new Set(requirements.map(([name])=>name))];
 const rows=(await admin.query(`SELECT r.rolname,r.rolcanlogin,r.rolsuper,r.rolbypassrls,
   ARRAY(SELECT g.rolname FROM pg_roles g WHERE g.rolname=ANY($2::text[])
     AND pg_has_role(r.oid,g.oid,'MEMBER') ORDER BY g.rolname) AS memberships
   FROM pg_roles r WHERE r.rolname=ANY($1::text[])`,[names,groups])).rows;
 for(const [name,expected] of requirements){
  const role=rows.find(row=>row.rolname===name);
  if(!role?.rolcanlogin||role.rolsuper||role.rolbypassrls||
    groups.some(group=>role.memberships.includes(group)!==expected.includes(group)))
   fail('Configure the restricted app, worker, verifier and combined negative-test roles using the disposable CI fixture setup; no roles are changed by this harness.');
 }
 const exists=(await admin.query("SELECT to_regclass('ritc.privacy_journal_origin') IS NOT NULL AS present")).rows[0].present;
 if(exists&&(await admin.query('SELECT 1 FROM ritc.privacy_journal_origin LIMIT 1')).rowCount)
  fail('Fixture journal origin already exists; use a fresh disposable database. Never clear or replace its origin.');
}

const identitySQL=`SELECT current_user AS login,current_database() AS database,
 (SELECT oid::text FROM pg_database WHERE datname=current_database()) AS database_oid,
 pg_postmaster_start_time()::text AS server_started,inet_server_port() AS port,
 r.rolcanlogin,r.rolsuper,r.rolbypassrls,
 ARRAY(SELECT g.rolname FROM pg_roles g WHERE g.rolname=ANY($1::text[])
   AND pg_has_role(r.oid,g.oid,'MEMBER') ORDER BY g.rolname) AS memberships
 FROM pg_roles r WHERE r.rolname=current_user`;
const sameServer=(a,b)=>a.database_oid===b.database_oid&&a.server_started===b.server_started&&a.port===b.port;
/** Verify credentials and the connected database, not merely catalog role names. */
export async function preflightIntegrationConnections(configuration,makeClient=target=>new pg.Client({
 connectionString:target.value,connectionTimeoutMillis:5000,query_timeout:5000,
})){
 async function probe(target,label,expected){
  const client=makeClient(target);let identity;
  try{
   await client.connect();identity=(await client.query(identitySQL,[groups])).rows[0];
  }catch{fail('Cannot verify '+label+' fixture connection; check its local endpoint and credentials.');}
  finally{await client.end().catch(()=>{});}
  if(!identity||identity.login!==target.user||identity.database!==target.database)
   fail(label+' connected to an unexpected fixture identity or database.');
  if(expected&&(identity.rolsuper||identity.rolbypassrls||!identity.rolcanlogin||
    groups.some(group=>identity.memberships.includes(group)!==expected.includes(group))))
   fail(label+' requires its distinct restricted fixture role.');
  return identity;
 }
 const admin=await probe(configuration.admin,'admin');
 for(const [label,expected] of [['runtime',['ritc_app']],['worker',['ritc_worker']],['verifier',['ritc_guardian_verifier']]]){
  const identity=await probe(configuration[label],label,expected);
  if(!sameServer(admin,identity))fail(label+' must connect to the same fixture server and database as admin.');
 }
 if(configuration.billing.value!==configuration.runtime.value||configuration.billingAdmin.value!==configuration.admin.value){
  const owner=await probe(configuration.billingAdmin,'billing admin');
  const runtime=await probe(configuration.billing,'billing runtime',['ritc_app']);
  if(!sameServer(owner,runtime))fail('Billing runtime must connect to the same fixture server and database as billing admin.');
 }
}
