import assert from 'node:assert/strict';
import test from 'node:test';
import {JSDOM} from 'jsdom';
import {IDBFactory} from 'fake-indexeddb';
import {API,ApiError,consumeInvitation,prepareProposal} from '../dist/api.js';
import {Outbox,scopeFor} from '../dist/outbox.js';
import {WebApp} from '../dist/app.js';

const session = () => ({authenticated:true,role:'contributor',household:{id:'household-a',label:'Family A'},memberId:'member-a',shopId:'shop-a',replayWindow:{id:'window-a',expiresAt:'2099-01-01T00:00:00Z'},csrf:'csrf-test',enrolled:true,queueConsent:false});
const own = () => ({requestId:'request-a',shopId:'shop-original',revision:1,originalItem:'No-salt frijoles',ownQuantity:'two 15 oz cans',authoredAt:'2026-01-01T12:00:00Z',receivedAt:'2026-01-01T12:00:01Z',route:'current',status:'pending',ownActionAllowed:true,clarification:null,followupTo:null});
const command = () => ({v:1,replayWindow:'window-a',clientKey:'stable-key',shopId:'shop-a',kind:'request.send',base:{shopRevision:0,authorityEpoch:0},body:{clientRequestId:'request-client',originalItem:'Beans',ownQuantity:null,authoredAt:'2026-01-01T12:00:00Z',route:'current'}});
async function waitForIdle(root) {
 const deadline=Date.now()+3000;
 while(root.querySelector('main')?.getAttribute('aria-busy')==='true'){
  assert.ok(Date.now()<deadline,'the page did not finish its action');
  await new Promise(resolve=>setTimeout(resolve,5));
 }
}
const setup = async (api,language='en',outbox=new Outbox(new IDBFactory())) => {
 const dom=new JSDOM('<div id="app"></div>',{url:'https://food.example/invite'});
 Object.defineProperty(dom.window.navigator,'language',{value:language});
 const root=dom.window.document.getElementById('app');
 const app=new WebApp(root,api,outbox);await app.start();return {dom,root,app};
};
const click=(root,label)=>{const b=[...root.querySelectorAll('button')].find(b=>b.textContent===label);assert.ok(b,`button ${label}`);b.click();};
const type=(dom,id,value)=>{const input=dom.window.document.getElementById(id);assert.ok(input,id);input.value=value;input.dispatchEvent(new dom.window.Event('input',{bubbles:true}));};
const submit=(root,dom)=>root.querySelector('form').dispatchEvent(new dom.window.Event('submit',{cancelable:true,bubbles:true}));
const fakeAPI=(overrides={})=>({authState:async()=>({available:true,authenticated:true,csrf:'csrf-test'}),session:async()=>session(),requests:async()=>[],receivedProposals:async()=>({proposals:[],nextCursor:null}),command:async()=>{},logout:async()=>{},...overrides});

test('only a generation and its live expiry authorize storage in a decoded session',async()=>{
 const base={...session(),queueConsent:false,capabilities:['own_requests','request_queue_permission']};
 const grant=crypto.randomUUID(),until=new Date(Date.now()+3600000).toISOString();
 const parse=data=>new API(async()=>new Response(JSON.stringify(data),{status:200})).session();
 assert.equal((await parse({...base,queueConsent:true})).queueConsent,false); // Older or malformed flag alone.
 assert.equal((await parse({...base,requestQueueGrant:grant,requestQueueUntil:until})).queueConsent,true);
 assert.equal((await parse({...base,requestQueueGrant:grant,requestQueueUntil:'2000-01-01T00:00:00Z'})).queueConsent,false);
 await assert.rejects(parse({...base,requestQueueGrant:grant}));
 await assert.rejects(parse({...base,requestQueueGrant:'invalid',requestQueueUntil:until}));
 await assert.rejects(parse({...base,capabilities:[],requestQueueGrant:grant,requestQueueUntil:until}));
});

test('queue opt-in and opt-out validate the raw scoped bootstrap acknowledgment', async()=>{
 const current=session(),grant=crypto.randomUUID(),until=new Date(Date.now()+3600000).toISOString();
 const base={household:current.household,memberId:current.memberId,capabilities:['request_queue_permission'],queueConsent:false};
 const active={...base,requestQueueGrant:grant,requestQueueUntil:until};
 const change=(enabled,data)=>new API(async(path,init)=>{
   assert.equal(path,'/v1/households/household-a/devices/current/request-queue');
   assert.equal(init.method,'PUT');assert.deepEqual(JSON.parse(init.body),{enabled});
   return Response.json(data);
 }).setRequestQueue(current,enabled);
 await change(true,active);await change(false,base);
 for(const bad of [base,{...base,queueConsent:true},{...active,memberId:'member-b'},{...active,household:{id:'other'}},
   {...active,requestQueueUntil:undefined},{...active,requestQueueUntil:'2000-01-01T00:00:00Z'},{...active,capabilities:[]}]){
   await assert.rejects(change(true,bad));
 }
 await assert.rejects(change(false,active));
});

test('invitation secrets leave URL before a request and never enter storage',()=>{
 const dom=new JSDOM('',{url:'https://food.example/invite?token=query-secret#token=fragment-secret'});
 assert.equal(consumeInvitation(dom.window.location,dom.window.history),'fragment-secret');
 assert.equal(dom.window.location.href,'https://food.example/invite');
 assert.equal(dom.window.localStorage.length,0);
});

test('companion links accept the trailing slashes served by the host',async(t)=>{
 for(const path of ['/requests/','/invite/','/view/']){
  const dom=new JSDOM('<div id="app"></div>',{url:`https://food.example${path}`});
  t.after(()=>dom.window.close());
  const root=dom.window.document.getElementById('app');
  let reads=0;
  const api=fakeAPI({session:async()=>{reads++;return session();}});
  await new WebApp(root,api,new Outbox(new IDBFactory())).start();
  assert.equal(reads,1,path);
  assert.match(root.querySelector('h1').textContent,/Ask the shopper/,path);
 }
});

test('API is same-origin, no-store, CSRF protected; own projection discards private keys',async()=>{
 const calls=[];const api=new API(async(path,options)=>{calls.push({path,options});return new Response(JSON.stringify(path.endsWith('/mine')?{requests:[{...own(),budgetMinor:3800,otherAuthors:['private']}],nextCursor:null}:{operationId:'op-a',kind:'request.send',request:{...own(),shopId:'shop-a'}}),{status:200});});
 const rows=await api.requests(session());assert.equal('budgetMinor' in rows[0],false);assert.equal('otherAuthors' in rows[0],false);
 await api.command(session(),command());const c=calls[1];assert.equal(c.options.credentials,'same-origin');assert.equal(c.options.cache,'no-store');assert.equal(c.options.headers['X-CSRF-Token'],'csrf-test');assert.equal(c.options.headers.Authorization,undefined);
});

test('server errors never become successful receipts',async()=>{
 const api=new API(async()=>new Response(JSON.stringify({error:{code:'access_ended'}}),{status:403}));
 await assert.rejects(api.command(session(),command()),e=>e instanceof ApiError&&e.status===403);
});

test('outbox requires enrollment, server permission, and explicit local consent',async()=>{
 const outbox=new Outbox(new IDBFactory());const s=session();const p={id:'stable-key',scope:scopeFor(s),command:command(),createdAt:'2026-01-01'};
 await assert.rejects(outbox.put(p,s,true));s.queueConsent=true;
 await assert.rejects(outbox.put(p,s,false));await outbox.put(p,s,true);
 assert.equal((await outbox.list(scopeFor(s))).length,1);assert.equal((await outbox.list('other/person')).length,0);
 await outbox.clear();assert.equal((await outbox.list(scopeFor(s))).length,0);
});

test('Spanish request review preserves original food names and unknown quantity',async()=>{
 const sent=[];const {root,dom}=await setup(fakeAPI({command:async(s,c)=>sent.push(c)}),'es-US');
 assert.match(root.textContent,/Pedir a quien hace la compra/);type(dom,'item','No-salt frijoles');submit(root,dom);
 assert.match(root.textContent,/No-salt frijoles/);assert.match(root.textContent,/Cantidad sin confirmar/);
 submit(root,dom);await waitForIdle(root);assert.equal(sent.length,1);assert.equal(sent[0].body.originalItem,'No-salt frijoles');assert.equal(sent[0].body.ownQuantity,null);assert.match(root.textContent,/Recibida por quien hace la compra/);
});

test('offline unconsented send is not saved and retry preserves operation key',async()=>{
 const sent=[];const {root,dom}=await setup(fakeAPI({command:async(s,c)=>{sent.push(c);throw new ApiError('network',0);}}));
 type(dom,'item','Milk');submit(root,dom);submit(root,dom);await waitForIdle(root);assert.match(root.textContent,/Not saved/);assert.match(root.textContent,/Milk/);
 submit(root,dom);await waitForIdle(root);assert.equal(sent.length,2);assert.equal(sent[0].clientKey,sent[1].clientKey);assert.doesNotMatch(root.textContent,/Received by the shopper/);
});

