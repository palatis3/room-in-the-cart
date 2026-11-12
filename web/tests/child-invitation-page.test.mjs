import assert from 'node:assert/strict';
import test from 'node:test';
import { webcrypto } from 'node:crypto';
import { JSDOM } from 'jsdom';
import { ChildInvitationAPI } from '../dist/child-invitation.js';
import { ChildInvitationPage, mountChildInvitationPage } from '../dist/child-invitation-page.js';
import { createChildFixture, fixtureInput } from './fixtures/child-invitation.mjs';
const tick=()=>new Promise(done=>setImmediate(done));
async function ready(root){for(let count=0;count<20&&root.querySelector('main')?.getAttribute('aria-busy')==='true';count++)await tick();assert.equal(root.querySelector('main')?.getAttribute('aria-busy'),'false');}
function input(dom,id,value){const element=dom.window.document.getElementById(id);assert.ok(element,`Missing field ${id}`);element.value=value;element.dispatchEvent(new dom.window.Event('input',{bubbles:true}));}
async function submit(dom,root){root.querySelector('form').dispatchEvent(new dom.window.Event('submit',{bubbles:true,cancelable:true}));await tick();await ready(root);}
async function click(root,text){const button=[...root.querySelectorAll('button')].find(item=>item.textContent===text);assert.ok(button,`Missing button ${text}`);assert.equal(button.disabled,false);button.click();await tick();await ready(root);}
async function setup(t,fixture=createChildFixture({configured:true}),token=fixtureInput.token,allowLocalStorage=false){
  const dom=new JSDOM('<div id="app"></div>',{url:'https://fixture.invalid/child-invite'});t.after(()=>dom.window.close());Object.defineProperty(dom.window,'crypto',{value:webcrypto});
  const stores=allowLocalStorage?['sessionStorage','indexedDB']:['localStorage','sessionStorage','indexedDB'];
  for(const name of stores)Object.defineProperty(dom.window,name,{get(){throw new Error('Enrollment private store touched');}});
  const api=new ChildInvitationAPI(fixture.fetcher),root=dom.window.document.getElementById('app'),page=new ChildInvitationPage(root,api,token);await page.start();
  return{dom,root,page,api,fixture};
}
async function signin(f){input(f.dom,'child-email',fixtureInput.email);await submit(f.dom,f.root);assert.ok(f.root.querySelector('#child-code'));input(f.dom,'child-code',fixtureInput.code);await submit(f.dom,f.root);assert.match(f.root.textContent,/Claim this child invitation/);}
async function paired(f){await signin(f);await click(f.root,'Claim this child invitation');assert.match(f.root.querySelector('#pairing-code').textContent,/^[A-Z2-7]{8}$/);}
async function approved(f){await paired(f);f.fixture.control('approve');await click(f.root,'Check current status');assert.match(f.root.textContent,/Your guardian confirmed/);}

async function mountedInvitation(t) {
  const fixture = createChildFixture({configured:true});
  const dom = new JSDOM('<div id="app"></div>', {url:'https://fixture.invalid/child-invite#token='+fixtureInput.token, pretendToBeVisual:true});
  t.after(()=>dom.window.close());
  Object.defineProperty(dom.window,'crypto',{value:webcrypto});
  const root=dom.window.document.querySelector('#app'), api=new ChildInvitationAPI(fixture.fetcher);
  assert.equal(mountChildInvitationPage(root,api),true);
  await ready(root);
  function visibility(state) {
    Object.defineProperty(dom.window.document,'visibilityState',{configurable:true,value:state});
    dom.window.document.dispatchEvent(new dom.window.Event('visibilitychange'));
  }
  return {fixture,dom,root,api,visibility};
}

test('history snapshots omit child pairing and a restored page rechecks withdrawn access',async t=>{
  const f=await mountedInvitation(t);await paired(f);
  const code=f.root.querySelector('#pairing-code').textContent;
  f.dom.window.dispatchEvent(new f.dom.window.PageTransitionEvent('pagehide',{persisted:true}));
  assert.equal(f.root.textContent.includes(code),false);
  f.fixture.control('withdraw');
  f.dom.window.dispatchEvent(new f.dom.window.PageTransitionEvent('pageshow',{persisted:true}));
  await tick();await ready(f.root);
  assert.match(f.root.textContent,/setup ended|no current child admission/);
  assert.equal(f.root.querySelector('#pairing-code, a[href="/requests"]'),null);
  assert.equal(f.fixture.counts.claimPosts,1);
});

