import {before,after} from 'node:test';
import assert from 'node:assert/strict';
import {randomUUID,randomBytes} from 'node:crypto';
import pg from 'pg';
import {generateKeyPair,exportJWK,createLocalJWKSet,SignJWT} from 'jose';
import {HouseholdRepository} from '../dist/repository.js';
import {bodySchemas} from '../dist/contracts.js';
import {digest} from '../dist/database.js';
import {JWTIdentityVerifier,SupabaseSessionVerifier} from '../dist/auth.js';
import {PrivacyService,PrivacyMaintenance} from '../dist/privacy.js';
import {openPrivacyJournalFixture} from './privacy-journal-fixture.mjs';
import {createHTTPServer} from '../dist/http.js';
const admin=new pg.Pool({connectionString:process.env.TEST_ADMIN_DATABASE_URL}),runtime=new pg.Pool({connectionString:process.env.TEST_DATABASE_URL}),worker=new pg.Pool({connectionString:process.env.TEST_WORKER_DATABASE_URL});
let runtimeQueries=0;runtime.on('connect',client=>{const query=client.query.bind(client);client.query=(...args)=>{runtimeQueries++;return query(...args);};});
const issuer='https://request-acceptance-undo.fixture.invalid';const {publicKey,privateKey}=await generateKeyPair('ES256'),jwk=await exportJWK(publicKey);jwk.kid='fixture';
const verifier=new JWTIdentityVerifier({issuer,audience:'authenticated',jwksUrl:issuer+'/jwks'},createLocalJWKSet({keys:[jwk]})),repo=new HouseholdRepository(runtime,{allowChildNetwork:false,noticeVersion:'fixture',trackingV2:true,sessionStatus:new SupabaseSessionVerifier(issuer)});
const journal=await openPrivacyJournalFixture(admin),provider={assertAvailable:async()=>{},deleteAccount:async subject=>{await admin.query('DELETE FROM auth.sessions WHERE user_id=$1',[subject]);}};
const privacy=new PrivacyService(repo,{provider,journal:journal.port,policy:{receiptRetentionDays:1,erasureMarkerRetentionDays:2,verifiedBackupRetentionDays:1}}),maintenance=new PrivacyMaintenance(worker,{provider,journal:journal.port});
const server=createHTTPServer({repository:repo,verifier,privacy,maxRequestsPerMinute:20000});let origin;
before(async()=>{await new Promise(r=>server.listen(0,'127.0.0.1',r));origin='http://127.0.0.1:'+server.address().port;});
after(async()=>{await new Promise(r=>server.close(r));await journal.close();await Promise.all([admin.end(),runtime.end(),worker.end()]);});
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