test('explicitly consented disconnected request is durably queued, never labeled received',async()=>{
 const s={...session(),queueConsent:true};const {root,dom}=await setup(fakeAPI({session:async()=>s,command:async()=>{throw new ApiError('network',0);}}));
 const consent=root.querySelector('input[type=checkbox]');consent.checked=true;consent.dispatchEvent(new dom.window.Event('change'));
 type(dom,'item','Rice');submit(root,dom);submit(root,dom);await waitForIdle(root);
 assert.match(root.textContent,/Waiting to send from this browser/);assert.doesNotMatch(root.textContent,/Received by the shopper/);
});

test('a request reviewed after disconnect survives reload and retries only after fresh authorization',async()=>{
 const s={...session(),queueConsent:true},outbox=new Outbox(new IDBFactory()),sent=[];
 let connected=true;
 const api=fakeAPI({session:async()=>{
  if(!connected)throw new ApiError('network',0);
  return s;
 },command:async(_session,body)=>{assert.equal(connected,true);sent.push(body);}});
 const {root,dom}=await setup(api,'en',outbox);
 connected=false;
 const consent=root.querySelector('input[type=checkbox]');consent.checked=true;consent.dispatchEvent(new dom.window.Event('change'));
 type(dom,'item','Rice');submit(root,dom);submit(root,dom);await waitForIdle(root);
 const [pending]=await outbox.list(scopeFor(s));
 assert.equal(pending?.command.body.originalItem,'Rice');
 assert.match(root.textContent,/Waiting to send from this browser/);
 assert.doesNotMatch(root.textContent,/Received by the shopper/);
 assert.equal(sent.length,0);

 const reloaded=await setup(api,'en',outbox);
 assert.doesNotMatch(reloaded.root.textContent,/Rice/);
 connected=true;await reloaded.app.start();
 assert.match(reloaded.root.textContent,/Rice/);
 assert.equal(sent.length,0);
 click(reloaded.root,'Retry');await waitForIdle(reloaded.root);
 assert.deepEqual(sent,[pending.command]);
 assert.deepEqual(await outbox.list(scopeFor(s)),[]);
 assert.match(reloaded.root.textContent,/Received by the shopper/);
});

test('offline queueing still requires consent and an unexpired replay window',async()=>{
 for(const {consented,expiresAt} of [
  {consented:false,expiresAt:'2099-01-01T00:00:00Z'},
  {consented:true,expiresAt:'2000-01-01T00:00:00Z'},
 ]){
  const s={...session(),queueConsent:true,replayWindow:{id:'window-a',expiresAt}};
  const outbox=new Outbox(new IDBFactory());
  let connected=true;
  const {root,dom}=await setup(fakeAPI({session:async()=>{
   if(!connected)throw new ApiError('network',0);
   return s;
  },command:async()=>assert.fail('No offline request should be sent')}),'en',outbox);
  connected=false;
  const consent=root.querySelector('input[type=checkbox]');consent.checked=consented;consent.dispatchEvent(new dom.window.Event('change'));
  type(dom,'item','Rice');submit(root,dom);submit(root,dom);await waitForIdle(root);
  assert.deepEqual(await outbox.list(scopeFor(s)),[]);
  assert.match(root.textContent,/Rice/);
  assert.doesNotMatch(root.textContent,/Waiting to send from this browser|Received by the shopper/);
 }
});

test('refresh hides the previous member as soon as the server reports a different or ended session',async()=>{
 for(const next of [null,{...session(),memberId:'member-b'}]){
  let current=session(),observed;
  const outbox=new Outbox(new IDBFactory());
  const {root,app}=await setup(fakeAPI({
   session:async()=>current,
   requests:async()=>current?.memberId==='member-a'?[own()]:[],
   authState:async()=>{observed=root.textContent;return {authenticated:false,available:true};}
  }),'en',outbox);
  assert.match(root.textContent,/No-salt frijoles/);
  outbox.retainScope=async()=>{observed=root.textContent;};
  current=next;await app.start();
  assert.equal(typeof observed,'string');
  assert.doesNotMatch(observed,/No-salt frijoles/);
  assert.doesNotMatch(root.textContent,/No-salt frijoles/);
 }
});

test('a command refusal hides private content even if the saved outbox cannot be removed',async()=>{
 for(const status of [401,403]){
  const outbox=new Outbox(new IDBFactory());
  const s={...session(),queueConsent:true};
  let duringRecovery,puts=0;
  const put=outbox.put.bind(outbox);
  outbox.put=async(...args)=>{await put(...args);puts++;};
  outbox.remove=async()=>{throw new DOMException('Storage denied','SecurityError');};
  const api=fakeAPI({
   session:async()=>s,
   command:async()=>{throw new ApiError(status===403?'access_ended':'session_needed',status);},
   authState:async()=>{duringRecovery=root.textContent;return {authenticated:false,available:true};}
  });
  const {root,dom}=await setup(api,'en',outbox);
  outbox.clear=async()=>{duringRecovery=root.textContent;throw new DOMException('Storage denied','SecurityError');};
  root.querySelector('input[type=checkbox]').click();
  type(dom,'item','Private test wording');submit(root,dom);submit(root,dom);await waitForIdle(root);
  assert.equal(puts,1);
  assert.doesNotMatch(root.textContent,/Private test wording|Ask the shopper/);
  assert.equal(typeof duringRecovery,'string');
  assert.doesNotMatch(duringRecovery,/Private test wording|Ask the shopper/);
  assert.match(root.textContent,status===403?/Access has ended.*Clear site data/:/Sign in again/);
 }
});

test('an explicit access refusal cannot queue against the earlier session',async()=>{
 const s={...session(),queueConsent:true},outbox=new Outbox(new IDBFactory());
 let revoked=false;
 const {root,dom}=await setup(fakeAPI({session:async()=>{
  if(revoked)throw new ApiError('access_ended',403);
  return s;
 },command:async()=>assert.fail('A revoked request must never be sent')}),'en',outbox);
 const consent=root.querySelector('input[type=checkbox]');consent.checked=true;consent.dispatchEvent(new dom.window.Event('change'));
 type(dom,'item','Private draft');submit(root,dom);revoked=true;submit(root,dom);await waitForIdle(root);
 assert.deepEqual(await outbox.list(scopeFor(s)),[]);
 assert.doesNotMatch(root.textContent,/Private draft|Waiting to send from this browser/);
 assert.match(root.textContent,/Access has ended/);
});

test('authorized Refresh clears an old mutation access denial without discarding storage warnings',async t=>{
 for(const storageClearFails of [false,true]){
  const original={...session(),queueConsent:true},outbox=new Outbox(new IDBFactory());
  let current=original,connected=true,commands=0;
  const {root,dom}=await setup(fakeAPI({
   session:async()=>{if(!connected)throw new ApiError('network',0);return current;},
   command:async()=>{commands++;assert.fail('A previous actor request must never be delivered');},
   authState:async()=>({available:false,authenticated:false})
  }),'en',outbox);
  t.after(()=>dom.window.close());
  root.querySelector('input[type=checkbox]').click();
  type(dom,'item','Previous actor private request');submit(root,dom);
  connected=false;submit(root,dom);await waitForIdle(root);
  assert.equal((await outbox.list(scopeFor(original))).length,1);
  current={...original,memberId:'member-b'};connected=true;
  if(storageClearFails)outbox.clear=async()=>{throw new DOMException('Storage denied','SecurityError');};
  click(root,'Retry');await waitForIdle(root);
  assert.match(root.textContent,/Access has ended/);
  assert.doesNotMatch(root.textContent,/Previous actor private request|Ask the shopper/);
  if(!storageClearFails)assert.deepEqual(await outbox.list(scopeFor(original)),[]);

  current=null;click(root,'Refresh');await waitForIdle(root);
  assert.match(root.textContent,/Access has ended/,'Anonymous refresh must not dismiss the denial');
  assert.equal(root.querySelector('#item'),null);
  current={...original,memberId:'member-b'};click(root,'Refresh');await waitForIdle(root);
  assert.ok(root.querySelector('#item'),'The newly authorized contributor can draft their own request');
  assert.doesNotMatch(root.textContent,/Previous actor private request/);
  if(storageClearFails)assert.match(root.textContent,/Access has ended.*Clear site data/);
  else assert.doesNotMatch(root.textContent,/Access has ended/,'Successful authenticated refresh must remove the stale denial');
  assert.equal(commands,0);
 }
});

test('pending edit carries request revision; withdrawal requires confirmation',async()=>{
 let rows=[own()];const sent=[];const {root,dom}=await setup(fakeAPI({requests:async()=>rows,command:async(s,c)=>{sent.push(c);}}));
 click(root,'Edit');type(dom,'amount','three cans');submit(root,dom);submit(root,dom);await waitForIdle(root);
 assert.equal(sent[0].kind,'request.edit');assert.equal(sent[0].base.requestRevision,1);assert.equal(sent[0].shopId,'shop-original');assert.equal(sent[0].body.ownQuantity,'three cans');
 click(root,'Withdraw');assert.equal(sent.length,1);click(root,'Confirm withdrawal');await waitForIdle(root);assert.equal(sent[1].kind,'request.withdraw');
});

test('received is retained if refresh fails after a committed send',async()=>{
 let reads=0;const {root,dom}=await setup(fakeAPI({requests:async()=>{if(++reads>1)throw new ApiError('network',0);return [];}}));
 type(dom,'item','Eggs');submit(root,dom);submit(root,dom);await waitForIdle(root);assert.match(root.textContent,/Received by the shopper/);assert.doesNotMatch(root.textContent,/Not saved/);
});

