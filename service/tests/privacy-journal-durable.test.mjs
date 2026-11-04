import test from 'node:test';
import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {verifyPrivacyJournal,validatePrivacyRestoreEvents} from '../dist/privacy-journal.js';
import {verifyDurableAdmissionReceipt} from '../dist/privacy-journal-durable.js';
import {fixture} from './durable-authority-fixture.mjs';
import {acceptedEvent,progressEvent,call,clone,digest,gate,keys} from './durable-independent-fixture.mjs';

test('real adapter: admitted intent precedes source commit, observation/head precedes exact SQL acknowledgement; existing canonical verifier restores', async () => {
  const f=fixture(), a=f.event(), port=f.adapter().port;
  await port.beforeCommit(a,call());
  assert.equal(f.acknowledgements.length,0);
  assert.equal(f.records.length,1);
  assert.deepEqual(f.records.map(r=>r.kind),['intent']);
  f.commit(a);
  await port.afterCommit(a.eventId,call());
  assert.deepEqual(f.records.map(r=>r.kind),['intent','commit']);
  assert.equal(f.acknowledgements.length,1);
  assert.deepEqual(f.acknowledgements[0].identity,{eventId:a.eventId,payloadDigest:a.payloadDigest,seq:2,hash:digest(f.records[1])});
  assert(f.logs.indexOf('publish:intent')<f.logs.indexOf('source:commit'));
  assert(f.logs.indexOf('source:commit')<f.logs.indexOf('publish:commit'));
  assert(f.logs.indexOf('publish:commit')<f.logs.indexOf('source:ack'));
  const checked=verifyPrivacyJournal(f.exportBytes(),f.sealedTrust());
  assert.deepEqual(checked.events,[a]);
  assert.equal(validatePrivacyRestoreEvents(checked.events).length,1);
});

test('real adapter: only fixed-source progress for the requested job is admitted and canonical restore validates it', async () => {
  const f=fixture(), a=f.event(), port=f.adapter().port;
  await port.beforeCommit(a,call());f.commit(a);await port.afterCommit(a.eventId,call());
  const p=progressEvent(a), completed=progressEvent(a,'source_completed');
  f.commit(p);f.commit(completed);
  await port.acknowledgeJob(a.payload.jobId,call());
  assert.deepEqual(f.records.map(r=>[r.kind,r.event.eventId]),[['intent',a.eventId],['commit',a.eventId],['commit',p.eventId],['commit',completed.eventId]]);
  assert.deepEqual(validatePrivacyRestoreEvents(verifyPrivacyJournal(f.exportBytes(),f.sealedTrust()).events),[a,p,completed]);
});

test('real adapter: completed retries across instances reuse immutable identity and original acknowledgement after later heads', async () => {
  const f=fixture(), a=f.event();
  let port=f.adapter().port;
  await port.beforeCommit(a,call());f.commit(a);await port.afterCommit(a.eventId,call());
  const committed=digest(f.records[1]);
  const p=progressEvent(a);f.commit(p);await port.acknowledgeJob(a.payload.jobId,call());
  port=f.adapter().port;
  await port.beforeCommit(clone(a),call());
  await port.afterCommit(a.eventId,call());
  assert.equal(f.records.length,3);
  assert.deepEqual(f.acknowledgements.at(-1).identity,{eventId:a.eventId,payloadDigest:a.payloadDigest,seq:2,hash:committed});
});

test('real adapter: valid status reconciliation with zero unacknowledged events remains a safe repeatable no-op', async () => {
  const f=fixture(), a=f.event(), adapter=f.adapter();
  await adapter.port.beforeCommit(a,call());f.commit(a);await adapter.port.afterCommit(a.eventId,call());
  const count=f.mutations;
  await adapter.port.acknowledgeJob(a.payload.jobId,call());
  await f.adapter().port.acknowledgeJob(a.payload.jobId,call());
  assert.equal(f.mutations,count);assert.equal(f.records.length,2);assert.equal(f.acknowledgements.length,1);
  assert.equal(adapter.isPoisoned(),false);
});

test('real adapter: missing job cannot pass empty status reconciliation', async () => {
  const f=fixture();
  await assert.rejects(()=>f.adapter().port.acknowledgeJob(randomUUID(),call()));
  assert.equal(f.mutations,0);assert.equal(f.acknowledgements.length,0);
});

test('real adapter: concurrent independent instances never admit duplicate event transitions', async () => {
  const f=fixture(), a=f.event();
  const results=await Promise.allSettled([f.adapter().port.beforeCommit(a,call()),f.adapter().port.beforeCommit(clone(a),call())]);
  assert(results.some(r=>r.status==='fulfilled'));
  assert.equal(f.records.length,1);
  assert.equal(f.records[0].event.eventId,a.eventId);
});

