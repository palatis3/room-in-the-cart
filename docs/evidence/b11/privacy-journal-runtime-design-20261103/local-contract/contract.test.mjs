import test from 'node:test';
import assert from 'node:assert/strict';
import {generateKeyPairSync} from 'node:crypto';
import {actual,copy,createContractRuntime,createContractRecovery,verifyHead,ACTUAL_VERIFIER_PINS} from './contract-runtime.mjs';
import {Scheduler,createDeterministicRecordStore,createDeterministicAuthority,createFakeSQLSource} from './deterministic-transports.mjs';

const uid=n=>'00000000-0000-4000-8000-'+n.toString(16).padStart(12,'0');
function acceptance(pins,n=1){
 const eventId=uid(100+n),identityHash=actual.hash('synthetic-adult-'+n),at='2026-11-03T12:00:00.000Z';
 const payload={version:1,eventId,lineage:pins.lineage,schemaDigest:pins.schemaDigest,configurationId:pins.configurationId,jobId:uid(200+n),kind:'acceptance',data:{identityHash,receiptHash:actual.hash('synthetic-receipt-hash-'+n),requestDigest:actual.hash('synthetic-request-'+n),acceptedAt:at,receiptDays:30,markerDays:90,receiptUntil:'2026-12-03T12:00:00.000Z',markerUntil:'2027-02-01T12:00:00.000Z',attestation:{configurationId:pins.configurationId,authenticatedAt:at,authenticatedMethod:'otp',providerAvailability:'configured_adapter_passed',appleGate:'availability_contract_passed',sqlAdultScopeCheck:'passed',policy:{receiptRetentionDays:30,erasureMarkerRetentionDays:90,verifiedBackupRetentionDays:60},sessionBindingHash:actual.hash('synthetic-session-binding-'+n),checkedAt:at},targets:[{householdId:uid(300+n),memberId:uid(400+n),kind:'self_adult',binding:{household_id:uid(300+n),member_id:uid(400+n),kind:'adult',state:'active',organizer:true,can_contribute:true,erased_at:null,identity_hash:identityHash}}],effects:[],guardianPreimage:[]}};
 return{eventId,payloadDigest:actual.hash(payload),payload};
}
function progress(a,n=1){const eventId=uid(500+n),target=a.payload.data.targets[0],payload={...copy(a.payload),eventId,kind:'target_erased',data:{householdId:target.householdId,memberId:target.memberId,retiredPurchases:[],erasedAt:'2026-11-03T12:01:00.000Z'}};return{eventId,payloadDigest:actual.hash(payload),payload};}
function fixture(){
 const scheduler=new Scheduler(),journalKeys=generateKeyPairSync('ed25519'),witnessKeys=generateKeyPairSync('ed25519'),clientCapability=Symbol('synthetic client-held capability');
 const pins=Object.freeze({lineage:uid(1),schemaDigest:actual.hash('synthetic-schema-not-production'),configurationId:'local-contract-synthetic-only',keyId:'synthetic-ed25519',sourceIdentity:'fake-sql-contract-only',recordNamespace:'synthetic-records'});
 let records,authority,sql,attempt=0;
 function reconstruct(saved){
  records=createDeterministicRecordStore({scheduler,snapshot:saved?.records,recordNamespace:pins.recordNamespace});
  authority=createDeterministicAuthority({pins,publicKey:journalKeys.publicKey,authorityPrivateKey:witnessKeys.privateKey,recordReader:records.reader,scheduler,snapshot:saved?.authority});
  sql=createFakeSQLSource({pins,scheduler,snapshot:saved?.sql,clientCapability,receiptCovers:r=>authority.reader.receiptCovers(r)});
 }
 reconstruct();
 const configuration=overrides=>({pins,privateKey:journalKeys.privateKey,authorityPublicKey:witnessKeys.publicKey,source:sql.source,records:records.writer,authority:authority.writer,clock:scheduler,...overrides});
 const runtime=overrides=>createContractRuntime(configuration(overrides));
 function context(ms=5000){const controller=new AbortController();return{controller,call:{attemptId:'synthetic-attempt-'+(++attempt),deadlineUnixMs:scheduler.now()+ms,signal:controller.signal}};}
 const call=ms=>context(ms).call;
 const recovery=()=>createContractRecovery({...configuration(),recoveryAuthority:authority.recovery});
 async function request(event,rt=runtime(),ctx=context()){
  const tx=sql.control.begin(event);
  try{await rt.port.beforeCommit(tx.sqlResult(),ctx.call);tx.commit();await rt.port.afterCommit(event.eventId,ctx.call);return{returned202:true};}
  catch(error){tx.rollback();throw error;}
 }
 function snapshot(){return{records:records.control.snapshot(),authority:authority.control.snapshot(),sql:sql.control.snapshot()};}
 async function verified(){const h=authority.reader.head();verifyHead(h,pins,witnessKeys.publicKey);const bytes=await authority.reader.materialize(call());const result=actual.verify(bytes,{...pins,publicKey:journalKeys.publicKey.export({type:'spki',format:'pem'}).toString(),head:h.head});actual.validateEvents(result.events);return{...result,bytes};}
 return{pins,scheduler,runtime,context,call,request,recovery,snapshot,restart(){const saved=snapshot();reconstruct(JSON.parse(JSON.stringify(saved)));},verified,get records(){return records;},get authority(){return authority;},get sql(){return sql;},get source(){return sql.source;},get publicKey(){return journalKeys.publicKey;},get witnessPublicKey(){return witnessKeys.publicKey;},makeEvent:n=>acceptance(pins,n)};
}

