import assert from 'node:assert/strict';
import test from 'node:test';
import { webcrypto } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { JSDOM } from 'jsdom';
import { ApiError } from '../dist/api.js';
import { ChildInvitationAPI, ChildClaimController } from '../dist/child-invitation.js';
import { mountChildInvitationPage, childInvitationCopy } from '../dist/child-invitation-page.js';

const ids={household:'11111111-1111-4111-8111-111111111111',claim:'22222222-2222-4222-8222-222222222222',member:'33333333-3333-4333-8333-333333333333',device:'44444444-4444-4444-8444-444444444444',key:'55555555-5555-4555-8555-555555555555'};
const expiry='2030-01-01T00:00:00.000Z';
const receipt={householdId:ids.household,claimId:ids.claim,status:'awaiting_guardian',expiresAt:expiry};
const credential={householdId:ids.household,memberId:ids.member,role:'contributor',deviceId:ids.device};
const access={kind:'approved_child_session',scope:'fixture-only-child-session',csrf:'fixture-csrf'};
function fixture(overrides={}) {
  let current=access,status='awaiting_guardian';const calls=[];
  const api={claim:async(_access,input)=>{calls.push({kind:'claim',input});return receipt;},status:async()=>({claimId:ids.claim,status,expiresAt:expiry}),finish:async(_access,input)=>{calls.push({kind:'finish',input});return credential;},...overrides};
  const controller=new ChildClaimController({current:async()=>current},api,webcrypto,()=>Date.parse('2026-11-03T12:00:00Z'));
  return {controller,calls,setAccess:value=>{current=value;},setStatus:value=>{status=value;}};
}

test('prepared caller has no claim authority without an approved live child session',async()=>{
  const f=fixture();f.setAccess(null);
  await assert.rejects(f.controller.claim('fixture-invite'),error=>error.code==='child_setup_unavailable');
  assert.equal(f.calls.length,0);assert.deepEqual(f.controller.state,{stage:'ended',pairingCode:null,expiresAt:null});
});

test('claim uncertainty retries the exact key and device-generated base32 pairing, never another token',async()=>{
  const calls=[];let failed=true;
  const f=fixture({claim:async(_access,input)=>{calls.push(input);if(failed)throw new ApiError('network',0);return receipt;}});
  await assert.rejects(f.controller.claim('fixture-invite'),error=>error.status===0);
  assert.match(f.controller.state.pairingCode,/^[A-Z2-7]{8}$/);
  await assert.rejects(f.controller.claim('different-invite'),error=>error.code==='review_original_invitation');
  assert.equal(calls.length,1);failed=false;await f.controller.claim('fixture-invite');
  assert.equal(calls[0],calls[1]);assert.equal(Object.isFrozen(calls[0]),true);
  assert.equal(f.controller.state.stage,'awaiting_guardian');
  assert.deepEqual(Object.keys(f.controller.state).sort(),['expiresAt','pairingCode','stage']);
});

test('guardian confirmation is server authority; finish checks it again and retains only an exact uncertain retry',async()=>{
  const calls=[];let failed=true;
  const f=fixture({finish:async(_access,input)=>{calls.push(input);if(failed)throw new ApiError('network',0);return credential;}});
  await f.controller.claim('fixture-invite');
  await assert.rejects(f.controller.finish(),error=>error.code==='guardian_confirmation_needed');assert.equal(calls.length,0);
  f.setStatus('approved');await f.controller.refresh();assert.equal(f.controller.state.stage,'approved');
  f.setStatus('awaiting_guardian');await assert.rejects(f.controller.finish(),error=>error.code==='guardian_confirmation_needed');assert.equal(calls.length,0);
  f.setStatus('approved');await assert.rejects(f.controller.finish(),error=>error.status===0);
  assert.equal(f.controller.state.stage,'finish_retry');
  assert.match(calls[0].deviceSecret,/^[A-Za-z0-9_-]{42}[AEIMQUYcgkosw048]$/);
  f.setStatus('active');await f.controller.refresh();assert.equal(f.controller.state.stage,'finish_retry');
  failed=false;const returned=await f.controller.finish();
  assert.equal(calls[0],calls[1]);assert.equal(Object.isFrozen(calls[0]),true);assert.deepEqual(returned,credential);
  assert.deepEqual(f.controller.state,{stage:'finished',pairingCode:null,expiresAt:null});
  await assert.rejects(f.controller.finish(),error=>error.code==='access_ended');
});

