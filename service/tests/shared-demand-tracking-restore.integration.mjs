import test,{before,after} from 'node:test';
import assert from 'node:assert/strict';
import {randomUUID,randomBytes} from 'node:crypto';
import pg from 'pg';
import {trackingPrivacyFixtures} from './shared-demand-tracking-privacy-fixture.mjs';
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
const control=new pg.Pool({connectionString:controlURL.toString()}),suffix=randomUUID().replaceAll('-',''),sourceName='ritc_tracking_source_'+suffix,destinationName='ritc_tracking_restore_'+suffix;
await control.query('CREATE DATABASE '+sourceName);
const withDB=(url,name)=>{const u=new URL(url);u.pathname='/'+name;return u.toString();};
const admin=new pg.Pool({connectionString:withDB(controlURL,sourceName)}),runtime=new pg.Pool({connectionString:withDB(process.env.TEST_DATABASE_URL,sourceName)}),worker=new pg.Pool({connectionString:withDB(process.env.TEST_WORKER_DATABASE_URL,sourceName)});
await admin.query('CREATE SCHEMA auth; CREATE TABLE auth.sessions(id uuid PRIMARY KEY,user_id uuid NOT NULL,not_after timestamptz); CREATE TABLE auth.users(id uuid PRIMARY KEY,email text,email_confirmed_at timestamptz)');
await migrate(withDB(controlURL,sourceName));
const privateRoot=await mkdtemp(join(process.env.RITC_DEMAND_STATE??tmpdir(),'demand-restore-'));await chmod(privateRoot,0o700);
const configurationPath=await preparePrivacyJournalFixture(admin,join(privateRoot,'journal-evidence'),privateRoot);
const configuration=JSON.parse(await readFile(configurationPath,'utf8'));let fenced=false;

const issuer='https://shared-demand.fixture.invalid';const {publicKey,privateKey}=await generateKeyPair('ES256'),jwk=await exportJWK(publicKey);jwk.kid='fixture';
const verifier=new JWTIdentityVerifier({issuer,audience:'authenticated',jwksUrl:issuer+'/jwks'},createLocalJWKSet({keys:[jwk]})),repo=new HouseholdRepository(runtime,{allowChildNetwork:false,noticeVersion:'fixture',trackingV2:true,sessionStatus:new SupabaseSessionVerifier(issuer)});
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

