import test from 'node:test';
import assert from 'node:assert/strict';
import {JSDOM} from 'jsdom';
import {IDBFactory} from 'fake-indexeddb';
import {API,ApiError} from '../dist/api.js';
import {WebApp} from '../dist/app.js';
import {Outbox} from '../dist/outbox.js';
import {waitForIdle} from './fixtures/wait-for-idle.mjs';
function input(dom,id,value){const field=dom.window.document.getElementById(id);assert.ok(field,id);field.value=value;field.dispatchEvent(new dom.window.Event('input',{bubbles:true}));}
function submit(dom){dom.window.document.querySelector('form').dispatchEvent(new dom.window.Event('submit',{bubbles:true,cancelable:true}));}
async function fixture(overrides={},language='en'){
  let authenticated=false;const calls=[];
  const api={session:async()=>null,authState:async()=>({available:true,authenticated,csrf:authenticated?'auth-csrf':'challenge-csrf'}),sendEmailCode:async(email,csrf)=>calls.push({email,csrf}),verifyEmailCode:async(code,csrf)=>{calls.push({code,csrf});authenticated=true;return{available:true,authenticated:true,csrf:'auth-csrf'};},redeem:async()=>{calls.push('redeem');throw new ApiError('unavailable',404);},...overrides};
  const dom=new JSDOM('<div id="app"></div>',{url:'https://food.example/invite'});Object.defineProperty(dom.window.navigator,'language',{value:language});
  const root=dom.window.document.getElementById('app'),app=new WebApp(root,api,new Outbox(new IDBFactory()),'retained-invitation-secret');await app.start();return{dom,root,app,calls};
}

test('email login remains distinct from invitation acceptance and retains no credentials in browser storage',async()=>{
  const {dom,root,calls}=await fixture();assert.match(root.textContent,/Signing in does not join a household/);assert.equal(root.querySelector('#invitation'),null);
  input(dom,'login-email','adult@example.invalid');submit(dom);await waitForIdle(root);assert.match(root.textContent,/Check your email/);assert.equal(root.querySelector('#login-code').autocomplete,'one-time-code');
  input(dom,'login-code','123456');submit(dom);await waitForIdle(root);assert.match(root.textContent,/Review your invitation/);assert.equal(root.querySelector('input[type=password]'),null);assert.doesNotMatch(root.innerHTML,/retained-invitation-secret/);assert.equal(root.querySelector('#adult-attestation').checked,false);
  assert.deepEqual(calls,[{email:'adult@example.invalid',csrf:'challenge-csrf'},{code:'123456',csrf:'challenge-csrf'}]);
  assert.equal(dom.window.localStorage.length,0);assert.equal(dom.window.sessionStorage.length,0);assert.equal(dom.window.location.search,'');assert.equal(root.querySelector('#login-code'),null);
});

for(const replace of [false,true]){
  test(`linked invitation submits the reviewed code (replace=${replace})`,async()=>{
    const tokens=[];
    const {root,dom}=await fixture({
      authState:async()=>({available:true,authenticated:true,csrf:'fixture-csrf'}),
      redeem:async token=>{tokens.push(token);throw new ApiError('unavailable',404);}
    });
    const confirmAge=()=>{
      const adult=root.querySelector('#adult-attestation');
      adult.checked=true;
      adult.dispatchEvent(new dom.window.Event('change'));
    };
    confirmAge();
    if(replace){
      [...root.querySelectorAll('button')].find(b=>b.textContent==='Enter a different invitation code').click();
      const field=root.querySelector('#invitation');
      assert.equal(field,dom.window.document.activeElement);
      assert.equal(field.type,'password');
      assert.equal(field.value,'');
      assert.equal(root.querySelector('#adult-attestation').checked,false);
      input(dom,'invitation','replacement-code');
      confirmAge();
    }
    assert.deepEqual(tokens,[]);
    submit(dom);await waitForIdle(root);
    assert.deepEqual(tokens,[replace?'replacement-code':'retained-invitation-secret']);
  });
}

test('unconfigured email service is honest and cannot display a sent-code success',async()=>{
  const {root}=await fixture({authState:async()=>({available:false,authenticated:false,csrf:null})});
  assert.match(root.textContent,/Email sign-in is not available yet/);assert.equal(root.querySelector('form'),null);assert.doesNotMatch(root.textContent,/Check your email|Signed in/);
});

test('wrong code and rate limits remain recoverable failures with Spanish copy',async()=>{
  const {dom,root}=await fixture({verifyEmailCode:async()=>{throw new ApiError('code_not_accepted',422);}},'es-US');
  input(dom,'login-email','adult@example.invalid');submit(dom);await waitForIdle(root);input(dom,'login-code','000000');submit(dom);await waitForIdle(root);
  assert.match(root.textContent,/No se aceptó ese código/);assert.ok(root.querySelector('#login-code'));assert.equal(root.querySelector('#adult-attestation'),null);
});

