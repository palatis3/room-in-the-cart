// Pure receipt verification; no listener/browser/process mutation.
import assert from 'node:assert/strict';
import {validateObservation} from './observation.mjs';
export const privateFlags=['household','shop','instruction','amount','action','suggestion','draft','draftPresent','editorControlsPresent','editorReady','cookHeadingPresent','datedRevision'];
const concealed=o=>{for(const key of privateFlags)assert.equal(o[key],false,'private field/control exposed: '+key);};
export function verifyForeground(r,identity,name){
 assert.equal(name,'editor-foreground-revoked');assert.equal(r.manifestSHA,identity);assert.equal(r.caseName,name);assert.equal(r.fixture.profile,'editor');assert.equal(r.fixture.cache,'private, max-age=0');assert.equal(r.fixture.privateCanariesPresent,true);
 assert.deepEqual(r.observations.map(o=>o.phase),['initial','held','final']);const [initial,held,final]=r.observations;
 for(const o of r.observations){
  const {phase,serverCounts,serverAttempts,pendingAuthority,...probe}=o;validateObservation(probe);assert.equal(o.truncated,false);assert.match(o.userAgent,/iPhone/);assert.match(o.userAgent,/Safari\//);assert.equal(o.visibility,'visible');assert.equal(o.action,'observe');assert.equal(o.doc,initial.doc,'document replaced');
  assert.deepEqual(serverCounts,{commandAttempts:0,commandEffects:0,forbiddenResponseCount:0});assert.deepEqual(serverAttempts,[]);assert(['absent','read'].includes(o.storage.status));assert.equal(o.storage.count,0);
  for(const sample of [o.current,...o.events]){assert.equal(sample.forbiddenBudget,false);assert.equal(sample.forbiddenOtherShop,false);assert.equal(sample.contributorControlsPresent,false);}
  for(let i=1;i<o.events.length;i++)assert(o.events[i].at>=o.events[i-1].at);
 }
 assert.equal(initial.pendingAuthority,0);for(const key of privateFlags)assert.equal(initial.current[key],true,'initial content/control missing: '+key);assert(initial.current.ready&&initial.current.statusEmpty);assert.equal(initial.current.busy,false);assert.equal(initial.current.accessEnded,false);
 assert.deepEqual(held.events.slice(0,initial.events.length),initial.events);assert.deepEqual(final.events.slice(0,held.events.length),held.events);
 const cycle=held.events.slice(initial.events.length),transitions=cycle.filter(e=>e.kind==='visibility-before-app-listener');assert.deepEqual(transitions.map(e=>e.visibility),['hidden','visible'],'actual hidden-visible cycle absent or repeated');
 assert.equal(cycle.filter(e=>['pageshow','pagehide-before-app-listener'].includes(e.kind)).length,0,'navigation occurred; this case requires Home return without navigation');
 const after=cycle.filter(e=>e.kind==='visibility-after-task');assert.equal(after.length,1);assert.equal(after[0].visibility,'visible');assert(after[0].at>=transitions[1].at);const index=held.events.indexOf(after[0]);
 for(const sample of held.events.slice(index))concealed(sample);assert.equal(held.pendingAuthority,1);assert(held.current.busy&&!held.current.ready);concealed(held.current);
 for(const sample of final.events.slice(held.events.length))concealed(sample);
 const events=r.fixture.events,controls=events.filter(e=>e.kind==='control'),clean=e=>Object.fromEntries(Object.entries(e).filter(([k])=>k!=='seq'));
 assert([2,3].includes(controls.length));assert.deepEqual(clean(controls[0]),{kind:'control',phase:'held',hold:true,actor:'revoked'});assert.deepEqual(clean(controls[1]),{kind:'control',phase:'final',hold:false});if(controls[2])assert.deepEqual(clean(controls[2]),{kind:'control',phase:'final',hold:false});
 const between=events.slice(events.indexOf(controls[0])+1,events.indexOf(controls[1]));assert.equal(between.filter(e=>e.kind==='authority-held').length,1);assert.deepEqual(between.filter(e=>e.kind==='request').map(e=>({method:e.method,path:e.path})),[{method:'GET',path:'/v1/session'}]);
 assert.equal(events.filter(e=>e.kind==='request'&&e.method!=='GET').length,0,'product write attempted');assert.equal(events.filter(e=>e.kind==='write-rejected').length,0);assert.equal(events.filter(e=>e.kind==='response'&&e.forbidden).length,0);
 const initialReads=events.slice(0,events.indexOf(controls[0])).filter(e=>e.kind==='request').map(e=>e.path);assert.deepEqual(initialReads,['/v1/session','/v1/views/editor-grant/current','/v1/views/editor-grant/proposals','/v1/session']);
 assert.equal(r.fixture.state.hold,false);assert.equal(r.fixture.state.actor,'revoked');assert.equal(r.fixture.state.phase,'final');assert.deepEqual(r.fixture.counts,{commandAttempts:0,commandEffects:0,forbiddenResponseCount:0});assert.deepEqual(r.fixture.attempts,[]);
 assert.equal(final.pendingAuthority,0);assert(final.current.ready&&!final.current.busy);concealed(final.current);assert(final.current.accessEnded&&final.current.refreshAvailable);assert.equal(final.current.loadUnavailable,false);
 return {status:'passed-scoped',case:name,sameDocument:true,observedHiddenVisibleCycle:true,concealedAfterVisibleTaskAndThroughRevocation:true,commandAttempts:0,commandEffects:0,forbiddenResponseCount:0};
}