test('revocation purges household display and exposes no cached request',async()=>{
 let denied=false;const {root}=await setup(fakeAPI({requests:async()=>{if(denied)throw new ApiError('access_ended',403);return [own()];}}));
 assert.match(root.textContent,/No-salt frijoles/);denied=true;click(root,'Refresh');await waitForIdle(root);assert.doesNotMatch(root.textContent,/No-salt frijoles|Family A/);assert.match(root.textContent,/Access has ended/);
});

test('helper content is inert text, read-only grants cannot propose or show adult routes',async()=>{
 const api=fakeAPI({session:async()=>({...session(),role:'helper',grantId:'grant-a'}),view:async()=>({grantId:'grant-a',shopId:'shop-a',shopLabel:'Tuesday',revision:2,asOf:'2026-01-01T12:00:00Z',expiresAt:'2099-01-01T00:00:00Z',canPropose:false,instructions:[{item:'<img src=x onerror=alert(1)>',amount:'4 wraps',action:'Reserve two for lunch'}]})});
 const {root}=await setup(api);
 assert.match(root.textContent,/Revision: 2/);assert.match(root.textContent,/As of: [^:]*2026/);
 const spanish=await setup(api,'es-US');
 assert.match(spanish.root.textContent,/Versión: 2/);assert.match(spanish.root.textContent,/Actualizado: [^:]*2026/);
 assert.equal(root.querySelector('img'),null);assert.match(root.textContent,/Reserve two for lunch/);assert.match(root.textContent,/read-only/);assert.doesNotMatch(root.textContent,/Ask the shopper|Send proposal/);
});

test('editor proposal is submitted against displayed revision and cannot apply a basket change',async()=>{
 const proposals=[];const {root,dom}=await setup(fakeAPI({session:async()=>({...session(),role:'editor',grantId:'grant-a'}),view:async()=>({grantId:'grant-a',shopId:'shop-a',shopLabel:'Tuesday',revision:7,asOf:'2026-01-01T12:00:00Z',expiresAt:'2099-01-01T00:00:00Z',canPropose:true,instructions:[]}),sendProposal:async(...args)=>{proposals.push(args);return {proposalId:'proposal-a',grantId:'grant-a',baseRevision:7,status:'pending'};}}));
 type(dom,'correction','Keep two for lunch');submit(root,dom);await waitForIdle(root);assert.equal(proposals[0][1].baseRevision,7);assert.equal(proposals[0][1].correction,'Keep two for lunch');assert.match(root.textContent,/shopper must review/);
});

test('a 200 response without the durable author receipt is not accepted',async()=>{
 const api=new API(async()=>new Response(JSON.stringify({ok:true}),{status:200}));
 await assert.rejects(api.command(session(),command()),e=>e.code==='invalid_response');
});

test('a replay window change leaves the queued intent unsent for fresh review',async()=>{
 let attempts=0;let current={...session(),queueConsent:true};
 const {root,dom}=await setup(fakeAPI({session:async()=>current,command:async()=>{attempts++;throw new ApiError('network',0);}}));
 const consent=root.querySelector('input[type=checkbox]');consent.checked=true;consent.dispatchEvent(new dom.window.Event('change'));
 type(dom,'item','Beans');submit(root,dom);submit(root,dom);await waitForIdle(root);
 current={...current,replayWindow:{id:'new-window',expiresAt:'2099-01-01T00:00:00Z'}};
 click(root,'Retry');await waitForIdle(root);assert.equal(attempts,1);assert.match(root.textContent,/needs a new review/);
});

test('storage quota errors never turn an offline request into saved or received',async()=>{
 const dom=new JSDOM('<div id="app"></div>',{url:'https://food.example'});const root=dom.window.document.getElementById('app');
 const denied={list:async()=>[],clear:async()=>{},put:async()=>{throw new Error('QuotaExceededError');}};
 const app=new WebApp(root,fakeAPI({session:async()=>({...session(),queueConsent:true}),command:async()=>{throw new ApiError('network',0);}}),denied);
 await app.start();const consent=root.querySelector('input[type=checkbox]');consent.checked=true;consent.dispatchEvent(new dom.window.Event('change'));
 type(dom,'item','Milk');submit(root,dom);submit(root,dom);await waitForIdle(root);assert.match(root.textContent,/Not saved/);assert.match(root.textContent,/Milk/);assert.doesNotMatch(root.textContent,/Waiting to send from this browser|Received by the shopper/);
});

test('denying access to indexedDB itself still lets an invite open and a contributor send online',async(t)=>{
 const previous=Object.getOwnPropertyDescriptor(globalThis,'indexedDB');
 Object.defineProperty(globalThis,'indexedDB',{configurable:true,get(){throw new DOMException('Storage denied','SecurityError');}});
 t.after(()=>{if(previous)Object.defineProperty(globalThis,'indexedDB',previous);else delete globalThis.indexedDB;});
 const dom=new JSDOM('<div id="app"></div>',{url:'https://food.example/invite#token=invite-code'});
 t.after(()=>dom.window.close());
 const root=dom.window.document.getElementById('app');
 const joined={...session(),queueConsent:true};
 let current=null;const sent=[];
 const api=fakeAPI({session:async()=>current,redeem:async token=>{
  assert.equal(token,'invite-code');return {householdId:joined.household.id,memberId:joined.memberId,role:'contributor'};
 },activateSession:async()=>{current=joined;},command:async(_s,c)=>sent.push(c)});
 const token=consumeInvitation(dom.window.location,dom.window.history);
 const app=new WebApp(root,api,undefined,token);
 await app.start();assert.equal(dom.window.location.hash,'');
 root.querySelector('#adult-attestation').click();submit(root,dom);await waitForIdle(root);
 assert.match(root.textContent,/Ask the shopper/);assert.match(root.textContent,/pending requests could not be opened/);
 root.querySelector('input[type=checkbox]').click();
 type(dom,'item','Rolled oats');submit(root,dom);submit(root,dom);await waitForIdle(root);
 assert.equal(sent.length,1);assert.equal(sent[0].body.originalItem,'Rolled oats');
 assert.match(root.textContent,/Received by the shopper/);
});

test('eviction during an open session replaces the waiting notice after refresh',async()=>{
 const s={...session(),queueConsent:true},factory=new IDBFactory(),outbox=new Outbox(factory);
 let attempts=0;
 const api=fakeAPI({session:async()=>s,command:async()=>{attempts++;throw new ApiError('network',0);}});
 const {dom,root,app}=await setup(api,'en',outbox);
 root.querySelector('input[type=checkbox]').click();
 type(dom,'item','Queued oats');submit(root,dom);submit(root,dom);await waitForIdle(root);
 assert.match(root.textContent,/Waiting to send from this browser/);
 const [database]=await factory.databases();
 await new Promise((resolve,reject)=>{
  const deletion=factory.deleteDatabase(database.name);
  deletion.onsuccess=resolve;deletion.onerror=()=>reject(deletion.error);
 });
 await app.start();assert.match(root.textContent,/no longer stored on this browser/);
 assert.doesNotMatch(root.textContent,/Waiting to send|Queued oats|Received by the shopper/);
 const reloaded=await setup(api,'en',outbox);
 assert.doesNotMatch(reloaded.root.textContent,/Waiting to send|Queued oats|Received by the shopper/);
 assert.equal(attempts,1);
});

test('a cold reload under a different contributor cannot recover the previous queue',async()=>{
 const original={...session(),queueConsent:true},outbox=new Outbox(new IDBFactory());
 let current=original,attempts=0;
 const api=fakeAPI({session:async()=>current,command:async()=>{attempts++;throw new ApiError('network',0);}});
 const {root,dom}=await setup(api,'en',outbox);
 root.querySelector('input[type=checkbox]').click();
 type(dom,'item','Private oats');submit(root,dom);submit(root,dom);await waitForIdle(root);
 assert.equal((await outbox.list(scopeFor(original))).length,1);
 current={...original,memberId:'second-member'};
 const reloaded=await setup(api,'en',outbox);
 assert.match(reloaded.root.textContent,/Ask the shopper/);
 assert.doesNotMatch(reloaded.root.textContent,/Private oats|Waiting to send|Pending requests/);
 assert.equal(reloaded.root.querySelector('input[type=checkbox]').checked,false);
 assert.deepEqual(await outbox.list(scopeFor(original)),[]);assert.equal(attempts,1);
});

test('a confirmed queued retry keeps its receipt if browser storage fails during cleanup',async()=>{
 const s={...session(),queueConsent:true},outbox=new Outbox(new IDBFactory());
 let attempts=0;
 const api=fakeAPI({session:async()=>s,command:async()=>{if(++attempts===1)throw new ApiError('network',0);}});
 const {dom,root}=await setup(api,'en',outbox);
 root.querySelector('input[type=checkbox]').click();
 type(dom,'item','Queued rice');submit(root,dom);submit(root,dom);await waitForIdle(root);
 outbox.remove=async()=>{throw new DOMException('Storage denied','SecurityError');};
 click(root,'Retry');await waitForIdle(root);
 assert.match(root.textContent,/Received by the shopper/);
 assert.match(root.textContent,/Received; local cleanup pending/);
 assert.doesNotMatch(root.textContent,/Not saved|Waiting to send from this browser/);
});