test('actual canonical/signature/full-chain verifier is hash pinned',()=>{
 assert.equal(ACTUAL_VERIFIER_PINS.module.sha256,'423c823cc5d1546390084727bf55d5febd7f7eaddb6ad2bb05acf548d9553937');
 assert.equal(actual.canonical({b:2,a:1}),'{"a":1,"b":2}');
});

test('intent/head precede source COMMIT; committed observation/head precede acknowledgement',async()=>{
 const f=fixture(),e=f.makeEvent(),pause=f.scheduler.pause('store.beforePut'),request=f.request(e);
 await pause.reached;assert.equal(f.sql.control.state().committed.length,0);assert.equal(f.sql.control.eligible(e.payload.jobId),false);
 pause.release();assert.deepEqual(await request,{returned202:true});
 const labels=f.scheduler.log.map(e=>e.label);
 assert.ok(labels.indexOf('authority.afterPublish')<labels.indexOf('source.commit'));
 assert.ok(labels.lastIndexOf('authority.afterPublish')<labels.indexOf('source.ackCommitted'));
 assert.equal(f.sql.control.eligible(e.payload.jobId),true);
 await f.recovery().fenceAndSeal(f.call());assert.equal((await f.verified()).events.length,1);
});

test('failed intent persistence returns no success and rolls back SQL; pending survives recreation',async()=>{
 const f=fixture(),e=f.makeEvent();f.scheduler.fail('store.beforePut');
 await assert.rejects(f.request(e),/Injected/);assert.equal(f.sql.control.state().committed.length,0);assert.equal(f.records.control.references().length,0);
 f.restart();await assert.rejects(f.runtime().port.beforeCommit(e,f.call()),/pending/);assert.equal(f.authority.control.state().head.seq,0);
});

test('crash after intent publication before SQL COMMIT resolves only after source fence',async()=>{
 const f=fixture(),e=f.makeEvent(),tx=f.sql.control.begin(e);await f.runtime().port.beforeCommit(tx.sqlResult(),f.call());tx.rollback();f.restart();
 assert.equal(f.authority.control.state().events[e.eventId].state,'intent');
 await assert.rejects(f.source.hasCommittedEvent(e.eventId,f.call()),/before source fence/);
 await f.recovery().fenceAndSeal(f.call());const verified=await f.verified();assert.equal(verified.events.length,0);assert.equal(verified.head.seq,2);
 const labels=f.scheduler.log.map(e=>e.label);assert.ok(labels.indexOf('source.fenceCommitted')<labels.indexOf('source.fencedAbsenceRead'));
});

