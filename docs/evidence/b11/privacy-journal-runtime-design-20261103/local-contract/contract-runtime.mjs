// NONPRODUCTION CONTRACT REHEARSAL. No HTTP, SQL driver, SDK or provider calls.
import {createHash, createPublicKey, sign, verify} from 'node:crypto';
import {readFile} from 'node:fs/promises';
import {pathToFileURL} from 'node:url';

export const ACTUAL_VERIFIER_PINS=Object.freeze({
 source:{path:'/Users/palatis/Room in the Cart/service/src/privacy-journal.ts',sha256:'5bc1944554aa6057805b087bd77adad128aff795458d8a17eb30ddda213f8c1c'},
 module:{path:'/Users/palatis/Room in the Cart/service/dist/privacy-journal.js',sha256:'423c823cc5d1546390084727bf55d5febd7f7eaddb6ad2bb05acf548d9553937'},
 zod:{path:'/Users/palatis/Room in the Cart/service/node_modules/zod/package.json',sha256:'c2d190d9ee4e0bdb60332aaa2130a6a98d65ddb903fe1d29248b15de57832c45'},
});
for(const pin of Object.values(ACTUAL_VERIFIER_PINS)){
 if(createHash('sha256').update(await readFile(pin.path)).digest('hex')!==pin.sha256)throw Error('Actual verifier pin changed: '+pin.path);
}
const imported=await import(pathToFileURL(ACTUAL_VERIFIER_PINS.module.path));
export const actual=Object.freeze({canonical:imported.journalCanonical,hash:imported.journalHash,verify:imported.verifyPrivacyJournal,validateEvents:imported.validatePrivacyRestoreEvents});
export const copy=value=>structuredClone(value);
export const ZERO='0'.repeat(64);
export const operationId=(pins,eventId,digest,kind)=>actual.hash({lineage:pins.lineage,configurationId:pins.configurationId,eventId,payloadDigest:digest,kind});
export function checkCall(call,clock){
 if(!call||typeof call.attemptId!=='string'||!Number.isSafeInteger(call.deadlineUnixMs))throw Error('Call context required');
 call.signal.throwIfAborted();if(clock.now()>=call.deadlineUnixMs)throw Error('Call deadline exceeded');
}
export function assertOrigin(origin,pins){
 if(origin.lineage!==pins.lineage||origin.schemaDigest!==pins.schemaDigest||origin.configurationId!==pins.configurationId||origin.sourceIdentity!==pins.sourceIdentity)throw Error('Fixed source origin mismatch');
}
function verifyAuthority(value,publicKey){
 const {authorityReceipt,...body}=value;
 if(typeof authorityReceipt!=='string'||!verify(null,Buffer.from(actual.canonical(body)),publicKey,Buffer.from(authorityReceipt,'base64url')))throw Error('Independent authority receipt rejected');
 return body;
}
export function verifyHead(value,pins,authorityPublicKey){
 const body=verifyAuthority(value,authorityPublicKey),h=body.head;
 if(h.lineage!==pins.lineage||h.schemaDigest!==pins.schemaDigest||h.configurationId!==pins.configurationId||!Number.isSafeInteger(h.seq)||h.seq<0||!/^[0-9a-f]{64}$/.test(h.hash))throw Error('Independent head pins rejected');
 return body;
}
export function verifyReceipt(receipt,pins,authorityPublicKey,expected){
 const body=verifyAuthority(receipt,authorityPublicKey);
 verifyHead(body.admitted,pins,authorityPublicKey);
 if(body.record.recordHash!==body.stored.recordHash||body.record.byteLength!==body.stored.byteLength||body.record.seq!==body.admitted.head.seq||body.record.recordHash!==body.admitted.head.hash)throw Error('Independent receipt record mismatch');
 for(const [field,value]of Object.entries(expected??{}))if(body.record[field]!==value)throw Error('Independent receipt event mismatch');
 if(body.operationId!==operationId(pins,body.record.eventId,body.record.payloadDigest,body.record.transition))throw Error('Independent operation identity mismatch');
 return receipt;
}

/** Private trusted constructor. Only the returned three-method port handles requests.
 * beforeCommit is called solely with this process's actual SQL-result candidate in
 * production design. The test source is explicitly NOT an authorization proof.
 */