for(const scenario of ['live replay window','expired replay window','changed member']){
 test(`retrying local cleanup after a confirmed receipt: ${scenario}`,async()=>{
  const original={...session(),queueConsent:true},outbox=new Outbox(new IDBFactory());
  let current=original,posts=0,removals=0;
  const remove=outbox.remove.bind(outbox);
  outbox.remove=async id=>{
   if(++removals===1)throw new DOMException('Storage denied','SecurityError');
   await remove(id);
  };
  const api=fakeAPI({session:async()=>current,command:async()=>{posts++;}});
  const {dom,root}=await setup(api,'en',outbox);
  root.querySelector('input[type=checkbox]').click();
  type(dom,'item','Confirmed rice');submit(root,dom);submit(root,dom);await waitForIdle(root);
  assert.match(root.textContent,/Received; local cleanup pending/);
  if(scenario==='expired replay window')current={...original,replayWindow:{...original.replayWindow,expiresAt:'2020-01-01T00:00:00Z'}};
  if(scenario==='changed member')current={...original,memberId:'second-member'};
  click(root,'Retry');await waitForIdle(root);
  assert.equal(posts,1);
  if(scenario==='changed member'){
   assert.equal(removals,1);assert.match(root.textContent,/Access has ended/);
   assert.doesNotMatch(root.textContent,/Confirmed rice|Received by the shopper/);
  }else{
   assert.equal(removals,2);assert.match(root.textContent,/Received by the shopper/);
   assert.doesNotMatch(root.textContent,/Confirmed rice|needs a new review|local cleanup pending/);
  }
  assert.deepEqual(await outbox.list(scopeFor(original)),[]);
 });
}

test('expired helper content is removed without requiring a network response',async()=>{
 const view={grantId:'grant-a',shopId:'shop-a',shopLabel:'Private shop',revision:1,asOf:'2026-01-01T12:00:00Z',expiresAt:'2099-01-01T00:00:00Z',canPropose:false,instructions:[{item:'Private ingredient',amount:'one',action:'Use today'}]};
 const {root,app}=await setup(fakeAPI({session:async()=>({...session(),role:'helper',grantId:'grant-a'}),view:async()=>view}));
 assert.match(root.textContent,/Private ingredient/);view.expiresAt='2020-01-01T00:00:00Z';app.checkExpiry();assert.doesNotMatch(root.textContent,/Private ingredient|Private shop/);assert.match(root.textContent,/Access has ended/);
});

test('new sends reauthenticate and cannot publish a private draft as another member',async()=>{
 let current=session(),sent=0;
 const {root,dom}=await setup(fakeAPI({session:async()=>current,command:async()=>{sent++;}}));
 type(dom,'item','Private draft');submit(root,dom);
 current={...session(),memberId:'different-member'};
 submit(root,dom);await waitForIdle(root);
 assert.equal(sent,0);assert.doesNotMatch(root.textContent,/Private draft|Family A/);assert.match(root.textContent,/Access has ended/);
});

test('uncertain memory retry cannot cross identities or silently make another operation',async()=>{
 let current=session(),sent=[];
 const {root,dom}=await setup(fakeAPI({session:async()=>current,requests:async()=>[own()],command:async(s,c)=>{sent.push(c);throw new ApiError('network',0);}}));
 type(dom,'item','Private original');submit(root,dom);submit(root,dom);await waitForIdle(root);
 click(root,'Edit');assert.match(root.textContent,/Private original/);assert.equal(root.querySelector('#item'),null);
 current={...session(),memberId:'other-member'};submit(root,dom);await waitForIdle(root);
 assert.equal(sent.length,1);assert.doesNotMatch(root.textContent,/Private original|No-salt frijoles/);
});

test('the device switch restores only its exact grant and removes earlier pending text after rotation',async()=>{
 let current={...session(),canSetRequestQueue:true};
 const outbox=new Outbox(new IDBFactory()), sends=[];
 const api=fakeAPI({session:async()=>current,setRequestQueue:async(s,enabled)=>{
   assert.equal(s,current);
   current={...s,queueConsent:enabled,requestQueueGrant:'first-grant',requestQueueUntil:'2099-01-01T00:00:00Z'};
 },command:async(_s,command,grant)=>{sends.push({command,grant});throw new ApiError('network',0);}});
 const {root,dom,app}=await setup(api,'en',outbox);
 click(root,'Allow pending requests on this browser for up to 24 hours');await waitForIdle(root);
 type(dom,'item','Private beans');submit(root,dom);submit(root,dom);await waitForIdle(root);
 assert.equal(sends[0].grant,'first-grant');
 assert.equal((await outbox.list(scopeFor(current))).length,1);
 const prior=current;
 current={...prior,requestQueueGrant:'replacement-grant'};
 await app.start();
 assert.equal((await outbox.list(scopeFor(prior))).length,0);
 assert.doesNotMatch(root.textContent,/Private beans|Waiting to send/);
 assert.equal(sends.length,1);
});

test('revoked queue permission prevents replay even for the same household and member',async()=>{
 let current={...session(),queueConsent:true},sent=0;
 const {root,dom}=await setup(fakeAPI({session:async()=>current,command:async()=>{sent++;throw new ApiError('network',0);}}));
 const consent=root.querySelector('input[type=checkbox]');consent.checked=true;consent.dispatchEvent(new dom.window.Event('change'));
 type(dom,'item','Beans');submit(root,dom);submit(root,dom);await waitForIdle(root);
 current={...current,queueConsent:false};click(root,'Retry');await waitForIdle(root);
 assert.equal(sent,1);assert.doesNotMatch(root.textContent,/Beans|Waiting to send/);
});

test('a retired queue grant leaves an authorized contributor able to send online', async () => {
 const active = {...session(), canSetRequestQueue:true, queueConsent:true, requestQueueGrant:'original-grant'};
 const disabled = {...session(), canSetRequestQueue:true};
 const outbox = new Outbox(new IDBFactory());
 let current = active;
 const attempts = [];
 const {root,dom} = await setup(fakeAPI({session:async()=>current, requests:async()=>[own()],
   command:async(_session,command,grant)=>{
     attempts.push({item:command.body.originalItem, grant});
     if (grant) throw new ApiError('network',0);
   }}),'en',outbox);
 type(dom,'item','Earlier private draft');submit(root,dom);submit(root,dom);await waitForIdle(root);
 current = disabled;
 click(root,'Retry');await waitForIdle(root);
 assert.equal(attempts.length,1);
 assert.deepEqual(await outbox.list(scopeFor(active)),[]);
 assert.doesNotMatch(root.textContent,/Earlier private draft|new invitation/);
 assert.match(root.textContent,/Offline permission changed/);
 assert.match(root.textContent,/No-salt frijoles/);
 type(dom,'item','New online request');submit(root,dom);submit(root,dom);await waitForIdle(root);
 assert.deepEqual(attempts[1],{item:'New online request',grant:undefined});
});

for (const [denial, code, expected] of [[403,'access_ended',/Access has ended/],[401,'session_needed',/Sign in again to continue/]]) {
test(`a grant rejected during send checks household access and clears the draft on ${denial}`, async () => {
 const active = {...session(), canSetRequestQueue:true, queueConsent:true, requestQueueGrant:'original-grant'};
 const outbox = new Outbox(new IDBFactory());
 let ended = false;
 const {root,dom} = await setup(fakeAPI({session:async()=>{
   if (ended) throw new ApiError(code,denial);
   return active;
 },requests:async()=>[own()],command:async()=>{
   ended = true;
   throw new ApiError('queue_permission_ended',409);
 }}),'en',outbox);
 type(dom,'item','Revoked private draft');submit(root,dom);submit(root,dom);await waitForIdle(root);
 assert.deepEqual(await outbox.list(scopeFor(active)),[]);
 assert.doesNotMatch(root.textContent,/Revoked private draft|No-salt frijoles|Family A/);
 assert.match(root.textContent,expected);
 assert.doesNotMatch(root.textContent,/Your text stays on this page/);
 assert.equal(root.querySelector('#item'),null);
});
}

test('queue cleanup while disconnected offers a fresh access check without replay', async () => {
 const active = {...session(), canSetRequestQueue:true, queueConsent:true, requestQueueGrant:'original-grant'};
 let disconnected=false, retired=false, attempts=0;
 const {root,dom} = await setup(fakeAPI({session:async()=>{
   if (disconnected) throw new ApiError('network',0);
   return retired ? {...session(),canSetRequestQueue:true} : active;
 },requests:async()=>[own()],command:async()=>{
   attempts++;retired=true;disconnected=true;throw new ApiError('queue_permission_ended',409);
 }}));
 type(dom,'item','Old request');submit(root,dom);submit(root,dom);await waitForIdle(root);
 assert.doesNotMatch(root.textContent,/Old request|No-salt frijoles|Family A/);
 assert.match(root.textContent,/Reconnect and refresh/);
 disconnected=false;click(root,'Refresh');await waitForIdle(root);
 assert.match(root.textContent,/No-salt frijoles/);
 assert.doesNotMatch(root.textContent,/Old request|Reconnect and refresh/);
 assert.equal(attempts,1);
});