test('already active claim cannot finish without the original finish intent',async()=>{
  const f=fixture();await f.controller.claim('fixture-invite');f.setStatus('active');
  await assert.rejects(f.controller.finish(),error=>error.code==='original_finish_needed');assert.equal(f.calls.filter(call=>call.kind==='finish').length,0);
  assert.deepEqual(f.controller.state,{stage:'restart_required',pairingCode:null,expiresAt:null});
});

test('refresh of active claim without an original finish intent requires restart and purges material',async()=>{
  const f=fixture();await f.controller.claim('fixture-invite');f.setStatus('active');
  await assert.rejects(f.controller.refresh(),error=>error.code==='original_finish_needed');
  assert.deepEqual(f.controller.state,{stage:'restart_required',pairingCode:null,expiresAt:null});assert.equal(f.calls.length,1);
});

test('scope change during an awaited claim discards all secrets and late response',async()=>{
  let resolve;const pending=new Promise(done=>{resolve=done;});
  const f=fixture({claim:async()=>pending});const action=f.controller.claim('fixture-invite');
  await new Promise(done=>setImmediate(done));f.setAccess({...access,scope:'another-child-session'});resolve(receipt);
  await assert.rejects(action,error=>error.code==='access_ended');assert.deepEqual(f.controller.state,{stage:'ended',pairingCode:null,expiresAt:null});
});

test('sign-out clearing prevents a late finish receipt from escaping',async()=>{
  let resolve;const pending=new Promise(done=>{resolve=done;});
  const f=fixture({finish:async()=>pending});await f.controller.claim('fixture-invite');f.setStatus('approved');
  const action=f.controller.finish();await new Promise(done=>setImmediate(done));f.controller.clear(true);resolve(credential);
  await assert.rejects(action,error=>error.code==='access_ended');assert.equal(f.controller.state.pairingCode,null);
});

test('expired and withdrawn claims purge retry material and never finish',async()=>{
  const expired=fixture({claim:async()=>({...receipt,expiresAt:'2026-01-01T00:00:00.000Z'})});
  await assert.rejects(expired.controller.claim('fixture-invite'),error=>error.code==='access_ended');assert.equal(expired.controller.state.pairingCode,null);
  const ended=fixture();await ended.controller.claim('fixture-invite');ended.setStatus('ended');
  await assert.rejects(ended.controller.finish(),error=>error.code==='access_ended');assert.equal(ended.controller.state.pairingCode,null);assert.equal(ended.calls.length,1);
});

test('prepared transport uses only child v1 endpoints, same-origin cookies and narrow projections',async()=>{
  const calls=[];
  const api=new ChildInvitationAPI(async(path,options)=>{calls.push({path,options});return Response.json(path.endsWith('/claim')?{...receipt,parentEmail:'private-fixture',budget:999}:path.endsWith('/finish')?{...credential,deviceToken:'MUST_NOT_ESCAPE',householdLabel:'private-fixture'}:{claimId:ids.claim,status:'approved',expiresAt:expiry,otherRequests:['private-fixture']});});
  const claim={clientKey:ids.key,token:'fixture-invite',pairingCode:'ABCDEFG2'};
  assert.deepEqual(await api.claim(access,claim),receipt);assert.deepEqual(await api.status(access,ids.household,ids.claim),{claimId:ids.claim,status:'approved',expiresAt:expiry});
  const finish={clientKey:ids.key,householdId:ids.household,claimId:ids.claim,pairingCode:'ABCDEFG2',deviceSecret:'A'.repeat(43)};
  assert.deepEqual(await api.finish(access,finish),credential);
  assert.deepEqual(calls.map(call=>call.path),['/v1/child-invitations/claim',`/v1/child-invitations/claims/${ids.claim}?householdId=${ids.household}`,'/v1/child-invitations/finish']);
  for(const {path,options} of calls){assert.equal(options.credentials,'same-origin');assert.equal(options.cache,'no-store');assert.equal(options.redirect,'error');assert.equal(options.referrerPolicy,'no-referrer');assert.equal(options.headers.Authorization,undefined);assert.doesNotMatch(path,/fixture-invite|ABCDEFG2/);}
  assert.deepEqual(JSON.parse(calls[0].options.body),claim);assert.deepEqual(JSON.parse(calls[2].options.body),finish);assert.equal(calls[2].options.headers['X-CSRF-Token'],access.csrf);
  assert.equal(calls.some(call=>call.path.includes('/auth/')||call.path.includes('/invites/redeem')||call.path.includes('/session')),false);
});