test('real adapter: one event ID cannot change its digest or job on retry', async t => {
  for(const variant of ['digest','job']) await t.test(variant,async()=>{
    const f=fixture(), a=f.event();await f.adapter().port.beforeCommit(a,call());
    const changed=clone(a);
    if(variant==='digest') changed.payload.data.requestDigest='e'.repeat(64);
    else changed.payload.jobId=randomUUID();
    changed.payloadDigest=digest(changed.payload);
    await assert.rejects(()=>f.adapter().port.beforeCommit(changed,call()));
    assert.equal(f.records.length,1);assert.equal(f.acknowledgements.length,0);
  });
});

test('real adapter: strict content-free runtime payload validation precedes remote reservation', async t => {
  const changes=[
    ['outer unknown',e=>e.extra=true],
    ['payload unknown',e=>e.payload.extra=true],
    ['acceptance unknown',e=>e.payload.data.unknownField='forbidden'],
    ['attestation unknown',e=>e.payload.data.attestation.unknownField='forbidden'],
    ['snapshot unknown',e=>e.payload.data.effects[0].after.unknownField='forbidden'],
    ['duplicate target',e=>e.payload.data.targets.push(clone(e.payload.data.targets[0]))],
    ['event mismatch',e=>e.payload.eventId=randomUUID()],
    ['policy mismatch',e=>e.payload.data.attestation.policy.receiptRetentionDays=2],
    ['unknown progress kind',e=>e.payload.kind='future'],
  ];
  for(const [name,change] of changes) await t.test(name,async()=>{
    const f=fixture(), e=f.event();change(e);e.payloadDigest=digest(e.payload);
    await assert.rejects(()=>f.adapter().port.beforeCommit(e,call()));
    assert.equal(f.records.length,0);assert.equal(f.mutations,0);
  });
});

test('real adapter: wrong receipt boundary or signature cannot complete a phase', async t => {
  for(const variant of ['signature','namespace','key','head','generation','record','stored','unknown']) await t.test(variant,async()=>{
    const f=fixture();f.faults.receipt=variant;
    const adapter=f.adapter();
    await assert.rejects(()=>adapter.port.beforeCommit(f.event(),call()));
    assert(adapter.isPoisoned());assert.equal(f.acknowledgements.length,0);assert(f.uncertainCount()>0);
  });
});

test('real adapter: authenticated stale active head is rejected for a fresh challenge and generation', async () => {
  const f=fixture(), a=f.event();
  f.faults.captureHead=true;await f.adapter().port.beforeCommit(a,call());
  f.faults.replayHead=true;
  await assert.rejects(()=>f.adapter().port.beforeCommit(f.event(),call()));
  assert.equal(f.records.length,1);
});

test('real adapter: constructor snapshots pins and caller event across awaited source/authority work', async () => {
  const f=fixture(), a=f.event(), original=clone(a), adapter=f.adapter();
  const hold=gate();f.hooks.inspect=()=>hold.promise;
  const started=adapter.port.beforeCommit(a,call());
  await f.entered('inspect');
  a.payload.jobId=randomUUID();a.payload.data.requestDigest='e'.repeat(64);a.payloadDigest=digest(a.payload);
  f.pins.configurationId='mutated';f.pins.recordNamespace='mutated';
  hold.resolve();await started;
  assert.deepEqual(f.records[0].event,original);
});

test('real adapter: returned source event must match exact requested event ID', async () => {
  const f=fixture(), a=f.event(), other=f.event(), port=f.adapter().port;
  await port.beforeCommit(a,call());f.commit(a);
  f.faults.sourceEvent=other;
  await assert.rejects(()=>port.afterCommit(a.eventId,call()));
  assert.equal(f.records.length,1);assert.equal(f.acknowledgements.length,0);
});

test('real adapter: returned unacknowledged event and acceptance must match requested job', async t => {
  for(const variant of ['event','acceptance']) await t.test(variant,async()=>{
    const f=fixture(), a=f.event(), b=f.event(), port=f.adapter().port;
    await port.beforeCommit(a,call());f.commit(a);await port.afterCommit(a.eventId,call());
    const progress=progressEvent(a);f.commit(progress);
    if(variant==='event') f.faults.sourceEvent=progressEvent(b);
    else f.faults.sourceAcceptance=b;
    await assert.rejects(()=>port.acknowledgeJob(a.payload.jobId,call()));
    assert.equal(f.records.length,2);assert.equal(f.acknowledgements.length,1);
  });
});

