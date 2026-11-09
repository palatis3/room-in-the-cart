import test,{before,after} from 'node:test';
import assert from 'node:assert/strict';
import {randomUUID,randomBytes} from 'node:crypto';
import pg from 'pg';
import {generateKeyPair,exportJWK,createLocalJWKSet,SignJWT} from 'jose';
import {HouseholdRepository} from '../dist/repository.js';
import {JWTIdentityVerifier,SupabaseSessionVerifier} from '../dist/auth.js';
import {PrivacyService,PrivacyMaintenance} from '../dist/privacy.js';
import {openPrivacyJournalFixture,preparePrivacyJournalFixture} from './privacy-journal-fixture.mjs';
import {createHTTPServer} from '../dist/http.js';
import {mkdtemp,chmod,readFile,writeFile} from 'node:fs/promises';
import {join} from 'node:path';
import {tmpdir} from 'node:os';
import {execFileSync} from 'node:child_process';
import {migrate} from '../scripts/migrate.mjs';
import {verifyPrivacyJournal,validatePrivacyRestoreEvents} from '../dist/privacy-journal.js';
const controlURL=new URL(process.env.TEST_ADMIN_DATABASE_URL);assert.ok(['localhost','127.0.0.1','[::1]'].includes(controlURL.hostname));assert.ok(controlURL.pathname.startsWith('/ritc_'));
const control=new pg.Pool({connectionString:controlURL.toString()}),suffix=randomUUID().replaceAll('-',''),sourceName='ritc_demand_source_'+suffix,destinationName='ritc_demand_restore_'+suffix;
await control.query('CREATE DATABASE '+sourceName);
const withDB=(url,name)=>{const u=new URL(url);u.pathname='/'+name;return u.toString();};
const admin=new pg.Pool({connectionString:withDB(controlURL,sourceName)}),runtime=new pg.Pool({connectionString:withDB(process.env.TEST_DATABASE_URL,sourceName)}),worker=new pg.Pool({connectionString:withDB(process.env.TEST_WORKER_DATABASE_URL,sourceName)});
await admin.query('CREATE SCHEMA auth; CREATE TABLE auth.sessions(id uuid PRIMARY KEY,user_id uuid NOT NULL,not_after timestamptz); CREATE TABLE auth.users(id uuid PRIMARY KEY,email text,email_confirmed_at timestamptz)');
await migrate(withDB(controlURL,sourceName));
const privateRoot=await mkdtemp(join(process.env.RITC_DEMAND_STATE??tmpdir(),'demand-restore-'));await chmod(privateRoot,0o700);
const configurationPath=await preparePrivacyJournalFixture(admin,join(privateRoot,'journal-evidence'),privateRoot);
const configuration=JSON.parse(await readFile(configurationPath,'utf8'));let fenced=false;

