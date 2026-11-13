// Offline retained-receipt audit only; no server, browser, network or product mutation.
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {createHash} from 'node:crypto';
import {fileURLToPath} from 'node:url';
import {dirname,join} from 'node:path';
import {verifyForeground} from './frozen/verify-foreground.mjs';
const here=dirname(fileURLToPath(import.meta.url));
const sha=x=>createHash('sha256').update(x).digest('hex');
const read=async p=>JSON.parse(await readFile(join(here,p),'utf8'));
const m=await read('frozen/manifest.json'),{identity,...payload}=m;
assert.equal(sha(JSON.stringify(payload)),identity);
assert.equal(identity,'161583ff8c0771c0bd85f3765a0a9981333840cfef91ed225ce793f11aee4414');
const copies=await read('retention.json');for(const f of copies.files){const b=await readFile(join(here,f.retained));assert.equal(b.length,f.bytes);assert.equal(sha(b),f.sha256);}
for(const n of ['verify-foreground.mjs','observation.mjs','probe.js','fixture.mjs','server.mjs','verify-case.mjs','verify-pin.mjs'])assert.equal(sha(await readFile(join(here,'frozen',n))),m.helpers[n]);
const facts=[];
for(const name of ['foreground-same','foreground-revoked']){
 const raw=await readFile(join(here,name,'receipt.json')),r=JSON.parse(raw),review=await read(name+'/root-review.json');
 assert.equal(review.receiptSHA256,sha(raw));assert.equal(review.manifestIdentity,identity);assert.equal(review.verifierExit,1);assert.equal(review.failure,'private field/control exposed: ownA');assert.equal(review.serverExit,0);assert.equal(review.portClosed,true);assert.equal(new URL(r.origin).port,String(review.port));assert.equal(new URL(r.origin).hostname,'127.0.0.1');
 assert.equal(r.caseName,name);assert.equal(r.manifestSHA,identity);assert.equal(r.fixture.profile,'history');assert.equal(r.fixture.cache,'private, max-age=0');assert.equal(review.documentIdentityUnchanged,true);assert.equal(review.zeroProductMutations,true);
 const [initial,held,final]=r.observations;assert.deepEqual(r.observations.map(x=>x.phase),['initial','held','final']);
 for(const o of r.observations){assert.equal(o.version,4);assert.equal(o.doc,initial.doc);assert.equal(o.truncated,false);assert.equal(o.visibility,'visible');assert.equal(o.action,'observe');assert.match(o.userAgent,/iPhone/);assert.match(o.userAgent,/Safari\//);assert.deepEqual(o.serverCounts,{commandAttempts:0,commandEffects:0,rowsA:1,rowsB:1});assert.deepEqual(o.serverAttempts,[]);assert.equal(o.storage.status,'read');assert.equal(o.storage.count,0);assert.deepEqual(o.storage.commands,[]);for(let i=1;i<o.events.length;i++)assert(o.events[i].at>=o.events[i-1].at);}
 assert.deepEqual(held.events.slice(0,initial.events.length),initial.events);assert.deepEqual(final.events.slice(0,held.events.length),held.events);
 assert(initial.current.ownA&&initial.current.draftA&&initial.current.ready&&initial.current.contributorControlsPresent);assert.equal(initial.current.busy,false);assert.equal(initial.current.ownB,false);assert.equal(initial.current.queued,false);assert.equal(initial.pendingAuthority,0);
 const changed=held.events.slice(initial.events.length),transitions=changed.filter(x=>x.kind==='visibility-before-app-listener');assert.deepEqual(transitions.map(x=>x.visibility),['hidden','visible']);
 const after=changed.filter(x=>x.kind==='visibility-after-task');assert.equal(after.length,1);assert.equal(after[0].visibility,'visible');assert(after[0].at>=transitions[1].at);assert.equal(held.pendingAuthority,1);
 for(const x of [after[0],held.current]){for(const k of ['ownA','draftA','queuePermissionControl','contributorControlsPresent','busy'])assert.equal(x[k],true);for(const k of ['ownB','queued','ready','contributorReady'])assert.equal(x[k],false);}
 const ev=r.fixture.events,controls=ev.filter(x=>x.kind==='control'),clean=x=>Object.fromEntries(Object.entries(x).filter(([k])=>k!=='seq')),actor=name==='foreground-same'?'A':'revoked';assert.deepEqual(controls.map(clean),[{kind:'control',phase:'held',actor,hold:true},{kind:'control',phase:'final',hold:false},{kind:'control',phase:'final',hold:false}]);assert(ev.slice(ev.indexOf(controls[0])+1,ev.indexOf(controls[1])).some(x=>x.kind==='authority-held'));assert(ev.filter(x=>x.kind==='request').every(x=>x.method==='GET'));assert.deepEqual(r.fixture.counts,{commandAttempts:0,commandEffects:0,rowsA:1,rowsB:1});assert.deepEqual(r.fixture.attempts,[]);assert.equal(r.fixture.pendingAuthority,0);assert.equal(r.fixture.state.actor,actor);assert.equal(r.fixture.state.hold,false);assert.equal(final.pendingAuthority,0);assert(final.current.ready&&!final.current.busy&&!final.current.retryPresent&&!final.current.loadUnavailable);
 if(name==='foreground-same'){assert(review.finalSameActorRecovery);for(const k of ['ownA','draftA','contributorReady','contributorControlsPresent','statusEmpty'])assert(final.current[k]);for(const k of ['ownB','queued','accessEnded'])assert.equal(final.current[k],false);}
 else {assert(review.finalRevokedClearing);for(const k of ['ownA','ownB','draftA','queued','queuePermissionControl','contributorControlsPresent','contributorReady'])assert.equal(final.current[k],false);assert(final.current.accessEnded&&final.current.refreshAvailable);}
 assert.throws(()=>verifyForeground(r,identity,name),/private field\/control exposed: ownA/);
 assert.match(await readFile(join(here,name,'verification.log'),'utf8'),/private field\/control exposed: ownA/);
 facts.push({case:name,baselinePrivacyOutcome:'failed-original-verifier-reproduced',sameDocument:initial.doc,postVisibleTask:after[0],heldCurrent:held.current,finalCurrent:final.current,zeroProductCommandAttemptsAndEffects:true,serverExitAndPortClosure:'Recorded in byte-pinned root-review; not re-observed by offline audit.',receiptSHA256:sha(raw)});
}
console.log(JSON.stringify({audit:'confirmed-original-failures-and-separate-final-outcomes',manifestIdentity:identity,sourceAndBrowserProofSeparate:true,noUIOrNetworkOrServerActions:true,cases:facts},null,2));