test('real adapter: unknown committed source remains quarantined without acknowledgement or head reset', async () => {
  const f=fixture(), a=f.event(), adapter=f.adapter();await adapter.port.beforeCommit(a,call());
  await assert.rejects(()=>adapter.port.afterCommit(a.eventId,call()));
  assert.equal(f.records.length,1);assert.equal(f.acknowledgements.length,0);
  await assert.rejects(()=>adapter.port.beforeCommit(f.event(),call()));
  assert.equal(f.records.length,1);
});

test('real adapter: accepted remote mutation with lost response stays durably blocked across reconstruction', async t => {
  for(const phase of ['begin','reserve','put','publish']) await t.test(phase,async()=>{
    const f=fixture();f.faults.lostResponse=phase;
    const adapter=f.adapter(), a=f.event();
    await assert.rejects(()=>adapter.port.beforeCommit(a,call()));
    assert(adapter.isPoisoned());
    const mutations=f.mutations, fresh=f.adapter();
    await assert.rejects(()=>fresh.port.beforeCommit(f.event(),call()));
    assert.equal(f.mutations,mutations);assert.equal(f.acknowledgements.length,0);
    assert(f.uncertainCount()>0);
  });
});

test('real adapter: pre-aborted or expired calls initiate no remote mutation or source acknowledgement', async t => {
  for(const phase of ['before','after','job']) for(const variant of ['abort','deadline']) await t.test(`${phase}:${variant}`,async()=>{
    const f=fixture(), a=f.event(), adapter=f.adapter();
    if(phase!=='before'){await adapter.port.beforeCommit(a,call());f.commit(a);}
    const c=call();if(variant==='abort')c.controller.abort();else c.deadlineUnixMs=Date.now()-1;
    const mutations=f.mutations;
    await assert.rejects(()=>phase==='before'?adapter.port.beforeCommit(a,c):phase==='after'?adapter.port.afterCommit(a.eventId,c):adapter.port.acknowledgeJob(a.payload.jobId,c));
    assert.equal(adapter.isPoisoned(),false);
    assert.equal(f.mutations,mutations);assert.equal(f.acknowledgements.length,0);
  });
});

test('real adapter: cancellation during a remote phase forwards actual signal and starts no next phase', async t => {
  for(const phase of ['reserve','put','publish']) await t.test(phase,async()=>{
    const f=fixture(), a=f.event(), c=call(), hold=gate();
    let actualSignal;
    f.hooks[phase]=async received=>{actualSignal=received.signal;assert(actualSignal instanceof AbortSignal);await hold.promise;};
    const adapter=f.adapter(), started=adapter.port.beforeCommit(a,c);
    await f.entered(phase);c.controller.abort();hold.resolve();
    await assert.rejects(()=>started);
    assert.equal(actualSignal.aborted,true);
    const at=f.logs.indexOf(`enter:${phase}`);
    if(phase==='reserve')assert(!f.logs.slice(at+1).includes('enter:put'));
    if(phase==='put')assert(!f.logs.slice(at+1).includes('enter:publish'));
    assert.equal(f.acknowledgements.length,0);
  });
});

test('real adapter: automatic deadline aborts the actual in-flight transport signal', async () => {
  const f=fixture(), c=call({deadlineUnixMs:Date.now()+45});
  let observedAbort=false, fallback;
  f.hooks.reserve=received=>new Promise((resolve,reject)=>{
    assert(received.signal instanceof AbortSignal);
    const abort=()=>{observedAbort=true;clearTimeout(fallback);reject(Error('Fixture transport cancelled by actual signal'));};
    if(received.signal.aborted)return abort();
    received.signal.addEventListener('abort',abort,{once:true});
    fallback=setTimeout(()=>reject(Error('No automatic deadline cancellation reached transport')),350);
  });
  try{await assert.rejects(()=>f.adapter().port.beforeCommit(f.event(),c));}
  finally{clearTimeout(fallback);}
  assert.equal(observedAbort,true);
  assert.equal(f.records.length,0);assert.equal(f.acknowledgements.length,0);
});

test('real adapter: successful remote phase arriving after caller abort initiates no next side effect', async t => {
  for(const phase of ['reserve','put','publish'])await t.test(phase,async()=>{
    const f=fixture(),c=call();f.afterHooks[phase]=()=>c.controller.abort();
    await assert.rejects(()=>f.adapter().port.beforeCommit(f.event(),c));
    if(phase==='reserve')assert(!f.logs.includes('enter:put'));
    if(phase==='put')assert(!f.logs.includes('enter:publish'));
    assert.equal(f.acknowledgements.length,0);assert(f.uncertainCount()>0);
  });
});

