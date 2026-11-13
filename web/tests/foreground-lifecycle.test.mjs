import assert from 'node:assert/strict';
import test from 'node:test';
import {JSDOM,loadApplication} from './support/source-dom-loader.mjs';
const current=(actor='a',role='contributor')=>({authenticated:true,role,household:{id:'household-'+actor,label:'Household '+actor},memberId:'member-'+actor,shopId:'shop-'+actor,replayWindow:{id:'window-'+actor,expiresAt:'2099-01-01T00:00:00Z'},csrf:'csrf',enrolled:true,queueConsent:false,...(['helper','editor'].includes(role)?{grantId:'grant-'+actor}:{})});
const row=()=>({requestId:'request-a',shopId:'shop-a',revision:1,originalItem:'PRIVATE OWN REQUEST',ownQuantity:null,authoredAt:'2026-11-06T12:00:00Z',receivedAt:'2026-11-06T12:00:01Z',route:'current',status:'pending',ownActionAllowed:true,clarification:null,followupTo:null});
const tick=()=>new Promise(r=>setTimeout(r,0));
async function until(predicate){const deadline=performance.now()+3000;while(performance.now()<deadline){if(predicate())return;await tick();}assert.fail('controlled API boundary not reached');}
async function idle(root){await until(()=>root.querySelector('main')?.getAttribute('aria-busy')==='false');}
async function setup(t,extra={}){
 const dom=new JSDOM('<div id="app"></div>',{url:'https://fixture.test/requests'});t.after(()=>dom.window.close());
 let reads=0;const api={session:async()=>{reads++;return current();},requests:async()=>[row()],authState:async()=>({available:false,authenticated:false,csrf:null}),receivedProposals:async()=>({proposals:[],nextCursor:null}),...extra};
 const {app,ApiError}=loadApplication(dom,api);const root=dom.window.document.getElementById('app');await idle(root);
 return {dom,root,api,app,ApiError,reads:()=>reads};
}
function visibility(dom,state){Object.defineProperty(dom.window.document,'visibilityState',{configurable:true,value:state});dom.window.document.dispatchEvent(new dom.window.Event('visibilitychange'));}
function draft(dom){const input=dom.window.document.getElementById('item');input.value='UNSENT PRIVATE DRAFT';input.dispatchEvent(new dom.window.Event('input',{bubbles:true}));}
function concealed(root){assert.doesNotMatch(root.textContent,/PRIVATE OWN REQUEST|Household a|PRIVATE COOK/);assert.equal(root.querySelector('#item'),null);assert.equal(root.querySelector('#correction'),null);}
for(const revoked of [false,true])test(`actual main visibility listener conceals during held ${revoked?'revoked':'same-actor'} authorization`,async t=>{
 const {dom,root,api,ApiError}=await setup(t);draft(dom);let release;
 api.session=()=>new Promise((yes,no)=>release=()=>revoked?no(new ApiError('access_ended',403)):yes(current()));
 visibility(dom,'hidden');visibility(dom,'visible');assert.equal(root.querySelector('main').getAttribute('aria-busy'),'true');concealed(root);
 release();await idle(root);
 if(revoked){concealed(root);assert.match(root.textContent,/Access has ended/);}else{assert.match(root.textContent,/PRIVATE OWN REQUEST/);assert.equal(root.querySelector('#item').value,'UNSENT PRIVATE DRAFT');}
});
test('changed foreground actor clears previous unsent draft and own requests',async t=>{
 const {dom,root,api}=await setup(t);draft(dom);let release;
 api.session=()=>new Promise(r=>release=()=>r(current('b')));api.requests=async()=>[];
 visibility(dom,'visible');concealed(root);release();await idle(root);assert.equal(root.querySelector('#item').value,'');assert.doesNotMatch(root.textContent,/Household a|PRIVATE OWN REQUEST/);assert.match(root.textContent,/Household b/);
});
test('offline foreground stays concealed and explicit same-actor recovery restores draft',async t=>{
 const {dom,root,api,app,ApiError}=await setup(t);draft(dom);api.session=async()=>{throw new ApiError('network',0);};visibility(dom,'visible');await idle(root);concealed(root);assert.match(root.textContent,/Could not load/);api.session=async()=>current();await app.start();assert.equal(root.querySelector('#item').value,'UNSENT PRIVATE DRAFT');
});
for(const order of ['visibility-first','pageshow-first'])test(`${order} BFCache/visibility notifications share one held authority read`,async t=>{
 const {dom,root,api}=await setup(t);draft(dom);let release,reads=0;
 api.session=()=>{reads++;return new Promise(r=>release=()=>r(current()));};dom.window.dispatchEvent(new dom.window.PageTransitionEvent('pagehide',{persisted:true}));concealed(root);
 const page=()=>dom.window.dispatchEvent(new dom.window.PageTransitionEvent('pageshow',{persisted:true}));
 if(order==='visibility-first'){visibility(dom,'visible');page();}else{page();visibility(dom,'visible');}
 visibility(dom,'visible');concealed(root);assert.equal(reads,1);release();await idle(root);assert.equal(reads,1);assert.equal(root.querySelector('#item').value,'UNSENT PRIVATE DRAFT');
});
test('foreground during old load rejects its reveal and performs one deferred authority check',async t=>{
 const {dom,root,api,app}=await setup(t);draft(dom);let releaseOld,releaseFresh,reads=0;
 api.requests=()=>new Promise(r=>releaseOld=()=>r([row()]));const previous=app.start();await tick();
 api.session=()=>{reads++;return new Promise(r=>releaseFresh=()=>r(current()));};visibility(dom,'visible');visibility(dom,'visible');concealed(root);assert.equal(reads,0);
 api.requests=async()=>[row()];releaseOld();await previous;await tick();concealed(root);assert.equal(reads,1);releaseFresh();await idle(root);assert.equal(root.querySelector('#item').value,'UNSENT PRIVATE DRAFT');
});
function click(root,text){const b=[...root.querySelectorAll('button')].find(x=>x.textContent===text);assert.ok(b,text);b.click();}
test('foreground during actual pending send conceals, never reposts, and defers fresh load',async t=>{
 const {dom,root,api}=await setup(t);draft(dom);let releaseCommand;const commands=[];
 api.command=(_s,command)=>{commands.push(JSON.stringify(command));return new Promise(r=>releaseCommand=r);};
 click(root,'Review request');click(root,'Send request');await until(()=>commands.length===1);assert.equal(commands.length,1);
 let reads=0;const releases=[];api.session=()=>{reads++;return new Promise(r=>releases.push(()=>r(current())));};visibility(dom,'visible');visibility(dom,'visible');concealed(root);assert.equal(reads,0);
 releaseCommand();await until(()=>reads===1);assert.equal(reads,1);concealed(root);releases.shift()();await until(()=>reads===2);assert.equal(reads,2);concealed(root);releases.shift()();await idle(root);assert.equal(commands.length,1);assert.match(root.textContent,/Received by the shopper/);assert.equal(root.querySelector('#item').value,'');
});
test('signout barrier prevents foreground authority reads and stale rendering',async t=>{
 const {dom,root,api,ApiError}=await setup(t);draft(dom);let rejectLogout,reads=0;
 api.logout=()=>new Promise((_r,reject)=>rejectLogout=reject);click(root,'Sign out');await until(()=>typeof rejectLogout==='function');api.session=async()=>{reads++;return current();};visibility(dom,'visible');concealed(root);rejectLogout(new ApiError('network',0));await idle(root);visibility(dom,'visible');await tick();concealed(root);assert.equal(reads,0);assert.match(root.textContent,/Sign-out could not be confirmed/);
});
for(const role of ['helper','editor'])test(`${role} foreground conceals private view until revoked result`,async t=>{
 const {dom,root,api,ApiError}=await setup(t,{session:async()=>current('a',role),view:async()=>({grantId:'grant-a',shopId:'shop-a',shopLabel:'Shop a',revision:1,asOf:'2026-11-06T12:00:00Z',expiresAt:'2099-01-01T00:00:00Z',canPropose:role==='editor',instructions:[{item:'PRIVATE COOK INSTRUCTION',amount:null,action:'Prepare'}]})});
 assert.match(root.textContent,/PRIVATE COOK/);let release;api.session=()=>new Promise((_r,no)=>release=()=>no(new ApiError('access_ended',403)));visibility(dom,'visible');concealed(root);release();await idle(root);concealed(root);assert.match(root.textContent,/Access has ended/);
});

test('two distinct foreground returns reject first-cycle authorization and require a newer read',async t=>{
 const {dom,root,api}=await setup(t);draft(dom);let reads=0;const releases=[];
 api.session=()=>{reads++;return new Promise(r=>releases.push(()=>r(current())));};
 visibility(dom,'hidden');visibility(dom,'visible');assert.equal(reads,1);concealed(root);
 visibility(dom,'hidden');visibility(dom,'visible');concealed(root);assert.equal(reads,1,'second read waits for first transport to settle');
 releases.shift()();await until(()=>reads===2||root.querySelector('main').getAttribute('aria-busy')==='false');
 concealed(root);assert.equal(reads,2,'new away cycle requires its own fresh authority');
 releases.shift()();await idle(root);assert.equal(root.querySelector('#item').value,'UNSENT PRIVATE DRAFT');
});