async function page(f,a=f.owner){return ok(await call(a,f.path+'/demand/tracking'));}
const baseOf=p=>({shopRevision:p.shopRevision,authorityEpoch:p.authorityEpoch,graphRevision:(p.state??p.projection.state).graph.revision,stateDigest:p.basisDigest});
async function candidate(f,intent,a=f.owner){return call(a,f.path+'/demand/tracking/candidates','POST',intent);}
async function accept(f,c,a=f.owner,disclosure=c.disclosure){return call(a,f.path+'/demand/tracking/previews','POST',{candidateId:c.candidateId,candidateDigest:c.candidateDigest,acknowledgedDisclosure:disclosure});}
async function commitTracking(f,c,p,base,a=f.owner){const command={v:1,replayWindow:a.window,clientKey:randomUUID(),shopId:f.shopId,kind:p.action.kind,base:{shopRevision:base.shopRevision,authorityEpoch:base.authorityEpoch,...(p.action.kind==='request.apply'?{requestRevision:c.after.catalog.find(f=>f.source.kind==='request'&&f.source.requestId===p.action.body.requestId).source.appliedRequestRevision}:{})},body:{...p.action.body,demandReview:{previewId:p.previewId,previewDigest:p.previewDigest,trackingVersion:2}}};return{command,response:await call(a,f.base+'/commands','POST',command)};}
async function applyIntent(f,intent){const c=ok(await candidate(f,intent)),p=ok(await accept(f,c)),a=await commitTracking(f,c,p,intent.base);ok(a.response);return{c,p,...a};}
async function first(f,{withMeal=true}={}){
 if(withMeal){f.occurrenceId=randomUUID();f.ingredientId=randomUUID();f.groupId=randomUUID();
  f.meal={title:'Dinner and protected lunch',day:null,kind:'dinner',portions:3,protected:false,planning:{groups:[{id:f.groupId,name:'Lunch',servings:{numerator:1,denominator:1},protected:true}],ingredients:[{id:f.ingredientId,name:'Wraps',quantity:{amount:{numerator:6,denominator:1},unit:'count',originalLiteral:'six wraps'},groupIds:[f.groupId],exclusions:[]}],exclusions:[]}};
  ok(await send(f,'shop.patch',{quote:f.quote,lines:[f.basket],mealEdit:{occurrenceId:f.occurrenceId,baseMealRevision:null,meal:f.meal}},1));
 }
 const before=await page(f),manual=source(f),catalog=before.state.catalog;
 const bound=catalog.map(fact=>({id:fact.id,lineId:f.basket.lineId,source:fact.source,productKey:'wraps',productName:'Wraps',originalText:fact.originalText,quantity:fact.quantity,sourceExclusions:fact.sourceExclusions,exclusions:[],contains:[],removedAt:null}));
 const input={...draft(f,manual),base:baseOf(before)};input.action.body.lines=[{...f.basket,packs:3}];input.change.contributions.push(...bound);input.packs[0].acceptUnresolved=withMeal;
 const accepted=await applyIntent(f,input);return{before,manual,input,...accepted};
}
async function addLater(f){const current=await page(f),old=current.state,extra={lineId:randomUUID(),originalItem:'Later apples',packs:1,unitPriceMinor:120,feeEligible:true};const c={...source({...f,basket:extra},q(3)),productKey:'apples',productName:'Apples',originalText:'three apples'};
 const input={mode:'change',base:baseOf(current),change:{...empty(),lines:[{id:extra.lineId,name:extra.originalItem,unit:'count',originalOrder:1,trashedAt:null}],contributions:[c]},unboundFactIds:old.unbound.map(u=>u.factId),action:{kind:'shop.patch',body:{quote:f.quote,lines:[...old.basket.map(l=>({lineId:l.id,originalItem:l.name,packs:l.packs,unitPriceMinor:l.id===f.basket.lineId?120:l.priceMinor,feeEligible:l.feeEligible})),extra]}},packs:[...old.packReviews,{lineId:extra.lineId,usablePerPack:q(3),acceptUnresolved:false}]};await applyIntent(f,input);return{extra,c};}
async function inverse(f,target,packs){const current=await page(f);return applyIntent(f,{mode:'firstAdoptionUndo',base:baseOf(current),targetOperationId:target,packs:packs??[]});}
async function counts(f){return Promise.all(['operation','shared_demand_revision','shared_tracking_revision','shared_tracking_adoption','basket_line'].map(t=>count(f,t)));}


const privacyCases=trackingPrivacyFixtures({fixture,source,q,empty,draft,page,baseOf,applyIntent,invited,send,ok,call,admin});