const issuer='https://shared-demand.fixture.invalid';const {publicKey,privateKey}=await generateKeyPair('ES256'),jwk=await exportJWK(publicKey);jwk.kid='fixture';
const verifier=new JWTIdentityVerifier({issuer,audience:'authenticated',jwksUrl:issuer+'/jwks'},createLocalJWKSet({keys:[jwk]})),repo=new HouseholdRepository(runtime,{allowChildNetwork:false,noticeVersion:'fixture',sessionStatus:new SupabaseSessionVerifier(issuer)});
const journal=await openPrivacyJournalFixture(admin,configurationPath),provider={assertAvailable:async()=>{},deleteAccount:async subject=>{await admin.query('DELETE FROM auth.sessions WHERE user_id=$1',[subject]);}};
const privacy=new PrivacyService(repo,{provider,journal:journal.port,policy:{receiptRetentionDays:1,erasureMarkerRetentionDays:2,verifiedBackupRetentionDays:1}}),maintenance=new PrivacyMaintenance(worker,{provider,journal:journal.port});
const server=createHTTPServer({repository:repo,verifier,privacy,maxRequestsPerMinute:20000});let origin;
before(async()=>{await new Promise(r=>server.listen(0,'127.0.0.1',r));origin='http://127.0.0.1:'+server.address().port;});
after(async()=>{await new Promise(r=>server.close(r));if(!fenced)await journal.fence();await journal.close();await Promise.all([admin.end(),runtime.end(),worker.end(),control.end()]);});
async function actor(subject=randomUUID()){const session=randomUUID();await admin.query('INSERT INTO auth.sessions(id,user_id) VALUES($1,$2)',[session,subject]);return{subject,session,token:await new SignJWT({session_id:session,amr:[{method:'otp',timestamp:Math.floor(Date.now()/1000)}]}).setProtectedHeader({alg:'ES256',kid:jwk.kid}).setIssuer(issuer).setSubject(subject).setAudience('authenticated').setIssuedAt().setExpirationTime('1h').sign(privateKey)};}
async function call(a,path,method='GET',body){const r=await fetch(origin+path,{method,headers:{Authorization:'Bearer '+a.token,...(a.device?{'X-Device-Token':a.device}:{}),...(body===undefined?{}:{'Content-Type':'application/json'})},...(body===undefined?{}:{body:JSON.stringify(body)})});return{status:r.status,data:await r.json()};}
function ok(r,status=200){assert.equal(r.status,status,JSON.stringify(r.data));return r.data;}
async function enroll(a,h){a.device=ok(await call(a,`/v1/households/${h}/devices`,'POST',{}),201).deviceToken;a.window=ok(await call(a,`/v1/households/${h}/replay-windows`,'POST',{})).id;}
const q=n=>({amount:{numerator:String(n),denominator:'1'},unit:'count',originalLiteral:n+' wraps',confirmedConversion:null});
const empty=()=>({lines:[],contributions:[],edges:[],removeSourceIds:[],removeEdgeIds:[]});
const line=()=>({lineId:randomUUID(),originalItem:'Wraps',packs:2,unitPriceMinor:100,feeEligible:true});
async function fixture(){const owner=await actor(),h=ok(await call(owner,'/v1/households','POST',{clientKey:randomUUID(),label:'Demand fixture',alias:'Shopper',adultAttestation:true}),201);owner.id=h.memberId;await enroll(owner,h.householdId);const shopId=randomUUID(),base=`/v1/households/${h.householdId}`,path=base+'/shops/'+shopId;
 const quote={currency:'USD',scope:'wholeCheckout',complete:true,capMinor:10000,capScope:'wholeCheckout',fee:{kind:'fixed',amountMinor:0},taxesMinor:0,depositsMinor:0,discountsMinor:0,observedAt:new Date(Date.now()-60000).toISOString(),expiresAt:new Date(Date.now()+3600000).toISOString()},basket=line();
 const f={owner,h:h.householdId,base,path,shopId,quote,basket};ok(await send(f,'shop.create',{quote,lines:[basket]},0,0));return f;}
async function send(f,kind,body,revision,epoch=1,a=f.owner,extra={}){return call(a,f.base+'/commands','POST',{v:1,replayWindow:a.window,clientKey:randomUUID(),shopId:f.shopId,kind,base:{shopRevision:revision,authorityEpoch:epoch},body,...extra});}
function source(f,quantity=q(12)){return{id:randomUUID(),lineId:f.basket.lineId,source:{kind:'manual'},productKey:'wraps',productName:'Wraps',originalText:'12 wraps',quantity,exclusions:[],contains:[],removedAt:null};}
function draft(f,c=source(f)){return{mode:'adopt',base:{shopRevision:1,authorityEpoch:1,graphRevision:0},change:{...empty(),lines:[{id:f.basket.lineId,name:'Wraps',unit:'count',originalOrder:0,trashedAt:null}],contributions:[c]},action:{kind:'shop.patch',body:{quote:f.quote,lines:[f.basket]}},packs:[{lineId:f.basket.lineId,usablePerPack:q(6),acceptUnresolved:false}]};}
async function preview(f,input,a=f.owner){return call(a,f.path+'/demand/previews','POST',input);}
async function apply(f,input,p,a=f.owner){const command={v:1,replayWindow:a.window,clientKey:randomUUID(),shopId:f.shopId,kind:input.action.kind,base:{shopRevision:input.base.shopRevision,authorityEpoch:input.base.authorityEpoch,...(input.action.kind==='request.apply'?{requestRevision:1}:{})},body:{...input.action.body,demandReview:{previewId:p.previewId,previewDigest:p.previewDigest}}};return{command,response:await call(a,f.base+'/commands','POST',command)};}
async function adopt(f){const input=draft(f),p=ok(await preview(f,input)),r=await apply(f,input,p);ok(r.response);return{input,p,...r};}
async function invited(f){const a=await actor(),i=ok(await call(f.owner,f.base+'/invites','POST',{kind:'adult_contributor'}));a.id=ok(await call(a,'/v1/invites/redeem','POST',{token:i.token,intent:'join',adultAttestation:true,alias:'Other adult'})).memberId;await enroll(a,f.h);return a;}
const count=async(f,t)=>(await admin.query(`SELECT count(*)::int n FROM ritc.${t} WHERE household_id=$1 AND shop_id=$2`,[f.h,f.shopId])).rows[0].n;