test('crash after SQL COMMIT before observation resumes through fixed-source job lookup',async()=>{
 const f=fixture(),e=f.makeEvent(),tx=f.sql.control.begin(e);await f.runtime().port.beforeCommit(tx.sqlResult(),f.call());tx.commit();f.restart();
 assert.equal(f.sql.control.eligible(e.payload.jobId),false);await f.runtime().port.acknowledgeJob(e.payload.jobId,f.call());
 assert.equal(f.sql.control.eligible(e.payload.jobId),true);assert.equal(f.authority.control.state().admitted.length,2);
});

test('lost commit-publication response recovers exact receipt without duplicate sequence or ack identity',async()=>{
 const f=fixture(),e=f.makeEvent(),tx=f.sql.control.begin(e),rt=f.runtime();await rt.port.beforeCommit(tx.sqlResult(),f.call());tx.commit();
 f.scheduler.fail('authority.afterPublish','Lost admitted response');await assert.rejects(rt.port.afterCommit(e.eventId,f.call()),/Lost admitted/);
 assert.equal(f.authority.control.state().admitted.length,2);assert.equal(Object.keys(f.sql.control.state().acks).length,0);
 const original=f.authority.control.state().admitted[1];f.restart();await f.runtime().port.afterCommit(e.eventId,f.call());
 assert.equal(f.authority.control.state().admitted.length,2);assert.deepEqual(f.sql.control.state().acks[e.eventId],{payloadDigest:e.payloadDigest,headSeq:original.record.seq,headHash:original.record.recordHash});
});

for(const point of ['authority.afterReserve','store.afterPut'])test('interruption at '+point+' leaves a persistent uncertain slot, never inferred success',async()=>{
 const f=fixture(),e=f.makeEvent();f.scheduler.fail(point);await assert.rejects(f.request(e),/Injected/);
 const saved=f.snapshot();assert.equal(JSON.stringify(saved).includes('PRIVATE KEY'),false);f.restart();
 assert.ok(f.authority.control.state().pending);await assert.rejects(f.request(e),/pending/);assert.equal(f.sql.control.state().committed.length,0);
 await f.recovery().fenceAndSeal(f.call());assert.equal(f.authority.reader.head().head.seq,0);assert.equal(f.authority.control.canonicalReferences().length,0);
 assert.equal(f.records.control.references().length,point==='store.afterPut'?1:0);
});

test('two independent instances racing one head admit one branch; loser cannot SQL-commit',async()=>{
 const f=fixture(),a=f.makeEvent(1),b=f.makeEvent(2),pause=f.scheduler.pause('authority.beforeReserve');
 const first=f.request(a,f.runtime());await pause.reached;await f.request(b,f.runtime());pause.release();await assert.rejects(first,/CAS conflict/);
 assert.deepEqual(f.sql.control.state().committed.map(e=>e.eventId),[b.eventId]);assert.equal(f.authority.control.state().head.seq,2);
 await f.recovery().fenceAndSeal(f.call());assert.deepEqual((await f.verified()).events.map(e=>e.eventId),[b.eventId]);
});

test('same event/digest across recreated instances reuses original intent and commit',async()=>{
 const f=fixture(),e=f.makeEvent();await f.request(e);const before=copy(f.sql.control.state().acks);f.restart();await f.request(e);
 assert.equal(f.authority.control.state().admitted.length,2);assert.deepEqual(f.sql.control.state().acks,before);
});

test('same event ID with changed digest conflicts without new source commit/head',async()=>{
 const f=fixture(),e=f.makeEvent();await f.request(e);const altered=copy(e);altered.payload.data.requestDigest=actual.hash('changed');altered.payloadDigest=actual.hash(altered.payload);
 await assert.rejects(f.request(altered),/digest conflict/);assert.equal(f.authority.control.state().head.seq,2);assert.equal(f.sql.control.state().committed.length,1);
});

