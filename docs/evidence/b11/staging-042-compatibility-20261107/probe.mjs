import {readFile,writeFile,mkdtemp} from 'node:fs/promises';
import {execFile} from 'node:child_process';
import {promisify} from 'node:util';
import {createServer as httpsServer} from 'node:https';
import {join} from 'node:path';
const run=promisify(execFile);const root=JSON.parse(await readFile('/tmp/ritc-rollback042-current.json','utf8')).root;
import assert from 'node:assert/strict';
import pg from 'pg';
import {migrate} from './current/service/scripts/migrate.mjs';
import {randomUUID,randomBytes} from 'node:crypto';
import {PrivacyService,PrivacyMaintenance} from './current/service/dist/privacy.js';
import {openPrivacyJournalFixture} from './current/service/tests/privacy-journal-fixture.mjs';
import {generateKeyPair,exportJWK,createLocalJWKSet,SignJWT} from 'jose';
import {HouseholdRepository} from './current/service/dist/repository.js';
import {JWTIdentityVerifier,SupabaseSessionVerifier} from './current/service/dist/auth.js';
import {BillingService} from './current/service/dist/billing/service.js';
import {createHTTPServer} from './current/service/dist/http.js';
const admin=new pg.Pool({connectionString:process.env.TEST_ADMIN_DATABASE_URL}),runtime=new pg.Pool({connectionString:process.env.TEST_DATABASE_URL}),subscriptions=new Map();let verifiedCalls=0;
const gateway={verifyTransaction:async value=>{const current=subscriptions.get(value);if(!current)throw Error('fixture signature');return current;},current:async id=>{verifiedCalls++;const value=subscriptions.get(id);if(!value)throw Error('fixture unavailable');return value;},verifyNotification:async()=>{throw Error('unused');}};
const issuer='https://amendment.fixture.invalid',audience='authenticated';const {publicKey,privateKey}=await generateKeyPair('ES256'),jwk=await exportJWK(publicKey);jwk.kid='history';
const verifier=new JWTIdentityVerifier({issuer,audience,jwksUrl:issuer+'/keys'},createLocalJWKSet({keys:[jwk]})),repo=new HouseholdRepository(runtime,{allowChildNetwork:false,noticeVersion:'fixture',sessionStatus:new SupabaseSessionVerifier(issuer)}),billing=new BillingService(gateway),server=createHTTPServer({repository:repo,verifier,billing,maxRequestsPerMinute:20000});let origin;
async function actor(){const subject=randomUUID(),session=randomUUID();await admin.query('INSERT INTO auth.sessions(id,user_id) VALUES($1,$2)',[session,subject]);const token=await new SignJWT({session_id:session,amr:[{method:'otp',timestamp:Math.floor(Date.now()/1000)}]}).setProtectedHeader({alg:'ES256',kid:jwk.kid}).setIssuer(issuer).setSubject(subject).setAudience(audience).setIssuedAt().setExpirationTime('1h').sign(privateKey);return{subject,session,token};}
async function call(a,path,method='GET',body,headers={}){const r=await fetch(origin+path,{method,headers:{Authorization:'Bearer '+a.token,...(a.device?{'X-Device-Token':a.device}:{}),...(body===undefined?{}:{'Content-Type':'application/json'}),...headers},...(body===undefined?{}:{body:JSON.stringify(body)})});return{status:r.status,data:await r.json()};}
function ok(r,status=200){assert.equal(r.status,status,JSON.stringify(r.data));return r.data;}
async function enroll(a,h){a.device=ok(await call(a,`/v1/households/${h}/devices`,'POST',{}),201).deviceToken;a.window=ok(await call(a,`/v1/households/${h}/replay-windows`,'POST',{})).id;}
async function fixture(){const owner=await actor(),created=ok(await call(owner,'/v1/households','POST',{clientKey:randomUUID(),label:'History fixture',alias:'Adult',adultAttestation:true}),201),h=created.householdId,base=`/v1/households/${h}`;owner.id=created.memberId;await enroll(owner,h);
 const shop=async(price=10000)=>{const id=randomUUID(),quote={currency:'USD',scope:'wholeCheckout',complete:true,capMinor:100000,capScope:'wholeCheckout',fee:{kind:'fixed',amountMinor:0},taxesMinor:0,depositsMinor:0,discountsMinor:0,observedAt:new Date(Date.now()-60000).toISOString(),expiresAt:new Date(Date.now()+3600000).toISOString()};ok(await call(owner,base+'/commands','POST',{v:1,replayWindow:owner.window,clientKey:randomUUID(),shopId:id,kind:'shop.create',base:{shopRevision:0,authorityEpoch:0},body:{quote,lines:[{lineId:randomUUID(),originalItem:'Private basket source',packs:1,unitPriceMinor:price,feeEligible:true}]}}));return id;};
 const shopId=await shop();async function paid(){const token=ok(await call(owner,base+'/billing/purchase-context','POST',{})).appAccountToken,original=String(Date.now())+String(Math.floor(Math.random()*1e6)),now=Date.now();subscriptions.set(original,{environment:'Sandbox',originalTransactionID:original,transactionID:original,appAccountToken:token,productID:'fixture.household.yearly',purchasedAt:now,signedAt:now,expiresAt:now+3600000,graceExpiresAt:null,status:'active'});ok(await call(owner,'/v1/billing/verify','POST',{householdId:h,signedTransactionInfo:original}));return original;}
 const version=async(id=shopId)=>ok(await call(owner,base+`/shops/${id}/financial-evidence`)).sourceVersion;
 const financial=async(entry,id=shopId)=>{const input={clientKey:randomUUID(),sourceVersion:await version(id),entry};return{input,result:ok(await call(owner,base+`/shops/${id}/financial-evidence`,'POST',input))};};
 return{owner,h,base,shopId,shop,paid,version,financial};}


