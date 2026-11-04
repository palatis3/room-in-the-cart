import test from 'node:test';
import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {createServer} from 'node:http';
import {setImmediate as immediate} from 'node:timers/promises';
import {PrivacyCall,privacyPhase,withPrivacyClient} from '../dist/privacy-call.js';
import {PrivacyService,SupabaseAccountDeletionProvider} from '../dist/privacy.js';
import {createHTTPServer} from '../dist/http.js';
import {ServiceError} from '../dist/errors.js';

const gate=()=>{let resolve,reject;const promise=new Promise((yes,no)=>{resolve=yes;reject=no;});return{promise,resolve,reject};};
const context=(controller=new AbortController(),deadline=Date.now()+10_000)=>({attemptId:randomUUID(),deadlineUnixMs:deadline,signal:controller.signal});
const unavailable=error=>error?.code==='deletion_unavailable';
const identity=()=>({issuer:'https://privacy-call.fixture.invalid',subject:randomUUID(),sessionId:randomUUID(),authenticatedAt:new Date(),authenticatedMethod:'otp',expiresAt:new Date(Date.now()+3_600_000)});
const input=()=>({clientKey:randomUUID(),statusToken:'a'.repeat(43),confirm:true,households:[]});
const retention=()=>({receiptRetentionDays:1,erasureMarkerRetentionDays:2,verifiedBackupRetentionDays:1});
function serviceFixture(options={}) {
 const queries=[],releases=[],event={eventId:randomUUID()};let clientID=0;
 const pool={async connect(){const id=++clientID;return{pipeline:false,async query(sql,values){queries.push({id,sql,values});if(options.query)return options.query(sql,values,id);if(sql.includes('privacy_journal_request'))return{rows:[{event}]};if(sql.includes('privacy_status'))return{rows:[{value:{status:'pending'}}]};return{rows:[]};},release(discard){releases.push({id,discard});}};}};
 const repo={pool,assertSession:options.assertSession??(async()=>{})};
 const journal={configurationId:'call-test',beforeCommit:async()=>{},afterCommit:async()=>{},acknowledgeJob:async()=>{},...options.journal};
 const provider={assertAvailable:async()=>{},deleteAccount:async()=>{},...options.provider};
 const service=new PrivacyService(repo,{journal,provider,policy:options.policy??retention()});
 return{service,repo,queries,releases,event};
}

test('aborted call never acquires a connection; a late pool lease is discarded without SQL',async()=>{
 const abort=new AbortController();abort.abort();let connects=0;
 await assert.rejects(()=>withPrivacyClient({connect:async()=>{connects++;throw Error('must not acquire');}},context(abort),async()=>{}),unavailable);
 assert.equal(connects,0);
 const acquired=gate(),started=gate(),controller=new AbortController(),released=[];let queries=0;
 const running=withPrivacyClient({connect(){started.resolve();return acquired.promise;}},context(controller),db=>db.query('SELECT 1'));
 await started.promise;controller.abort();await assert.rejects(running,unavailable);
 acquired.resolve({query(){queries++;},release(value){released.push(value);}});await immediate();
 assert.deepEqual(released,[true]);assert.equal(queries,0);
});

test('aborting an issued query discards its lease and blocks its late COMMIT continuation',async()=>{
 const queryStarted=gate(),query=gate(),controller=new AbortController(),sql=[],released=[];
 const client={query(text){sql.push(text);if(text==='SELECT held'){queryStarted.resolve();return query.promise;}return Promise.resolve({rows:[]});},release(value){released.push(value);}};
 const running=withPrivacyClient({connect:async()=>client},context(controller),async db=>{await db.query('SELECT held');await db.query('COMMIT');});
 await queryStarted.promise;controller.abort();await assert.rejects(running,unavailable);query.resolve({rows:[]});await immediate();
 assert.deepEqual(sql,['SELECT held']);assert.deepEqual(released,[true]);
});

test('a completed lease cannot be reused and concurrent queries cannot enter the pg queue',async()=>{
 const queries=[],held=gate(),started=gate(),released=[];let escaped;
 const client={async query(text){queries.push(text);if(text==='SELECT held'){started.resolve();return held.promise;}return{rows:[]};},release(value){released.push(value);}};
 await withPrivacyClient({connect:async()=>client},context(),async db=>{
  escaped=db;const first=db.query('SELECT held');await started.promise;
  await assert.rejects(()=>db.query('SELECT must_not_queue'),/sequentially/);held.resolve({rows:[]});await first;
 });
 await assert.rejects(()=>escaped.query('SELECT escaped'),unavailable);
 assert.deepEqual(queries,['SELECT held']);assert.deepEqual(released,[undefined]);
});