test('signed quarantined restore removes tracking transfers, lineage, sealed copies and pending review while preserving unrelated IDs',async()=>{
 const f=await fixture(),a=await first(f);await inverse(f,ok(a.response).operationId);const partial=await page(f);assert.equal(partial.coverage.protectedUnboundFactIds.length,1);
 const oldOwner=f.owner,other=await invited(f);ok(await send(f,'shop.transferAuthority',{newShopperId:other.id},partial.shopRevision));f.owner=other;
 const later=await addLater(f),p=await page(f),held=ok(await candidate(f,{mode:'review',base:baseOf(p),action:{kind:'shop.patch',body:{quote:f.quote,lines:p.state.basket.map(l=>({lineId:l.id,originalItem:l.name,packs:l.packs,unitPriceMinor:l.priceMinor,feeEligible:l.feeEligible}))}},packs:p.state.packReviews}));
 const frozen=ok(await send(f,'shop.freeze',{trackingReview:p.freezeReview},p.shopRevision,p.authorityEpoch));
 const linkCase=await privacyCases.linkAuthor(),labelCase=await privacyCases.legacyLabel();
 const dumpPath=join(privateRoot,'tracking-before-deletion.dump'),pgTool=name=>process.env.RITC_TEST_PG_BIN?join(process.env.RITC_TEST_PG_BIN,name):name;
 const connection=['--host',controlURL.hostname,'--port',controlURL.port||'5432','--username',decodeURIComponent(controlURL.username)],toolEnv={...process.env,PGPASSWORD:decodeURIComponent(controlURL.password)};
 execFileSync(pgTool('pg_dump'),[...connection,'--format=custom','--file',dumpPath,'--dbname',sourceName],{env:toolEnv,timeout:30000,maxBuffer:65536});
 const deletion={clientKey:randomUUID(),statusToken:randomBytes(32).toString('base64url'),confirm:true,households:[{householdId:f.h,organizer:'transfer',organizerMemberId:other.id,shops:[],eraseChildProfiles:[]}]};ok(await call(oldOwner,'/v1/privacy/deletions','POST',deletion),202);assert.equal((await maintenance.run({batchSize:1})).completed,1);
 assert.equal((await accept(f,held)).status,409);
 const linkDeletion=await privacyCases.erase(linkCase.f,linkCase.eraser);assert.equal((await maintenance.run({batchSize:1})).completed,1);await privacyCases.assertProjection(linkCase);await privacyCases.recover(linkCase);
 const labelDeletion=await privacyCases.erase(labelCase.f,labelCase.eraser,true);assert.equal((await maintenance.run({batchSize:1})).completed,1);await privacyCases.assertProjection(labelCase);await privacyCases.recover(labelCase);
 const head=await journal.fence();fenced=true;
 const verified=verifyPrivacyJournal(await readFile(join(configuration.directory,'journal.ndjson')),{...configuration,publicKey:journal.publicKey,head});validatePrivacyRestoreEvents(verified.events);
 await control.query('CREATE DATABASE '+destinationName);const runtimeRole=new URL(process.env.TEST_DATABASE_URL).username,workerRole=new URL(process.env.TEST_WORKER_DATABASE_URL).username;assert.match(runtimeRole,/^[a-z_]+$/);assert.match(workerRole,/^[a-z_]+$/);
 await control.query('REVOKE CONNECT ON DATABASE '+destinationName+' FROM PUBLIC,'+runtimeRole+',ritc_app');await control.query('GRANT CONNECT ON DATABASE '+destinationName+' TO '+workerRole);
 assert.equal((await control.query("SELECT has_database_privilege($1,$2,'CONNECT') AS allowed",[runtimeRole,destinationName])).rows[0].allowed,false);
 execFileSync(pgTool('pg_restore'),[...connection,'--exit-on-error','--dbname',destinationName,dumpPath],{env:toolEnv,timeout:30000,maxBuffer:65536});
 const restored=new pg.Pool({connectionString:withDB(controlURL,destinationName)}),restoreWorker=new pg.Pool({connectionString:withDB(process.env.TEST_WORKER_DATABASE_URL,destinationName)});
 try{
  const secret='six wraps',copies=['shared_tracking_revision','shared_tracking_adoption','shop_snapshot'];
  for(const table of copies)assert.ok(JSON.stringify((await restored.query('SELECT to_jsonb(t) AS value FROM ritc.'+table+' t WHERE household_id=$1',[f.h])).rows).includes(secret),'backup really includes '+table);
  assert.equal((await restored.query('SELECT count(*)::integer AS n FROM ritc.shared_tracking_preview WHERE household_id=$1',[f.h])).rows[0].n,1);
  const oid=(await restored.query('SELECT oid FROM pg_database WHERE datname=current_database()')).rows[0].oid,runId=randomUUID();
  await restored.query('SELECT ritc.privacy_restore_register($1,$2,$3,$4::jsonb,$5::jsonb)',[runId,oid,verified.bundleDigest,JSON.stringify(verified.head),JSON.stringify(verified.events)]);
  const lease=randomUUID(),job=(await restoreWorker.query('SELECT ritc.privacy_restore_claim($1,$2) AS job',[runId,lease])).rows[0].job;assert.ok([deletion.clientKey,linkDeletion.clientKey,labelDeletion.clientKey].includes(job));
  const result=(await restoreWorker.query('SELECT ritc.privacy_restore_erase_next($1,$2,$3) AS value',[runId,job,lease])).rows[0].value;assert.equal(result.applied,true);
  const appliedJobs=new Set([job]);for(let remaining=0;remaining<2;remaining++){const nextLease=randomUUID(),next=(await restoreWorker.query('SELECT ritc.privacy_restore_claim($1,$2) AS job',[runId,nextLease])).rows[0].job;assert.ok(next&&!appliedJobs.has(next));const receipt=(await restoreWorker.query('SELECT ritc.privacy_restore_erase_next($1,$2,$3) AS value',[runId,next,nextLease])).rows[0].value;assert.equal(receipt.applied,true);appliedJobs.add(next);}
  assert.deepEqual([...appliedJobs].sort(),[deletion.clientKey,linkDeletion.clientKey,labelDeletion.clientKey].sort());
  await privacyCases.assertProjection(linkCase,restored);await privacyCases.assertProjection(labelCase,restored);
  for(const table of [...copies,'shared_tracking_preview','shared_demand_revision','basket_line','operation_response'])assert.ok(!JSON.stringify((await restored.query('SELECT to_jsonb(t) AS value FROM ritc.'+table+' t WHERE household_id=$1',[f.h])).rows).includes(secret),'erased '+table);
  const current=(await restored.query('SELECT state,state_digest,projection,review FROM ritc.shared_tracking_revision WHERE household_id=$1 AND shop_id=$2 ORDER BY shop_revision DESC LIMIT 1',[f.h,f.shopId])).rows[0];
  assert.equal(current.state,null);assert.equal(current.state_digest,null);assert.equal(current.review,null);assert.equal(current.projection.status,'reviewRequired');
  assert.deepEqual(current.projection.state.graph.contributions.find(c=>c.id===later.c.id),later.c);assert.ok(current.projection.state.graph.usedIds.includes(a.manual.id));assert.equal(current.projection.state.unbound.length,0);
  assert.equal((await restored.query('SELECT count(*)::integer n FROM ritc.shared_tracking_preview WHERE household_id=$1',[f.h])).rows[0].n,0);
  assert.equal((await restored.query('SELECT evidence FROM ritc.shared_tracking_adoption WHERE household_id=$1',[f.h])).rows[0].evidence,null);
  const seal=(await restored.query('SELECT snapshot,digest FROM ritc.shop_snapshot WHERE household_id=$1 AND shop_id=$2 AND revision=$3',[f.h,f.shopId,frozen.shopRevision])).rows[0];assert.equal(seal.snapshot.trackingSeal,undefined);assert.equal(seal.digest,'0'.repeat(64));
  assert.equal((await control.query("SELECT has_database_privilege($1,$2,'CONNECT') AS allowed",[runtimeRole,destinationName])).rows[0].allowed,false,'provider reconciliation/runtime reopening not claimed');
  await writeFile(join(privateRoot,'tracking-restore-receipt.json'),JSON.stringify({runId,bundleDigest:verified.bundleDigest,signatureVerified:true,applied:result.applied,runtimeStillQuarantined:true,sourceName,destinationName})+'\n',{mode:0o600});
 }finally{await Promise.all([restored.end(),restoreWorker.end()]);}
});
