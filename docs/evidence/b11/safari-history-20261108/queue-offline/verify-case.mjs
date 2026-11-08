// Post-execution check only; this never runs a browser, server or mutation.
import assert from 'node:assert/strict';import {readFile} from 'node:fs/promises';import {verifyPin} from './verify-pin.mjs';import {validateObservation} from './observation.mjs';
const [name,path]=process.argv.slice(2);assert(['history-same','history-changed','history-revoked','history-offline','queue-offline','queue-lost','queue-evicted','queue-revoked'].includes(name));
const m=await verifyPin(),r=JSON.parse(await readFile(path,'utf8'));assert.equal(r.manifestSHA,m.identity);
const at=phase=>{const values=r.observations.filter(o=>o.phase===phase);assert.equal(values.length,1,`one explicit observation required for ${phase}`);const o=values[0];const {phase:ignoredPhase,serverCounts,serverAttempts,pendingAuthority,...probe}=o;validateObservation(probe);assert.equal(o.truncated,false);assert.match(o.userAgent,/iPhone/);assert.match(o.userAgent,/Safari\//);return o;};
const count=(o,attempts,effects)=>{assert.equal(o.serverCounts.commandAttempts,attempts);assert.equal(o.serverCounts.commandEffects,effects);};
const stored=(o,n)=>{assert(['read','absent'].includes(o.storage.status),'IndexedDB evidence unavailable');assert.equal(o.storage.count,n);};
const finalReady=o=>{assert.equal(o.pendingAuthority,0,'final authority still held');assert.equal(o.current.busy,false,'final product still busy');assert.equal(o.current.ready,true,'final product main absent or not ready');};
if(name.startsWith('history-')){
 const initial=at('initial'),held=at('held'),final=at('final');assert(initial.current.ownA&&initial.current.draftA);assert(held.pendingAuthority>0);assert.equal(held.current.ownA,false);assert.equal(held.current.ownB,false);assert.equal(held.current.draftA,false);
 const page=held.events.filter(e=>e.kind==='pageshow').at(-1);assert(page,'pageshow evidence missing');
 const persisted=initial.doc===held.doc&&page.persisted;
 if(r.fixture.cache!=='no-store')assert(persisted,'eligible document did not restore from BFCache; not a pass');
 if(persisted)for(const key of ['ownA','ownB','draftA'])assert.equal(page[key],false,`private ${key} visible synchronously at pageshow`);
 finalReady(final);
 if(name==='history-revoked'){assert(final.current.accessEnded,'exact access-ended outcome missing');assert.equal(final.current.loadUnavailable,false);assert(final.current.refreshAvailable);assert.equal(final.current.retryPresent,false);}
 if(name==='history-offline'){assert(final.current.loadUnavailable,'exact account-unavailable outcome missing');assert.equal(final.current.accessEnded,false);assert(final.current.refreshAvailable);assert.equal(final.current.retryPresent,false);}
 if(name==='history-same'){assert(final.current.ownA);if(persisted)assert(final.current.draftA);}else{assert.equal(final.current.ownA,false);assert.equal(final.current.draftA,false);if(name==='history-changed')assert(final.current.ownB);}
 for(const o of [initial,held,final])count(o,0,0);
 assert.equal(r.fixture.events.filter(e=>e.kind==='request'&&e.method!=='GET').length,0,'history caused a product mutation');
 console.log(JSON.stringify({status:'passed-scoped',case:name,persisted,cache:r.fixture.cache}));
}else{
 const queued=at('queued'),final=at('final');finalReady(final);stored(queued,1);assert(queued.current.waiting);assert(queued.current.retryPresent);const digest=queued.storage.commands[0].digest;
 if(name==='queue-offline'||name==='queue-revoked'){count(queued,0,0);}else if(name==='queue-lost'){count(queued,1,1);}else count(queued,1,0);
 if(['queue-offline','queue-lost'].includes(name)){
  const reopened=at('reloaded');stored(reopened,1);assert.equal(reopened.storage.commands[0].digest,digest);count(reopened,queued.serverCounts.commandAttempts,queued.serverCounts.commandEffects);
  stored(final,0);count(final,name==='queue-offline'?1:2,1);assert(final.current.received);assert(final.current.queued);assert(final.serverAttempts.every(x=>x.digest===digest&&x.grant==='4f14be8f-efc9-48c4-af14-cb09a8489f38'));
 }else{stored(final,0);assert.equal(final.current.queued,false);assert.equal(final.current.waiting,false);count(final,queued.serverCounts.commandAttempts,queued.serverCounts.commandEffects);assert.equal(final.current.retryPresent,false,'stale Retry control remains');assert(final.current.contributorReady,'authorized online form not restored');if(name==='queue-evicted')assert(final.current.missing,'exact missing-pending notice absent');if(name==='queue-revoked'){assert.equal(final.current.queuePermissionControl,false,'queue permission control remains');assert(final.current.statusEmpty,'unexpected revocation refresh notice');assert.equal(final.current.accessEnded,false);assert.equal(final.current.loadUnavailable,false);assert.equal(r.fixture.state.queueAllowed,false);}}
 console.log(JSON.stringify({status:'passed-scoped',case:name,commandAttempts:final.serverCounts.commandAttempts,commandEffects:final.serverCounts.commandEffects}));
}