test('a late stale-generation PUT remains an unreferenced object and cannot publish',async()=>{
 const f=fixture(),e=f.makeEvent(),ctx=f.context(),pause=f.scheduler.pause('store.beforePut'),request=f.request(e,f.runtime(),ctx);
 await pause.reached;const oldTicket=f.authority.control.state().pending,oldWriter=f.authority.writer;
 await f.authority.recovery.beginFence(f.call());const sourceFence=f.source.fence(f.call(50000));
 assert.equal(f.sql.control.state().origin.fenced,false);ctx.controller.abort();f.scheduler.advance(6000);pause.release();await assert.rejects(request);
 await sourceFence;const orphan=f.records.control.references()[0];assert.ok(orphan);
 await assert.rejects(oldWriter.publish(oldTicket,orphan,f.call()),/mode\/fence/);
 await f.recovery().fenceAndSeal(f.call());assert.equal(f.authority.control.canonicalReferences().length,0);assert.equal(f.authority.reader.head().head.seq,0);assert.equal(f.sql.control.state().committed.length,0);
});

test('authority-clock expiry rejects late publication even before outer call deadline',async()=>{
 const f=fixture(),e=f.makeEvent(),ctx=f.context(),pause=f.scheduler.pause('authority.beforePublish'),request=f.request(e,f.runtime(),ctx);
 await pause.reached;f.scheduler.advance(3600);pause.release();await assert.rejects(request,/authority deadline/);
 assert.equal(f.records.control.references().length,1);assert.equal(f.authority.control.state().head.seq,0);assert.equal(f.sql.control.state().committed.length,0);
});

test('already-sent SQL acknowledgement may finish after timeout; original status capability recovers safely',async()=>{
 const f=fixture(),e=f.makeEvent(),tx=f.sql.control.begin(e),rt=f.runtime();await rt.port.beforeCommit(tx.sqlResult(),f.call());tx.commit();
 const ctx=f.context(),pause=f.scheduler.pause('source.beforeAckCommit'),observation=rt.port.afterCommit(e.eventId,ctx.call);
 await pause.reached;assert.equal(f.authority.control.state().head.seq,2);assert.equal(f.sql.control.eligible(e.payload.jobId),false);
 ctx.controller.abort();f.scheduler.advance(6000);pause.release();await assert.rejects(observation);
 assert.equal(f.sql.control.eligible(e.payload.jobId),true);
 assert.deepEqual(f.sql.control.receiptStatus(e.payload.jobId,f.sql.control.heldCapability),{jobExists:true,workerEligible:true});
 assert.throws(()=>f.sql.control.receiptStatus(e.payload.jobId,Symbol('different')),/capability/);
 f.restart();assert.deepEqual(f.sql.control.receiptStatus(e.payload.jobId,f.sql.control.heldCapability),{jobExists:true,workerEligible:true});
});

test('forged independent receipt cannot cause source COMMIT or acknowledgement',async()=>{
 const f=fixture(),e=f.makeEvent(),real=f.authority.writer;
 const forged={...real,async publish(...args){const receipt=await real.publish(...args);receipt.record.recordHash='f'.repeat(64);return receipt;}};
 await assert.rejects(f.request(e,f.runtime({authority:forged})),/receipt rejected/);assert.equal(f.sql.control.state().committed.length,0);assert.equal(Object.keys(f.sql.control.state().acks).length,0);
});

test('wrong fixed source identity fails before persistence',async()=>{
 const f=fixture(),e=f.makeEvent(),wrong={...f.source,async readOrigin(call){return{...await f.source.readOrigin(call),sourceIdentity:'another-source'};}};
 await assert.rejects(f.request(e,f.runtime({source:wrong})),/origin mismatch/);assert.equal(f.records.control.references().length,0);assert.equal(f.authority.control.state().pending,null);
});