test('switching to email conceals a child OTP draft and restores it only after fresh same-account authority',async t=>{
  const f=await mountedInvitation(t);
  input(f.dom,'child-email',fixtureInput.email);await submit(f.dom,f.root);
  input(f.dom,'child-code','123');
  f.visibility('hidden');
  assert.equal(f.root.querySelector('input'),null);
  const authState=f.api.authState.bind(f.api);
  f.api.authState=async()=>{throw new Error('Offline');};
  f.visibility('visible');await tick();await ready(f.root);
  assert.equal(f.root.querySelector('input'),null);
  f.api.authState=authState;
  await click(f.root,'Check current status');
  assert.equal(f.root.querySelector('#child-code')?.value,'123');
  assert.equal(f.fixture.counts.starts,1);
  assert.equal(f.fixture.counts.verifies,0);
});

test('only the latest return can reveal pairing, and each return rechecks guardian authority', async t => {
  const f = await mountedInvitation(t);
  await paired(f);
  const originalCode = f.root.querySelector('#pairing-code').textContent;
  const reads = [Promise.withResolvers(), Promise.withResolvers()];
  const availability = f.api.availability.bind(f.api);
  let calls = 0;
  f.api.availability = async language => {
    const read = reads[calls++];
    if (read) await read.promise;
    return availability(language);
  };
  f.visibility('hidden');
  f.visibility('visible');
  f.visibility('hidden');
  f.visibility('visible');
  assert.equal(calls, 1);
  reads[0].resolve();
  await tick();
  assert.equal(calls, 2);
  assert.equal(f.root.textContent.includes(originalCode), false);
  reads[1].resolve();
  await ready(f.root);
  assert.equal(f.root.querySelector('#pairing-code')?.textContent, originalCode);

  f.visibility('hidden');
  f.fixture.control('withdraw');
  f.visibility('visible');
  await ready(f.root);
  assert.match(f.root.textContent, /setup ended|no current child admission/);
  assert.equal(f.root.textContent.includes(originalCode), false);
  assert.equal(f.fixture.counts.claimPosts, 1);
  assert.equal(f.fixture.counts.finishPosts, 0);
});

test('a background history restore waits for visibility and drops the previous sign-in draft', async t => {
  const f = await mountedInvitation(t);
  input(f.dom, 'child-email', fixtureInput.email);
  f.visibility('hidden');
  const sessionReads = () => f.fixture.requests.filter(r => r.path === '/v1/auth/session').length;
  const reads = sessionReads();
  f.dom.window.dispatchEvent(new f.dom.window.PageTransitionEvent('pagehide', {persisted:true}));
  f.dom.window.dispatchEvent(new f.dom.window.PageTransitionEvent('pageshow', {persisted:true}));
  await tick();
  assert.equal(sessionReads(), reads);
  assert.equal(f.root.querySelector('input'), null);
  f.visibility('visible');
  await ready(f.root);
  assert.equal(f.root.querySelector('#child-email')?.value, '');
  assert.equal(f.root.querySelector('#child-invitation')?.value, '');
  assert.equal(f.fixture.counts.starts, 0);
});

test('an account change while the child is entering an email clears the invitation and email', async t => {
  const f = await mountedInvitation(t);
  input(f.dom, 'child-email', fixtureInput.email);
  f.visibility('hidden');
  f.fixture.control('reset');
  f.visibility('visible');
  await ready(f.root);
  assert.equal(f.root.querySelector('#child-email')?.value, '');
  assert.equal(f.root.querySelector('#child-invitation')?.value, '');
  assert.equal(f.fixture.counts.starts, 0);
});