test('prepared transport rejects mismatched child response and preserves server unavailable gate',async()=>{
  const wrong=new ChildInvitationAPI(async()=>Response.json({...credential,householdId:ids.device}));
  await assert.rejects(wrong.finish(access,{clientKey:ids.key,householdId:ids.household,claimId:ids.claim,pairingCode:'ABCDEFG2',deviceSecret:'A'.repeat(43)}),error=>error.code==='invalid_response');
  const denied=new ChildInvitationAPI(async()=>Response.json({error:{code:'consent_unavailable'}},{status:503}));
  await assert.rejects(denied.claim(access,{clientKey:ids.key,token:'fixture-invite',pairingCode:'ABCDEFG2'}),error=>error.code==='consent_unavailable'&&error.status===503);
});

test('unavailable production child entry scrubs secrets before availability and has no account, mutation or store access',async()=>{
  const dom=new JSDOM('<div id="app"></div>',{url:'https://food.example/child-invite?token=fixture-query&email=private-fixture#token=fixture-fragment'});
  Object.defineProperty(dom.window.navigator,'language',{value:'es-US'});
  Object.defineProperty(dom.window,'localStorage',{get(){throw new Error('private store touched');}});Object.defineProperty(dom.window,'sessionStorage',{get(){throw new Error('private store touched');}});Object.defineProperty(dom.window,'indexedDB',{get(){throw new Error('private store touched');}});
  dom.window.fetch=()=>{throw new Error('account API touched');};
  const calls=[];const unavailable={availability:async()=>{assert.equal(dom.window.location.search,'');assert.equal(dom.window.location.hash,'');calls.push('availability');return{available:false,reason:'provider_configuration_required'};}};
  const root=dom.window.document.getElementById('app');assert.equal(mountChildInvitationPage(root,unavailable),true);await new Promise(done=>setImmediate(done));
  assert.equal(dom.window.location.href,'https://food.example/child-invite');assert.match(root.textContent,/aún no está disponible/);assert.match(root.textContent,/cuenta propia del menor/);
  assert.equal(root.querySelector('form,input,button'),null);assert.doesNotMatch(root.textContent,/fixture-query|fixture-fragment|private-fixture/);
  const language=root.querySelector('select');language.value='en';language.dispatchEvent(new dom.window.Event('change'));
  assert.match(root.textContent,/not available in this browser yet/);assert.match(root.textContent,/Do not share an adult/);assert.equal(dom.window.document.documentElement.lang,'en');
  for(const copy of Object.values(childInvitationCopy)){assert.ok(copy.en&&copy.es);assert.notEqual(copy.en,copy.es);}assert.deepEqual(calls,['availability']);dom.window.close();
});

test('new entry isolates exact child path and main hook preserves public and helper dispatch',()=>{
  for(const path of ['/child-invite-extra','/invite','/view','/privacy']){const dom=new JSDOM('<div id="app">untouched</div>',{url:'https://food.example'+path});assert.equal(mountChildInvitationPage(dom.window.document.getElementById('app')),false);assert.equal(dom.window.document.getElementById('app').textContent,'untouched');}
  const main=readFileSync(new URL('../src/main.ts',import.meta.url),'utf8');assert.match(main,/!mountPublicPage\(root\)\s*&&\s*!mountChildInvitationPage\(root\)/);
  const dom=new JSDOM('<div id="app"></div>',{url:'https://food.example/child-invite/#token=fixture'});assert.equal(mountChildInvitationPage(dom.window.document.getElementById('app'),{availability:async()=>({available:false,reason:'provider_configuration_required'})}),true);assert.equal(dom.window.location.hash,'');dom.window.close();
});