test('failed sign-out clears private content and background reload cannot restore it',async()=>{
 let logoutFails=true,sessionReads=0;
 const {root,app}=await setup(fakeAPI({session:async()=>{sessionReads++;return session();},requests:async()=>[own()],logout:async()=>{if(logoutFails)throw new ApiError('network',0);}}));
 click(root,'Sign out');await waitForIdle(root);assert.doesNotMatch(root.textContent,/No-salt frijoles|Family A/);assert.match(root.textContent,/Sign-out could not be confirmed/);
 const before=sessionReads;await app.start();assert.equal(sessionReads,before);
 logoutFails=false;click(root,'Retry sign-out');await waitForIdle(root);assert.match(root.textContent,/You are signed out/);
});

test('an interrupted sign-out stays private across a cold reload and retries with the current session',async()=>{
 let current=session(),offline=false,sessionReads=0;const logoutCSRF=[];
 const api=fakeAPI({session:async()=>{sessionReads++;return current;},requests:async()=>[own()],logout:async s=>{
  logoutCSRF.push(s.csrf);if(offline)throw new ApiError('network',0);current=null;return {providerRevoked:true};
 }});
 const {root,dom}=await setup(api);
 offline=true;click(root,'Sign out');await waitForIdle(root);
 const reloaded=new WebApp(root,api,new Outbox(new IDBFactory()));await reloaded.start();
 assert.doesNotMatch(root.textContent,/No-salt frijoles|Family A/);
 assert.match(root.textContent,/Finish signing out/);assert.equal(sessionReads,1);
 assert.equal(dom.window.localStorage.length,1);
 assert.equal(dom.window.localStorage.getItem(dom.window.localStorage.key(0)),'1');
 offline=false;current={...session(),csrf:'rotated-csrf'};
 click(root,'Retry sign-out');await waitForIdle(root);
 assert.deepEqual(logoutCSRF,['csrf-test','rotated-csrf']);
 assert.match(root.textContent,/You are signed out/);assert.equal(dom.window.localStorage.length,0);
});

test('a lost successful sign-out response can be confirmed after reload without posting a second logout',async()=>{
 let active=true,posts=0;
 const api=fakeAPI({session:async()=>{
  if(!active)throw new ApiError('session_needed',401);
  return session();
 },authState:async()=>({available:true,authenticated:false,csrf:'anonymous-challenge'}),logout:async()=>{
  posts++;active=false;throw new ApiError('network',0);
 }});
 const {root,dom}=await setup(api);
 click(root,'Sign out');await waitForIdle(root);
 const reloaded=new WebApp(root,api,new Outbox(new IDBFactory()));await reloaded.start();
 click(root,'Retry sign-out');await waitForIdle(root);
 assert.equal(posts,1);assert.match(root.textContent,/You are signed out/);
 assert.equal(dom.window.localStorage.length,0);
});

test('failed helper loading never falls back to the contributor form',async()=>{
 const {root}=await setup(fakeAPI({session:async()=>({...session(),role:'helper',grantId:'grant-a'}),view:async()=>{throw new ApiError('network',0);}}));
 assert.doesNotMatch(root.textContent,/Ask the shopper|Review request|Send proposal/);assert.match(root.textContent,/No instructions are available/);
});

test('narrow session validation rejects malformed identity and expiry',async()=>{
 for(const body of [{...session(),role:'unknown'},{...session(),memberId:{}},{...session(),replayWindow:{id:'w',expiresAt:'not a date'}},{...session(),role:'helper'}]) {
  const api=new API(async()=>new Response(JSON.stringify(body),{status:200}));
  await assert.rejects(api.session(),e=>e.code==='invalid_response');
 }
});

test('own request pagination rejects cursor loops and malformed projected fields',async()=>{
 let calls=0;const looping=new API(async()=>{calls++;return new Response(JSON.stringify({requests:[],nextCursor:'same-cursor'}),{status:200});});
 await assert.rejects(looping.requests(session()),e=>e.code==='invalid_response');assert.equal(calls,2);
 const malformed=new API(async()=>new Response(JSON.stringify({requests:[{...own(),ownQuantity:{privateBudget:3800}}],nextCursor:null}),{status:200}));
 await assert.rejects(malformed.requests(session()),e=>e.code==='invalid_response');
});

test('receipt must match the actual shop and requested edit',async()=>{
 const api=new API(async()=>new Response(JSON.stringify({operationId:'op-a',kind:'request.edit',request:{...own(),requestId:'someone-else'}}),{status:200}));
 const edit={...command(),shopId:'shop-original',kind:'request.edit',base:{shopRevision:0,authorityEpoch:0,requestRevision:1},body:{requestId:'request-a',originalItem:'Beans',ownQuantity:null}};
 await assert.rejects(api.command(session(),edit),e=>e.code==='invalid_response');
 const wrongShop=new API(async()=>new Response(JSON.stringify({operationId:'op-a',kind:'request.send',request:own()}),{status:200}));
 await assert.rejects(wrongShop.command(session(),command()),e=>e.code==='invalid_response');
});

test('helper projection verifies its grant and never retains adult fields',async()=>{
 const s={...session(),role:'helper',grantId:'grant-a'};
 const view={grantId:'grant-a',shopId:'shop-a',shopLabel:'Tuesday',revision:2,asOf:'2026-01-01T12:00:00Z',expiresAt:'2099-01-01T00:00:00Z',canPropose:true,mode:'edit',language:'en',budgetMinor:3800,items:[{label:'Wraps',amount:'six',unit:'wraps',action:'Use for dinner',privatePrice:100}]};
 const api=new API(async()=>new Response(JSON.stringify(view),{status:200}));
 const projection=await api.view(s);assert.equal(projection.canPropose,false);assert.equal('budgetMinor' in projection,false);assert.equal('privatePrice' in projection.instructions[0],false);
 view.grantId='another-grant';await assert.rejects(api.view(s),e=>e.code==='invalid_response');
 let calls=0;const isolated=new API(async()=>{calls++;throw Error('must not call');});
 await assert.rejects(isolated.command(s,command()),e=>e.status===403);assert.equal(calls,0);
});

test('proposal requires an identified pending receipt for the viewed grant and revision',async()=>{
 const s={...session(),role:'editor',grantId:'grant-a'};
 const view={grantId:'grant-a',shopId:'shop-a',shopLabel:'Tuesday',revision:7,asOf:'2026-01-01T12:00:00Z',expiresAt:'2099-01-01T00:00:00Z',canPropose:true,instructions:[]};
 const invalid=new API(async()=>new Response(JSON.stringify({ok:true}),{status:200}));
 await assert.rejects(invalid.propose(s,view,'Save two wraps','proposal-key'),e=>e.code==='invalid_response');
 const valid=new API(async()=>new Response(JSON.stringify({proposalId:'proposal-a',grantId:'grant-a',baseRevision:7,status:'pending'}),{status:200}));
 await valid.propose(s,view,'Save two wraps','proposal-key');
});

test('outbox purges other identities and rejects non-request operations',async()=>{
 const outbox=new Outbox(new IDBFactory()),a={...session(),queueConsent:true},b={...session(),queueConsent:true,memberId:'member-b'};
 const pending=(s,key)=>({id:key,scope:scopeFor(s),command:{...command(),clientKey:key},createdAt:'2026-01-01T00:00:00Z'});
 await outbox.put(pending(a,'a'),a,true);await outbox.put(pending(b,'b'),b,true);
 await outbox.retainScope(scopeFor(b));assert.equal((await outbox.list(scopeFor(a))).length,0);assert.equal((await outbox.list(scopeFor(b))).length,1);
 const malicious=pending(b,'c');malicious.command.kind='shop.transferAuthority';
 await assert.rejects(outbox.put(malicious,b,true));
});

test('typed field limits match the service request contract',async()=>{
 const {root}=await setup(fakeAPI());assert.equal(root.querySelector('#item').maxLength,240);assert.equal(root.querySelector('#amount').maxLength,80);
});


test('unknown and adult routes do not fetch or display household data',async()=>{
 const dom=new JSDOM('<div id="app"></div>',{url:'https://food.example/admin'}),root=dom.window.document.getElementById('app');
 let calls=0;const app=new WebApp(root,fakeAPI({session:async()=>{calls++;return session();}}),new Outbox(new IDBFactory()));
 await app.start();assert.equal(calls,0);assert.match(root.textContent,/This page is not available/);assert.equal(root.querySelector('a').getAttribute('href'),'/requests');
});

test('invitation requires explicit adult review and validates the redemption receipt',async()=>{
 const calls=[];const api=new API(async(path,options)=>{calls.push({path,options});return new Response(JSON.stringify({householdId:'household-b',memberId:'member-b',role:'contributor'}),{status:200});});
 await assert.rejects(api.redeem('invite-secret','csrf-test',{adultAttestation:false}),e=>e.status===422);assert.equal(calls.length,0);
 assert.deepEqual(await api.redeem('invite-secret','csrf-test',{adultAttestation:true,alias:'Mia'}),{householdId:'household-b',memberId:'member-b',role:'contributor'});
 assert.deepEqual(JSON.parse(calls[0].options.body),{token:'invite-secret',intent:'join',adultAttestation:true,alias:'Mia'});
 const invalid=new API(async()=>new Response(JSON.stringify({ok:true}),{status:200}));
 await assert.rejects(invalid.redeem('invite-secret',undefined,{adultAttestation:true}),e=>e.code==='invalid_response');
});