test('a child signing in elsewhere cannot inherit an earlier invitation on this tab', async t => {
  const f = await mountedInvitation(t);
  const anotherInvite = fixtureInput.token.replace('22222222-', '99999999-');
  input(f.dom, 'child-invitation', anotherInvite);
  input(f.dom, 'child-email', 'previous@example.invalid');
  f.visibility('hidden');
  const auth = await f.api.authState();
  await f.api.startSignin(fixtureInput, auth.csrf);
  await f.api.verifySignin(fixtureInput.code, auth.csrf);
  f.visibility('visible');
  await ready(f.root);
  assert.equal(f.root.querySelector('#child-invitation')?.value, '');
  assert.equal(f.fixture.counts.claimPosts, 0);
  assert.equal(f.fixture.counts.finishPosts, 0);
});

test('configured covered flow uses guardian-approved auth, server pairing confirmation and exact scoped handoff',async t=>{
  const f=await setup(t);await paired(f);
  assert.equal(f.fixture.counts.starts,1);assert.equal(f.fixture.counts.verifies,1);assert.equal(f.fixture.counts.claims,1);assert.equal(f.fixture.counts.finishPosts,0);assert.doesNotMatch(f.root.textContent,/Finish child setup/);
  f.fixture.control('approve');await click(f.root,'Check current status');await click(f.root,'Finish child setup');
  assert.match(f.root.textContent,/own-request access is ready/);assert.equal(f.root.querySelector('a[href="/requests"]').textContent,'Open your requests');assert.equal(f.root.querySelector('#pairing-code'),null);
  assert.equal(f.fixture.counts.finishes,1);assert.equal(f.fixture.counts.forbidden,0);
  assert.doesNotMatch(f.root.textContent,/child@example|deviceSecret|deviceToken|123456/);
  const posts=f.fixture.requests.filter(row=>row.method==='POST').map(row=>row.path);assert.deepEqual(posts,['/v1/child-invitations/auth/start','/v1/auth/email/verify','/v1/child-invitations/claim','/v1/child-invitations/finish']);
  const recovered=new ChildInvitationPage(f.root,f.api);await recovered.start();assert.ok(f.root.querySelector('a[href="/requests"]'));assert.equal(f.fixture.counts.finishPosts,1);
});

test('generic authenticated account cannot display covered OTP, claim or own-request access',async t=>{
  const f=await setup(t);f.fixture.control('generic');await f.page.start();
  assert.match(f.root.textContent,/no current child admission/);assert.equal(f.root.querySelector('form'),null);assert.equal(f.root.querySelector('a[href="/requests"]'),null);assert.equal(f.fixture.counts.starts,0);assert.equal(f.fixture.counts.claimPosts,0);
});

test('interrupted child sign-out hides pairing after reload and retries using current identity',async t=>{
  const fixture=createChildFixture({configured:true}),fetcher=fixture.fetcher;
  let offline=false;
  fixture.fetcher=async(path,options)=>{
    if(offline&&path==='/v1/auth/session'&&options.method==='DELETE')throw new TypeError('disconnected');
    return fetcher(path,options);
  };
  const f=await setup(t,fixture,fixtureInput.token,true);await paired(f);
  offline=true;await click(f.root,'Sign out');
  assert.equal(f.root.querySelector('#pairing-code'),null);
  assert.equal(f.dom.window.localStorage.length,1);
  const before=fixture.requests.filter(row=>row.path==='/v1/auth/session').length;
  const reloaded=new ChildInvitationPage(f.root,f.api);await reloaded.start();
  assert.equal(f.root.querySelector('#pairing-code'),null);
  assert.equal(fixture.requests.filter(row=>row.path==='/v1/auth/session').length,before);
  offline=false;await click(f.root,'Retry sign-out');
  assert.equal(f.dom.window.localStorage.length,0);
  assert.ok(f.root.querySelector('#child-email'));
  assert.equal(f.root.querySelector('#pairing-code'),null);
});

test('wrong guardian-approved email cannot claim that an OTP was sent',async t=>{
  const f=await setup(t);input(f.dom,'child-email','another@example.invalid');await submit(f.dom,f.root);
  assert.match(f.root.textContent,/Check the invitation and guardian-approved email/);assert.doesNotMatch(f.root.textContent,/Check your email for a six-digit code/);assert.equal(f.fixture.counts.starts,0);assert.equal(f.root.querySelector('#child-code'),null);
});

