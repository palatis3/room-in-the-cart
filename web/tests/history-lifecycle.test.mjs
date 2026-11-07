import assert from 'node:assert/strict';
import test from 'node:test';
import {JSDOM} from 'jsdom';
import {IDBFactory} from 'fake-indexeddb';
import {ApiError} from '../dist/api.js';
import {Outbox} from '../dist/outbox.js';
import {WebApp} from '../dist/app.js';
const session=(actor='a',role='contributor')=>({authenticated:true,role,household:{id:'household-'+actor,label:'Household '+actor},memberId:'member-'+actor,shopId:'shop-'+actor,replayWindow:{id:'window-'+actor,expiresAt:'2099-01-01T00:00:00Z'},csrf:'csrf',enrolled:true,queueConsent:false,...(['helper','editor'].includes(role)?{grantId:'grant-'+actor}:{})});
const row=()=>({requestId:'request-a',shopId:'shop-a',revision:1,originalItem:'PRIVATE OWN REQUEST',ownQuantity:null,authoredAt:'2026-11-06T12:00:00Z',receivedAt:'2026-11-06T12:00:01Z',route:'current',status:'pending',ownActionAllowed:true,clarification:null,followupTo:null});
const settle=async root=>{const end=Date.now()+1500;do{await new Promise(r=>setTimeout(r,5));assert.ok(Date.now()<end);}while(root.querySelector('main')?.getAttribute('aria-busy')==='true');};
async function setup(t,overrides={}){
 const dom=new JSDOM('<div id="app"></div>',{url:'https://fixture.test/requests'});t.after(()=>dom.window.close());
 const root=dom.window.document.getElementById('app');
 const api={session:async()=>session(),requests:async()=>[row()],authState:async()=>({available:false,authenticated:false,csrf:null}),receivedProposals:async()=>({proposals:[],nextCursor:null}),...overrides};
 const app=new WebApp(root,api,new Outbox(new IDBFactory()));await app.start();return {app,api,root,dom};
}
function draft(dom){const input=dom.window.document.getElementById('item');input.value='UNSENT PRIVATE DRAFT';input.dispatchEvent(new dom.window.Event('input',{bubbles:true}));}
test('history suspension hides own request and draft until delayed same-actor authority succeeds',async t=>{
 const {app,api,root,dom}=await setup(t);draft(dom);let release;
 api.session=()=>new Promise(r=>release=()=>r(session()));
 app.suspendForHistory();assert.doesNotMatch(root.textContent,/PRIVATE OWN REQUEST|Household a/);assert.equal(root.querySelector('#item'),null);
 app.resumeFromHistory();assert.equal(root.querySelector('#item'),null);release();await settle(root);
 assert.match(root.textContent,/PRIVATE OWN REQUEST/);assert.equal(root.querySelector('#item').value,'UNSENT PRIVATE DRAFT');
});
test('history network failure stays closed; explicit fresh authorization recovers the same-actor draft',async t=>{
 const {app,api,root,dom}=await setup(t);draft(dom);
 api.session=async()=>{throw new ApiError('network',0);};app.suspendForHistory();app.resumeFromHistory();await settle(root);
 assert.doesNotMatch(root.textContent,/PRIVATE OWN REQUEST|Household a/);assert.equal(root.querySelector('#item'),null);assert.match(root.textContent,/Could not load/);
 api.session=async()=>session();await app.start();assert.equal(root.querySelector('#item').value,'UNSENT PRIVATE DRAFT');
});
test('changed actor on history return clears the previous draft and request',async t=>{
 const {app,api,root,dom}=await setup(t);draft(dom);app.suspendForHistory();api.session=async()=>session('b');api.requests=async()=>[];
 app.resumeFromHistory();await settle(root);assert.doesNotMatch(root.textContent,/PRIVATE OWN REQUEST|Household a/);assert.equal(root.querySelector('#item').value,'');
});
test('history restore during an existing load waits and then revalidates instead of uncovering stale content',async t=>{
 const {app,api,root}=await setup(t);let release,reads=0;
 api.requests=()=>new Promise(r=>release=()=>r([row()]));const previous=app.start();await new Promise(r=>setTimeout(r,0));
 app.suspendForHistory();app.resumeFromHistory();api.session=async()=>{reads++;throw new ApiError('access_ended',403);};release();await previous;await settle(root);
 assert.equal(reads,1);assert.doesNotMatch(root.textContent,/PRIVATE OWN REQUEST|Household a/);assert.match(root.textContent,/Access has ended/);
});
for(const role of ['helper','editor'])test(`${role} history return remains closed after revocation`,async t=>{
 const {app,api,root}=await setup(t,{session:async()=>session('a',role),view:async()=>({grantId:'grant-a',shopId:'shop-a',shopLabel:'Shop a',revision:1,asOf:'2026-11-06T12:00:00Z',expiresAt:'2099-01-01T00:00:00Z',canPropose:role==='editor',instructions:[{item:'PRIVATE COOK INSTRUCTION',amount:null,action:'Prepare'}]})});
 assert.match(root.textContent,/PRIVATE COOK INSTRUCTION/);app.suspendForHistory();api.session=async()=>{throw new ApiError('access_ended',403);};app.resumeFromHistory();await settle(root);
 assert.doesNotMatch(root.textContent,/PRIVATE COOK INSTRUCTION|Household a/);assert.equal(root.querySelector('#correction'),null);assert.equal(root.querySelector('#item'),null);
});