async function copiedRequestPreview(f,author,wording){
 const sent=ok(await send(f,'request.send',{clientRequestId:randomUUID(),originalItem:wording,ownQuantity:'2 wraps',authoredAt:new Date().toISOString()},1,2,author)),requestId=sent.request.requestId;
 const rp=ok(await call(f.owner,f.path+'/previews','POST',{requestId,base:{shopRevision:1,authorityEpoch:2,requestRevision:1},decision:{choice:'link',lineId:f.basket.lineId,promote:false}}));
 const c=source(f,q(2));c.source={kind:'request',requestId,appliedRequestRevision:1};c.originalText=wording;
 const input=draft(f);input.base.authorityEpoch=2;input.change.contributions.push(c);input.packs[0].usablePerPack=q(7);input.action={kind:'request.apply',body:{requestId,previewId:rp.previewId,acceptOverage:false,acceptUnknown:false}};
 const p=ok(await preview(f,input));assert.equal(await count(f,'shared_demand_source_member'),0);assert.equal(await count(f,'shared_demand_revision'),0);return{input,p};
}

test('quarantined PostgreSQL backup restore replays verified signed erasure into all shared graph copies',async()=>{
 const f=await fixture(),a=await adopt(f),oldOwner=f.owner,other=await invited(f);ok(await send(f,'shop.transferAuthority',{newShopperId:other.id},2));f.owner=other;
 const extra=source(f,q(3));extra.originalText='Unrelated retained source';const input={...draft(f),mode:'change',base:{shopRevision:2,authorityEpoch:2,graphRevision:1},change:{...empty(),contributions:[extra]}};input.action.body.lines[0].packs=3;
 ok((await apply(f,input,ok(await preview(f,input)))).response);
 const review={...input,mode:'review',base:{shopRevision:3,authorityEpoch:2,graphRevision:2},change:empty()};ok(await preview(f,review));
 const secondId=randomUUID(),previewOnly={...f,owner:oldOwner,shopId:secondId,path:f.base+'/shops/'+secondId,basket:line()};
 ok(await send(previewOnly,'shop.create',{quote:f.quote,lines:[previewOnly.basket]},0,0));ok(await send(previewOnly,'shop.transferAuthority',{newShopperId:other.id},1));previewOnly.owner=other;
 const previewSecret='Backup uncommitted source wording';await copiedRequestPreview(previewOnly,oldOwner,previewSecret);
 const dumpPath=join(privateRoot,'before-deletion.dump'),pgTool=name=>process.env.RITC_TEST_PG_BIN?join(process.env.RITC_TEST_PG_BIN,name):name;
 const connection=['--host',controlURL.hostname,'--port',controlURL.port||'5432','--username',decodeURIComponent(controlURL.username)],toolEnv={...process.env,PGPASSWORD:decodeURIComponent(controlURL.password)};
 execFileSync(pgTool('pg_dump'),[...connection,'--format=custom','--file',dumpPath,'--dbname',sourceName],{env:toolEnv,timeout:30000,maxBuffer:65536});
 const deletion={clientKey:randomUUID(),statusToken:randomBytes(32).toString('base64url'),confirm:true,households:[{householdId:f.h,organizer:'transfer',organizerMemberId:other.id,shops:[],eraseChildProfiles:[]}]};ok(await call(oldOwner,'/v1/privacy/deletions','POST',deletion),202);assert.equal((await maintenance.run({batchSize:1})).completed,1);
 assert.equal(await count(previewOnly,'shared_demand_preview'),0);
 const head=await journal.fence();fenced=true;
 const verified=verifyPrivacyJournal(await readFile(join(configuration.directory,'journal.ndjson')),{...configuration,publicKey:journal.publicKey,head});validatePrivacyRestoreEvents(verified.events);
 await control.query('CREATE DATABASE '+destinationName);const runtimeRole=new URL(process.env.TEST_DATABASE_URL).username,workerRole=new URL(process.env.TEST_WORKER_DATABASE_URL).username;
 assert.match(runtimeRole,/^[a-z_]+$/);assert.match(workerRole,/^[a-z_]+$/);
 await control.query('REVOKE CONNECT ON DATABASE '+destinationName+' FROM PUBLIC,'+runtimeRole+',ritc_app');await control.query('GRANT CONNECT ON DATABASE '+destinationName+' TO '+workerRole);
 assert.equal((await control.query("SELECT has_database_privilege($1,$2,'CONNECT') AS allowed",[runtimeRole,destinationName])).rows[0].allowed,false);
 execFileSync(pgTool('pg_restore'),[...connection,'--exit-on-error','--dbname',destinationName,dumpPath],{env:toolEnv,timeout:30000,maxBuffer:65536});
 const restored=new pg.Pool({connectionString:withDB(controlURL,destinationName)}),restoreWorker=new pg.Pool({connectionString:withDB(process.env.TEST_WORKER_DATABASE_URL,destinationName)});
 try{
  const before=(await restored.query('SELECT graph FROM ritc.shared_demand_revision WHERE household_id=$1 ORDER BY revision',[f.h])).rows;assert.ok(JSON.stringify(before).includes('12 wraps'),'actual backup contains erased source before journal replay');
  assert.ok(JSON.stringify((await restored.query('SELECT intent FROM ritc.shared_demand_preview WHERE household_id=$1 AND shop_id=$2',[f.h,secondId])).rows).includes(previewSecret),'actual backup contains other shopper uncommitted copy before replay');
  const oid=(await restored.query('SELECT oid FROM pg_database WHERE datname=current_database()')).rows[0].oid,runId=randomUUID();
  await restored.query('SELECT ritc.privacy_restore_register($1,$2,$3,$4::jsonb,$5::jsonb)',[runId,oid,verified.bundleDigest,JSON.stringify(verified.head),JSON.stringify(verified.events)]);
  const lease=randomUUID(),job=(await restoreWorker.query('SELECT ritc.privacy_restore_claim($1,$2) AS job',[runId,lease])).rows[0].job;assert.equal(job,deletion.clientKey);
  const result=(await restoreWorker.query('SELECT ritc.privacy_restore_erase_next($1,$2,$3) AS value',[runId,job,lease])).rows[0].value;assert.equal(result.applied,true);assert.equal(result.localAppErasureApplied,true);
  for(const table of ['shared_demand_revision','shared_demand_preview','basket_line','shop_snapshot','operation_response'])assert.ok(!JSON.stringify((await restored.query('SELECT to_jsonb(t) AS value FROM ritc.'+table+' t WHERE household_id=$1',[f.h])).rows).includes('12 wraps'),table);
  assert.equal((await restored.query('SELECT count(*)::int n FROM ritc.shared_demand_preview WHERE household_id=$1',[f.h])).rows[0].n,0);
  const current=(await restored.query('SELECT graph,receipt FROM ritc.shared_demand_revision WHERE household_id=$1 ORDER BY revision DESC LIMIT 1',[f.h])).rows[0];assert.deepEqual(current.graph.contributions.find(c=>c.id===extra.id),extra);assert.ok(!current.graph.contributions.some(c=>c.id===a.input.change.contributions[0].id));assert.ok(current.graph.usedIds.includes(a.input.change.contributions[0].id));assert.equal(current.receipt,null);
  assert.equal((await restored.query('SELECT demand_review_required FROM ritc.shop WHERE household_id=$1 AND shop_id=$2',[f.h,f.shopId])).rows[0].demand_review_required,true);
  assert.equal((await restored.query('SELECT phase FROM ritc.privacy_restore_run WHERE run_id=$1',[runId])).rows[0].phase,'local_app_erased');
  assert.equal((await control.query("SELECT has_database_privilege($1,$2,'CONNECT') AS allowed",[runtimeRole,destinationName])).rows[0].allowed,false,'provider reconciliation and runtime reopening are not claimed');
  await writeFile(join(privateRoot,'restore-receipt.json'),JSON.stringify({runId,bundleDigest:verified.bundleDigest,signatureVerified:true,applied:result.applied,runtimeStillQuarantined:true,sourceName,destinationName})+'\n',{mode:0o600});
 }finally{await Promise.all([restored.end(),restoreWorker.end()]);}
});