test('session activation requires an authenticated response for the redeemed household',async()=>{
 const calls=[];const api=new API(async(path,options)=>{calls.push({path,options});return new Response(JSON.stringify(session()),{status:200});});
 await api.activateSession('household-a','csrf-test');assert.equal(calls[0].path,'/v1/session');assert.equal(calls[0].options.method,'POST');assert.deepEqual(JSON.parse(calls[0].options.body),{householdId:'household-a'});
 await assert.rejects(api.activateSession('household-b','csrf-test'),e=>e.code==='invalid_response');
});

test('joined invitation retries session activation without redeeming a single-use token twice',async()=>{
 let current=null,redeems=0,activations=0;
 const {root,dom}=await setup(fakeAPI({session:async()=>current,redeem:async()=>{redeems++;return {householdId:'household-a',memberId:'member-a',role:'contributor'};},activateSession:async()=>{activations++;if(activations===1)throw new ApiError('network',0);current=session();}}));
 type(dom,'invitation','single-use-secret');submit(root,dom);await waitForIdle(root);assert.equal(redeems,0);
 const adult=root.querySelector('#adult-attestation');adult.checked=true;adult.dispatchEvent(new dom.window.Event('change'));
 submit(root,dom);await waitForIdle(root);assert.equal(redeems,1);assert.equal(activations,1);assert.doesNotMatch(root.textContent,/Ask the shopper/);
 submit(root,dom);await waitForIdle(root);assert.equal(redeems,1);assert.equal(activations,2);assert.match(root.textContent,/Ask the shopper/);
});

test('child enrollment unavailable is an explicit failure in Spanish',async()=>{
 const {root,dom}=await setup(fakeAPI({session:async()=>null,redeem:async()=>{throw new ApiError('consent_unavailable',503);}}),'es-US');
 type(dom,'invitation','invite-code');const adult=root.querySelector('#adult-attestation');adult.checked=true;adult.dispatchEvent(new dom.window.Event('change'));
 submit(root,dom);await waitForIdle(root);assert.match(root.textContent,/registro de menores aún no está disponible/);assert.doesNotMatch(root.textContent,/Pedir a quien hace la compra/);
});

test('confirmed receipt remains received when deleting a queued copy fails',async()=>{
 const dom=new JSDOM('<div id="app"></div>',{url:'https://food.example/requests'}),root=dom.window.document.getElementById('app');
 let rows=[];const outbox={retainScope:async()=>{},list:async()=>rows,clear:async()=>{rows=[];},put:async p=>{rows=[p];},remove:async()=>{throw Error('storage denied');}};
 const app=new WebApp(root,fakeAPI({session:async()=>({...session(),queueConsent:true})}),outbox);await app.start();
 const consent=root.querySelector('input[type=checkbox]');consent.checked=true;consent.dispatchEvent(new dom.window.Event('change'));
 type(dom,'item','Rice');submit(root,dom);submit(root,dom);await waitForIdle(root);
 assert.match(root.textContent,/Received by the shopper/);assert.match(root.textContent,/Received; local cleanup pending/);assert.doesNotMatch(root.textContent,/Not saved|Waiting to send from this browser/);
});

test('confirmed logout reports a local storage cleanup failure without exposing records',async()=>{
 const dom=new JSDOM('<div id="app"></div>',{url:'https://food.example/requests'}),root=dom.window.document.getElementById('app');
 const outbox={clear:async()=>{throw Error('storage denied');}};
 const app=new WebApp(root,fakeAPI({requests:async()=>[own()]}),outbox);await app.start();click(root,'Sign out');await waitForIdle(root);
 assert.doesNotMatch(root.textContent,/No-salt frijoles|Family A/);assert.match(root.textContent,/browser storage could not be cleared/);
});

test('redeeming a helper link never opens a different most-recent grant',async()=>{
 let current=null;
 const dom=new JSDOM('<div id="app"></div>',{url:'https://food.example/view'}),root=dom.window.document.getElementById('app');
 const app=new WebApp(root,fakeAPI({session:async()=>current,redeem:async()=>({householdId:'household-a',memberId:'member-a',role:'helper',grantId:'requested-grant'}),activateSession:async()=>{current={...session(),role:'helper',grantId:'wrong-grant'};},view:async()=>({grantId:'wrong-grant',shopId:'shop-a',shopLabel:'Different shop',revision:1,asOf:'2026-01-01T12:00:00Z',expiresAt:'2099-01-01T00:00:00Z',canPropose:false,instructions:[{item:'Different private ingredient',amount:'one',action:'Do not display'}]})}),new Outbox(new IDBFactory()),'secret');
 await app.start();const adult=root.querySelector('#adult-attestation');adult.checked=true;adult.dispatchEvent(new dom.window.Event('change'));
 submit(root,dom);await waitForIdle(root);assert.doesNotMatch(root.textContent,/Different shop|Different private ingredient/);assert.match(root.textContent,/information changed/);
});

test('helper session activation sends and verifies the selected grant',async()=>{
 const calls=[];const helper={...session(),role:'helper',grantId:'selected-grant'};
 const api=new API(async(path,options)=>{calls.push({path,options});return new Response(JSON.stringify(helper),{status:200});});
 await api.activateSession('household-a','csrf-test','selected-grant');assert.deepEqual(JSON.parse(calls[0].options.body),{householdId:'household-a',grantId:'selected-grant'});
 await assert.rejects(api.activateSession('household-a','csrf-test','another-grant'),e=>e.code==='invalid_response');
});

test('successful Refresh preserves an actual failed-save notice and unsent draft',async()=>{
 const {root,dom}=await setup(fakeAPI({command:async()=>{throw new ApiError('network',0);}}));
 type(dom,'item','Unsent oats');submit(root,dom);submit(root,dom);await waitForIdle(root);
 assert.match(root.textContent,/Not saved/);assert.match(root.textContent,/Unsent oats/);
 click(root,'Refresh');await waitForIdle(root);assert.match(root.textContent,/Not saved/);assert.match(root.textContent,/Unsent oats/);
});

test('a reviewed request cannot silently move to a newly selected shop',async()=>{
 let active=session(); const sent=[];
 const {root,dom}=await setup(fakeAPI({session:async()=>active,command:async(s,c)=>sent.push(c)}));
 type(dom,'item','Only for Tuesday');
 submit(root,dom);await waitForIdle(root);
 active={...active,shopId:'shop-b'};
 const send=[...root.querySelectorAll('button')].find(b=>b.textContent==='Send request');
 assert.ok(send,root.textContent);send.click();await waitForIdle(root);
 assert.deepEqual(sent,[]);assert.doesNotMatch(root.textContent,/Only for Tuesday/);
});

test('a helper correction draft is cleared when refresh opens a different grant',async()=>{
 let grantId='grant-a';
 const {root,dom}=await setup(fakeAPI({
  session:async()=>({...session(),role:'editor',grantId}),
  view:async()=>({grantId,shopId:'shop-a',shopLabel:grantId,revision:grantId==='grant-a'?1:4,asOf:'2026-01-01T00:00:00Z',expiresAt:'2099-01-01T00:00:00Z',canPropose:true,instructions:[]})
 }));
 assert.match(root.textContent,/Revision: 1/);
 type(dom,'correction','A note for the first cook');
 grantId='grant-b';click(root,'Refresh');await waitForIdle(root);
 assert.match(root.textContent,/grant-b/);assert.match(root.textContent,/Revision: 4/);assert.doesNotMatch(root.textContent,/Revision: 1/);
 assert.equal(dom.window.document.getElementById('correction').value,'');
});

const editorSession=()=>({...session(),role:'editor',grantId:'grant-a'});
const cookView=(revision=7)=>({grantId:'grant-a',shopId:'shop-a',shopLabel:'Tuesday',revision,asOf:'2026-01-01T12:00:00Z',expiresAt:'2099-01-01T00:00:00Z',canPropose:true,instructions:[]});
const suggestionReceipt=(intent)=>({proposalId:'proposal-a',grantId:intent.grantId,baseRevision:intent.baseRevision,status:'pending'});

test('lost editor reply retries identical reviewed bytes after refresh advances instructions and recovers current status',async()=>{
 let revision=7,commits=0;const requests=[],accepted=new Map();
 const api=new API(async(path,options)=>{
  if(options.method==='POST'){
   requests.push(options.body);const body=JSON.parse(options.body),old=accepted.get(body.clientKey);
   if(old){assert.equal(options.body,old.body);return new Response(JSON.stringify(old.receipt));}
   assert.equal(body.baseRevision,revision);commits++;
   const receipt={proposalId:'proposal-a',grantId:'grant-a',baseRevision:body.baseRevision,status:'pending'};
   accepted.set(body.clientKey,{body:options.body,receipt});throw Error('response lost after commit');
  }
  assert.equal(path,'/v1/views/grant-a/proposals/proposal-a');
  return new Response(JSON.stringify({proposalId:'proposal-a',grantId:'grant-a',baseRevision:7,proposalRevision:2,
   correction:'No-salt frijoles / dos latas',status:'reviewed',createdAt:'2026-01-01T12:00:00Z',
   resolution:{mutationId:'resolution-a',decision:'replaced',revision:8,resolvedAt:'2026-01-01T13:00:00Z'},budgetMinor:99999}));
 });
 const {root,dom}=await setup(fakeAPI({session:async()=>editorSession(),view:async()=>cookView(revision),sendProposal:api.sendProposal.bind(api),ownProposal:api.ownProposal.bind(api)}));
 type(dom,'correction','No-salt frijoles / dos latas');submit(root,dom);await waitForIdle(root);
 assert.match(root.textContent,/receipt is unconfirmed/);assert.doesNotMatch(root.textContent,/Not saved/);
 assert.equal(root.querySelector('#correction'),null);assert.match(root.textContent,/only kept on this page/);
 revision=8;click(root,'Refresh');await waitForIdle(root);
 assert.match(root.textContent,/Revision: 8/);assert.match(root.textContent,/Reviewed revision: 7/);click(root,'Retry original suggestion');await waitForIdle(root);
 assert.equal(commits,1);assert.equal(requests.length,2);assert.equal(requests[0],requests[1]);
 assert.match(root.textContent,/Suggestion received for shopper review/);
 click(root,'Check suggestion status');await waitForIdle(root);
 assert.match(root.textContent,/Suggestion reviewed/);assert.doesNotMatch(root.textContent,/99999/);
});