test('uncertain covered OTP send has explicit code checking and no automatic resend on refresh',async t=>{
  const f=await setup(t);f.fixture.control('lose-start');input(f.dom,'child-email',fixtureInput.email);await submit(f.dom,f.root);
  assert.match(f.root.textContent,/Code delivery is unconfirmed/);assert.ok(f.root.querySelector('#child-code'));assert.equal(f.fixture.counts.starts,1);
  await click(f.root,'Check current status');assert.equal(f.fixture.counts.starts,1);input(f.dom,'child-code',fixtureInput.code);await submit(f.dom,f.root);assert.match(f.root.textContent,/Claim this child invitation/);assert.equal(f.fixture.counts.starts,1);
});

test('lost verify response reconciles cookie-bound admission without another OTP or verification',async t=>{
  const f=await setup(t);input(f.dom,'child-email',fixtureInput.email);await submit(f.dom,f.root);f.fixture.control('lose-verify');input(f.dom,'child-code',fixtureInput.code);await submit(f.dom,f.root);
  assert.match(f.root.textContent,/Sign-in could not be confirmed/);await click(f.root,'Check current status');assert.match(f.root.textContent,/Claim this child invitation/);assert.equal(f.fixture.counts.starts,1);assert.equal(f.fixture.counts.verifies,1);
  assert.equal(f.root.querySelector('#child-invitation')?.value,fixtureInput.token);
  await click(f.root,'Claim this child invitation');assert.ok(f.root.querySelector('#pairing-code'));
});

test('lost claim response retries the original pairing and key, then shows confirmed pairing',async t=>{
  const f=await setup(t);await signin(f);f.fixture.control('lose-claim');await click(f.root,'Claim this child invitation');
  assert.match(f.root.textContent,/invitation claim is unconfirmed/);assert.equal(f.root.querySelector('#pairing-code'),null);await click(f.root,'Retry original claim');
  assert.ok(f.root.querySelector('#pairing-code'));assert.equal(f.fixture.counts.claimPosts,2);assert.equal(f.fixture.counts.claims,1);assert.equal(f.fixture.counts.exactClaimRetries,1);
  const rows=f.fixture.requests.filter(row=>row.path==='/v1/child-invitations/claim');assert.deepEqual(rows[0].body,rows[1].body);
});

test('lost finish response with no cookie retries exact original finish and device secret',async t=>{
  const f=await setup(t);await approved(f);f.fixture.control('lose-finish');await click(f.root,'Finish child setup');
  assert.match(f.root.textContent,/setup response is unconfirmed/);assert.equal(f.root.querySelector('a[href="/requests"]'),null);await click(f.root,'Retry original setup');assert.ok(f.root.querySelector('a[href="/requests"]'));
  assert.equal(f.fixture.counts.finishPosts,2);assert.equal(f.fixture.counts.finishes,1);assert.equal(f.fixture.counts.exactFinishRetries,1);
  const rows=f.fixture.requests.filter(row=>row.path==='/v1/child-invitations/finish');assert.deepEqual(rows[0].body,rows[1].body);
});

test('lost finish body with installed cookie recovers access without another finish POST',async t=>{
  const f=await setup(t);await approved(f);f.fixture.control('lose-finish-cookie');await click(f.root,'Finish child setup');
  assert.match(f.root.textContent,/setup response is unconfirmed/);await click(f.root,'Check current status');assert.ok(f.root.querySelector('a[href="/requests"]'));assert.equal(f.fixture.counts.finishPosts,1);
});

for(const status of ['awaiting_guardian','approved'])test(`${status} cold reload shows missing original pairing and never creates replacement intent`,async t=>{
  const f=await setup(t);await paired(f);if(status==='approved')f.fixture.control('approve');
  const posts=f.fixture.requests.filter(row=>row.method==='POST').length;const recovered=new ChildInvitationPage(f.root,f.api);await recovered.start();
  assert.match(f.root.textContent,/kept only on the original page/);assert.match(f.root.textContent,/cancel this setup and review a new invitation/);assert.equal(f.root.querySelector('#pairing-code'),null);assert.equal(f.root.querySelector('form'),null);assert.doesNotMatch(f.root.textContent,/Finish child setup|Retry original setup/);
  await recovered.start();assert.equal(f.fixture.requests.filter(row=>row.method==='POST').length,posts);assert.equal(f.fixture.counts.finishPosts,0);
});