test('transport cannot redirect a ticket outside its constructor-pinned namespace',async()=>{
 const f=fixture(),e=f.makeEvent(),real=f.authority.writer;
 const redirected={...real,async reserve(...args){const ticket=await real.reserve(...args);ticket.objectKey='another-namespace/target';return ticket;}};
 await assert.rejects(f.request(e,f.runtime({authority:redirected})),/storage namespace/);assert.equal(f.records.control.references().length,0);assert.equal(f.sql.control.state().committed.length,0);
});

test('unapproved fields fail actual strict content validation before any object PUT',async()=>{
 const f=fixture(),e=f.makeEvent();e.payload.data.email='synthetic-forbidden-field@example.invalid';e.payloadDigest=actual.hash(e.payload);
 await assert.rejects(f.request(e));assert.equal(f.records.control.references().length,0);assert.equal(f.authority.control.state().head.seq,0);assert.equal(f.sql.control.state().committed.length,0);
});

test('target pair/binding replacement is rejected before persistence',async()=>{
 const f=fixture(),e=f.makeEvent();e.payload.data.targets[0].householdId=uid(999);e.payloadDigest=actual.hash(e.payload);
 await assert.rejects(f.request(e),/Target binding/);assert.equal(f.records.control.references().length,0);assert.equal(f.sql.control.state().committed.length,0);
});

test('valid signatures from an unpinned journal key cannot enter the canonical head',async()=>{
 const f=fixture(),e=f.makeEvent(),other=generateKeyPairSync('ed25519');
 await assert.rejects(f.request(e,f.runtime({privateKey:other.privateKey})),/signature rejected/);assert.equal(f.authority.control.state().head.seq,0);assert.equal(f.sql.control.state().committed.length,0);
});

test('committed source acceptance without original admitted intent cannot be exported/acknowledged',async()=>{
 const f=fixture(),e=f.makeEvent(),tx=f.sql.control.begin(e);tx.commit();
 await assert.rejects(f.runtime().port.afterCommit(e.eventId,f.call()),/original durable intent/);
 assert.equal(f.records.control.references().length,0);assert.equal(f.sql.control.eligible(e.payload.jobId),false);
});

test('unacknowledged source progress blocks eligibility until exact progress head/ack',async()=>{
 const f=fixture(),e=f.makeEvent();await f.request(e);const p=progress(e),tx=f.sql.control.begin(p);tx.commit();
 assert.equal(f.sql.control.eligible(e.payload.jobId),false);f.restart();await f.runtime().port.acknowledgeJob(e.payload.jobId,f.call());assert.equal(f.sql.control.eligible(e.payload.jobId),true);
 await f.recovery().fenceAndSeal(f.call());const verified=await f.verified();assert.equal(verified.head.seq,3);assert.equal(verified.events.length,2);
});

test('progress for a target outside the original acceptance is never written or acknowledged',async()=>{
 const f=fixture(),e=f.makeEvent();await f.request(e);const p=progress(e);p.payload.data.householdId=uid(999);p.payloadDigest=actual.hash(p.payload);f.sql.control.begin(p).commit();
 await assert.rejects(f.runtime().port.acknowledgeJob(e.payload.jobId,f.call()),/Progress target outside acceptance/);
 assert.equal(f.records.control.references().length,2);assert.equal(f.sql.control.eligible(e.payload.jobId),false);
});

test('source fence waits for earlier transaction before absence can resolve rollback',async()=>{
 const f=fixture(),e=f.makeEvent(),tx=f.sql.control.begin(e);await f.runtime().port.beforeCommit(tx.sqlResult(),f.call());
 await f.authority.recovery.beginFence(f.call());const pending=f.source.fence(f.call());assert.equal(f.sql.control.state().origin.fenced,false);
 await assert.rejects(f.source.hasCommittedEvent(e.eventId,f.call()),/before source fence/);tx.rollback();await pending;
 await f.recovery().fenceAndSeal(f.call());assert.equal((await f.verified()).head.seq,2);
});

