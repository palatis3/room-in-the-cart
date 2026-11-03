import assert from 'node:assert/strict';
import test from 'node:test';
import { webcrypto } from 'node:crypto';
import { JSDOM } from 'jsdom';
import { ChildInvitationAPI } from '../dist/child-invitation.js';
import { ChildInvitationPage } from '../dist/child-invitation-page.js';
import { createChildFixture, fixtureInput } from './fixtures/child-invitation.mjs';
const tick=()=>new Promise(done=>setImmediate(done));
async function ready(root){for(let count=0;count<20&&root.querySelector('main')?.getAttribute('aria-busy')==='true';count++)await tick();assert.equal(root.querySelector('main')?.getAttribute('aria-busy'),'false');}
function input(dom,id,value){const element=dom.window.document.getElementById(id);assert.ok(element,`Missing field ${id}`);element.value=value;element.dispatchEvent(new dom.window.Event('input',{bubbles:true}));}
async function submit(dom,root){root.querySelector('form').dispatchEvent(new dom.window.Event('submit',{bubbles:true,cancelable:true}));await tick();await ready(root);}
async function click(root,text){const button=[...root.querySelectorAll('button')].find(item=>item.textContent===text);assert.ok(button,`Missing button ${text}`);assert.equal(button.disabled,false);button.click();await tick();await ready(root);}
async function setup(t,fixture=createChildFixture({configured:true}),token=fixtureInput.token){
  const dom=new JSDOM('<div id="app"></div>',{url:'https://fixture.invalid/child-invite'});t.after(()=>dom.window.close());Object.defineProperty(dom.window,'crypto',{value:webcrypto});
  for(const name of ['localStorage','sessionStorage','indexedDB'])Object.defineProperty(dom.window,name,{get(){throw new Error('Enrollment private store touched');}});
  const api=new ChildInvitationAPI(fixture.fetcher),root=dom.window.document.getElementById('app'),page=new ChildInvitationPage(root,api,token);await page.start();
  return{dom,root,page,api,fixture};
}
async function signin(f){input(f.dom,'child-email',fixtureInput.email);await submit(f.dom,f.root);assert.ok(f.root.querySelector('#child-code'));input(f.dom,'child-code',fixtureInput.code);await submit(f.dom,f.root);assert.match(f.root.textContent,/Claim this child invitation/);}
async function paired(f){await signin(f);await click(f.root,'Claim this child invitation');assert.match(f.root.querySelector('#pairing-code').textContent,/^[A-Z2-7]{8}$/);}
async function approved(f){await paired(f);f.fixture.control('approve');await click(f.root,'Check current status');assert.match(f.root.textContent,/Your guardian confirmed/);}

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