test('auth API sends only same-origin code requests and ignores unexpected private response fields',async()=>{
  const calls=[];const api=new API(async(path,options)=>{calls.push({path,options});return Response.json(path.endsWith('/start')?{status:'check_email'}:{available:true,authenticated:path.endsWith('/verify'),csrf:'server-csrf',access_token:'MUST_NOT_ESCAPE',refresh_token:'MUST_NOT_ESCAPE'});});
  const state=await api.authState();assert.deepEqual(state,{available:true,authenticated:false,csrf:'server-csrf'});
  await api.sendEmailCode('adult@example.invalid',state.csrf);await api.verifyEmailCode('123456',state.csrf);
  for(const call of calls){assert.equal(call.options.credentials,'same-origin');assert.equal(call.options.cache,'no-store');assert.equal(call.options.headers.Authorization,undefined);}
  assert.deepEqual(JSON.parse(calls[2].options.body),{code:'123456'});assert.equal(calls[2].options.headers['X-CSRF-Token'],'server-csrf');
  await assert.rejects(api.verifyEmailCode('12345','csrf'),e=>e.status===422);
  const invalid=new API(async()=>Response.json({available:false,authenticated:true,csrf:null}));await assert.rejects(invalid.authState(),e=>e.code==='invalid_response');
});

test('fresh root with disabled email has no draft-save failure or invented invitation',async()=>{
  const dom=new JSDOM('<div id="app"></div>',{url:'https://food.example/'}),root=dom.window.document.getElementById('app');
  const api={session:async()=>null,authState:async()=>({available:false,authenticated:false,csrf:null})};
  const app=new WebApp(root,api,new Outbox(new IDBFactory()));await app.start();
  assert.equal(root.querySelector('[role="status"]').textContent,'');assert.match(root.textContent,/Email sign-in is not available yet\./);
  assert.doesNotMatch(root.textContent,/Not saved|Your text|Your invitation/);
});
test('transient bootstrap failure describes loading and clears after successful Refresh into disabled email',async()=>{
  let failed=true;const dom=new JSDOM('<div id="app"></div>',{url:'https://food.example/'}),root=dom.window.document.getElementById('app');
  const api={session:async()=>{if(failed)throw new ApiError('network',0);return null;},authState:async()=>({available:false,authenticated:false,csrf:null})};
  const app=new WebApp(root,api,new Outbox(new IDBFactory()));await app.start();
  assert.match(root.querySelector('[role="status"]').textContent,/Could not load your account/);assert.doesNotMatch(root.textContent,/Not saved|Your text|Your invitation/);
  failed=false;[...root.querySelectorAll('button')].find(button=>button.textContent==='Refresh').click();await waitForIdle(root);
  assert.equal(root.querySelector('[role="status"]').textContent,'');assert.match(root.textContent,/Email sign-in is not available yet/);assert.doesNotMatch(root.textContent,/Could not load|Not saved/);
});

test('default API fetch preserves the browser global receiver instead of binding the API instance',async()=>{
  const original=globalThis.fetch;let called=0;
  globalThis.fetch=function(_input,_init){
    assert.equal(this,globalThis,'native browser fetch requires its global receiver');called++;
    return Promise.resolve(Response.json({available:false,authenticated:false,csrf:null}));
  };
  try{assert.deepEqual(await new API().authState(),{available:false,authenticated:false,csrf:null});assert.equal(called,1);}finally{globalThis.fetch=original;}
});

test('a replacement sign-in challenge clears the previous email code on return', async () => {
  let csrf = 'first-challenge';
  const { app, dom, root, calls } = await fixture({
    authState: async () => ({ available: true, authenticated: false, csrf })
  });
  input(dom, 'login-email', 'first@example.invalid');
  submit(dom);
  await waitForIdle(root);
  input(dom, 'login-code', '123');
  app.suspendForHistory();
  app.resumeWithFreshAuthority();
  await waitForIdle(root);
  assert.equal(root.querySelector('#login-code')?.value, '123');
  app.suspendForHistory();
  csrf = 'replacement-challenge';
  app.resumeWithFreshAuthority();
  await waitForIdle(root);
  assert.equal(root.querySelector('#login-code'), null);
  assert.equal(root.querySelector('#login-email')?.value, '');
  assert.doesNotMatch(root.textContent, /Check your email for a six-digit code/);
  assert.equal(calls.length, 1);
});

test('a new browser identity must provide its own invitation, alias and age confirmation', async () => {
  let csrf = 'adult-a';
  const { app, dom, root, calls } = await fixture({
    authState: async () => ({ available: true, authenticated: true, csrf })
  });
  input(dom, 'invite-alias', 'First person');
  root.querySelector('#adult-attestation').click();
  app.suspendForHistory();
  csrf = 'adult-b';
  app.resumeWithFreshAuthority();
  await waitForIdle(root);
  assert.equal(root.querySelector('#invitation')?.value, '');
  assert.equal(root.querySelector('#invite-alias')?.value, '');
  assert.equal(root.querySelector('#adult-attestation')?.checked, false);
  assert.deepEqual(calls, []);
});

