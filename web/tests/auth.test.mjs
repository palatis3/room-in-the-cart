import test from 'node:test';
import assert from 'node:assert/strict';
import {JSDOM} from 'jsdom';
import {IDBFactory} from 'fake-indexeddb';
import {API,ApiError,consumeInvitation} from '../dist/api.js';
import {WebApp} from '../dist/app.js';
import {Outbox} from '../dist/outbox.js';
import {waitForIdle} from './fixtures/wait-for-idle.mjs';
function input(dom,id,value){const field=dom.window.document.getElementById(id);assert.ok(field,id);field.value=value;field.dispatchEvent(new dom.window.Event('input',{bubbles:true}));}
function submit(dom){dom.window.document.querySelector('form').dispatchEvent(new dom.window.Event('submit',{bubbles:true,cancelable:true}));}
async function fixture(overrides={},language='en'){
  let authenticated=false;const calls=[];
  const api={previewInvite:async()=>({householdLabel:'Inviting household',role:'adult_contributor'}),session:async()=>null,authState:async()=>({available:true,authenticated,csrf:authenticated?'auth-csrf':'challenge-csrf'}),sendEmailCode:async(email,csrf)=>calls.push({email,csrf}),verifyEmailCode:async(code,csrf)=>{calls.push({code,csrf});authenticated=true;return{available:true,authenticated:true,csrf:'auth-csrf'};},redeem:async()=>{calls.push('redeem');throw new ApiError('unavailable',404);},...overrides};
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
    confirmAge();await waitForIdle(root);
    if(replace){
      [...root.querySelectorAll('button')].find(b=>b.textContent==='Enter a different invitation code').click();
      const field=root.querySelector('#invitation');
      assert.equal(field,dom.window.document.activeElement);
      assert.equal(field.type,'password');
      assert.equal(field.value,'');
      assert.equal(root.querySelector('#adult-attestation').checked,false);
      input(dom,'invitation','replacement-code');
      confirmAge();await waitForIdle(root);
    }
    assert.deepEqual(tokens,[]);
    submit(dom);await waitForIdle(root);
    assert.deepEqual(tokens,[replace?'replacement-code':'retained-invitation-secret']);
  });
}

for (const [language, heading, joinedHeading] of [
  ['en', 'Enter an invitation code', 'Ask the shopper'],
  ['es', 'Ingresa un código de invitación', 'Pedir a quien hace la compra']
]) {
  for (const [status, code] of [[404, 'unavailable'], [403, 'access_ended']]) {
    test(`a rejected invitation accepts a replacement code in ${language} (${status})`, async () => {
      const submitted = [];
      let active = false;
      const scope = { authenticated:true, role:'contributor', household:{id:'home',label:'Replacement household'},
        memberId:'member', shopId:'shop', csrf:'scope', enrolled:true, queueConsent:false,
        replayWindow:{id:'window',expiresAt:'2099-01-01T00:00:00Z'} };
      const { dom, root } = await fixture({
        authState:async () => ({ available:true, authenticated:true, csrf:'identity' }),
        session:async () => active ? scope : null,
        redeem:async (token, _csrf, review) => {
          submitted.push([token, review.alias]);
          if (token === 'retained-invitation-secret') throw new ApiError(code,status);
          return { householdId:'home', memberId:'member', role:'contributor' };
        },
        activateSession:async () => { active = true; },
        requests:async () => []
      }, language);
      root.querySelector('#adult-attestation').click();await waitForIdle(root);
      input(dom,'invite-alias','Earlier alias');
      submit(dom);
      await waitForIdle(root);
      assert.equal(root.querySelector('h1').textContent,heading);
      assert.equal(root.querySelector('#invitation').value,'');
      assert.equal(root.querySelector('#invite-alias'),null);
      assert.equal(root.querySelector('#adult-attestation').checked,false);
      assert.match(root.querySelector('[role=status]').textContent,/new invitation|nueva invitación/);
      const invitation = root.querySelector('#invitation');
      const notice = root.querySelector('[role=status]');
      const rejected = notice.textContent;
      invitation.focus();
      input(dom,'invitation','   ');
      assert.equal(notice.textContent,rejected);
      invitation.value = 'replacement-code';
      invitation.setSelectionRange(5,5);
      invitation.dispatchEvent(new dom.window.Event('input',{bubbles:true}));
      assert.equal(notice.textContent,status === 404 ? '' : rejected);
      assert.equal(dom.window.document.activeElement,invitation);
      assert.equal(invitation.selectionStart,5);
      assert.equal(invitation.selectionEnd,5);
      root.querySelector('#adult-attestation').click();await waitForIdle(root);
      submit(dom);
      await waitForIdle(root);
      assert.deepEqual(submitted,[['retained-invitation-secret','Earlier alias'],['replacement-code','']]);
      assert.equal(root.querySelector('h1').textContent,joinedHeading);
      const confirmation=root.querySelector('[role=status]');
      assert.equal(dom.window.document.activeElement,confirmation);
      assert.match(confirmation.textContent,/Replacement household/);
      assert.match(confirmation.textContent,language==='en'?/your own grocery requests/:/tus propias solicitudes/);
      assert.doesNotMatch(confirmation.textContent,/instructions|instrucciones/);
      dom.window.close();
    });
  }
}

