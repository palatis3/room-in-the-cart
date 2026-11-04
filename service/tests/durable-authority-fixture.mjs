import assert from 'node:assert/strict';
import {randomUUID,sign,verify} from 'node:crypto';
import {createDurablePrivacyJournal} from '../dist/privacy-journal-durable.js';
import {validatePrivacyRestoreEvents} from '../dist/privacy-journal.js';
import {acceptedEvent,assertCanonicalRecord,canonical,checkCall,clone,digest,gate,keys,zero} from './durable-independent-fixture.mjs';

// Test-only backing state models independently authenticated CAS and immutable
// object versions. Its state is shared by every constructed real adapter. This
// deliberately does not establish a remote provider's production durability.
export function fixture(originPins={}) {
  const writer=keys(), authorityKeys=keys();
  const pins={
    lineage:randomUUID(),schemaDigest:'b'.repeat(64),configurationId:'actual-option-a-local-fixture',
    keyId:'fixture-writer-v1',publicKeyFingerprint:writer.fingerprint,
    sourceIdentity:'fixture-fixed-source-v1',recordStoreIdentity:'fixture-record-store-v1',recordNamespace:'fixture-namespace-v1',
    checkpointAuthority:'fixture-checkpoint-v1',deploymentPrincipal:'fixture-deployment-v1',
    authorityKeyId:'fixture-authority-v1',authorityPublicKeyFingerprint:authorityKeys.fingerprint,
    ...originPins,
  };
  const fixedPins=clone(pins), scopeDigest=digest({version:1,...fixedPins});
  const origin={lineage:pins.lineage,schemaDigest:pins.schemaDigest,configurationId:pins.configurationId};
  const objects=new Map(), operations=new Map(), claims=new Map(), committed=new Map(), eventIndex=new Map(), accepted=new Map();
  const logs=[], records=[], acknowledgements=[], hooks={}, afterHooks={}, faults={}, entered=new Map();
  let current={head:{version:1,...origin,seq:0,hash:zero,fenced:false},generation:1,authorityRevision:0,mode:'active',pendingOperation:null,totalBytes:0};
  let mutations=0,capturedHead=null,sourceFenced=false;
  const copy=clone;
  const operationId=identity=>digest({version:1,scopeDigest,eventId:identity.eventId,payloadDigest:identity.payloadDigest,transition:identity.transition});
  const authSign=(value,domain='ritc-privacy-journal-authority-v1')=>{
    const body=copy(value);
    return {...body,authoritySignature:sign(null,Buffer.from(canonical(body)),authorityKeys.privateKey).toString('base64url')};
  };
  function authenticate(value) {
    const {authoritySignature,...body}=value;
    assert.equal(body.scopeDigest,scopeDigest);assert.equal(body.authorityKeyId,fixedPins.authorityKeyId);
    assert(verify(null,Buffer.from(canonical(body)),authorityKeys.publicKey,Buffer.from(authoritySignature,'base64url')));
  }
  function envelope(value,call){return authSign({version:1,domain:'ritc-privacy-journal-authority-v1',scopeDigest,authorityKeyId:fixedPins.authorityKeyId,requestNonce:call.requestNonce,value:copy(value)});}
  async function enter(phase,call) {
    logs.push('enter:'+phase);
    if(!entered.has(phase))entered.set(phase,gate());
    entered.get(phase).resolve();
    if(hooks[phase]) await hooks[phase](call);
  }
  const unchanged=(left,right)=>assert.equal(canonical(left),canonical(right));
  function validateStored(stored,ticket) {
    assert.equal(stored.objectKey,ticket.objectKey);assert.equal(stored.recordHash,ticket.record.recordHash);assert.equal(stored.byteLength,ticket.record.byteLength);
    const object=objects.get(stored.objectKey);assert(object);unchanged(stored,object.stored);
    return assertCanonicalRecord(object.bytes,writer.publicKey,ticket.record);
  }
  function validReceipt(receipt) {
    authenticate(receipt);assert.equal(receipt.domain,'ritc-privacy-journal-admission-v1');
    const actual=operations.get(receipt.operationId);assert.equal(actual?.state,'admitted');unchanged(receipt,actual.receipt);
  }
  function corruptedReceipt(receipt) {
    if(faults.otherReceipt)return copy(faults.otherReceipt);
    if(!faults.receipt)return copy(receipt);
    const changed=copy(receipt), variant=faults.receipt;
    if(variant==='signature')changed.authoritySignature='A'.repeat(86);
    else {
      delete changed.authoritySignature;
      if(variant==='namespace')changed.scopeDigest='e'.repeat(64);
      if(variant==='key')changed.authorityKeyId='other-authority-key';
      if(variant==='head')changed.admitted.head.hash='e'.repeat(64);
      if(variant==='generation')changed.admitted.generation++;
      if(variant==='record')changed.record.jobId=randomUUID();
      if(variant==='stored')changed.stored.immutableVersion='other-version';
      if(variant==='unknown')changed.extra=true;
      return authSign(changed);
    }
    return changed;
  }
  const authority={
    async readCurrent(call){
      checkCall(call);await enter('head',call);checkCall(call);
      if(faults.replayHead){assert(capturedHead);return copy(capturedHead);}
      const result=envelope(current,call);if(faults.captureHead)capturedHead=copy(result);return result;
    },
    async inspectOperation(id,call){
      checkCall(call);await enter('inspect',call);checkCall(call);
      const op=operations.get(id);return envelope(op?{...copy(op),operationId:id}:{state:'absent',operationId:id},call);
    },
    async reserve(expected,identity,call){
      checkCall(call);await enter('reserve',call);checkCall(call);
      const id=operationId(identity), prior=operations.get(id);
      if(prior?.state==='admitted')throw Error('Already admitted; inspect exact receipt');
      assert.equal(current.mode,'active');assert.equal(current.pendingOperation,null);unchanged(expected,current);
      assert.equal(identity.seq,current.head.seq+1);assert.equal(identity.previousHash,current.head.hash);
      const existing=eventIndex.get(identity.eventId);
      if(existing){assert.equal(existing.digest,identity.payloadDigest);assert.equal(existing.jobId,identity.jobId);assert(!existing.transitions.has(identity.transition));}
      const ticket={operationId:id,generation:current.generation,expected:copy(expected),record:copy(identity),objectKey:`${scopeDigest}/${identity.seq}/${identity.recordHash}`,authorityExpiresAtUnixMs:Math.min(call.deadlineUnixMs-10,Date.now()+3000)};
      current={...current,mode:'pending',pendingOperation:id};operations.set(id,{state:'pending',ticket:copy(ticket)});mutations++;
      if(afterHooks.reserve)await afterHooks.reserve(call);
      if(faults.lostResponse==='reserve')throw Error('Fixture reserve response lost after durable CAS');
      const returned=copy(ticket);
      if(faults.ticket==='objectKey')returned.objectKey='other-scope/1/other-record';
      if(faults.ticket==='generation')returned.generation++;
      if(faults.ticket==='deadline')returned.authorityExpiresAtUnixMs=Date.now()-1;
      if(faults.ticket==='identity')returned.record.byteLength++;
      if(faults.ticket==='previousHead')returned.expected.head.hash='e'.repeat(64);
      if(faults.ticket==='unknown')returned.extra=true;
      return envelope(returned,call);
    },
    async publish(ticket,stored,call){
      checkCall(call);await enter('publish',call);checkCall(call);
      const prior=operations.get(ticket.operationId);
      if(prior?.state==='admitted')return corruptedReceipt(prior.receipt);
      assert.equal(prior?.state,'pending');unchanged(ticket,prior.ticket);
      assert.equal(current.generation,ticket.generation);assert.equal(current.pendingOperation,ticket.operationId);
      assert.equal(current.mode,'pending');assert(Date.now()<ticket.authorityExpiresAtUnixMs);
      const record=validateStored(stored,ticket), event=record.event, state=eventIndex.get(event.eventId);
      assert.equal(record.keyId,fixedPins.keyId);
      assert.equal(event.payload.lineage,origin.lineage);assert.equal(event.payload.schemaDigest,origin.schemaDigest);assert.equal(event.payload.configurationId,origin.configurationId);
      if(state){assert.equal(state.digest,event.payloadDigest);assert.equal(state.jobId,event.payload.jobId);assert(!state.transitions.has(record.kind));}
      if(record.kind==='intent')assert(!state);
      if(record.kind==='commit'){
        if(event.payload.kind==='acceptance'){assert(state?.transitions.has('intent'));assert(!accepted.has(event.payload.jobId));}
        else assert(accepted.has(event.payload.jobId));
      }
      if(event.payload.kind==='acceptance')validatePrivacyRestoreEvents([event]);
      else validatePrivacyRestoreEvents([accepted.get(event.payload.jobId),event]);
      if(record.kind==='commit'&&event.payload.kind==='acceptance')accepted.set(event.payload.jobId,copy(event));
      const transitions=state?.transitions??new Set();transitions.add(record.kind);
      eventIndex.set(event.eventId,{digest:event.payloadDigest,jobId:event.payload.jobId,transitions});
      records.push(copy(record));
      current={head:{version:1,...origin,seq:record.seq,hash:digest(record),fenced:false},generation:ticket.generation,authorityRevision:current.authorityRevision+1,mode:'active',pendingOperation:null,totalBytes:current.totalBytes+ticket.record.byteLength};
      const receipt=authSign({version:1,domain:'ritc-privacy-journal-admission-v1',scopeDigest,authorityKeyId:fixedPins.authorityKeyId,operationId:ticket.operationId,admitted:copy(current),record:copy(ticket.record),stored:copy(stored)});
      operations.set(ticket.operationId,{state:'admitted',receipt});logs.push('publish:'+record.kind);mutations++;
      if(afterHooks.publish)await afterHooks.publish(call);
      if(faults.lostResponse==='publish')throw Error('Fixture publish response lost after durable admission');
      return corruptedReceipt(receipt);
    },
  };
  const recordTransport={
    async putExact(ticket,bytes,call){
      checkCall(call);await enter('put',call);checkCall(call);
      assert.equal(ticket.objectKey,`${scopeDigest}/${ticket.record.seq}/${ticket.record.recordHash}`);
      assert.equal(bytes.byteLength,ticket.record.byteLength);assertCanonicalRecord(bytes,writer.publicKey,ticket.record);
      const found=objects.get(ticket.objectKey);
      if(found){assert(Buffer.from(bytes).equals(found.bytes));return copy(found.stored);}
      const stored={objectKey:ticket.objectKey,immutableVersion:randomUUID(),recordHash:ticket.record.recordHash,byteLength:bytes.byteLength};
      objects.set(ticket.objectKey,{stored:copy(stored),bytes:Buffer.from(bytes)});mutations++;
      if(afterHooks.put)await afterHooks.put(call);
      if(faults.lostResponse==='put')throw Error('Fixture immutable object response lost after persisted bytes');
      return copy(stored);
    },
    async readExact(stored,call){checkCall(call);await enter('readExact',call);checkCall(call);const found=objects.get(stored.objectKey);assert(found);unchanged(stored,found.stored);if(afterHooks.readExact)await afterHooks.readExact(call,JSON.parse(found.bytes.toString('utf8')));return Buffer.from(found.bytes);},
  };
  const uncertainty={
    async begin(operation,call){
      checkCall(call);await enter('begin',call);checkCall(call);assert.equal(operation.scopeDigest,scopeDigest);assert(!claims.has(operation.scopeDigest),'Outstanding durable claim cannot be cleared by new instance');
      const claim={...copy(operation),claimId:randomUUID()};claims.set(operation.scopeDigest,copy(claim));
      if(faults.lostResponse==='begin')throw Error('Fixture durable guard response lost after persisted claim');
      return copy(claim);
    },
    async complete(claim,proof,call){
      checkCall(call);await enter('complete',call);checkCall(call);unchanged(claim,claims.get(claim.scopeDigest));validReceipt(proof);
      assert.equal(proof.scopeDigest,claim.scopeDigest);assert.equal(proof.record.eventId,claim.eventId);assert.equal(proof.record.transition,claim.transition);
      claims.delete(claim.scopeDigest);
      if(faults.lostResponse==='complete')throw Error('Fixture durable claim completion response lost after proof-checked release');
    },
  };
  const source={
    async readOrigin(call){checkCall(call);await enter('sourceOrigin',call);checkCall(call);return {...origin,sourceIdentity:fixedPins.sourceIdentity,fenced:sourceFenced};},
    async readCommittedEvent(id,call){checkCall(call);await enter('sourceRead',call);checkCall(call);const event=faults.sourceEvent??committed.get(id);if(!event)throw Error('Committed source event unknown');return copy(event);},
    async readCommittedAcceptance(job,call){checkCall(call);await enter('sourceAcceptance',call);checkCall(call);const event=faults.sourceAcceptance??[...committed.values()].find(e=>e.payload.jobId===job&&e.payload.kind==='acceptance');if(!event)throw Error('Committed acceptance unavailable');return copy(event);},
    async listUnacknowledgedJobEvents(job,call){checkCall(call);await enter('sourceList',call);checkCall(call);return [...committed.values()].filter(e=>e.payload.jobId===job&&!acknowledgements.some(a=>a.identity.eventId===e.eventId)).map(e=>e.eventId);},
    async acknowledge(eventId,payloadDigest,seq,hash,receipt,call){
      checkCall(call);validReceipt(receipt);assert.equal(receipt.record.transition,'commit');
      assert.equal(receipt.record.eventId,eventId);assert.equal(receipt.record.payloadDigest,payloadDigest);assert.equal(receipt.record.seq,seq);assert.equal(receipt.record.recordHash,hash);
      assert.equal(committed.get(eventId)?.payloadDigest,payloadDigest);
      // Simulate private SQL execution already sent. Cancellation after entry does
      // not undo the legitimate acknowledgement protected by a durable receipt.
      await enter('ack',call);
      acknowledgements.push({identity:{eventId,payloadDigest,seq,hash},receipt:copy(receipt)});logs.push('source:ack');
    },
  };
  return {
    pins,origin,records,logs,acknowledgements,hooks,afterHooks,faults,source,authority,uncertainty,recordTransport,scopeDigest,
    writerKeys:writer,authorityKeys,
    get mutations(){return mutations;},
    event(options={}){return acceptedEvent(origin,options);},
    adapter(options={}){return createDurablePrivacyJournal({pins,privateKey:writer.privateKey,authorityPublicKey:authorityKeys.publicKey,source,records:recordTransport,authority,uncertainty,...options});},
    commit(event){committed.set(event.eventId,copy(event));logs.push('source:commit');},
    status(job){return acknowledgements.some(a=>committed.get(a.identity.eventId)?.payload.jobId===job)?'pending':null;},
    exportBytes(){return Buffer.from(records.map(canonical).join('\n')+'\n');},
    sealedTrust(){return {...origin,keyId:fixedPins.keyId,publicKey:writer.publicKeyPEM,head:{...current.head,fenced:true}};},
    uncertainCount(){return claims.size;},
    receiptFor(eventId,transition){return copy(operations.get(digest({version:1,scopeDigest,eventId,payloadDigest:committed.get(eventId)?.payloadDigest??records.find(r=>r.event.eventId===eventId)?.event.payloadDigest,transition}))?.receipt);},
    entered(phase){if(!entered.has(phase))entered.set(phase,gate());return entered.get(phase).promise;},
    fence(){sourceFenced=true;current={...current,generation:current.generation+1,mode:'recovery'};},
    authorityFenceOnly(mode='recovery'){current={...current,head:{...current.head,fenced:mode==='sealed'},generation:current.generation+1,mode};},
    setCurrent(changes){current={...current,...copy(changes),head:{...current.head,...copy(changes.head??{})}};},
  };
}
