import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {createHash,randomBytes,randomUUID} from 'node:crypto';
import {once} from 'node:events';
import {chmod,copyFile,mkdir,mkdtemp,readFile,readdir,rm,symlink} from 'node:fs/promises';
import {join,resolve} from 'node:path';
import {fileURLToPath,pathToFileURL} from 'node:url';
import test from 'node:test';
import pg from 'pg';
import {exportJWK,generateKeyPair,SignJWT} from 'jose';
import {migrate} from '../scripts/migrate.mjs';
import {createRuntime} from '../dist/runtime.js';
import {createOperationsRuntime} from '../dist/operations-runtime.js';

const service=fileURLToPath(new URL('../',import.meta.url));
const checksum=bytes=>createHash('sha256').update(bytes).digest('hex');
const migrations=(await readdir(join(service,'migrations'))).filter(name=>/^\d+.*\.sql$/.test(name)).sort();
const baseline=migrations.filter(name=>/^00[1-8]_/.test(name));
assert.equal(baseline.length,8);
const registry=async client=>(await client.query('SELECT version,checksum FROM public.ritc_schema_migration ORDER BY version')).rows;

test('upgrade and backup restore preserve households and access from the deployed 008 baseline',async()=>{
 if(!process.env.TEST_POSTGRES_BIN)throw Error('Set TEST_POSTGRES_BIN to local PostgreSQL executables');
 const bin=resolve(process.env.TEST_POSTGRES_BIN),fixture=await mkdtemp('/tmp/ritc-stage-upgrade-');
 const data=join(fixture,'data'),port=55437;
 const ownerRole='ritc_upgrade_owner',appRole='ritc_upgrade_app',workerRole='ritc_upgrade_worker';
 const pgTool=(name,args)=>execFileSync(join(bin,name),args,{env:{PATH:'/usr/bin:/bin',LANG:'C'},stdio:'pipe',timeout:20000});
 const databaseURL=(user,database='postgres')=>`postgresql://${user}@localhost:${port}/${database}?host=${encodeURIComponent(fixture)}`;
 const originalFetch=globalThis.fetch;
 let running=false,owner,restored,runtime,operations;
 try{
  pgTool('initdb',['-D',data,'-A','trust','-U',ownerRole,'--no-locale','-E','UTF8']);
  pgTool('pg_ctl',['-D',data,'-l',join(fixture,'postgres.log'),'-o',`-h '' -k ${fixture} -p ${port} -c unix_socket_permissions=0700`,'-w','start']);
  running=true;
  owner=new pg.Client({connectionString:databaseURL(ownerRole)});
  await owner.connect();
  await owner.query('CREATE SCHEMA auth; CREATE TABLE auth.users(id uuid PRIMARY KEY,email text,email_confirmed_at timestamptz); CREATE TABLE auth.sessions(id uuid PRIMARY KEY,user_id uuid NOT NULL,not_after timestamptz)');
  // Run the same migration engine against an immutable copy of the old inputs.
  const old=join(fixture,'baseline');
  await mkdir(join(old,'scripts'),{recursive:true});
  await mkdir(join(old,'migrations'));
  await symlink(join(service,'node_modules'),join(old,'node_modules'),'dir');
  const runner=join(old,'scripts','migrate.mjs');
  await copyFile(join(service,'scripts','migrate.mjs'),runner);
  for(const name of baseline)await copyFile(join(service,'migrations',name),join(old,'migrations',name));
  const {migrate:applyBaseline}=await import(pathToFileURL(runner));
  await applyBaseline(databaseURL(ownerRole));
  const before=await registry(owner);
  assert.deepEqual(before.map(row=>row.version),baseline);
  await owner.query(`CREATE ROLE ${appRole} LOGIN; CREATE ROLE ${workerRole} LOGIN; GRANT ritc_app TO ${appRole}`);

  const issuer='https://staging-upgrade.fixture.invalid/auth/v1';
  async function seed(label){
   const subject=randomUUID(),sessionId=randomUUID(),householdId=randomUUID(),memberId=randomUUID(),deviceId=randomUUID();
   const deviceToken=randomBytes(32).toString('base64url'),shopId=randomUUID(),requestId=randomUUID(),browserHash=checksum(label);
   await owner.query('INSERT INTO auth.users(id,email_confirmed_at) VALUES($1,now())',[subject]);
   await owner.query('INSERT INTO auth.sessions(id,user_id) VALUES($1,$2)',[sessionId,subject]);
   await owner.query('INSERT INTO ritc.household(household_id,label) VALUES($1,$2)',[householdId,label]);
   await owner.query("INSERT INTO ritc.member(household_id,member_id,issuer,subject,alias,kind,state,organizer) VALUES($1,$2,$3,$4,'Fixture shopper','adult','active',true)",[householdId,memberId,issuer,subject]);
   await owner.query('INSERT INTO ritc.device(household_id,device_id,member_id,token_hash,session_id) VALUES($1,$2,$3,$4,$5)',[householdId,deviceId,memberId,checksum(deviceToken),sessionId]);
   await owner.query("INSERT INTO ritc.shop(household_id,shop_id,shopper_id,quote) VALUES($1,$2,$3,'{}')",[householdId,shopId,memberId]);
   await owner.query('INSERT INTO ritc.shop_authority(household_id,shop_id,epoch,member_id) VALUES($1,$2,1,$3)',[householdId,shopId,memberId]);
   await owner.query("INSERT INTO ritc.request(household_id,request_id,author_id,client_request_id,shop_id,original_item,route,authored_at) VALUES($1,$2,$3,$4,$5,$6,'current',now())",[householdId,requestId,memberId,randomUUID(),shopId,label]);
   await owner.query("INSERT INTO ritc.browser_auth(token_hash,csrf,expires_at) VALUES($1,'synthetic-csrf',now()+interval '1 day')",[browserHash]);
   return {subject,sessionId,householdId,deviceToken,requestId,label};
  }
  const first=await seed('Fictional cereal'),other=await seed('Fictional wraps');
  const inspect=async db=>(await db.query(`SELECT
   (SELECT jsonb_agg(jsonb_build_array(household_id,label) ORDER BY household_id) FROM ritc.household) AS households,
   (SELECT jsonb_agg(jsonb_build_array(household_id,request_id,author_id,original_item,revision,status) ORDER BY request_id) FROM ritc.request) AS requests,
   (SELECT jsonb_agg(jsonb_build_array(household_id,device_id,member_id,token_hash,session_id) ORDER BY device_id) FROM ritc.device) AS devices,
   (SELECT jsonb_agg(jsonb_build_array(token_hash,phase,expires_at) ORDER BY token_hash) FROM ritc.browser_auth) AS browser
  `)).rows[0];
  const legacy=await inspect(owner),dump=join(fixture,'before-upgrade.dump');
  pgTool('pg_dump',['-h',fixture,'-p',String(port),'-U',ownerRole,'-d','postgres','-Fc','-f',dump]);
  await chmod(dump,0o600);

  await migrate(databaseURL(ownerRole));
  const after=await registry(owner);
  const expected=await Promise.all(migrations.map(async version=>({version,checksum:checksum(await readFile(join(service,'migrations',version)))})));
  assert.deepEqual(after,expected);
  assert.deepEqual(after.slice(0,before.length),before);
  assert.deepEqual(await inspect(owner),legacy);
  await migrate(databaseURL(ownerRole));
  assert.deepEqual(await registry(owner),after);
  assert.deepEqual(await inspect(owner),legacy);
  await owner.query(`GRANT ritc_worker TO ${workerRole}`);

  const audience='authenticated',jwksUrl=issuer+'/.well-known/jwks.json';
  const {privateKey,publicKey}=await generateKeyPair('ES256'),key={...await exportJWK(publicKey),kid:'upgrade-fixture'};
  globalThis.fetch=(input,init)=>String(input)===jwksUrl?Promise.resolve(Response.json({keys:[key]})):originalFetch(input,init);
  const environment={DATABASE_URL:databaseURL(appRole),WORKER_DATABASE_URL:databaseURL(workerRole),
   JWT_ISSUER:issuer,JWT_JWKS_URL:jwksUrl,JWT_AUDIENCE:audience};
  runtime=await createRuntime(environment);
  runtime.server.listen(0,'127.0.0.1');
  await once(runtime.server,'listening');
  const base='http://127.0.0.1:'+runtime.server.address().port;
  const token=await new SignJWT({session_id:first.sessionId}).setProtectedHeader({alg:'ES256',kid:key.kid})
   .setIssuer(issuer).setAudience(audience).setSubject(first.subject).setIssuedAt().setExpirationTime('5m').sign(privateKey);
  const headers={Authorization:'Bearer '+token,'X-Device-Token':first.deviceToken};
  const workspaces=await originalFetch(base+'/v1/me/workspaces',{headers});
  assert.equal(workspaces.status,200);
  assert.deepEqual(await workspaces.json(),{workspaces:[{householdId:first.householdId,label:first.label,role:'organizer'}]});
  const list=await originalFetch(base+'/v1/households/'+first.householdId+'/requests/mine',{headers});
  assert.equal(list.status,200);
  assert.deepEqual((await list.json()).requests.map(row=>row.requestId),[first.requestId]);
  const forbidden=await originalFetch(base+'/v1/households/'+other.householdId+'/requests/mine',{headers});
  assert.equal(forbidden.status,404);
  const preview=await originalFetch(base+'/v1/privacy/deletion-preview',{headers});
  assert.equal(preview.status,200);
  assert.equal((await preview.json()).deletionAvailable,false);
  operations=createOperationsRuntime(environment);
  const status=await operations.run('status');
  assert.equal(status.privacyJournal.state,'disabled');
  assert.equal(status.privacyJobProcessingEnabled,false);
  await assert.rejects(operations.pool.query('SELECT * FROM ritc.request'),{code:'42501'});

  await owner.query('CREATE DATABASE ritc_upgrade_rollback TEMPLATE template0');
  await owner.query('REVOKE CONNECT ON DATABASE ritc_upgrade_rollback FROM PUBLIC');
  pgTool('pg_restore',['--exit-on-error','-h',fixture,'-p',String(port),'-U',ownerRole,'-d','ritc_upgrade_rollback',dump]);
  restored=new pg.Client({connectionString:databaseURL(ownerRole,'ritc_upgrade_rollback')});
  await restored.connect();
  assert.deepEqual(await registry(restored),before);
  assert.deepEqual(await inspect(restored),legacy);
  assert.equal((await restored.query("SELECT to_regclass('ritc.privacy_restore_window') AS relation")).rows[0].relation,null);
 }finally{
  globalThis.fetch=originalFetch;
  if(runtime){
   await new Promise(resolve=>runtime.server.close(resolve));
   await runtime.pool.end();
  }
  await operations?.close();
  await restored?.end();
  await owner?.end();
  if(running)pgTool('pg_ctl',['-D',data,'-m','fast','-w','stop']);
  await rm(fixture,{recursive:true,force:true});
 }
});
