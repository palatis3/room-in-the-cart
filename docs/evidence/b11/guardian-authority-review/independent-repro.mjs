// Independent local-only review. Creates and removes one disposable database.
// No service build, staging, live provider request, or source mutation occurs.
import {createRequire} from 'node:module';
import assert from 'node:assert/strict';
import {randomUUID,createHash} from 'node:crypto';
import {readFile,readdir} from 'node:fs/promises';
const service=new URL('../../../../service/',import.meta.url);
const root=new URL('../../../../',import.meta.url);
const require=createRequire(new URL('package.json',service));
const pg=require('pg');
const base='postgresql://palatis@localhost/postgres?host=/tmp&port=55432';
const control=new pg.Client({connectionString:base});
const database='ritc_independent_review_'+randomUUID().replaceAll('-','');
const issuer='https://independent-review.fixture.invalid';
const clients=[];
const temporaryRoles=[];
const report={kind:'independent-local-guardian-authority-review',startedAt:new Date().toISOString(),nodeVersion:process.version,
  scope:'Frozen migrations 001–021; no 022 journal changes or provider/staging actions',sourceHashes:{},outcomes:{}};
const hash=value=>createHash('sha256').update(value).digest('hex');
let admin,gate,writer,privacy,locker;
await control.connect();
try{
  const files=(await readdir(new URL('migrations/',service))).filter(n=>/^\d+.*\.sql$/.test(n)&&Number(n.slice(0,3))<=21).sort();
  const frozen=await Promise.all(files.map(async name=>[name,await readFile(new URL('migrations/'+name,service),'utf8')]));
  for(const [name,sql]of frozen)report.sourceHashes['service/migrations/'+name]=hash(sql);
  for(const name of ['src/guardian.ts','src/guardian-provider.ts','src/guardian-runtime.ts','src/guardian-policy.ts','src/http.ts','src/repository.ts','src/auth.ts','src/browser-auth.ts','src/lifecycle.ts','src/privacy.ts','src/operations-runtime.ts','tests/guardian.integration.mjs','tests/guardian-provider.test.mjs','dist/guardian-runtime.js','dist/guardian.js','dist/browser-auth.js']){
    report.sourceHashes['service/'+name]=hash(await readFile(new URL(name,service)));
  }
  report.sourceHashes['shared/contracts/guardian-enrollment-v1.d.ts']=hash(await readFile(new URL('shared/contracts/guardian-enrollment-v1.d.ts',root)));
  report.sourceHashes['independent-repro.mjs']=hash(await readFile(import.meta.url.startsWith('file:')?new URL(import.meta.url):import.meta.url));
  await control.query('CREATE DATABASE '+database);
  const adminURL=new URL(base);adminURL.pathname='/'+database;
  async function connect(user){const url=new URL(adminURL);if(user){url.username=user;url.password='';}const client=new pg.Client({connectionString:url.toString()});await client.connect();clients.push(client);return client;}
  admin=await connect();
  await admin.query('CREATE SCHEMA auth;CREATE TABLE auth.users(id uuid PRIMARY KEY,email text,email_confirmed_at timestamptz);CREATE TABLE auth.sessions(id uuid PRIMARY KEY,user_id uuid NOT NULL,not_after timestamptz)');
  for(const [name,sql]of frozen){try{await admin.query(sql);}catch(error){throw new Error(name+': '+error.message);}}
  await admin.query("DO $$ BEGIN IF NOT EXISTS(SELECT 1 FROM pg_roles WHERE rolname='ritc_guardian_test_verifier') THEN CREATE ROLE ritc_guardian_test_verifier LOGIN NOSUPERUSER NOBYPASSRLS;END IF;END $$;GRANT ritc_guardian_verifier TO ritc_guardian_test_verifier");
  gate=await connect('ritc_guardian_test_verifier');writer=await connect('ritc_test_runtime');privacy=await connect('ritc_test_runtime');locker=await connect();
  async function seed({existing=false,relationship=false,organizer=true,state='active'}={}){
    const x=Object.fromEntries(['h','g','gd','gs','gp','child','cs','cp','en','a','inv','claim'].map(k=>[k,randomUUID()]));
    // All interpolated values below are generated UUIDs or fixed fixture values.
    const s=Object.fromEntries(Object.entries(x).map(([k,v])=>[k,"'"+v+"'"]));
    await admin.query(`
      INSERT INTO auth.users VALUES(${s.gs},'guardian@fixture.invalid',clock_timestamp()),(${s.cs},'child@fixture.invalid',clock_timestamp());
      INSERT INTO auth.sessions(id,user_id)VALUES(${s.gp},${s.gs}),(${s.cp},${s.cs});
      INSERT INTO ritc.household(household_id,label)VALUES(${s.h},'Disposable authority review');
      INSERT INTO ritc.member(household_id,member_id,issuer,subject,alias,kind,state,organizer,can_contribute)VALUES(${s.h},${s.g},'${issuer}',${s.gs},'Guardian','adult','active',${organizer},true);
      INSERT INTO ritc.device(household_id,device_id,member_id,token_hash,session_id)VALUES(${s.h},${s.gd},${s.g},repeat('a',64),${s.gp});
      ${existing?`INSERT INTO ritc.member(household_id,member_id,issuer,subject,alias,kind,state,organizer,can_contribute)VALUES(${s.h},${s.child},'${issuer}',${s.cs},'Existing child','child','${state}',false,true);`:''}
      ${relationship?`INSERT INTO ritc.guardian_relationship(household_id,child_id,guardian_id,proof_ref)VALUES(${s.h},${s.child},${s.g},'trusted-fixture-relationship');`:''}
      INSERT INTO ritc.guardian_enrollment(household_id,enrollment_id,guardian_id,guardian_device_id,guardian_issuer,guardian_subject,guardian_session,child_id,notice_version,notice_digest,method_version,language,child_location,declaration,expires_at,state,verified_at,consented_at,child_alias,child_email_digest,claim_id)VALUES(${s.h},${s.en},${s.g},${s.gd},'${issuer}',${s.gs},${s.gp},${s.child},'approved-v1',repeat('b',64),'approved-method','en','US','parent_or_legal_guardian',clock_timestamp()+interval '1 hour','child_approved',clock_timestamp(),clock_timestamp(),'Child private alias',repeat('f',64),${s.claim});
      INSERT INTO ritc.guardian_attempt(household_id,enrollment_id,attempt_id,organization_id,product_id,environment,nonce_hash,email_digest,expires_at)VALUES(${s.h},${s.en},${s.a},'${randomUUID()}','${randomUUID()}','test',repeat('c',64),repeat('d',64),clock_timestamp()+interval '1 hour');
      INSERT INTO ritc.guardian_provider_event(household_id,attempt_id,transaction_id,event_digest)VALUES(${s.h},${s.a},'${randomUUID()}',repeat('e',64));
      INSERT INTO ritc.guardian_child_invitation(household_id,invite_id,enrollment_id,secret_hash,expires_at)VALUES(${s.h},${s.inv},${s.en},repeat('a',64),clock_timestamp()+interval '30 minutes');
      INSERT INTO ritc.guardian_child_claim(household_id,claim_id,invite_id,issuer,subject,session_id,pairing_hash,expires_at,approved_at)VALUES(${s.h},${s.claim},${s.inv},'${issuer}',${s.cs},${s.cp},repeat('b',64),clock_timestamp()+interval '30 minutes',clock_timestamp());
      INSERT INTO ritc.guardian_child_signin VALUES(${s.h},${s.inv},'${issuer}',${s.cs},${s.cp},clock_timestamp()+interval '30 minutes');
    `);
    return x;
  }
  async function beginGate(x){await gate.query('BEGIN');await gate.query("SELECT set_config('app.household_id',$1,true)",[x.h]);}
  const finish=x=>gate.query("SELECT ritc.guardian_finish_verified($1,$2,$3,$4,$5,repeat('b',64),repeat('d',64),$6,repeat('c',64),$7,repeat('a',64),'guardian@fixture.invalid','child@fixture.invalid')AS receipt",[x.h,x.claim,issuer,x.cs,x.cp,randomUUID(),randomUUID()]);
  async function waiting(pid){for(let i=0;i<100;i++){if((await admin.query("SELECT wait_event_type='Lock' waiting FROM pg_stat_activity WHERE pid=$1",[pid])).rows[0]?.waiting)return;await new Promise(r=>setTimeout(r,10));}throw new Error('Deterministic PostgreSQL barrier not reached');}
  const initial=await seed();await writer.query("SELECT set_config('app.household_id',$1,false)",[initial.h]);
  const calls=[
    ['oldFinalizer',"SELECT ritc.guardian_finish($1,$2,$3,$4,$5,repeat('b',64),repeat('d',64),$6,repeat('c',64))",[initial.h,initial.claim,issuer,initial.cs,initial.cp,randomUUID()]],
    ['oldAdmission',"SELECT ritc.guardian_admit_signin($1,$2,$3,$4,$5,repeat('f',64))",[initial.h,initial.inv,issuer,initial.cs,initial.cp]],
    ['verifiedFinalizer',"SELECT ritc.guardian_finish_verified($1,$2,$3,$4,$5,repeat('b',64),repeat('d',64),$6,repeat('c',64),$7,repeat('a',64),'guardian@fixture.invalid','child@fixture.invalid')",[initial.h,initial.claim,issuer,initial.cs,initial.cp,randomUUID(),randomUUID()]],
    ['verifiedAdmission',"SELECT ritc.guardian_admit_child_verified($1,$2,$3,$4,$5,'child@fixture.invalid',repeat('f',64))",[initial.h,initial.inv,issuer,initial.cs,initial.cp]],
    ['nativeVerifiedAdmission',"SELECT ritc.guardian_admit_native_verified($1,$2,$3,$4,$5,'child@fixture.invalid',repeat('f',64),repeat('a',64),$6)",[initial.h,randomUUID(),issuer,initial.cs,initial.cp,randomUUID()]]
  ];
  report.outcomes.appSQL={expected:'Every call fails with SQLSTATE 42501',actual:{}};
  for(const [name,query,parameters]of calls){try{await writer.query(query,parameters);report.outcomes.appSQL.actual[name]='ALLOWED';}catch(error){report.outcomes.appSQL.actual[name]=error.code;}}
  report.outcomes.nativeChallengeColumns=(await admin.query("SELECT has_column_privilege('ritc_test_runtime','ritc.guardian_native_challenge','subject','UPDATE') AS subject_update,has_column_privilege('ritc_test_runtime','ritc.guardian_native_challenge','session_id','UPDATE') AS session_update")).rows[0];
  report.outcomes.erasureInterleavings=[];
  for(const order of ['finalization_first','deletion_first']){
    const x=await seed();await locker.query('BEGIN');await locker.query('SELECT 1 FROM ritc.household WHERE household_id=$1 FOR UPDATE',[x.h]);await beginGate(x);
    const job=randomUUID();const deletion=()=>privacy.query("SELECT ritc.privacy_request($1,$2,$3,$4,repeat('e',64),repeat('a',64),'[]'::jsonb,1,2)AS job",[issuer,x.cs,x.cp,job]).then(r=>({accepted:r.rows[0].job===job}),e=>({accepted:false,error:e.message}));let f,d;
    if(order==='finalization_first'){const pendingFinish=finish(x);await waiting(gate.processID);const pendingDelete=deletion();await waiting(privacy.processID);await locker.query('COMMIT');f=(await pendingFinish).rows[0].receipt;await gate.query('COMMIT');d=await pendingDelete;}
    else{const pendingDelete=deletion();await waiting(privacy.processID);f=(await finish(x)).rows[0].receipt;await gate.query('COMMIT');await locker.query('COMMIT');d=await pendingDelete;}
    const members=(await admin.query('SELECT count(*)::int n FROM ritc.member WHERE household_id=$1 AND member_id=$2',[x.h,x.child])).rows[0].n;
    report.outcomes.erasureInterleavings.push({order,expected:order==='finalization_first'?'Finish commits; deletion rejects adult_scope_required':'Deletion accepts; finish rejects; no child member remains',actual:{finishCommitted:!!f,deletion:d,remainingChildMembers:members}});
  }
  report.outcomes.membership=[];
  for(const [name,options,expected]of [
    ['new_child_organizer_lost',{organizer:false},false],
    ['existing_child_wrong_guardian',{existing:true},false],
    ['existing_active_child_own_nonorganizer_guardian',{existing:true,relationship:true,organizer:false},true],
    ['revoked_child_nonorganizer_guardian',{existing:true,relationship:true,organizer:false,state:'revoked'},false]
  ]){const x=await seed(options);await beginGate(x);const receipt=(await finish(x)).rows[0].receipt;await gate.query('COMMIT');report.outcomes.membership.push({name,expected,actual:!!receipt});}
  const workerRole='ritc_review_worker_'+randomUUID().replaceAll('-','');temporaryRoles.push(workerRole);await admin.query('CREATE ROLE '+workerRole+' LOGIN NOSUPERUSER NOBYPASSRLS;GRANT ritc_guardian_verifier,ritc_worker TO '+workerRole);
  const badURL=new URL(adminURL);badURL.username=workerRole;badURL.password='';
  const {guardianRuntime}=await import(new URL('dist/guardian-runtime.js',service));
  const fixtureEnv={KWS_ORGANIZATION_ID:randomUUID(),KWS_SCOPE:'product',KWS_PRODUCT_ID:randomUUID(),KWS_ENVIRONMENT:'test',KWS_CLIENT_ID:'fixture-only',KWS_API_KEY:'fixture-only',KWS_SERVICE_ORIGIN:'https://api.kidswebservices.com',KWS_USER_AGENT:'IndependentLocalReview/1',KWS_WEBHOOK_SECRETS_JSON:JSON.stringify(['fixture-only-signing-secret']),GUARDIAN_EMAIL_DIGEST_KEY:Buffer.alloc(32,1).toString('base64url'),GUARDIAN_VERIFIER_DATABASE_URL:badURL.toString()};
  try{const value=await guardianRuntime({pool:writer},fixtureEnv,env=>({connectionString:env.DATABASE_URL,max:1}));await value.pool?.end();report.outcomes.verifierWorkerExclusion={expected:'Rejected',actual:'ALLOWED'};}catch(error){report.outcomes.verifierWorkerExclusion={expected:'Rejected',actual:'Rejected',message:error.message};}
  for(const code of Object.values(report.outcomes.appSQL.actual))assert.equal(code,'42501');
  assert.deepEqual(report.outcomes.nativeChallengeColumns,{subject_update:false,session_update:false});
  for(const result of report.outcomes.membership)assert.equal(result.actual,result.expected,result.name);
  assert.equal(report.outcomes.verifierWorkerExclusion.actual,'Rejected');
  const [finishFirst,deleteFirst]=report.outcomes.erasureInterleavings;
  assert.equal(finishFirst.actual.finishCommitted,true);assert.equal(finishFirst.actual.deletion.accepted,false);assert.equal(finishFirst.actual.deletion.error,'adult_scope_required');
  assert.equal(deleteFirst.actual.finishCommitted,false);assert.equal(deleteFirst.actual.deletion.accepted,true);assert.equal(deleteFirst.actual.remainingChildMembers,0);
  report.finishedAt=new Date().toISOString();report.assertionsPassed=true;
}finally{
  if(locker)await locker.query('ROLLBACK').catch(()=>{});await Promise.all(clients.map(c=>c.end()));
  await control.query('SELECT pg_terminate_backend(pid)FROM pg_stat_activity WHERE datname=$1 AND pid<>pg_backend_pid()',[database]);await control.query('DROP DATABASE '+database);
  for(const role of temporaryRoles)await control.query('DROP ROLE '+role);await control.end();
}
process.stdout.write(JSON.stringify(report,null,2)+'\n');