test('an invitation cannot be submitted with a newly active household when its identity check fails', async () => {
  let activated = false;
  const scope = { authenticated: true, role: 'contributor', memberId: 'new-member',
    household: { id: 'new-household', label: 'New household' }, shopId: 'new-shop',
    csrf: 'new-scope', replayWindow: { id: 'new-window', expiresAt: '2099-01-01' } };
  const { app, dom, root, calls } = await fixture({
    session: async () => activated ? scope : null,
    authState: async () => {
      if (activated) throw new Error('Offline');
      return { available: true, authenticated: true, csrf: 'first-identity' };
    },
    requests: async () => []
  });
  input(dom, 'invite-alias', 'Previous adult');
  root.querySelector('#adult-attestation').click();
  activated = true;
  await app.start();
  assert.equal(root.querySelector('#invitation, #adult-attestation'), null);
  assert.equal(root.textContent.includes('Previous adult'), false);
  assert.deepEqual(calls, []);
});

for (const ending of ['grant expires', 'session returns 401']) {
  test('an invitation opened by an enrolled helper is cleared when its '+ending, async t => {
    let ended = false;
    const now = Date.now();
    const scope = { authenticated:true, role:'helper', grantId:'grant-a', shopId:'shop-a',
      memberId:'member-a', household:{id:'household-a',label:'A'}, csrf:'scope-a' };
    const { app, dom, root } = await fixture({
      session:async () => {
        if (ended) throw new ApiError('session_needed',401);
        return scope;
      },
      authState:async () => ({ available:true, authenticated:true, csrf:'identity-b' }),
      view:async () => ({ grantId:'grant-a', shopId:'shop-a', shopLabel:'A', revision:1,
        asOf:new Date(now).toISOString(), expiresAt:new Date(now+60_000).toISOString(),
        canPropose:false, instructions:[] }),
      receivedProposals:async () => ({ proposals:[], nextCursor:null })
    });
    input(dom, 'invite-alias', 'First helper');
    root.querySelector('#adult-attestation').click();
    if (ending === 'grant expires') {
      t.mock.method(Date,'now',()=>now+60_001);
      app.checkExpiry();
    }
    ended = true;
    await app.start();
    assert.equal(root.querySelector('#invitation')?.value, '');
    assert.equal(root.querySelector('#invite-alias')?.value, '');
    assert.equal(root.querySelector('#adult-attestation')?.checked, false);
  });
}

test('a revoked household cookie lets a signed-in adult sign out using current identity', async () => {
  let ended = false, signedOut = false;
  const recovery=Promise.withResolvers();
  const { app, root, dom } = await fixture({
    session:async () => { if(ended){await recovery.promise;throw new ApiError('access_ended',403);}return null; },
    authState:async () => ({ available:true, authenticated:!signedOut, csrf:signedOut?'new-challenge':'current-identity' }),
    logoutIdentity:async csrf => { assert.equal(csrf,'current-identity');signedOut=true;return {providerRevoked:true}; }
  });
  input(dom,'invite-alias','Previous name');
  root.querySelector('#adult-attestation').click();
  ended = true;
  app.suspendForHistory();
  app.resumeWithFreshAuthority();
  assert.equal(root.querySelector('main').getAttribute('aria-busy'),'true');
  assert.equal(root.querySelector('#invite-alias'),null);
  recovery.resolve();
  await waitForIdle(root);
  assert.match(root.textContent,/Access has ended/);
  assert.equal(root.querySelector('#adult-attestation')?.checked,false);
  assert.equal(root.querySelector('#invitation')?.value,'');
  const button=[...root.querySelectorAll('button')].find(b=>b.textContent==='Sign out');
  assert.ok(button);
  button.click();
  await waitForIdle(root);
  assert.equal(signedOut,true);
  assert.ok(root.querySelector('#login-email'));
});

test('when a verified adult cookie outlives a lost response, explain how to recover the invitation', async () => {
  let verified=false, verifies=0;
  const { app, dom, root } = await fixture({
    authState:async () => ({ available:true,authenticated:verified,csrf:verified?'verified':'challenge' }),
    verifyEmailCode:async () => { verifies++;verified=true;throw new Error('Lost response'); }
  });
  input(dom,'login-email','first@example.invalid');
  submit(dom);
  await waitForIdle(root);
  input(dom,'login-code','123456');
  submit(dom);
  await waitForIdle(root);
  app.suspendForHistory();
  app.resumeWithFreshAuthority();
  await waitForIdle(root);
  assert.match(root.textContent,/Reopen the invitation you want to use/);
  assert.equal(root.querySelector('#invitation')?.value,'');
  assert.equal(root.querySelector('#adult-attestation')?.checked,false);
  assert.equal(verifies,1);
});