const line=(name='Added retailer item')=>({lineId:randomUUID(),originalItem:name,packs:2,unitPriceMinor:275,feeEligible:true});
async function placedFixture(){const f=await fixture(),path=f.base+'/shops/'+f.shopId;
 const initial=ok(await call(f.owner,path));
 const command=(kind,revision,body)=>({v:1,replayWindow:f.owner.window,clientKey:randomUUID(),shopId:f.shopId,kind,base:{shopRevision:revision,authorityEpoch:1},body});
 ok(await call(f.owner,f.base+'/commands','POST',command('shop.freeze',1,{})));
 ok(await call(f.owner,f.base+'/commands','POST',command('shop.reportPlaced',2,{occurredAt:new Date().toISOString()})));
 const read=()=>call(f.owner,path+'/confirmed-order');
 const send=c=>call(f.owner,f.base+'/commands','POST',c);
 const amend=(lines,base=3,predecessorId=null)=>command('amendment.recordResponse',base,{placedRevision:2,predecessorId,retailerReference:'Retailer confirmation #42',confirmedAt:new Date().toISOString(),lines});
 return{...f,path,initial,command,read,send,amend};}


const {HouseholdRepository:OldRepository}=await import('./old/service/dist/repository.js');
const {createHTTPServer:oldHTTP}=await import('./old/service/dist/http.js');
const {migrate:oldMigrate}=await import('./old/service/scripts/migrate.mjs');
const oldRepo=new OldRepository(runtime,{allowChildNetwork:false,noticeVersion:'fixture',sessionStatus:new SupabaseSessionVerifier(issuer)});
const oldServer=oldHTTP({repository:oldRepo,verifier,billing,maxRequestsPerMinute:20000});
const results={oldSource:'02f9b872a9bfe919039cbd7f8117f1faf5983396',checks:[],swift:[]};
function same(actual,expected){assert.deepEqual(actual,expected);return true;}
function check(name,value){assert(value,name);results.checks.push(name);console.log('PASS '+name);}
async function oldCall(f,path,method='GET',body){const previous=origin;origin=oldOrigin;try{return await call(f.owner,path,method,body);}finally{origin=previous;}}
async function swiftProbe(name,server,f,expect){
 const dir=await mkdtemp(join(root,'tls-')),key=join(dir,'key.pem'),cert=join(dir,'cert.pem'),der=join(dir,'cert.der'),config=join(dir,'openssl.cnf'),code=randomUUID();
 await writeFile(config,'[req]\ndistinguished_name=dn\nx509_extensions=ext\nprompt=no\n[dn]\nCN=localhost\n[ext]\nsubjectAltName=IP:127.0.0.1\nextendedKeyUsage=serverAuth\nkeyUsage=digitalSignature,keyEncipherment\n');
 await run('openssl',['req','-x509','-newkey','rsa:2048','-sha256','-nodes','-days','1','-config',config,'-keyout',key,'-out',cert]);
 await run('openssl',['x509','-in',cert,'-outform','DER','-out',der]);
 const user={id:f.owner.subject,email:'fixture@example.invalid',email_confirmed_at:new Date().toISOString()};
 const tls=httpsServer({key:await readFile(key),cert:await readFile(cert)},async(req,res)=>{
  if(!req.url.startsWith('/auth/v1/')){server.emit('request',req,res);return;}
  res.setHeader('Content-Type','application/json');
  if(req.url==='/auth/v1/verify'){let raw='';for await(const b of req)raw+=b;if(JSON.parse(raw).token===code){res.end(JSON.stringify({access_token:f.owner.token,refresh_token:randomUUID(),expires_in:3600,user}));return;}}
  if(req.url==='/auth/v1/user'&&req.headers.authorization==='Bearer '+f.owner.token){res.end(JSON.stringify(user));return;}
  res.writeHead(401);res.end('{}');
 });
 await new Promise(resolve=>tls.listen(0,'127.0.0.1',resolve));
 try {
  const env={...process.env,PROBE_PORT:String(tls.address().port),PROBE_CERT:der,PROBE_CODE:code,PROBE_HOUSEHOLD:f.h,PROBE_SHOP:f.shopId,...Object.fromEntries(Object.entries(expect).map(([k,v])=>['PROBE_'+k,String(v)]))};
  const args=['test','--package-path',root+'/old/ios/Packages/HouseholdClient','--scratch-path',root+'/swift','--skip-build','--filter','^HouseholdClientTests\.Rollback041ProbeTests/testReleasedClientDeliveryProjection$'];
  try{const out=await run('swift',args,{env,timeout:90000,maxBuffer:2000000});await writeFile(root+'/'+name+'.log',out.stdout+'\n'+out.stderr);check(name,/Test Case .*testReleasedClientDeliveryProjection.*passed/.test(out.stdout));results.swift.push({name,...expect});}
  catch(e){await writeFile(root+'/'+name+'.log',(e.stdout??'')+'\n'+(e.stderr??''));throw e;}
 }finally{await new Promise(resolve=>tls.close(resolve));}
}
let oldOrigin;
try {
 await admin.query('CREATE SCHEMA auth;CREATE TABLE auth.users(id uuid PRIMARY KEY,email text,email_confirmed_at timestamptz);CREATE TABLE auth.sessions(id uuid PRIMARY KEY,user_id uuid NOT NULL,not_after timestamptz)');
 await oldMigrate(process.env.TEST_ADMIN_DATABASE_URL);
 await admin.query('GRANT ritc_app TO rollback_runtime;GRANT ritc_worker TO ritc_test_worker;');
 await new Promise(resolve=>oldServer.listen(0,'127.0.0.1',resolve));oldOrigin='http://127.0.0.1:'+oldServer.address().port;
 await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));const newOrigin='http://127.0.0.1:'+server.address().port;
 origin=oldOrigin;const f=await placedFixture();const originalLine=f.initial.lines[0];
 const q=n=>({amount:{numerator:n,denominator:1},unit:'count',originalLiteral:String(n)});
 const reg=(lineId,supply,revision=3)=>f.command('delivery.register',revision,{placedRevision:2,supplyRevision:supply,lineId,segmentKey:randomUUID(),foodName:lineId===originalLine.lineId?'Original food':'Added replacement',exclusionTags:[]});
 const oldSource=ok(await f.send(reg(originalLine.lineId,0))).sourceId;
 const oldArrival=randomUUID();ok(await f.send(f.command('delivery.arrival',3,{sourceId:oldSource,supplyRevision:1,observationId:oldArrival,predecessorId:null,arrivedAt:new Date().toISOString(),received:q(8)})));
 ok(await f.send(f.command('delivery.usable',3,{sourceId:oldSource,supplyRevision:2,observationId:randomUUID(),predecessorId:null,arrivalObservationId:oldArrival,confirmedAt:new Date().toISOString(),usable:q(7)})));
 await f.financial({id:randomUUID(),evidenceKey:randomUUID(),kind:'postedCharge',amountMinor:3720,currency:'USD',occurredAt:new Date().toISOString(),creditId:null,chargeEvidenceKey:null,holdEvidenceKey:null,sourceText:'Original posted receipt'});
 const sealed=(await admin.query('SELECT revision,snapshot,digest FROM ritc.shop_snapshot WHERE household_id=$1 ORDER BY revision',[f.h])).rows;
 await swiftProbe('old-client-old-service-schema041',oldServer,f,{LINES:1,SOURCES:1,ORPHANS:0});
 await migrate(process.env.TEST_ADMIN_DATABASE_URL);await oldMigrate(process.env.TEST_ADMIN_DATABASE_URL);
 check('old migration runner leaves all42 registry entries intact',(await admin.query('SELECT count(*)::int n FROM public.ritc_schema_migration')).rows[0].n===42);
 check('existing shop has false erasure fence',(await admin.query('SELECT confirmed_order_erased FROM ritc.shop WHERE household_id=$1',[f.h])).rows[0].confirmed_order_erased===false);
 await swiftProbe('old-client-old-service-schema042-before-amendment',oldServer,f,{LINES:1,SOURCES:1,ORPHANS:0});
 origin=newOrigin;const added=line('Added replacement');const amendment=f.amend([added]);const head=ok(await f.send(amendment));
 check('old service lacks confirmed-order capability',!ok(await oldCall(f,f.base+'/bootstrap')).capabilities.includes('confirmed_order'));
 check('old service has no confirmed-order route',(await oldCall(f,f.path+'/confirmed-order')).status===404);
 check('old service rejects amendment exact retry before receipt lookup',(await oldCall(f,f.base+'/commands','POST',amendment)).status===422);
 const addedCommand=reg(added.lineId,3,4),addedReceipt=ok(await f.send(addedCommand));
 check('old service exact-replays already registered added identity',same(ok(await oldCall(f,f.base+'/commands','POST',addedCommand)),addedReceipt));
 const newAdded=reg(added.lineId,4,4);check('old service cannot register another segment for added identity',(await oldCall(f,f.base+'/commands','POST',newAdded)).status===404);
 const addedArrival=randomUUID(),arrival=f.command('delivery.arrival',4,{sourceId:addedReceipt.sourceId,supplyRevision:4,observationId:addedArrival,predecessorId:null,arrivedAt:new Date().toISOString(),received:q(2)});
 ok(await oldCall(f,f.base+'/commands','POST',arrival));
 const usable=f.command('delivery.usable',4,{sourceId:addedReceipt.sourceId,supplyRevision:5,observationId:randomUUID(),predecessorId:null,arrivalObservationId:addedArrival,confirmedAt:new Date().toISOString(),usable:q(1)});
 const usableReceipt=ok(await oldCall(f,f.base+'/commands','POST',usable));
 check('old service can correct already registered amendment source while placed',ok(await call(f.owner,f.path+'/delivery-evidence')).sources.find(s=>s.sourceId===addedReceipt.sourceId).confirmed.quantity.amount.numerator===1);
 await swiftProbe('old-client-new-service-two-historical-identities',server,f,{LINES:2,SOURCES:2,ORPHANS:0,ADDED:added.lineId});
 await swiftProbe('old-client-old-service-silently-omits-added-line',oldServer,f,{LINES:1,SOURCES:2,ORPHANS:1,ADDED:added.lineId});
 const many=Array.from({length:200},(_,i)=>line('Later product '+i));const manyHead=ok(await f.send(f.amend(many,4,head.amendmentId)));
 check('new service returns complete202 historical identities',ok(await call(f.owner,f.path+'/delivery-evidence')).lines.length===202);
 await swiftProbe('old-client-new-service-rejects-202-identities',server,f,{INVALID:1});
 await swiftProbe('old-client-old-service-accepts-truncated-202-union',oldServer,f,{LINES:1,SOURCES:2,ORPHANS:1,ADDED:added.lineId});
 const beforeOrder=ok(await f.read());const financial=ok(await call(f.owner,f.path+'/financial-evidence'));
 const close=ok(await oldCall(f,f.path+'/financial-reviews','POST',{clientKey:randomUUID(),sourceVersion:financial.sourceVersion,allEvidenceEntered:false,closeShop:true}));
 check('old service can close shop without deleting amendment chain',close.appShopClosed===true);
 const closed=ok(await call(f.owner,f.path));check('closed revision advances once and placed identity unchanged',closed.phase==='closed'&&closed.shopRevision===6&&closed.placedRevision===2);
 const correction=f.command('delivery.usable',6,{...usable.body,supplyRevision:6,observationId:randomUUID(),predecessorId:usable.body.observationId,usable:q(0)});
 check('old service blocks fresh closed usable correction',(await oldCall(f,f.base+'/commands','POST',correction)).data.error.code==='placed_order_required');
 check('old service still exact-replays prior delivery receipt after close',same(ok(await oldCall(f,f.base+'/commands','POST',usable)),usableReceipt));
 ok(await f.send(correction));check('new service permits same reviewed closed correction',ok(await call(f.owner,f.path+'/delivery-evidence')).sources.find(s=>s.sourceId===addedReceipt.sourceId).confirmed.quantity.amount.numerator===0);
 const afterOrder=ok(await f.read());assert.deepEqual(afterOrder.original,beforeOrder.original);assert.deepEqual(afterOrder.current,beforeOrder.current);assert.deepEqual(afterOrder.amendments,beforeOrder.amendments);
 assert.deepEqual(ok(await call(f.owner,f.path+'/financial-evidence')).entries,financial.entries);
 assert.deepEqual((await admin.query('SELECT revision,snapshot,digest FROM ritc.shop_snapshot WHERE household_id=$1 ORDER BY revision',[f.h])).rows,sealed);
 check('rollback reads and allowed writes preserve snapshots amended order and posted financial evidence',true);
 results.final={shopRevision:closed.shopRevision,placedRevision:closed.placedRevision,amendments:afterOrder.amendments.length,historicalLines:202,oldProjectedLines:1,sources:2,supplyRevision:ok(await call(f.owner,f.path+'/delivery-evidence')).supplyRevision};
 await writeFile(root+'/results.json',JSON.stringify(results,null,2)+'\n');
}finally{
 for(const s of [server,oldServer])if(s.listening)await new Promise(resolve=>s.close(resolve));await Promise.all([admin.end(),runtime.end()]);
}