for (const [role, canPropose] of [['helper',false], ['editor',false], ['editor',true]]) {
  test(`confirmed ${role} invitation describes its actual view (suggestions=${canPropose})`,async t => {
    let current=null;
    let online=false;
    const grantId='supper-grant';
    const scope={authenticated:true,role,grantId,memberId:'cook',shopId:'pickup',
      household:{id:'home',label:'A & B $& kitchen'},enrolled:true,csrf:'scope-csrf'};
    const {app,dom,root}=await fixture({
      authState:async()=>({available:true,authenticated:true,csrf:'identity-csrf'}),
      session:async()=>current,
      redeem:async()=>({householdId:'home',memberId:'cook',role,grantId}),
      activateSession:async()=>{if(!online)throw new ApiError('network',0);current=scope;},
      view:async()=>({grantId,shopId:'pickup',shopLabel:'Friday',revision:1,expiresAt:'2099-01-01T00:00:00Z',
        asOf:'2026-11-01T12:00:00Z',instructions:[],canPropose}),
      receivedProposals:async()=>({proposals:[],nextCursor:null})
    });
    t.after(()=>dom.window.close());
    root.querySelector('#adult-attestation').click();await waitForIdle(root);
    submit(dom);await waitForIdle(root);
    const status=()=>root.querySelector('[role=status]').textContent;
    assert.doesNotMatch(status(),/You joined|A & B/);
    online=true;submit(dom);await waitForIdle(root);
    assert.match(status(),/You joined A & B \$& kitchen\./);
    assert.match(status(),/instructions shared with you/);
    assert.equal(status().includes('suggest changes'),canPropose);
    assert.doesNotMatch(status(),/own grocery requests/);
    const picker=root.querySelector('#language');
    picker.value='es';picker.dispatchEvent(new dom.window.Event('change'));
    assert.match(status(),/Te uniste a A & B \$& kitchen\./);
    assert.match(status(),/instrucciones que compartieron contigo/);
    assert.equal(status().includes('sugerir cambios'),canPropose);
    app.suspendForHistory();
    assert.doesNotMatch(root.textContent,/A & B|Te uniste/);
    current=null;app.resumeWithFreshAuthority();await waitForIdle(root);
    assert.doesNotMatch(root.textContent,/A & B|Te uniste/);
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
  root.querySelector('#adult-attestation').click();await waitForIdle(root);
  input(dom, 'invite-alias', 'First person');
  app.suspendForHistory();
  csrf = 'adult-b';
  app.resumeWithFreshAuthority();
  await waitForIdle(root);
  assert.equal(root.querySelector('#invitation')?.value, '');
  assert.equal(root.querySelector('#invite-alias'),null);
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
  root.querySelector('#adult-attestation').click();await waitForIdle(root);
  input(dom, 'invite-alias', 'Previous adult');
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
    root.querySelector('#adult-attestation').click();await waitForIdle(root);
    input(dom, 'invite-alias', 'First helper');
    if (ending === 'grant expires') {
      t.mock.method(Date,'now',()=>now+60_001);
      app.checkExpiry();
    }
    ended = true;
    await app.start();
    assert.equal(root.querySelector('#invitation')?.value, '');
    assert.equal(root.querySelector('#invite-alias'),null);
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
  root.querySelector('#adult-attestation').click();await waitForIdle(root);
  input(dom,'invite-alias','Previous name');
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

test('leaving an invitation clears only its draft and the public destination carries only the language', async () => {
  for (const language of ['en', 'es']) {
    const {root, dom, app, calls} = await fixture({
      authState: async () => ({available: true, authenticated: true, csrf: 'fixture-csrf'})
    }, language);
    root.querySelector('#adult-attestation').click();await waitForIdle(root);
    input(dom, 'invite-alias', 'Picnic helper');
    const leave = [...root.querySelectorAll('a')].find(link =>
      link.textContent === (language === 'es' ? 'Salir sin unirme' : 'Leave without joining'));
    assert.ok(leave);
    assert.equal(leave.getAttribute('href'), '/help?lang=' + language);
    assert.equal(leave.referrerPolicy, 'no-referrer');
    leave.addEventListener('click', event => event.preventDefault());
    leave.click();
    app.render();
    assert.equal(root.querySelector('#invitation')?.value, '');
    assert.equal(root.querySelector('#invite-alias'),null);
    assert.equal(root.querySelector('#adult-attestation')?.checked, false);
    assert.deepEqual(calls, []);
  }
});

test('an unavailable invitation offers language-matched public help and support without carrying the invitation', async () => {
  for (const language of ['en', 'es']) {
    const {root} = await fixture({authState: async () => ({available: false, authenticated: false, csrf: null})}, language);
    const links = [...root.querySelectorAll('a')];
    assert.deepEqual(links.map(link => link.getAttribute('href')), ['/help?lang=' + language, '/support?lang=' + language]);
    assert.deepEqual(links.map(link => link.textContent), language === 'es'
      ? ['Ayuda pública', 'Opciones de soporte'] : ['Public help', 'Support options']);
    assert.ok(links.every(link => link.referrerPolicy === 'no-referrer'));
    assert.equal(root.querySelector('form'), null);
  }
});

test('a replacement waits for the current join and clears its activation retry before the next review', async t => {
  const redeemed = [], activated = [];
  const pendingActivation = Promise.withResolvers();
  const activationStarted = Promise.withResolvers();
  const oldToken = 'retained-invitation-secret';
  const { app, root, dom } = await fixture({
    authState:async () => ({ available:true, authenticated:true, csrf:'identity' }),
    redeem:async (token, _csrf, review) => {
      redeemed.push([token, review.alias]);
      if (token !== oldToken) throw new ApiError('unavailable', 404);
      return { householdId:'old-household', memberId:'member', role:'contributor' };
    },
    activateSession:async household => {
      activated.push(household);
      if (activated.length === 2) {
        activationStarted.resolve();
        await pendingActivation.promise;
      }
      throw new ApiError('network', 0);
    }
  });
  t.after(() => dom.window.close());
  root.querySelector('#adult-attestation').click();await waitForIdle(root);
  input(dom, 'invite-alias', 'Previous alias');
  submit(dom); await waitForIdle(root);
  app.openInvitation(oldToken);
  submit(dom); await activationStarted.promise;
  assert.deepEqual(redeemed, [[oldToken, 'Previous alias']], 'Retry must reuse the receipt');
  app.openInvitation('intermediate-code');
  app.openInvitation('newest-code');
  assert.equal(root.querySelector('form'), null);
  pendingActivation.resolve();
  await waitForIdle(root);
  assert.equal(root.querySelector('#adult-attestation').checked, false);
  assert.equal(root.querySelector('#invite-alias'),null);
  assert.equal(root.querySelector('[role=status]').textContent, '');
  assert.deepEqual(activated, ['old-household', 'old-household']);
  root.querySelector('#adult-attestation').click();await waitForIdle(root);
  submit(dom); await waitForIdle(root);
  assert.deepEqual(redeemed, [[oldToken, 'Previous alias'], ['newest-code', '']]);
  assert.equal(activated.length, 2);
});

test('an offline link replacement waits for a verified identity and keeps the newest invitation for retry', async t => {
  const attempts = [];
  let online = true, identity = 'old-identity';
  const { app, root, dom } = await fixture({
    session:async () => {
      if (!online) throw new ApiError('network', 0);
      return null;
    },
    authState:async () => ({ available:true, authenticated:true, csrf:identity }),
    redeem:async (token, csrf, review) => {
      attempts.push([token, csrf, review.alias]);
      throw new ApiError('unavailable', 404);
    }
  });
  t.after(() => dom.window.close());
  root.querySelector('#adult-attestation').click();await waitForIdle(root);
  input(dom, 'invite-alias', 'Previous alias');
  online = false;
  app.openInvitation('replacement');
  await waitForIdle(root);
  assert.equal(root.querySelector('form'), null);
  assert.match(root.textContent, /Could not load/);
  online = true;
  identity = 'current-identity';
  await app.start();
  assert.equal(root.querySelector('#adult-attestation').checked, false);
  assert.equal(root.querySelector('#invite-alias'),null);
  assert.deepEqual(attempts, []);
  root.querySelector('#adult-attestation').click();await waitForIdle(root);
  submit(dom); await waitForIdle(root);
  assert.deepEqual(attempts, [['replacement', 'current-identity', '']]);
});

for (const [language, guidance, entryHint] of [
  ['en','Confirm your age to see which household invited you and what you can do there.',
    'Open the link from your household, or enter its invitation code below.'],
  ['es','Confirma tu edad para ver qué hogar te invitó y qué podrás hacer allí.',
    'Abre el enlace que te envió tu familia o ingresa el código de invitación aquí.']
]) {
  for (const manual of [false,true]) {
    test(`household confirmation guidance precedes an explicit join in ${language} (manual=${manual})`,async t=>{
      const secret='example-invite';
      const url='https://fixture.test/invite?lang='+language+(manual?'&enterCode=1':'#token='+secret);
      const dom=new JSDOM('<div id="app"></div>',{url});t.after(()=>dom.window.close());
      const root=dom.window.document.getElementById('app'), writes=[];
      const api={
        session:async()=>({authenticated:true,role:'contributor',household:{id:'existing',label:'Existing household name'},
          memberId:'member',shopId:'shop',enrolled:true,queueConsent:false,csrf:'verified'}),
        previewInvite:async(received,csrf,adult)=>{assert.equal(received,secret);assert.equal(csrf,'verified');assert.equal(adult,true);return {householdLabel:'Picnic house',role:'helper_read'};},
        requests:async()=>[],
        redeem:async token=>{writes.push(token);throw new ApiError('unavailable',404);},
        activateSession:async()=>{writes.push('activation');}
      };
      const token=consumeInvitation(dom.window.location,dom.window.history);
      const app=new WebApp(root,api,new Outbox(new IDBFactory()),token);await app.start();
      assert.equal(dom.window.location.href,'https://fixture.test/invite?lang='+language);
      assert.ok(root.textContent.includes(guidance));
      assert.equal(root.textContent.includes(entryHint),manual);
      assert.ok(!root.innerHTML.includes(secret));
      assert.ok(!root.textContent.includes('Existing household name'));
      if(manual)input(dom,'invitation',secret);
      submit(dom);await waitForIdle(root);
      assert.deepEqual(writes,[]);
      root.querySelector('#adult-attestation').click();await waitForIdle(root);
      assert.deepEqual(writes,[]);
      assert.equal(root.querySelector('#invitation-household').textContent,'Picnic house');
      submit(dom);await waitForIdle(root);
      assert.deepEqual(writes,[secret]);
    });
  }
}

test('a late preview cannot populate a replacement invitation, and a rejected replacement never reveals an offer',async t=>{
  const started=Promise.withResolvers(),old=Promise.withResolvers();
  const tokens=[];
  const {app,dom,root}=await fixture({
    authState:async()=>({available:true,authenticated:true,csrf:'adult'}),
    previewInvite:async token=>{
      tokens.push(token);
      if(tokens.length===1){started.resolve();await old.promise;return {householdLabel:'Original household',role:'helper_edit'};}
      throw new ApiError('unavailable',404);
    },
    redeem:async()=>assert.fail('No explicit Join'),
    activateSession:async()=>assert.fail('No enrollment')
  });
  t.after(()=>dom.window.close());
  root.querySelector('#adult-attestation').click();await started.promise;
  app.openInvitation('replacement');
  assert.equal(root.querySelector('form'),null);
  old.resolve();await waitForIdle(root);
  assert.doesNotMatch(root.textContent,/Original household/);
  assert.equal(root.querySelector('#adult-attestation').checked,false);
  root.querySelector('#adult-attestation').click();await waitForIdle(root);
  assert.deepEqual(tokens,['retained-invitation-secret','replacement']);
  assert.equal(root.querySelector('#invitation').value,'');
  assert.equal(root.querySelector('#invite-alias'),null);
  assert.match(root.querySelector('[role=status]').textContent,/new invitation/);
});

test('a continuously open preview expires and needs an explicit fresh check',async t=>{
  const now=Date.now();let checks=0;
  const {app,dom,root}=await fixture({
    authState:async()=>({available:true,authenticated:true,csrf:'adult'}),
    previewInvite:async()=>{
      if(++checks===1)return {householdLabel:'Picnic kitchen',role:'helper_read'};
      throw new ApiError('unavailable',404);
    }
  });
  t.after(()=>dom.window.close());
  root.querySelector('#adult-attestation').click();await waitForIdle(root);
  assert.equal(root.querySelector('#invitation-household')?.textContent,'Picnic kitchen');
  t.mock.method(Date,'now',()=>now+121_000);
  app.checkExpiry();
  assert.doesNotMatch(root.textContent,/Picnic kitchen|Join this household/);
  assert.equal(checks,1);
  submit(dom);await waitForIdle(root);
  assert.equal(checks,2);assert.match(root.textContent,/new invitation/);
});

test('a lost join response keeps the original confirmed offer available for an explicit retry only',async t=>{
  const offer={householdLabel:'Weekend kitchen',role:'adult_contributor'};
  const attempts=[];let previews=0;
  const {app,dom,root}=await fixture({
    authState:async()=>({available:true,authenticated:true,csrf:'adult'}),
    previewInvite:async()=>{previews++;return offer;},
    redeem:async(token,csrf,review)=>{attempts.push({token,csrf,review});throw new ApiError('network',0);}
  });
  t.after(()=>dom.window.close());
  root.querySelector('#adult-attestation').click();await waitForIdle(root);
  input(dom,'invite-alias','Weekend cook');
  submit(dom);await waitForIdle(root);
  assert.doesNotMatch(root.textContent,/Weekend kitchen/);assert.match(root.textContent,/Retry joining/);
  await app.start();assert.equal(previews,1);assert.equal(attempts.length,1);
  submit(dom);await waitForIdle(root);
  assert.equal(attempts.length,2);assert.deepEqual(attempts[0],attempts[1]);
  assert.deepEqual(attempts[1].review.reviewedOffer,offer);
});

test('preview uses authenticated body-only exchange and rejects unrecognized roles and empty names',async()=>{
  const sent=[];let role='helper_edit',householdLabel='Saturday kitchen';
  const api=new API(async(path,options)=>{sent.push({path,options});return Response.json({householdLabel,role,member:'not disclosed'});});
  await assert.rejects(api.previewInvite('token','csrf',false),error=>error.status===422);
  assert.equal(sent.length,0);
  assert.deepEqual(await api.previewInvite('token','csrf',true),{householdLabel,role});
  const {path,options}=sent[0];assert.equal(path,'/v1/invites/preview');
  assert.deepEqual(JSON.parse(options.body),{token:'token',adultAttestation:true});
  assert.equal(options.headers['X-CSRF-Token'],'csrf');assert.equal(options.cache,'no-store');
  assert.equal(options.referrerPolicy,'no-referrer');assert.equal(options.credentials,'same-origin');
  role='organizer';await assert.rejects(api.previewInvite('token','csrf',true),error=>error.code==='invalid_response');
  role='helper_edit';householdLabel=' ';await assert.rejects(api.previewInvite('token','csrf',true),error=>error.code==='invalid_response');
});

for(const [offeredRole,scopedRole] of [['adult_contributor','contributor'],['helper_read','helper']]){
  test(`an existing organizer opens only the narrow ${scopedRole} session they accepted`,async t=>{
    let current={authenticated:true,role:'organizer',household:{id:'home',label:'Weekend kitchen'},
      memberId:'organizer',shopId:'shop',csrf:'initial',enrolled:true,queueConsent:false};
    const grantId=scopedRole==='helper'?'accepted-grant':undefined;
    const offer={householdLabel:current.household.label,role:offeredRole};
    const reads=[],accepted=[];
    const {dom,root}=await fixture({
      session:async()=>current,
      previewInvite:async()=>offer,
      redeem:async(_token,_csrf,review)=>{
        assert.deepEqual(review.reviewedOffer,offer);
        return {householdId:'home',memberId:'organizer',role:scopedRole,grantId};
      },
      activateSession:async(h,csrf,grant)=>{
        accepted.push([h,csrf,grant]);
        current={...current,role:scopedRole,csrf:'scoped',grantId:grant,canContribute:!grant};
      },
      requests:async session=>{reads.push([session.role,session.grantId]);return [];},
      view:async session=>{
        reads.push([session.role,session.grantId]);
        return {grantId,shopId:'shop',shopLabel:'Shared instructions',revision:1,asOf:'2026-11-22T00:00:00Z',expiresAt:'2099-01-01T00:00:00Z',canPropose:false,instructions:[]};
      },
      receivedProposals:async()=>({proposals:[],nextCursor:null})
    });
    t.after(()=>dom.window.close());
    root.querySelector('#adult-attestation').click();await waitForIdle(root);
    assert.match(root.querySelector('#invitation-household').parentElement.textContent,/This invitation lets you/);
    assert.deepEqual(accepted,[]);
    reads.length=0;
    submit(dom);await waitForIdle(root);
    assert.deepEqual(accepted,[['home','initial',grantId]]);
    assert.deepEqual(reads,[[scopedRole,grantId]]);
    assert.match(root.querySelector('[role=status]').textContent,/You joined Weekend kitchen/);
  });
}