test('stale unaccepted suggestion requires explicit current review and then a different key',async()=>{
 let revision=7;const intents=[];
 const {root,dom}=await setup(fakeAPI({session:async()=>editorSession(),view:async()=>cookView(revision),sendProposal:async(_,intent)=>{
  intents.push(intent);if(intents.length===1)throw new ApiError('stale_base',409);return suggestionReceipt(intent);
 }}));
 type(dom,'correction','Keep original wording');submit(root,dom);await waitForIdle(root);
 assert.match(root.textContent,/not accepted/);assert.equal(root.querySelector('#correction'),null);
 revision=8;click(root,'Review current instructions');await waitForIdle(root);
 assert.equal(root.querySelector('#correction').value,'Keep original wording');assert.equal(intents.length,1);
 submit(root,dom);await waitForIdle(root);
 assert.equal(intents[0].baseRevision,7);assert.equal(intents[1].baseRevision,8);assert.notEqual(intents[0].clientKey,intents[1].clientKey);
});

test('editor exact retry stops and clears private intent after grant, shop, actor or role changes',async()=>{
 for(const change of [{grantId:'grant-b'},{shopId:'shop-b'},{memberId:'member-b'},{role:'helper'}]){
  let active=editorSession(),attempts=0;
  const {root,dom}=await setup(fakeAPI({session:async()=>active,view:async()=>cookView(),sendProposal:async()=>{attempts++;throw new ApiError('network',0);}}));
  type(dom,'correction','Private original suggestion');submit(root,dom);await waitForIdle(root);
  active={...active,...change};click(root,'Retry original suggestion');await waitForIdle(root);
  assert.equal(attempts,1);assert.doesNotMatch(root.textContent,/Private original suggestion/);assert.match(root.textContent,/Access has ended/);
 }
});

test('late proposal receipt cannot restore private text after displayed grant expires',async()=>{
 let finish;const view=cookView();
 const {root,dom,app}=await setup(fakeAPI({session:async()=>editorSession(),view:async()=>view,
  sendProposal:async(_,intent)=>new Promise(resolve=>{finish=()=>resolve(suggestionReceipt(intent));})}));
 type(dom,'correction','Private late suggestion');submit(root,dom);
 while(!finish)await new Promise(resolve=>setTimeout(resolve,5));
 view.expiresAt='2020-01-01T00:00:00Z';app.checkExpiry();finish();await waitForIdle(root);
 assert.doesNotMatch(root.textContent,/Private late suggestion|Suggestion received|shopper must review/);assert.match(root.textContent,/Access has ended/);
});

test('own suggestion status rejects mismatched proposal body or resolution and prepared bodies cannot be tampered',async()=>{
 const s=editorSession(),intent=prepareProposal(s,cookView(),'Keep two','key-a'),receipt=suggestionReceipt(intent);
 assert.ok(Object.isFrozen(intent));let calls=0;
 const denied=new API(async()=>{calls++;throw Error('must not fetch');});
 await assert.rejects(denied.sendProposal(s,{...intent,body:intent.body.replace('Keep two','Keep three')}),e=>e.code==='invalid_response');
 await assert.rejects(denied.sendProposal({...s,memberId:'member-b'},intent),e=>e.status===403);assert.equal(calls,0);
 const valid={...receipt,proposalRevision:1,correction:'Keep two',createdAt:'2026-01-01T00:00:00Z',resolution:null};
 for(const patch of [{proposalId:'other'},{baseRevision:8},{correction:'Other private text'},{status:'reviewed'},{resolution:{mutationId:'mutation-a',decision:'dismissed',revision:8,resolvedAt:'2026-01-01T00:00:00Z'}}]){
  const api=new API(async()=>new Response(JSON.stringify({...valid,...patch})));
  await assert.rejects(api.ownProposal(s,intent,receipt),e=>e.code==='invalid_response');
 }
});

test('revoked editor status clears original text and Spanish lost reply stays honest',async()=>{
 const {root,dom}=await setup(fakeAPI({session:async()=>editorSession(),view:async()=>cookView(),sendProposal:async()=>{throw new ApiError('network',0);}}),'es-US');
 type(dom,'correction','Texto privado');submit(root,dom);await waitForIdle(root);
 assert.match(root.textContent,/No se ha confirmado/);assert.match(root.textContent,/solo se conserva en esta página/i);assert.doesNotMatch(root.textContent,/Not saved|Retry original suggestion/);
 const other=await setup(fakeAPI({session:async()=>editorSession(),view:async()=>cookView(),sendProposal:async(_,i)=>suggestionReceipt(i),ownProposal:async()=>{throw new ApiError('unavailable',404);}}));
 type(other.dom,'correction','Private revoked text');submit(other.root,other.dom);await waitForIdle(other.root);
 click(other.root,'Check suggestion status');await waitForIdle(other.root);
 assert.doesNotMatch(other.root.textContent,/Private revoked text/);assert.match(other.root.textContent,/Access has ended/);
});


test('status network failure never downgrades a confirmed suggestion to not saved',async()=>{
 const {root,dom}=await setup(fakeAPI({session:async()=>editorSession(),view:async()=>cookView(),sendProposal:async(_,i)=>suggestionReceipt(i),ownProposal:async()=>{throw new ApiError('network',0);}}));
 type(dom,'correction','Confirmed original text');submit(root,dom);await waitForIdle(root);
 click(root,'Check suggestion status');await waitForIdle(root);
 assert.match(root.textContent,/earlier receipt is still confirmed/);assert.match(root.textContent,/Confirmed original text/);assert.doesNotMatch(root.textContent,/Not saved|Receipt unconfirmed/);
});

test('key-reused conflict cannot silently replace the original envelope or reopen an editable form',async()=>{
 const intents=[];
 const {root,dom}=await setup(fakeAPI({session:async()=>editorSession(),view:async()=>cookView(9),sendProposal:async(_,i)=>{intents.push(i);throw new ApiError('key_reused',409);}}));
 type(dom,'correction','Exact original text');submit(root,dom);await waitForIdle(root);
 click(root,'Refresh');await waitForIdle(root);click(root,'Retry original suggestion');await waitForIdle(root);
 assert.equal(intents.length,2);assert.equal(intents[0],intents[1]);assert.equal(root.querySelector('#correction'),null);
 assert.doesNotMatch(root.textContent,/original suggestion was not accepted/);assert.match(root.textContent,/may already have received/);
});


test('render-time grant expiry clears a pending suggestion before the timer can run',async()=>{
 const view=cookView();const {root,dom,app}=await setup(fakeAPI({session:async()=>editorSession(),view:async()=>view,sendProposal:async()=>{throw new ApiError('network',0);}}));
 type(dom,'correction','Expired private intent');submit(root,dom);await waitForIdle(root);
 view.expiresAt='2020-01-01T00:00:00Z';app.render();assert.doesNotMatch(root.textContent,/Expired private intent/);
 view.expiresAt='2099-01-01T00:00:00Z';await app.start();assert.equal(root.querySelector('#correction').value,'');assert.doesNotMatch(root.textContent,/Expired private intent/);
});


test('own status matches server whitespace normalization while retries retain exact original text bytes',async()=>{
 const s=editorSession(),intent=prepareProposal(s,cookView(),'  Keep two / frijoles  ','key-a'),receipt=suggestionReceipt(intent),bodies=[];
 const api=new API(async(_,options)=>{if(options.method==='POST'){bodies.push(options.body);return new Response(JSON.stringify(receipt));}
  return new Response(JSON.stringify({...receipt,proposalRevision:1,correction:'Keep two / frijoles',createdAt:'2026-01-01T00:00:00Z',resolution:null}));});
 await api.sendProposal(s,intent);await api.sendProposal(s,intent);assert.equal(bodies[0],bodies[1]);assert.equal(JSON.parse(bodies[0]).correction,'  Keep two / frijoles  ');
 const result=await api.ownProposal(s,intent,receipt);assert.equal(result.correction,'Keep two / frijoles');assert.equal(intent.correction,'  Keep two / frijoles  ');
});


const receivedSuggestion=(overrides={})=>({proposalId:'proposal-a',grantId:'grant-a',baseRevision:7,proposalRevision:1,correction:'Previously received private suggestion',status:'pending',createdAt:'2026-01-01T00:00:00Z',resolution:null,...overrides});