test('fence waits for an earlier COMMIT, then recovery observes it rather than fabricating rollback',async()=>{
 const f=fixture(),e=f.makeEvent(),tx=f.sql.control.begin(e);await f.runtime().port.beforeCommit(tx.sqlResult(),f.call());
 await f.authority.recovery.beginFence(f.call());const fence=f.source.fence(f.call());tx.commit();await fence;await f.recovery().fenceAndSeal(f.call());
 const verified=await f.verified();assert.equal(verified.events.length,1);assert.equal(f.authority.control.state().events[e.eventId].state,'commit');
});

test('ordinary authority cannot admit rollback or clear a fence',async()=>{
 const f=fixture(),head=await f.authority.writer.readCurrent(f.call());
 await assert.rejects(f.authority.writer.reserve(head,{eventId:uid(9),payloadDigest:'a'.repeat(64),transition:'rollback'},f.call()),/rollback forbidden/);
 assert.equal('beginFence' in f.authority.writer,false);assert.equal('seal' in f.authority.writer,false);
 await f.authority.recovery.beginFence(f.call());await assert.rejects(f.runtime().port.beforeCommit(f.makeEvent(),f.call()),/mode\/fence/);
});

test('seal rejects unresolved intent; actual verifier rejects an unresolved journal even with claimed fenced head',async()=>{
 const f=fixture(),e=f.makeEvent(),tx=f.sql.control.begin(e);await f.runtime().port.beforeCommit(tx.sqlResult(),f.call());tx.rollback();
 const bytes=await f.authority.reader.materialize(f.call()),head=f.authority.reader.head().head;
 assert.throws(()=>actual.verify(bytes,{...f.pins,publicKey:f.publicKey.export({type:'spki',format:'pem'}).toString(),head:{...head,fenced:true}}),/unresolved intent/);
 await f.authority.recovery.beginFence(f.call());await f.source.fence(f.call());await assert.rejects(f.authority.recovery.seal(await f.source.readOrigin(f.call()),f.call()),/unresolved/);
});

test('actual verifier rejects valid early prefix, missing suffix and changed record under independent final head',async()=>{
 const f=fixture();await f.request(f.makeEvent(1));const prefix=await f.authority.reader.materialize(f.call());const oldHead=f.authority.reader.head();
 await f.request(f.makeEvent(2));await f.recovery().fenceAndSeal(f.call());const full=await f.verified(),trust={...f.pins,publicKey:f.publicKey.export({type:'spki',format:'pem'}).toString(),head:full.head};
 assert.throws(()=>actual.verify(prefix,trust),/prefix/);assert.throws(()=>actual.verify(full.bytes.subarray(0,-1),trust),/Truncated/);
 const changed=Buffer.from(full.bytes);changed[20]^=1;assert.throws(()=>actual.verify(changed,trust));
 assert.throws(()=>actual.verify(prefix,{...trust,head:oldHead.head}),/fenced head/);
 const forgedOld=copy(oldHead);forgedOld.head.fenced=true;assert.throws(()=>verifyHead(forgedOld,f.pins,f.witnessPublicKey),/receipt rejected/);
});

test('corrupt stored version fails full-chain verification rather than yielding a ready bundle',async()=>{
 const f=fixture();await f.request(f.makeEvent());await f.recovery().fenceAndSeal(f.call());const ref=f.authority.control.canonicalReferences()[0];
 f.records.control.corrupt(ref,bytes=>{const next=Buffer.from(bytes);next[30]^=1;return next;});await assert.rejects(f.verified());
});

test('sealed origin is terminal for ordinary writers and recovery generation',async()=>{
 const f=fixture();await f.request(f.makeEvent());await f.recovery().fenceAndSeal(f.call());
 await assert.rejects(f.runtime().port.beforeCommit(f.makeEvent(2),f.call()),/Source fenced/);
 await assert.rejects(f.authority.recovery.beginFence(f.call()),/terminal/);assert.equal((await f.verified()).events.length,1);
});