export function createContractRuntime(configuration){return createTrustedRuntime(configuration,false);}
function createTrustedRuntime({pins,privateKey,authorityPublicKey,source,records,authority,clock},recoveryMode){
 const publicKey=createPublicKey(privateKey);if(publicKey.asymmetricKeyType!=='ed25519')throw Error('Ed25519 required');
 let poisoned=false;
 async function origin(call,recovery=recoveryMode){
  checkCall(call,clock);const value=await source.readOrigin(call);assertOrigin(value,pins);
  if(Boolean(value.fenced)!==recovery)throw Error(recovery?'Recovery needs fenced source':'Source fenced');return value;
 }
 function eventPins(event){
  if(event.eventId!==event.payload.eventId||actual.hash(event.payload)!==event.payloadDigest||event.payload.lineage!==pins.lineage||event.payload.schemaDigest!==pins.schemaDigest||event.payload.configurationId!==pins.configurationId)throw Error('Source event pins/digest rejected');
 }
 async function content(event,call){
  if(event.payload.kind==='acceptance')actual.validateEvents([event]);
  else{
   const acceptance=await source.readCommittedAcceptance(event.payload.jobId,call);eventPins(acceptance);
   actual.validateEvents([acceptance,event]);
  }
 }
 async function append(kind,event,call,recoveryAuthority){
  checkCall(call,clock);eventPins(event);await content(event,call);checkCall(call,clock);
  const api=recoveryAuthority??authority;
  const prior=await api.findTransition(event.eventId,event.payloadDigest,kind,call);
  if(prior){verifyReceipt(prior,pins,authorityPublicKey,{eventId:event.eventId,payloadDigest:event.payloadDigest,transition:kind});checkCall(call,clock);return prior;}
  const head=await api.readCurrent(call);verifyHead(head,pins,authorityPublicKey);checkCall(call,clock);
  const unsigned={version:1,keyId:pins.keyId,seq:head.head.seq+1,previousHash:head.head.hash,kind,event:copy(event)};
  const record={...unsigned,signature:sign(null,Buffer.from(actual.canonical(unsigned)),privateKey).toString('base64url')};
  const bytes=Buffer.from(actual.canonical(record)+'\n');
  const identity={seq:record.seq,previousHash:record.previousHash,recordHash:actual.hash(record),byteLength:bytes.length,eventId:event.eventId,payloadDigest:event.payloadDigest,jobId:event.payload.jobId,transition:kind};
  const ticket=await api.reserve(head,identity,call);checkCall(call,clock);
  const stored=await records.putExact(ticket,bytes,call);checkCall(call,clock);
  const receipt=await api.publish(ticket,stored,call);checkCall(call,clock);
  return verifyReceipt(receipt,pins,authorityPublicKey,identity);
 }
 async function afterCommit(eventId,call,recoveryAuthority){
  const event=await source.readCommittedEvent(eventId,call);eventPins(event);checkCall(call,clock);
  const api=recoveryAuthority??authority;
  if(event.payload.kind==='acceptance'){
   const intent=await api.findTransition(event.eventId,event.payloadDigest,'intent',call);
   if(!intent)throw Error('Committed acceptance lacks original durable intent');
   verifyReceipt(intent,pins,authorityPublicKey,{eventId:eventId,payloadDigest:event.payloadDigest,transition:'intent'});
  }
  const receipt=await append('commit',event,call,recoveryAuthority);checkCall(call,clock);
  await source.acknowledge(eventId,event.payloadDigest,receipt.record.seq,receipt.record.recordHash,receipt,call);
  // A SQL acknowledgement already sent may have committed when this check fails.
  checkCall(call,clock);
 }
 async function guarded(call,work){
  if(poisoned)throw Error('Runtime poisoned; recreate only with authoritative state/recovery');
  try{return await work();}catch(error){poisoned=true;throw error;}
 }
 const port=Object.freeze({configurationId:pins.configurationId,
  beforeCommit:(event,call)=>guarded(call,async()=>{await origin(call);if(event.payload.kind!=='acceptance')throw Error('Acceptance intent required');await append('intent',event,call);}),
  afterCommit:(eventId,call)=>guarded(call,async()=>{await origin(call);await afterCommit(eventId,call);}),
  acknowledgeJob:(jobId,call)=>guarded(call,async()=>{await origin(call);for(const eventId of await source.listUnacknowledgedJobEvents(jobId,call))await afterCommit(eventId,call);}),
 });
 return Object.freeze({port,isPoisoned:()=>poisoned});
}

/** Operator-only constructor, separate from the ordinary port. No supplied events. */
export function createContractRecovery({pins,privateKey,authorityPublicKey,source,records,authority,recoveryAuthority,clock}){
 return Object.freeze({async fenceAndSeal(call){
  checkCall(call,clock);await recoveryAuthority.beginFence(call);
  await source.fence(call);const sourceOrigin=await source.readOrigin(call);assertOrigin(sourceOrigin,pins);
  if(!sourceOrigin.fenced)throw Error('Source fence not committed');
  // Internal recovery mode retains the genuine fenced source and separately held
  // recovery authority. No false source-origin view or ordinary-port override.
  const runtime=createTrustedRuntime({pins,privateKey,authorityPublicKey,source,records,authority:recoveryAuthority,clock},true);
  for(const eventId of await source.listUnacknowledgedEvents(call))await runtime.port.afterCommit(eventId,call);
  for(const event of await recoveryAuthority.unresolvedIntents(call)){
   if(await source.hasCommittedEvent(event.eventId,call))throw Error('Committed intent reconciliation pending');
   const head=await recoveryAuthority.readCurrent(call);verifyHead(head,pins,authorityPublicKey);
   const unsigned={version:1,keyId:pins.keyId,seq:head.head.seq+1,previousHash:head.head.hash,kind:'rollback',event};
   const record={...unsigned,signature:sign(null,Buffer.from(actual.canonical(unsigned)),privateKey).toString('base64url')};
   const bytes=Buffer.from(actual.canonical(record)+'\n');
   const id={seq:record.seq,previousHash:record.previousHash,recordHash:actual.hash(record),byteLength:bytes.length,eventId:event.eventId,payloadDigest:event.payloadDigest,jobId:event.payload.jobId,transition:'rollback'};
   const ticket=await recoveryAuthority.reserve(head,id,call),stored=await records.putExact(ticket,bytes,call);
   await recoveryAuthority.publish(ticket,stored,call);
  }
  const sealed=await recoveryAuthority.seal(await source.readOrigin(call),call);verifyHead(sealed,pins,authorityPublicKey);
  return sealed;
 }});
}