test('history identity denial exposes available sign-in immediately even when the scope cookie keeps returning 401',async t=>{
 const {app,api,root,dom}=await setup(t);draft(dom);let attempts=0;
 api.session=async()=>{attempts++;throw new ApiError('session_needed',401);};
 api.authState=async()=>({available:true,authenticated:false,csrf:'fresh-challenge'});
 app.suspendForHistory();app.resumeFromHistory();await settle(root);
 assert.equal(attempts,1);assert.doesNotMatch(root.textContent,/PRIVATE OWN REQUEST|Household a/);
 assert.equal(root.querySelector('#item'),null);assert.ok(root.querySelector('#login-email'),'401 recovery must expose sign-in without another Refresh');
 const buttons=[...root.querySelectorAll('button')].map(button=>button.textContent);assert.ok(buttons.includes('Send sign-in code'));
});

for(const actor of ['a','b'])test(`history 401 email and code recovery ${actor==='a'?'preserves same-actor':'clears changed-actor'} draft`,async t=>{
 const {app,api,root,dom}=await setup(t);draft(dom);let expired=true;const login=[];
 api.session=async()=>{if(expired)throw new ApiError('session_needed',401);return session(actor);};
 api.authState=async()=>({available:true,authenticated:false,csrf:'fresh-challenge'});
 api.requests=async()=>actor==='a'?[row()]:[];
 api.sendEmailCode=async(email,csrf)=>{login.push(['email',email,csrf]);};
 api.verifyEmailCode=async(code,csrf)=>{login.push(['code',code,csrf]);expired=false;return {available:true,authenticated:true,csrf:'verified-challenge'};};
 app.suspendForHistory();app.resumeFromHistory();await settle(root);
 const email=root.querySelector('#login-email');assert.ok(email,'sign-in must be reachable without Refresh');email.value='fixture@example.test';email.dispatchEvent(new dom.window.Event('input'));
 root.querySelector('form').dispatchEvent(new dom.window.Event('submit',{cancelable:true}));await settle(root);
 const code=root.querySelector('#login-code');assert.ok(code);code.value='123456';code.dispatchEvent(new dom.window.Event('input'));
 root.querySelector('form').dispatchEvent(new dom.window.Event('submit',{cancelable:true}));await settle(root);
 assert.deepEqual(login,[['email','fixture@example.test','fresh-challenge'],['code','123456','fresh-challenge']]);
 assert.equal(root.querySelector('#login-email'),null);assert.equal(root.querySelector('#login-code'),null);
 assert.equal(root.querySelector('#item')?.value,actor==='a'?'UNSENT PRIVATE DRAFT':'');
 if(actor==='a')assert.match(root.textContent,/PRIVATE OWN REQUEST/);else assert.doesNotMatch(root.textContent,/PRIVATE OWN REQUEST|Household a/);
});