// Prepared real HTTP/PG controls. No database run is claimed by this packet.
async function head(f){return ok(await call(f.owner,f.path));}
async function acceptRequest(f,request,choice){
 const s=await head(f),decision=choice==='add'?{choice,line:{lineId:randomUUID(),originalItem:'Private accepted wraps',packs:1,unitPriceMinor:150,feeEligible:true},promote:request.route==='next'}:{choice,lineId:f.basket.lineId,promote:request.route==='next'};
 const p=ok(await call(f.owner,f.path+'/previews','POST',{requestId:request.requestId,base:{shopRevision:s.shopRevision,authorityEpoch:s.authorityEpoch,requestRevision:request.revision},decision}));
 const action={kind:'request.apply',body:{requestId:request.requestId,previewId:p.previewId,acceptOverage:false,acceptUnknown:false}};
 const demand=ok(await call(f.owner,f.path+'/demand'));let demandReview;
 if(demand.status==='enabled'){
  const target=choice==='add'?decision.line.lineId:decision.lineId;
  const contribution={id:randomUUID(),lineId:target,source:{kind:'request',requestId:request.requestId,appliedRequestRevision:request.revision},productKey:'wraps',productName:choice==='add'?decision.line.originalItem:f.basket.originalItem,originalText:request.originalItem,quantity:q(2),exclusions:[],contains:[],removedAt:null};
  const lines=choice==='add'?[{id:target,name:decision.line.originalItem,unit:'count',originalOrder:9,trashedAt:null}]:[];
  const input={mode:'change',base:{shopRevision:s.shopRevision,authorityEpoch:s.authorityEpoch,graphRevision:demand.graph.revision},change:{...empty(),lines,contributions:[contribution]},action,packs:[...s.lines,...(choice==='add'?[decision.line]:[])].map(l=>({lineId:l.lineId,usablePerPack:q(10),acceptUnresolved:false}))};
  const reviewed=ok(await preview(f,input));demandReview={previewId:reviewed.previewId,previewDigest:reviewed.previewDigest};
 }
 const command={v:1,replayWindow:f.owner.window,clientKey:randomUUID(),shopId:f.shopId,kind:'request.apply',base:{shopRevision:s.shopRevision,authorityEpoch:s.authorityEpoch,requestRevision:request.revision},body:{...action.body,...(demandReview?{demandReview}:{})}};
 const receipt=ok(await call(f.owner,f.base+'/commands','POST',command));return{command,receipt,decision,request};
}
async function setup(kind='tracked',choice='add',status='pending'){
 const f=await fixture();if(kind==='tracked')await adopt(f);f.author=await invited(f);const s=await head(f);
 let request=ok(await send(f,'request.send',{clientRequestId:randomUUID(),originalItem:'Wraps for guest',ownQuantity:'two original wraps',authoredAt:new Date().toISOString()},s.shopRevision,1,f.author)).request;
 if(status==='clarified'){ok(await send(f,'request.clarify',{requestId:request.requestId,question:'Which wraps?'},s.shopRevision,1,f.owner,{base:{shopRevision:s.shopRevision,authorityEpoch:1,requestRevision:request.revision}}));request={...request,revision:request.revision+1,status,clarification:'Which wraps?'};}
 if(status==='deferred'){
  const p=ok(await call(f.owner,f.path+'/previews','POST',{requestId:request.requestId,base:{shopRevision:s.shopRevision,authorityEpoch:1,requestRevision:request.revision},decision:{choice:'defer'}}));
  ok(await send(f,'request.apply',{requestId:request.requestId,previewId:p.previewId,acceptOverage:false,acceptUnknown:false},s.shopRevision,1,f.owner,{base:{shopRevision:s.shopRevision,authorityEpoch:1,requestRevision:request.revision}}));request={...request,revision:request.revision+1,status,route:'next'};
 }
 f.target=await acceptRequest(f,request,choice);return f;
}
async function candidate(f){const s=await head(f);return call(f.owner,f.path+'/requests/operation-undo-candidates','POST',{targetOperationId:f.target.receipt.operationId,base:{shopRevision:s.shopRevision,authorityEpoch:s.authorityEpoch}});}
async function review(f,c=undefined){c??=ok(await candidate(f));const input={targetOperationId:c.targetOperationId,base:c.base,effectDigest:c.effectDigest,packs:c.packReviewLineIds.map(lineId=>({lineId,usablePerPack:c.foodAfter.kind!=='legacy'?q(10):null,acceptUnresolved:true})),acceptOverage:true,acceptUnknown:true};return{input,response:await call(f.owner,f.path+'/requests/operation-undo-previews','POST',input)};}
function undoCommand(f,p){return{v:1,replayWindow:f.owner.window,clientKey:randomUUID(),shopId:f.shopId,kind:p.candidate.action.kind,base:{shopRevision:p.candidate.base.shopRevision,authorityEpoch:p.candidate.base.authorityEpoch,requestRevision:p.candidate.base.requestRevision},body:{...p.candidate.action.body,operationUndoReview:{previewId:p.previewId,previewDigest:p.previewDigest}}};}
async function own(f){return ok(await call(f.author,f.base+'/requests/mine')).requests.find(r=>r.requestId===f.target.request.requestId);}
async function state(f){return{shop:await head(f),own:await own(f),links:(await admin.query('SELECT * FROM ritc.request_link WHERE household_id=$1 AND shop_id=$2 ORDER BY request_id',[f.h,f.shopId])).rows,operations:await count(f,'operation'),effects:await count(f,'request_acceptance_effect'),inverses:await count(f,'request_acceptance_inverse'),graphs:await count(f,'shared_demand_revision'),snapshots:await count(f,'shop_snapshot')};}
async function append(f,extra,mealEdit){const s=await head(f),d=ok(await call(f.owner,f.path+'/demand')),lines=[...s.lines,...(extra?[extra]:[])],body={quote:s.quote,lines,...(mealEdit?{mealEdit}:{})};
 if(d.status==='legacy')return ok(await send(f,'shop.patch',body,s.shopRevision,s.authorityEpoch));
 const change=extra?{...empty(),lines:[{id:extra.lineId,name:extra.originalItem,unit:'count',originalOrder:25,trashedAt:null}],contributions:[{id:randomUUID(),lineId:extra.lineId,source:{kind:'manual'},productKey:'apples',productName:extra.originalItem,originalText:extra.originalItem,quantity:q(1),exclusions:[],contains:[],removedAt:null}]}:empty();
 const input={mode:extra?'change':'review',base:{shopRevision:s.shopRevision,authorityEpoch:s.authorityEpoch,graphRevision:d.graph.revision},change,action:{kind:'shop.patch',body},packs:lines.map(l=>({lineId:l.lineId,usablePerPack:q(10),acceptUnresolved:true}))};return ok((await apply(f,input,ok(await preview(f,input)))).response);
}

export {admin,runtime,worker,repo,maintenance,actor,call,ok,enroll,q,empty,line,fixture,send,source,draft,preview,apply,adopt,invited,count,head,acceptRequest,setup,candidate,review,undoCommand,own,state,append};