test('full app recreation recovers received suggestions from the service without a local intent or submission',async()=>{
 let posts=0;const api=fakeAPI({session:async()=>editorSession(),view:async()=>cookView(8),receivedProposals:async()=>({proposals:[receivedSuggestion()],nextCursor:null}),sendProposal:async()=>{posts++;}});
 const first=await setup(api);assert.match(first.root.textContent,/Previously received private suggestion/);
 const second=await setup(api);assert.match(second.root.textContent,/Reviewed revision: 7/);assert.match(second.root.textContent,/do not need to be sent again/);
 assert.equal(second.root.querySelector('#correction').value,'');assert.equal(posts,0);assert.equal(second.dom.window.localStorage.length,0);
 click(second.root,'Check received suggestions');await waitForIdle(second.root);assert.equal(posts,0);assert.equal(second.root.querySelectorAll('[data-proposal-id]').length,1);
});

test('failed discovery blocks a new suggestion until explicit recovery succeeds and permits read-only own status',async()=>{
 let failed=true,posts=0;
 const {root}=await setup(fakeAPI({session:async()=>editorSession(),view:async()=>cookView(),receivedProposals:async()=>{if(failed)throw new ApiError('network',0);return {proposals:[receivedSuggestion()],nextCursor:null};},sendProposal:async()=>{posts++;}}));
 assert.equal(root.querySelector('#correction'),null);assert.match(root.textContent,/Retry recovery before sending/);
 failed=false;click(root,'Check received suggestions');await waitForIdle(root);assert.ok(root.querySelector('#correction'));assert.equal(posts,0);assert.doesNotMatch(root.textContent,/Retry recovery before sending/);
 const readonly=await setup(fakeAPI({session:async()=>({...editorSession(),role:'helper'}),view:async()=>({...cookView(),canPropose:false}),receivedProposals:async()=>({proposals:[receivedSuggestion()],nextCursor:null})}));
 assert.match(readonly.root.textContent,/Previously received private suggestion/);assert.match(readonly.root.textContent,/read-only/);assert.equal(readonly.root.querySelector('#correction'),null);
});

test('late received-page response cannot expose old actor data after account switch or local expiry',async()=>{
 for(const expire of [false,true]){
  let active=editorSession(),release;const view=cookView();
  const api=fakeAPI({session:async()=>active,view:async()=>view,receivedProposals:async()=>({proposals:[],nextCursor:null})});
  const {root,app}=await setup(api);
  api.receivedProposals=async()=>new Promise(resolve=>{release=()=>resolve({proposals:[receivedSuggestion()],nextCursor:null});});
  click(root,'Check received suggestions');while(!release)await new Promise(r=>setTimeout(r,5));
  if(expire){view.expiresAt='2020-01-01T00:00:00Z';app.checkExpiry();}else active={...active,memberId:'other-member'};
  release();await waitForIdle(root);assert.doesNotMatch(root.textContent,/Previously received private suggestion/);assert.match(root.textContent,/Access has ended/);
 }
});

test('expiry during Refresh keeps its current denial after the received-page response finishes',async t=>{
 for(const role of ['helper','editor']){
  let release;const view={...cookView(),canPropose:role==='editor'};
  const api=fakeAPI({session:async()=>({...editorSession(),role}),view:async()=>view,receivedProposals:async()=>({proposals:[],nextCursor:null})});
  const {root,dom,app}=await setup(api);t.after(()=>dom.window.close());
  api.receivedProposals=async()=>new Promise(resolve=>{release=()=>resolve({proposals:[receivedSuggestion()],nextCursor:null});});
  click(root,'Refresh');
  const deadline=Date.now()+3000;
  while(!release){assert.ok(Date.now()<deadline,'Refresh must reach suggestion loading');await new Promise(r=>setTimeout(r,5));}
  view.expiresAt='2020-01-01T00:00:00Z';app.checkExpiry();release();await waitForIdle(root);
  assert.match(root.textContent,/Access has ended/);
  assert.doesNotMatch(root.textContent,/Previously received private suggestion|Family A|Current instructions/);
  assert.equal(root.querySelector('#correction'),null);
 }
});

test('received pages reject wrong grants, duplicate rows, wrong cursors and private projection fields are discarded',async()=>{
 const view=cookView(),s=editorSession();
 for(const page of [{proposals:[receivedSuggestion({grantId:'other'})],nextCursor:null},{proposals:[receivedSuggestion(),receivedSuggestion()],nextCursor:null},
   {proposals:[receivedSuggestion()],nextCursor:'other'},{proposals:Array.from({length:21},(_,i)=>receivedSuggestion({proposalId:'p'+i})),nextCursor:null}]){
  await assert.rejects(new API(async()=>new Response(JSON.stringify(page))).receivedProposals(s,view),e=>e.code==='invalid_response');
 }
 const calls=[],api=new API(async(path)=>{calls.push(path);return new Response(JSON.stringify({proposals:[{...receivedSuggestion(),budgetMinor:999,otherAuthors:['secret']}],nextCursor:null}));});
 const result=await api.receivedProposals({...s,role:'helper'},{...view,canPropose:false});assert.equal('budgetMinor' in result.proposals[0],false);assert.equal('otherAuthors' in result.proposals[0],false);
 await assert.rejects(api.receivedProposals(s,view,'proposal-a'),e=>e.code==='invalid_response');assert.equal(calls[1],'/v1/views/grant-a/proposals?cursor=proposal-a');
});

test('pagination appends only distinct own rows and receipt recovery avoids duplicate received cards',async()=>{
 const requests=[];const {root,dom}=await setup(fakeAPI({session:async()=>editorSession(),view:async()=>cookView(),receivedProposals:async(_,__,cursor)=>{requests.push(cursor);return cursor?{proposals:[receivedSuggestion({proposalId:'proposal-b',correction:'Older suggestion'})],nextCursor:null}:{proposals:[receivedSuggestion()],nextCursor:'proposal-a'};},sendProposal:async(_,i)=>suggestionReceipt(i)}));
 click(root,'Show older suggestions');await waitForIdle(root);assert.equal(root.querySelectorAll('[data-proposal-id]').length,2);assert.deepEqual(requests,[null,'proposal-a']);
 type(dom,'correction','Previously received private suggestion');submit(root,dom);await waitForIdle(root);
 assert.equal(root.querySelector('[data-proposal-id="proposal-a"]'),null);assert.match(root.textContent,/Your reviewed suggestion/);assert.ok(root.querySelector('[data-proposal-id="proposal-b"]'));
});

test('only an added own request may carry an explicit purchase outcome',async()=>{
 const row={...own(),status:'added',ownActionAllowed:false};
 const read=async fields=>{
  const api=new API(async()=>Response.json({requests:[{...row,...fields}],nextCursor:null}));
  return (await api.requests(session()))[0];
 };
 for(const outcome of ['bought','notBought']){
  const parsed=await read({purchaseOutcome:outcome,linkedLineId:'shopper-only',priceMinor:399});
  assert.equal(parsed.purchaseOutcome,outcome);
  assert.equal('linkedLineId' in parsed,false);
  assert.equal('priceMinor' in parsed,false);
 }
 assert.equal('purchaseOutcome' in await read({}),false);
 for(const fields of [{purchaseOutcome:'unknown'},{purchaseOutcome:null},{purchaseOutcome:'bought',status:'deferred'}]){
  await assert.rejects(()=>read(fields),ApiError);
 }
});

for(const [language,refresh,unconfirmed,bought,notBought] of [
 ['en','Refresh','Purchase not confirmed','Shopper confirmed purchase','Shopper confirmed the item was not bought'],
 ['es','Actualizar','Compra sin confirmar','La persona que hizo la compra confirmó que compró el artículo','La persona que hizo la compra confirmó que no compró el artículo']
]){
 test('own receipt refresh follows the shopper purchase correction in '+language,async t=>{
  let row=own();
  const {root,dom}=await setup(fakeAPI({requests:async()=>[row]}),language);
  t.after(()=>dom.window.close());
  assert.ok(!root.textContent.includes(unconfirmed));
  row={...row,status:'added',ownActionAllowed:false};
  for(const [outcome,expected] of [[undefined,unconfirmed],['bought',bought],['notBought',notBought],[undefined,unconfirmed]]){
   row={...row,revision:row.revision+1,purchaseOutcome:outcome};
   click(root,refresh);await waitForIdle(root);
   const labels=[...root.querySelectorAll('p')].map(p=>p.textContent);
   assert.deepEqual(labels.filter(label=>[unconfirmed,bought,notBought].includes(label)),[expected]);
  }
 });
}

test('a carried request keeps its own source and later trip legible without disclosing a shop link',async t=>{
 const source={...own(),route:'next',status:'deferred',ownActionAllowed:false,carriedForward:true,sourceShopId:'private-source'};
 const next={...own(),requestId:'next-request',shopId:'next-shop',fromPreviousShop:true};
 const api=new API(async()=>Response.json({requests:[source,next],nextCursor:null}));
 const rows=await api.requests(session());
 assert.equal(rows[0].carriedForward,true);
 assert.equal('sourceShopId' in rows[0],false);
 assert.equal(rows[1].fromPreviousShop,true);
 const {dom,root}=await setup(fakeAPI({requests:async()=>rows}),'es');
 t.after(()=>dom.window.close());
 assert.match(root.textContent,/Se pasó a una compra posterior para su revisión/);
 assert.match(root.textContent,/De una compra anterior/);
 const malformed=new API(async()=>Response.json({requests:[{...source,ownActionAllowed:true}],nextCursor:null}));
 await assert.rejects(()=>malformed.requests(session()),ApiError);
});