test('real adapter: cancellation during exact committed-record read cannot initiate SQL acknowledgement', async () => {
  const f=fixture(),a=f.event(),port=f.adapter().port;
  await port.beforeCommit(a,call());f.commit(a);
  const c=call();let cancelled=false;
  f.afterHooks.readExact=(received,record)=>{if(record.kind==='commit'){cancelled=true;c.controller.abort();}};
  await assert.rejects(()=>port.afterCommit(a.eventId,c));
  assert.equal(cancelled,true);assert.equal(f.acknowledgements.length,0);
});

test('real adapter: generation fence makes delayed immutable PUT inert and ordinary writer cannot reset origin', async () => {
  const f=fixture(),a=f.event();f.afterHooks.put=()=>f.fence();
  await assert.rejects(()=>f.adapter().port.beforeCommit(a,call()));
  assert.equal(f.records.length,0);assert.equal(f.acknowledgements.length,0);
  const mutations=f.mutations;
  await assert.rejects(()=>f.adapter().port.beforeCommit(f.event(),call()));
  assert.equal(f.mutations,mutations);assert(f.uncertainCount()>0);
});

test('real adapter: cancellation during committed source work prevents initiating acknowledgement', async () => {
  const f=fixture(), a=f.event(), port=f.adapter().port;
  await port.beforeCommit(a,call());f.commit(a);
  const c=call();f.hooks.sourceRead=()=>c.controller.abort();
  await assert.rejects(()=>port.afterCommit(a.eventId,c));
  assert.equal(f.acknowledgements.length,0);
});

test('real adapter: an acknowledgement sent after durable commit may safely complete after caller abort', async () => {
  const f=fixture(), a=f.event(), port=f.adapter().port;
  await port.beforeCommit(a,call());f.commit(a);
  const hold=gate(), c=call();f.hooks.ack=async()=>hold.promise;
  const pending=port.afterCommit(a.eventId,c);
  await f.entered('ack');
  assert.equal(f.records.at(-1).kind,'commit');
  c.controller.abort();hold.resolve();
  await Promise.allSettled([pending]);
  assert.equal(f.acknowledgements.length,1);
  assert.equal(f.status(a.payload.jobId),'pending');
  assert(f.logs.indexOf('publish:commit')<f.logs.indexOf('enter:ack'));
});

test('real adapter: unpinned signing key is rejected before any remote mutation', async () => {
  const f=fixture(), wrong=keys();
  assert.throws(()=>f.adapter({privateKey:wrong.privateKey}));
  assert.equal(f.mutations,0);
});

test('real adapter: authority verifier accepts only a distinct pinned public Ed25519 key', async t => {
  await t.test('private KeyObject',()=>{
    const f=fixture();assert.throws(()=>f.adapter({authorityPublicKey:f.authorityKeys.privateKey}));assert.equal(f.mutations,0);
  });
  await t.test('private PEM',()=>{
    const f=fixture(),pem=f.authorityKeys.privateKey.export({type:'pkcs8',format:'pem'}).toString();
    assert.throws(()=>f.adapter({authorityPublicKey:pem}));assert.equal(f.mutations,0);
  });
  await t.test('writer and witness are same key',()=>{
    const f=fixture();f.pins.authorityPublicKeyFingerprint=f.writerKeys.fingerprint;
    assert.throws(()=>f.adapter({authorityPublicKey:f.writerKeys.publicKey}));assert.equal(f.mutations,0);
  });
});

test('real adapter: canonical chain limits refuse new immutable PUT at 10000 records or 32 MiB', async t => {
  for(const variant of ['records','bytes'])await t.test(variant,async()=>{
    const f=fixture();
    f.setCurrent(variant==='records'?{head:{seq:10000,hash:'e'.repeat(64)},totalBytes:1000000}:{head:{seq:1,hash:'e'.repeat(64)},totalBytes:32*1024*1024-1});
    await assert.rejects(()=>f.adapter().port.beforeCommit(f.event(),call()));
    assert(!f.logs.includes('enter:put'));assert.equal(f.records.length,0);assert.equal(f.acknowledgements.length,0);
  });
});

