// Pure receipt verification. No browser, server, process or filesystem mutation.
import assert from 'node:assert/strict';
import {validateObservation} from './observation.mjs';
const privateFlags=['ownA','ownB','queued','draftA','queuePermissionControl','contributorControlsPresent','contributorReady'];
const concealed=o=>{for(const key of privateFlags)assert.equal(o[key],false,'private field/control exposed: '+key);};
export function verifyForeground(r,identity,name){
 assert(['foreground-same','foreground-revoked'].includes(name));assert.equal(r.manifestSHA,identity);assert.equal(r.fixture.profile,'history');assert.equal(r.fixture.cache,'private, max-age=0');
 assert.deepEqual(r.observations.map(o=>o.phase),['initial','held','final']);
 const [initial,held,final]=r.observations;
 for(const o of r.observations){
  const {phase,serverCounts,serverAttempts,pendingAuthority,...probe}=o;validateObservation(probe);
  assert.equal(o.truncated,false);assert.match(o.userAgent,/iPhone/);assert.match(o.userAgent,/Safari\//);assert.equal(o.visibility,'visible');
  assert.equal(serverCounts.commandAttempts,0);assert.equal(serverCounts.commandEffects,0);assert.deepEqual(serverAttempts,[]);
  assert.equal(o.action,'observe');assert.equal(o.doc,initial.doc,'foreground replaced document; not this same-document case');
  assert(['absent','read'].includes(o.storage.status),'storage evidence unavailable');assert.equal(o.storage.count,0);
  for(let i=1;i<o.events.length;i++)assert(o.events[i].at>=o.events[i-1].at,'event times not monotonic');
 }
 assert.equal(initial.pendingAuthority,0);assert(initial.current.contributorControlsPresent,'initial contributor controls absent');assert(initial.current.ownA&&initial.current.draftA&&initial.current.ready);assert.equal(initial.current.busy,false);assert.equal(initial.current.ownB,false,'initial includes other actor');assert.equal(initial.current.queued,false,'initial includes unrelated queued item');
 assert.deepEqual(held.events.slice(0,initial.events.length),initial.events,'initial event prefix changed');
 assert.deepEqual(final.events.slice(0,held.events.length),held.events,'held event prefix changed');
 const transitions=held.events.slice(initial.events.length).filter(e=>e.kind==='visibility-before-app-listener');
 assert.deepEqual(transitions.map(e=>e.visibility),['hidden','visible'],'actual hidden-to-visible lifecycle evidence missing or extra cycle');
 // Before-listener samples retain causal context, not a verdict before product execution.
 const after=held.events.slice(initial.events.length).filter(e=>e.kind==='visibility-after-task');
 assert.equal(after.length,1,'visible next-task sample missing or repeated');assert.equal(after[0].visibility,'visible');assert(after[0].at>=transitions[1].at);const postTaskIndex=held.events.indexOf(after[0]);assert(postTaskIndex>=initial.events.length);
 for(const sample of held.events.slice(postTaskIndex))concealed(sample);
 assert(held.pendingAuthority>0,'fresh authority must still be held');assert.equal(held.current.busy,true,'held product is not actively revalidating');assert.equal(held.current.ready,false);concealed(held.current);
 const events=r.fixture.events;
 const controls=events.filter(e=>e.kind==='control');assert([2,3].includes(controls.length),'unexpected authority control count');
 const clean=e=>Object.fromEntries(Object.entries(e).filter(([k])=>k!=='seq'));
 const heldControl=events.indexOf(controls[0]);
 const expectedActor=name==='foreground-revoked'?'revoked':'A';
 assert.deepEqual(clean(controls[0]),{kind:'control',phase:'held',hold:true,actor:expectedActor},'unprescribed held authority control');
 assert.deepEqual(clean(controls[1]),{kind:'control',phase:'final',hold:false},'unprescribed authority release');
 if(controls[2])assert.deepEqual(clean(controls[2]),{kind:'control',phase:'final',hold:false},'only optional stop release may follow');
 assert(events.slice(heldControl+1,events.indexOf(controls[1])).some(e=>e.kind==='authority-held'),'no authority request before release');
 assert(events.slice(heldControl+1).some(e=>e.kind==='control'&&e.hold===false&&e.phase==='final'),'explicit release missing');
 assert.equal(events.filter(e=>e.kind==='request'&&e.method!=='GET').length,0,'foreground caused product mutation');
 assert.equal(r.fixture.state.hold,false);assert.equal(r.fixture.state.actor,expectedActor);
 assert.equal(final.pendingAuthority,0);assert(final.current.ready);assert.equal(final.current.busy,false);assert.equal(final.current.retryPresent,false);
 if(name==='foreground-same'){
  assert(final.current.ownA&&final.current.draftA&&final.current.contributorReady&&final.current.contributorControlsPresent&&final.current.statusEmpty,'same-actor exact work not restored');assert.equal(final.current.accessEnded,false);assert.equal(final.current.loadUnavailable,false);assert.equal(final.current.ownB,false,'same-actor final includes other actor');assert.equal(final.current.queued,false,'same-actor final includes unrelated queued item');
 }else{concealed(final.current);assert(final.current.accessEnded&&final.current.refreshAvailable,'exact revoked outcome missing');assert.equal(final.current.loadUnavailable,false);}
 const pageEvents=held.events.slice(initial.events.length).filter(e=>['pageshow','pagehide-before-app-listener'].includes(e.kind));
 return {status:'passed-scoped',case:name,observedHiddenVisibleCycle:true,sameDocument:true,concealedAfterVisibleTaskAndWhileAuthorityHeld:true,pageLifecycleDuringBackground:pageEvents.map(e=>({kind:e.kind,persisted:e.persisted})),commandAttempts:0,commandEffects:0};
}