test('nested phases preserve the original deadline and actually abort a stalled phase signal',async()=>{
 const outer=new PrivacyCall(undefined,1000),started=gate(),held=gate();let signal,deadline;
 try{
  const running=privacyPhase(outer.call,call=>{signal=call.signal;deadline=call.deadlineUnixMs;started.resolve();return held.promise;},25);
  await started.promise;await assert.rejects(running,unavailable);
  assert.equal(signal.aborted,true);assert.ok(deadline<=outer.call.deadlineUnixMs);assert.equal(outer.call.signal.aborted,false);
  held.resolve();
 }finally{outer.dispose();}
});

test('expired intent rejection cannot be turned into a late acceptance COMMIT',async()=>{
 const before=gate(),finish=gate(),controller=new AbortController();let after=0,signal;
 const f=serviceFixture({journal:{beforeCommit:async(_event,call)=>{signal=call.signal;before.resolve();await finish.promise;},afterCommit:async()=>{after++;}}});
 const running=f.service.request(identity(),input(),context(controller));await before.promise;controller.abort();await assert.rejects(running,unavailable);
 assert.equal(signal.aborted,true);finish.resolve();await immediate();
 const acceptance=f.queries.find(q=>q.sql.includes('privacy_journal_request')).id;
 assert.equal(f.queries.some(q=>q.id===acceptance&&q.sql==='COMMIT'),false);assert.equal(after,0);
 assert.ok(f.releases.some(q=>q.id===acceptance&&q.discard===true));
});

test('reviewed deletion input and retention are snapshotted before asynchronous provider checks',async()=>{
 const providerStarted=gate(),provider=gate(),body=input(),original=structuredClone(body),policy=retention();
 const f=serviceFixture({policy,provider:{assertAvailable:async()=>{providerStarted.resolve();await provider.promise;}}});
 const running=f.service.request(identity(),body);await providerStarted.promise;
 body.clientKey=randomUUID();body.households.push({householdId:randomUUID(),organizer:'archive',shops:[],eraseChildProfiles:[]});policy.receiptRetentionDays=365;
 provider.resolve();await running;
 const accepted=f.queries.find(q=>q.sql.includes('privacy_journal_request')).values;
 assert.equal(accepted[3],original.clientKey);assert.equal(accepted[6],'[]');assert.equal(accepted[7],1);
 assert.equal(JSON.parse(accepted[9]).policy.receiptRetentionDays,1);
 assert.ok(f.queries.filter(q=>q.sql.includes('privacy_status')).every(q=>q.values[0]===original.clientKey));
});

test('durable-port calls receive live server-owned phase contexts; invalid status capability cannot reconcile',async()=>{
 const calls=[];const f=serviceFixture({journal:Object.fromEntries(['beforeCommit','afterCommit','acknowledgeJob'].map(name=>[name,async(_value,call)=>{assert.ok(call.signal instanceof AbortSignal);assert.equal(call.signal.aborted,false);calls.push(name);}]))});
 await f.service.request(identity(),input());assert.deepEqual(calls,['beforeCommit','afterCommit','acknowledgeJob']);
 let acknowledgements=0;const invalid=serviceFixture({query:async()=>({rows:[{value:null}]}),journal:{acknowledgeJob:async()=>{acknowledgements++;}}});
 await assert.rejects(()=>invalid.service.status(randomUUID(),'b'.repeat(43)),error=>error.status===404);assert.equal(acknowledgements,0);
});

test('a cancelled ambiguous COMMIT starts no observation; its original receipt can still recover',async()=>{
 const commitStarted=gate(),commit=gate(),controller=new AbortController();let acceptedClient,committed=false,observations=0;
 const f=serviceFixture({query:async(sql,_values,id)=>{
  if(sql.includes('privacy_journal_request')){acceptedClient=id;return{rows:[{event:{eventId:randomUUID()}}]};}
  if(sql==='COMMIT'&&id===acceptedClient){commitStarted.resolve();await commit.promise;committed=true;}
  if(sql.includes('privacy_status'))return{rows:[{value:committed?{status:'pending'}:null}]};return{rows:[]};
 },journal:{afterCommit:async()=>{observations++;}}});
 const body=input(),running=f.service.request(identity(),body,context(controller));await commitStarted.promise;controller.abort();await assert.rejects(running,unavailable);
 commit.resolve();await immediate();assert.equal(observations,0);
 assert.equal((await f.service.status(body.clientKey,body.statusToken)).status,'pending');
});