test('real adapter: an unrelated valid admitted receipt cannot release the held event claim', async () => {
  const f=fixture(),a=f.event();await f.adapter().port.beforeCommit(a,call());
  f.faults.otherReceipt=f.receiptFor(a.eventId,'intent');
  await assert.rejects(()=>f.adapter().port.beforeCommit(f.event(),call()));
  assert(f.uncertainCount()>0);assert.equal(f.acknowledgements.length,0);
  const mutations=f.mutations;
  await assert.rejects(()=>f.adapter().port.beforeCommit(f.event(),call()));
  assert.equal(f.mutations,mutations);
});

test('real adapter: historical intent receipt cannot authorize beforeCommit after authority-only fence', async t => {
  for(const mode of ['recovery','sealed','active'])await t.test(mode,async()=>{
    const f=fixture(),a=f.event();await f.adapter().port.beforeCommit(a,call());
    f.authorityFenceOnly(mode);
    await assert.rejects(()=>f.adapter().port.beforeCommit(a,call()));
    assert.equal(f.records.length,1);assert.equal(f.acknowledgements.length,0);assert(f.uncertainCount()>0);
  });
});

test('real adapter: authority fence after publish but before response prevents completing beforeCommit', async () => {
  const f=fixture();f.afterHooks.publish=()=>f.authorityFenceOnly();
  await assert.rejects(()=>f.adapter().port.beforeCommit(f.event(),call()));
  assert.equal(f.records.length,1);assert.equal(f.acknowledgements.length,0);assert(f.uncertainCount()>0);
});

test('real adapter: changed same-job committed acceptance must match its original admitted receipt before progress PUT', async t => {
  for(const variant of ['content','target'])await t.test(variant,async()=>{
    const f=fixture(),a=f.event(),port=f.adapter().port;
    await port.beforeCommit(a,call());f.commit(a);await port.afterCommit(a.eventId,call());
    const changed=clone(a);
    if(variant==='content')changed.payload.data.requestDigest='e'.repeat(64);
    else {
      const memberId=randomUUID(),data=changed.payload.data,target=data.targets[0];
      target.memberId=memberId;target.binding.member_id=memberId;
      for(const effect of data.effects){effect.key=`${target.householdId}/${memberId}`;effect.before.member_id=memberId;effect.after.member_id=memberId;}
    }
    changed.payloadDigest=digest(changed.payload);
    const p=progressEvent(changed);f.commit(p);f.faults.sourceAcceptance=changed;
    const puts=f.logs.filter(x=>x==='enter:put').length;
    await assert.rejects(()=>port.afterCommit(p.eventId,call()));
    assert.equal(f.logs.filter(x=>x==='enter:put').length,puts);
    assert.equal(f.records.length,2);assert.equal(f.acknowledgements.length,1);
  });
});

test('real adapter: lost guard completion response permits safe exact retry after durable receipt', async () => {
  const f=fixture(),a=f.event();f.faults.lostResponse='complete';
  await assert.rejects(()=>f.adapter().port.beforeCommit(a,call()));
  assert.equal(f.records.length,1);assert.equal(f.uncertainCount(),0);
  delete f.faults.lostResponse;
  await f.adapter().port.beforeCommit(a,call());
  assert.equal(f.records.length,1);assert.equal(f.uncertainCount(),0);
});

test('real receipt verifier: independent authenticated receipt validates; private witness material or signer reuse rejects', async t => {
  const f=fixture(),a=f.event();await f.adapter().port.beforeCommit(a,call());
  const proof=f.receiptFor(a.eventId,'intent');
  assert.deepEqual(verifyDurableAdmissionReceipt(proof,f.pins,f.authorityKeys.publicKey),proof);
  await t.test('private KeyObject',()=>assert.throws(()=>verifyDurableAdmissionReceipt(proof,f.pins,f.authorityKeys.privateKey)));
  await t.test('private PEM',()=>assert.throws(()=>verifyDurableAdmissionReceipt(proof,f.pins,f.authorityKeys.privateKey.export({type:'pkcs8',format:'pem'}).toString())));
  await t.test('same signer/witness key',()=>assert.throws(()=>verifyDurableAdmissionReceipt(proof,{...f.pins,authorityPublicKeyFingerprint:f.writerKeys.fingerprint},f.writerKeys.publicKey)));
});

test('real adapter: independently signed wrong ticket identity, generation, namespace, head or deadline causes no PUT', async t => {
  for(const variant of ['objectKey','generation','deadline','identity','previousHead','unknown'])await t.test(variant,async()=>{
    const f=fixture();f.faults.ticket=variant;
    await assert.rejects(()=>f.adapter().port.beforeCommit(f.event(),call()));
    assert(!f.logs.includes('enter:put'));assert.equal(f.records.length,0);assert(f.uncertainCount()>0);
  });
});