test('active cold reload without a scoped cookie does not infer credentials or finish again',async t=>{
  const f=await setup(t);await approved(f);f.fixture.control('lose-finish');await click(f.root,'Finish child setup');
  const recovered=new ChildInvitationPage(f.root,f.api);await recovered.start();assert.match(f.root.textContent,/access on this browser could not be confirmed/);assert.equal(f.root.querySelector('a[href="/requests"]'),null);assert.equal(f.root.querySelector('form'),null);assert.doesNotMatch(f.root.textContent,/Retry original setup/);assert.equal(f.fixture.counts.finishPosts,1);
});

test('accepted finish with malformed 200 and no cookie deterministically blocks cold-reload access without a second POST',async t=>{
  const f=await setup(t);await approved(f);f.fixture.control('lose-finish-no-cookie-body');await click(f.root,'Finish child setup');
  assert.match(f.root.textContent,/setup response is unconfirmed/);assert.equal(f.fixture.counts.finishPosts,1);assert.equal(f.fixture.counts.finishes,1);assert.equal(await f.api.scopedSession(),null);
  assert.equal(f.root.textContent.split('The setup response is unconfirmed. Check current status or retry the original setup from this page.').length-1,1,'Unconfirmed setup message appears once');
  const recovered=new ChildInvitationPage(f.root,f.api);await recovered.start();
  assert.match(f.root.textContent,/Setup is active, but access on this browser could not be confirmed/);assert.equal(f.root.querySelector('a[href="/requests"]'),null);assert.equal(f.root.querySelector('form'),null);assert.doesNotMatch(f.root.textContent,/Retry original setup/);
  assert.equal(f.root.textContent.split('Setup is active, but access on this browser could not be confirmed. Continue on the original page to retry its original setup, or ask your guardian to review a new setup.').length-1,1,'Missing browser access message appears once');
  assert.equal(f.fixture.counts.finishPosts,1);assert.equal(f.fixture.counts.finishes,1);assert.equal(f.fixture.counts.exactFinishRetries,0);
});

test('withdrawal and a changed session purge pairing and block finish',async t=>{
  const f=await setup(t);await paired(f);f.fixture.control('withdraw');await click(f.root,'Check current status');assert.match(f.root.textContent,/setup ended or the account changed/);assert.equal(f.root.querySelector('#pairing-code'),null);assert.equal(f.fixture.counts.finishPosts,0);
});

test('a mismatched scoped household cannot expose the own-request handoff',async t=>{
  const f=await setup(t);await approved(f);f.fixture.control('wrong-scope');await click(f.root,'Finish child setup');assert.equal(f.root.querySelector('a[href="/requests"]'),null);assert.equal(f.root.querySelector('#pairing-code'),null);assert.match(f.root.textContent,/setup ended or the account changed/);
});

test('availability and child session parsers reject invented authority and narrow unexpected fields',async()=>{
  const falseAuthority=new ChildInvitationAPI(async()=>Response.json({available:false,reason:null}));await assert.rejects(falseAuthority.availability('en'),error=>error.code==='invalid_response');
  const generic=new ChildInvitationAPI(async()=>Response.json({available:true,authenticated:true,admitted:true,scope:null,householdId:null,inviteId:null,claimId:null,status:'none',expiresAt:null}));await assert.rejects(generic.childSession(),error=>error.code==='invalid_response');
  const f=createChildFixture({configured:true}),api=new ChildInvitationAPI(f.fetcher);const auth=await api.authState();await api.startSignin(fixtureInput,auth.csrf);await api.verifySignin(fixtureInput.code,auth.csrf);const child=await api.childSession();assert.equal(child.scope,'own_requests');assert.equal(child.admitted,true);assert.deepEqual(Object.keys(child).sort(),['admitted','authenticated','available','claimId','expiresAt','householdId','inviteId','scope','status']);
});