async function listening(t,server){await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));t.after(async()=>{server.closeAllConnections();await new Promise(resolve=>server.close(resolve));});return'http://127.0.0.1:'+server.address().port;}

test('provider abort reaches an actual fetch body and never starts the subsequent DELETE',async t=>{
 const opened=gate(),closed=gate(),methods=[],controller=new AbortController(),who=randomUUID();
 const url=await listening(t,createServer((req,res)=>{methods.push(req.method);res.writeHead(200,{'Content-Type':'application/json'});res.write('{"id":');res.on('close',()=>closed.resolve());opened.resolve();}));
 const provider=new SupabaseAccountDeletionProvider({url:'https://provider.fixture.invalid',secretKey:'sb_secret_'+ 'x'.repeat(32)},(_input,init)=>fetch(url,init));
 const running=provider.deleteAccount(who,context(controller));await opened.promise;controller.abort();await assert.rejects(running,unavailable);await closed.promise;
 assert.deepEqual(methods,['GET']);
});

test('normal HTTP body completion leaves the deletion context active through the response',async t=>{
 const started=gate(),finish=gate(),who=identity();let call;
 const repo={};const url=await listening(t,createHTTPServer({repository:repo,verifier:{verify:async()=>who},privacy:{request:async(_who,_input,value)=>{call=value;started.resolve();await finish.promise;return{status:'pending'};}}}));
 const response=fetch(url+'/v1/privacy/deletions',{method:'POST',headers:{Authorization:'Bearer fixture-token','Content-Type':'application/json','X-Deadline-Unix-Ms':'1'},body:JSON.stringify(input())});
 await started.promise;await immediate();assert.equal(call.signal.aborted,false);assert.ok(call.deadlineUnixMs>Date.now());finish.resolve();assert.equal((await response).status,202);assert.equal(call.signal.aborted,false);
});

test('disconnecting HTTP after its full body aborts the private call without crashing the server',async t=>{
 const started=gate(),aborted=gate(),controller=new AbortController(),who=identity();
 const url=await listening(t,createHTTPServer({repository:{},verifier:{verify:async()=>who},privacy:{request:async(_who,_input,call)=>{started.resolve();await new Promise((_,reject)=>call.signal.addEventListener('abort',()=>{aborted.resolve();reject(new ServiceError(503,'deletion_unavailable','Keep the receipt.'));},{once:true}));}}}));
 const request=fetch(url+'/v1/privacy/deletions',{method:'POST',headers:{Authorization:'Bearer fixture-token','Content-Type':'application/json'},body:JSON.stringify(input()),signal:controller.signal});
 await started.promise;controller.abort();await assert.rejects(request);await aborted.promise;
 assert.equal((await fetch(url+'/health')).status,200);
});

for(const kind of ['bearer','browser','scoped-cookie'])test(`disconnect during ${kind} authentication prevents a late lifecycle continuation`,async t=>{
 const started=gate(),auth=gate(),closed=gate(),controller=new AbortController(),who=identity();let requests=0;
 const verifier={verify:async()=>{started.resolve();return auth.promise;}};
 const browserAuth={authenticate:async()=>{started.resolve();await auth.promise;return{identity:who,csrf:'fixture-csrf'};}};
 const repository={webIdentity:async()=>{started.resolve();await auth.promise;return{auth:{identity:who},csrf:'fixture-csrf'};}};
 const server=createHTTPServer({repository,verifier,webOrigin:'https://web.fixture.invalid',...(kind==='browser'?{browserAuth}:{}),privacy:{request:async()=>{requests++;return{status:'pending'};}}});
 server.on('request',(_req,res)=>res.once('close',()=>closed.resolve()));
 const url=await listening(t,server),headers={'Content-Type':'application/json',Origin:'https://web.fixture.invalid','X-CSRF-Token':'fixture-csrf'};
 if(kind==='bearer')headers.Authorization='Bearer fixture-token';
 else headers.Cookie=kind==='browser'?'__Host-ritc_auth=fixture-cookie':'ritc_session=fixture-cookie';
 const response=fetch(url+'/v1/privacy/deletions',{method:'POST',headers,body:JSON.stringify(input()),signal:controller.signal});
 await started.promise;controller.abort();await assert.rejects(response);await closed.promise;
 auth.resolve(who);await immediate();assert.equal(requests,0);
});
