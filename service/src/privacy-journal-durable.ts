import {createHash,createPublicKey,randomBytes,sign,verify,type KeyObject} from 'node:crypto';
import {z} from 'zod';
import {journalCanonical,journalHash,validatePrivacyRestoreEvents,type PrivacyJournalEvent} from './privacy-journal.js';
import {MAX_JOURNAL_BYTES as MAX_BYTES,MAX_JOURNAL_RECORDS as MAX_RECORDS} from './privacy-journal-limits.js';
import {ServiceError} from './errors.js';
import {JournalWriterBusy} from './privacy-journal-durable-contract.js';
import type {
 AdmittedHead,AdmissionReceipt,AuthorityCall,JournalCapacity,
 DurableJournalPins,DurablePrivacyJournalConfiguration,DurablePrivacyJournalPort,
 JournalCall,JournalTransition,RecordIdentity,UncertaintyClaim,WorkerJournalKind,
} from './privacy-journal-durable-contract.js';
export type * from './privacy-journal-durable-contract.js';

const ZERO='0'.repeat(64);
const hash=z.string().regex(/^[0-9a-f]{64}$/);
const uuid=z.string().regex(/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/);
const identifier=z.string().min(1).max(300).regex(/^[^\x00-\x1f\x7f]+$/);
const safe=z.number().int().min(0).max(Number.MAX_SAFE_INTEGER);
const signature=z.string().regex(/^[A-Za-z0-9_-]{86}$/);
export const durableJournalPinsSchema=z.object({lineage:uuid,schemaDigest:hash,configurationId:identifier.max(100),keyId:identifier.max(100),publicKeyFingerprint:hash,sourceIdentity:identifier,recordStoreIdentity:identifier,recordNamespace:identifier,checkpointAuthority:identifier,deploymentPrincipal:identifier,authorityKeyId:identifier.max(100),authorityPublicKeyFingerprint:hash}).strict();
const payloadSchema=z.object({version:z.literal(1),eventId:uuid,lineage:uuid,schemaDigest:hash,configurationId:identifier.max(100),jobId:uuid,kind:z.enum(['acceptance','target_erased','source_completed','source_pending']),data:z.record(z.string(),z.unknown())}).strict();
const eventSchema=z.object({eventId:uuid,payloadDigest:hash,payload:payloadSchema}).strict();
const headSchema=z.object({version:z.literal(1),lineage:uuid,schemaDigest:hash,configurationId:identifier.max(100),seq:safe.max(MAX_RECORDS),hash,fenced:z.boolean()}).strict();
export const admittedSchema=z.object({head:headSchema,generation:safe.min(1),authorityRevision:safe,mode:z.enum(['active','pending','blocked','recovery','sealed']),pendingOperation:hash.nullable(),totalBytes:safe.max(MAX_BYTES)}).strict();
export const journalCapacitySchema=z.object({mode:admittedSchema.shape.mode,uncertain:z.boolean(),
 usedRecords:safe.max(MAX_RECORDS),reservedRecords:safe.max(MAX_RECORDS),usedBytes:safe.max(MAX_BYTES),reservedBytes:safe.max(MAX_BYTES)}).strict();
export const identitySchema=z.object({seq:safe.min(1).max(MAX_RECORDS),previousHash:hash,recordHash:hash,byteLength:safe.min(1).max(MAX_BYTES),eventId:uuid,payloadDigest:hash,jobId:uuid,transition:z.enum(['intent','commit','rollback'])}).strict();
export const storedSchema=z.object({objectKey:identifier,immutableVersion:identifier,recordHash:hash,byteLength:safe.min(1).max(MAX_BYTES)}).strict();
export const workerKindSchema=z.enum(['target_erased','source_pending','source_completed']);
export const workerKindsSchema=z.array(workerKindSchema).min(1).max(3).refine(kinds=>new Set(kinds).size===kinds.length);
export const ticketSchema=z.object({operationId:hash,generation:safe.min(1),expected:admittedSchema,record:identitySchema,objectKey:identifier,authorityExpiresAtUnixMs:safe.min(1),workerKind:workerKindSchema.optional()}).strict();
export const receiptSchema=z.object({version:z.literal(1),domain:z.literal('ritc-privacy-journal-admission-v1'),scopeDigest:hash,authorityKeyId:identifier.max(100),operationId:hash,admitted:admittedSchema,record:identitySchema,stored:storedSchema,authoritySignature:signature}).strict();
export const inspectionSchema=z.discriminatedUnion('state',[
 z.object({state:z.literal('absent'),operationId:hash}).strict(),
 z.object({state:z.enum(['pending','blocked']),operationId:hash,ticket:ticketSchema}).strict(),
 z.object({state:z.literal('admitted'),operationId:hash,receipt:receiptSchema}).strict(),
]);
export const recordSchema=z.object({version:z.literal(1),keyId:identifier.max(100),seq:safe.min(1).max(MAX_RECORDS),previousHash:hash,kind:z.enum(['intent','commit','rollback']),event:eventSchema,signature}).strict();
const originSchema=z.object({lineage:uuid,schemaDigest:hash,configurationId:identifier.max(100),sourceIdentity:identifier,fenced:z.boolean()}).strict();
const claimSchema=z.object({scopeDigest:hash,eventId:uuid,transition:z.enum(['intent','commit']),claimId:identifier}).strict();
class JournalCapacityUnavailable extends ServiceError {
 constructor(){super(503,'deletion_unavailable','Account deletion is temporarily unavailable. Try again later.');}
}

/** SHA-256 of the exact Ed25519 public SPKI DER, independent of PEM formatting. */
export function durableJournalPublicKeyFingerprint(key:KeyObject|string):string{
 const publicKey=typeof key==='string'?pinnedPublicKey(key):key.type==='public'?key:createPublicKey(key);
 if(publicKey.asymmetricKeyType!=='ed25519')throw Error('Pinned Ed25519 public key required');
 return createHash('sha256').update(publicKey.export({format:'der',type:'spki'})).digest('hex');
}
function pinnedPublicKey(input:KeyObject|string):KeyObject{
 // createPublicKey also accepts private PEM and silently derives its public key.
 // Independent witness custody requires this capability to contain PUBLIC SPKI.
 if(typeof input==='string'){
  if(!/^-----BEGIN PUBLIC KEY-----\r?\n(?:[A-Za-z0-9+/=]+\r?\n)+-----END PUBLIC KEY-----\r?\n?$/.test(input))throw Error('Public SPKI PEM required; authority private material is forbidden');
  return createPublicKey(input);
 }
 if(input.type!=='public')throw Error('Public authority key required');return input;
}
export function durableJournalScopeDigest(pins:DurableJournalPins):string{return journalHash({version:1,...durableJournalPinsSchema.parse(pins)});}
export function durableJournalOperationId(scopeDigest:string,eventId:string,payloadDigest:string,transition:JournalTransition):string{
 hash.parse(scopeDigest);uuid.parse(eventId);hash.parse(payloadDigest);
 return journalHash({version:1,scopeDigest,eventId,payloadDigest,transition:z.enum(['intent','commit','rollback']).parse(transition)});
}
function equal(a:unknown,b:unknown,message:string):void{if(journalCanonical(a)!==journalCanonical(b))throw Error(message);}
function immutable<T>(value:T):T{
 if(value&&typeof value==='object'){for(const item of Object.values(value))immutable(item);Object.freeze(value);}
 return value;
}
function copied<T>(value:T):T{return structuredClone(value);}
function assertCall(call:JournalCall,now:()=>number):void{
 if(!call||typeof call.attemptId!=='string'||!call.attemptId.length||call.attemptId.length>100||!Number.isSafeInteger(call.deadlineUnixMs)||!(call.signal instanceof AbortSignal))throw Error('Call-owned journal deadline and AbortSignal required');
 call.signal.throwIfAborted();if(now()>=call.deadlineUnixMs)throw Error('Journal deadline exceeded');
}
/** Abort the actual injected I/O and stop our continuation even if it ignores abort. */
async function withOwnedCall<T>(input:JournalCall,now:()=>number,work:(call:JournalCall)=>Promise<T>):Promise<T>{
 assertCall(input,now);
 const controller=new AbortController();
 const abort=()=>controller.abort(input.signal.reason??Error('Journal call aborted'));
 input.signal.addEventListener('abort',abort,{once:true});
 const timer=setTimeout(()=>controller.abort(Error('Journal deadline exceeded')),Math.min(2_147_483_647,Math.max(0,input.deadlineUnixMs-now())));
 const call=Object.freeze({attemptId:input.attemptId,deadlineUnixMs:input.deadlineUnixMs,signal:controller.signal});
 let onAbort:(()=>void)|undefined;
 const cancelled=new Promise<never>((_,reject)=>{onAbort=()=>reject(controller.signal.reason??Error('Journal call aborted'));controller.signal.addEventListener('abort',onAbort,{once:true});});
 try{assertCall(call,now);return await Promise.race([work(call),cancelled]);}
 finally{clearTimeout(timer);input.signal.removeEventListener('abort',abort);if(onAbort)controller.signal.removeEventListener('abort',onAbort);}
}
function verifySignature(body:Record<string,unknown>,encoded:string,key:KeyObject):void{
 const bytes=Buffer.from(encoded,'base64url');
 if(bytes.toString('base64url')!==encoded||bytes.length!==64||!verify(null,Buffer.from(journalCanonical(body)),key,bytes))throw Error('Independent authority signature rejected');
}
function verifyHeadPins(head:AdmittedHead,pins:DurableJournalPins):void{
 if(head.head.lineage!==pins.lineage||head.head.schemaDigest!==pins.schemaDigest||head.head.configurationId!==pins.configurationId)throw Error('Independent head origin conflict');
 if(head.head.seq===0&&(head.head.hash!==ZERO||head.totalBytes!==0)||head.head.seq>0&&head.totalBytes===0)throw Error('Independent head capacity conflict');
}
function active(head:AdmittedHead):void{
 if(head.mode!=='active'||head.pendingOperation!==null||head.head.fenced)throw Error('Independent origin is not active');
}
function objectKey(scopeDigest:string,record:RecordIdentity):string{return `${scopeDigest}/${record.seq}/${record.recordHash}`;}

/** Strict, independently authenticated immutable proof; never accepts a provider Boolean. */
export function verifyDurableAdmissionReceipt(input:unknown,pinsInput:DurableJournalPins,authorityPublicKey:KeyObject|string):AdmissionReceipt{
 const pins=durableJournalPinsSchema.parse(pinsInput),scopeDigest=durableJournalScopeDigest(pins);
 const key=pinnedPublicKey(authorityPublicKey);
 if(key.type!=='public'||durableJournalPublicKeyFingerprint(key)!==pins.authorityPublicKeyFingerprint||pins.authorityPublicKeyFingerprint===pins.publicKeyFingerprint)throw Error('Independent authority key fingerprint conflict');
 const receipt=receiptSchema.parse(input),{authoritySignature,...body}=receipt;
 if(receipt.scopeDigest!==scopeDigest||receipt.authorityKeyId!==pins.authorityKeyId)throw Error('Independent receipt scope conflict');
 verifySignature(body,authoritySignature,key);verifyHeadPins(receipt.admitted,pins);active(receipt.admitted);
 if(receipt.operationId!==durableJournalOperationId(scopeDigest,receipt.record.eventId,receipt.record.payloadDigest,receipt.record.transition)||receipt.admitted.head.seq!==receipt.record.seq||receipt.admitted.head.hash!==receipt.record.recordHash||receipt.record.recordHash!==receipt.stored.recordHash||receipt.record.byteLength!==receipt.stored.byteLength||receipt.stored.objectKey!==objectKey(scopeDigest,receipt.record)||receipt.admitted.totalBytes<receipt.record.byteLength)throw Error('Independent receipt record or storage conflict');
 return immutable(receipt);
}

/**
 * Private in-process signer. Only wire this port to the trusted actual SQL-result
 * callback. It is not an arbitrary-event network signing or import endpoint.
 * There is deliberately no environment composition or provider implementation.
 */
export function createDurablePrivacyJournal(configuration:DurablePrivacyJournalConfiguration):{readonly port:DurablePrivacyJournalPort;isPoisoned():boolean;capacity(call:JournalCall):Promise<JournalCapacity>}{
 const pins=immutable(durableJournalPinsSchema.parse(copied(configuration.pins))),scopeDigest=durableJournalScopeDigest(pins);
 const privateKey=configuration.privateKey;
 if(privateKey.type!=='private'||privateKey.asymmetricKeyType!=='ed25519'||durableJournalPublicKeyFingerprint(privateKey)!==pins.publicKeyFingerprint)throw Error('Pinned Ed25519 private key required');
 const publicKey=createPublicKey(privateKey),authorityPublicKey=pinnedPublicKey(configuration.authorityPublicKey);
 if(authorityPublicKey.type!=='public'||authorityPublicKey.asymmetricKeyType!=='ed25519'||durableJournalPublicKeyFingerprint(authorityPublicKey)!==pins.authorityPublicKeyFingerprint)throw Error('Pinned independent authority key required');
 if(durableJournalPublicKeyFingerprint(authorityPublicKey)===pins.publicKeyFingerprint)throw Error('Journal signer and authority key must be independent');
 const now=configuration.clock?configuration.clock.now.bind(configuration.clock):Date.now;
 // Capture method identities now. Each trusted capability implementation must
 // independently pin its actual endpoint, credentials and registered resource.
 const source={readOrigin:configuration.source.readOrigin.bind(configuration.source),readCommittedEvent:configuration.source.readCommittedEvent.bind(configuration.source),readCommittedAcceptance:configuration.source.readCommittedAcceptance.bind(configuration.source),listUnacknowledgedJobEvents:configuration.source.listUnacknowledgedJobEvents.bind(configuration.source),acknowledge:configuration.source.acknowledge.bind(configuration.source)};
 const records={putExact:configuration.records.putExact.bind(configuration.records),readExact:configuration.records.readExact.bind(configuration.records)};
 const authority={readCurrent:configuration.authority.readCurrent.bind(configuration.authority),inspectOperation:configuration.authority.inspectOperation.bind(configuration.authority),reserve:configuration.authority.reserve.bind(configuration.authority),publish:configuration.authority.publish.bind(configuration.authority),reserveWorkerCapacity:configuration.authority.reserveWorkerCapacity?.bind(configuration.authority),readCapacity:configuration.authority.readCapacity?.bind(configuration.authority)};
 const uncertainty={begin:configuration.uncertainty.begin.bind(configuration.uncertainty),beginIntent:configuration.uncertainty.beginIntent?.bind(configuration.uncertainty),complete:configuration.uncertainty.complete.bind(configuration.uncertainty)};
 let poisoned=false;
 async function step<T>(call:JournalCall,work:()=>Promise<T>):Promise<T>{
  assertCall(call,now);const value=await work();assertCall(call,now);return value;
 }
 function authorityCall(call:JournalCall):AuthorityCall{return Object.freeze({...call,requestNonce:randomBytes(32).toString('hex')});}
 function envelope<T>(input:unknown,schema:z.ZodType<T>,call:AuthorityCall):T{
  const parsed=z.object({version:z.literal(1),domain:z.literal('ritc-privacy-journal-authority-v1'),scopeDigest:hash,authorityKeyId:identifier.max(100),requestNonce:hash,value:schema,authoritySignature:signature}).strict().parse(input);
  if(parsed.scopeDigest!==scopeDigest||parsed.authorityKeyId!==pins.authorityKeyId||parsed.requestNonce!==call.requestNonce)throw Error('Independent observation scope or freshness conflict');
  const {authoritySignature,...body}=parsed;verifySignature(body,authoritySignature,authorityPublicKey);return immutable(parsed.value);
 }
 async function current(call:JournalCall,readOnly=false):Promise<AdmittedHead>{
  const request=authorityCall(call),value=envelope(await step(call,()=>authority.readCurrent(request)),admittedSchema,request);
  verifyHeadPins(value,pins);
  if(readOnly&&!value.head.fenced&&value.mode==='pending'&&value.pendingOperation)throw new JournalWriterBusy();
  active(value);return value;
 }
 function event(input:unknown):PrivacyJournalEvent{
  const value=eventSchema.parse(copied(input));
  if(value.eventId!==value.payload.eventId||value.payloadDigest!==journalHash(value.payload)||value.payload.lineage!==pins.lineage||value.payload.schemaDigest!==pins.schemaDigest||value.payload.configurationId!==pins.configurationId)throw Error('Fixed source event pins or digest conflict');
  return immutable(value);
 }
 async function origin(call:JournalCall):Promise<void>{
  const value=originSchema.parse(await step(call,()=>source.readOrigin(call)));
  if(value.lineage!==pins.lineage||value.schemaDigest!==pins.schemaDigest||value.configurationId!==pins.configurationId||value.sourceIdentity!==pins.sourceIdentity||value.fenced)throw Error('Fixed source origin unavailable or fenced');
 }
 async function content(value:PrivacyJournalEvent,call:JournalCall):Promise<void>{
  if(value.payload.kind==='acceptance'){validatePrivacyRestoreEvents([value]);return;}
  const acceptance=event(await step(call,()=>source.readCommittedAcceptance(value.payload.jobId,call)));
  if(acceptance.payload.kind!=='acceptance'||acceptance.payload.jobId!==value.payload.jobId)throw Error('Requested committed acceptance binding conflict');
  validatePrivacyRestoreEvents([acceptance,value]);
  // A self-consistent source acceptance must also be the original admitted
  // authorization. Reject changed targets/content before creating an object.
  if(!await find(acceptance,'commit',call))throw Error('Progress lacks its original durable accepted authorization');
 }
 function receipt(input:unknown,expected?:RecordIdentity):AdmissionReceipt{
  const value=verifyDurableAdmissionReceipt(input,pins,authorityPublicKey);
  if(expected)equal(value.record,expected,'Independent admitted identity changed');return value;
 }
 async function storedRecord(proof:AdmissionReceipt,value:PrivacyJournalEvent,kind:JournalTransition,call:JournalCall):Promise<void>{
  if(proof.record.eventId!==value.eventId||proof.record.payloadDigest!==value.payloadDigest||proof.record.jobId!==value.payload.jobId||proof.record.transition!==kind)throw Error('Original transition event binding conflict');
  const bytes=Buffer.from(await step(call,()=>records.readExact(proof.stored,call)));
  if(bytes.length!==proof.record.byteLength||bytes.length>MAX_BYTES||bytes.at(-1)!==10)throw Error('Stored canonical record length conflict');
  const line=new TextDecoder('utf-8',{fatal:true}).decode(bytes.subarray(0,-1));
  const record=recordSchema.parse(JSON.parse(line));
  if(journalCanonical(record)!==line||journalHash(record)!==proof.record.recordHash||record.seq!==proof.record.seq||record.previousHash!==proof.record.previousHash||record.kind!==kind||record.keyId!==pins.keyId)throw Error('Stored canonical record identity conflict');
  equal(record.event,value,'Stored immutable event changed');
  const {signature:encoded,...body}=record;verifySignature(body,encoded,publicKey);
 }
 async function find(value:PrivacyJournalEvent,kind:JournalTransition,call:JournalCall):Promise<AdmissionReceipt|undefined>{
  const operationId=durableJournalOperationId(scopeDigest,value.eventId,value.payloadDigest,kind),request=authorityCall(call);
  const inspected=envelope(await step(call,()=>authority.inspectOperation(operationId,request)),inspectionSchema,request);
  if(inspected.operationId!==operationId)throw Error('Independent operation lookup conflict');
  if(inspected.state==='absent')return;
  if(inspected.state!=='admitted')throw Error('Uncertain operation requires explicit fenced recovery');
  const proof=receipt(inspected.receipt);
  if(proof.operationId!==operationId)throw Error('Independent original receipt conflict');
  await storedRecord(proof,value,kind,call);return proof;
 }
 async function append(value:PrivacyJournalEvent,kind:'intent'|'commit',call:JournalCall):Promise<AdmissionReceipt>{
  await content(value,call);
  const prior=await find(value,kind,call);if(prior)return prior;
  const head=await current(call);
  const unsigned={version:1 as const,keyId:pins.keyId,seq:head.head.seq+1,previousHash:head.head.hash,kind,event:value};
  const record={...unsigned,signature:sign(null,Buffer.from(journalCanonical(unsigned)),privateKey).toString('base64url')};
  const bytes=Buffer.from(journalCanonical(record)+'\n');
  if(head.head.seq>=MAX_RECORDS||head.totalBytes+bytes.length>MAX_BYTES)throw Error('Durable journal capacity reached');
  const identity:RecordIdentity=immutable({seq:record.seq,previousHash:record.previousHash,recordHash:journalHash(record),byteLength:bytes.length,eventId:value.eventId,payloadDigest:value.payloadDigest,jobId:value.payload.jobId,transition:kind});
  const workerKind=value.payload.kind==='acceptance'?undefined:value.payload.kind;
  const request=authorityCall(call),ticket=envelope(await step(call,()=>authority.reserve(head,identity,request,workerKind)),ticketSchema,request);
  equal(ticket.expected,head,'Reservation changed expected independent head');equal(ticket.record,identity,'Reservation changed record identity');
  if(ticket.operationId!==durableJournalOperationId(scopeDigest,value.eventId,value.payloadDigest,kind)||ticket.generation!==head.generation||ticket.objectKey!==objectKey(scopeDigest,identity)||ticket.authorityExpiresAtUnixMs>=call.deadlineUnixMs||ticket.authorityExpiresAtUnixMs<=now()||authority.reserveWorkerCapacity&&ticket.workerKind!==workerKind)throw Error('Reservation scope, generation or deadline conflict');
  const stored=immutable(storedSchema.parse(await step(call,()=>records.putExact(ticket,Buffer.from(bytes),call))));
  if(stored.objectKey!==ticket.objectKey||stored.recordHash!==identity.recordHash||stored.byteLength!==identity.byteLength)throw Error('Immutable storage result conflict');
  const exact=Buffer.from(await step(call,()=>records.readExact(stored,call)));
  if(!exact.equals(bytes))throw Error('Conditional object create did not preserve exact bytes');
  // Reject stale tickets before starting publication. The authority must repeat
  // generation/mode/head/deadline checks atomically using its own clock.
  assertCall(call,now);if(now()>=ticket.authorityExpiresAtUnixMs)throw Error('Reservation deadline exceeded');
  const proof=receipt(await step(call,()=>authority.publish(ticket,stored,authorityCall(call))),identity);
  if(proof.admitted.generation!==ticket.generation||proof.admitted.authorityRevision<=head.authorityRevision||proof.admitted.totalBytes!==head.totalBytes+bytes.length)throw Error('Publication generation, revision or byte coverage conflict');
  equal(proof.stored,stored,'Publication changed immutable storage version');return proof;
 }
 async function claim(eventId:string,transition:'intent'|'commit',call:JournalCall,intent?:PrivacyJournalEvent):Promise<UncertaintyClaim>{
  const expected=Object.freeze({scopeDigest,eventId,transition});
  const beginIntent=uncertainty.beginIntent;
  const result=intent&&beginIntent?await step(call,()=>beginIntent(expected,Buffer.byteLength(journalCanonical({version:1,keyId:pins.keyId,
   seq:MAX_RECORDS,previousHash:ZERO,kind:'intent',event:intent,signature:'A'.repeat(86)})+'\n'),call)):
   await step(call,()=>uncertainty.begin(expected,call));
  if(result===null&&intent&&beginIntent)throw new JournalCapacityUnavailable();
  const held=immutable(claimSchema.parse(result));
  if(held.scopeDigest!==scopeDigest||held.eventId!==eventId||held.transition!==transition)throw Error('Durable uncertainty claim changed');return held;
 }
 async function complete(held:UncertaintyClaim,proof:AdmissionReceipt,call:JournalCall):Promise<void>{
  receipt(proof);
  if(held.scopeDigest!==proof.scopeDigest||held.eventId!==proof.record.eventId||held.transition!==proof.record.transition)throw Error('Uncertainty completion proof binding conflict');
  await step(call,()=>uncertainty.complete(held,proof,call));
 }
 async function covered(proof:AdmissionReceipt,call:JournalCall,readOnly=false):Promise<void>{
  const head=await current(call,readOnly);
  if(head.generation!==proof.admitted.generation||head.authorityRevision<proof.admitted.authorityRevision||head.head.seq<proof.record.seq||head.head.seq===proof.record.seq&&head.head.hash!==proof.record.recordHash)throw Error('Receipt is not covered by current active independent head');
 }
 async function afterCommit(eventId:string,call:JournalCall,requiredJobId?:string):Promise<void>{
  const held=await claim(eventId,'commit',call);await origin(call);
  const value=event(await step(call,()=>source.readCommittedEvent(eventId,call)));
  if(value.eventId!==eventId||requiredJobId!==undefined&&value.payload.jobId!==requiredJobId)throw Error('Requested committed event binding conflict');
  await content(value,call);
  if(value.payload.kind==='acceptance'&&!await find(value,'intent',call))throw Error('Committed acceptance lacks its original durable intent');
  const proof=await append(value,'commit',call);
  await covered(proof,call);
  // This check is immediately before initiating SQL acknowledgement. Once sent,
  // cancellation cannot undo it; exact durable commit/head make late success safe.
  assertCall(call,now);receipt(proof);
  await step(call,()=>source.acknowledge(eventId,value.payloadDigest,proof.record.seq,proof.record.recordHash,proof,call));
  await complete(held,proof,call);
 }
 async function guarded<T>(call:JournalCall,work:(owned:JournalCall)=>Promise<T>):Promise<T>{
  if(poisoned)throw Error('Durable journal requires explicit fenced reconciliation');
  let started=false;
  try{return await withOwnedCall(call,now,owned=>{started=true;return work(owned);});}catch(error){
   if(started&&!(error instanceof JournalCapacityUnavailable||error instanceof JournalWriterBusy))poisoned=true;
   throw error;
  }
 }
 const port:DurablePrivacyJournalPort=Object.freeze({configurationId:pins.configurationId,
  reserveWorkerCapacity(jobId:string,kinds:readonly WorkerJournalKind[],call:JournalCall):Promise<boolean>{
   const id=uuid.parse(jobId),requested=workerKindsSchema.parse(kinds),reserve=authority.reserveWorkerCapacity;
   if(!reserve)return Promise.reject(Error('Durable worker capacity is unavailable'));
   return guarded(call,async owned=>{
    await origin(owned);
    return z.boolean().parse(await step(owned,()=>reserve(id,requested,owned)));
   });
  },
  beforeCommit(candidate:PrivacyJournalEvent,call:JournalCall):Promise<void>{
   // Snapshot and fully validate before first await: caller mutation cannot change
   // signed bytes while origin/head/storage I/O is pending.
   let value:PrivacyJournalEvent;
   try{value=event(candidate);if(value.payload.kind!=='acceptance')throw Error('Acceptance intent required');validatePrivacyRestoreEvents([value]);}
   catch(error){return Promise.reject(error);}
   return guarded(call,async owned=>{const held=await claim(value.eventId,'intent',owned,value);await origin(owned);const proof=await append(value,'intent',owned);await covered(proof,owned);await complete(held,proof,owned);});
  },
  afterCommit(eventId:string,call:JournalCall):Promise<void>{
   try{uuid.parse(eventId);}catch(error){return Promise.reject(error);}
   return guarded(call,owned=>afterCommit(eventId,owned));
  },
  acknowledgeJob(jobId:string,call:JournalCall):Promise<void>{
   try{uuid.parse(jobId);}catch(error){return Promise.reject(error);}
   return guarded(call,async owned=>{
    // A read-only empty status path requires a genuine committed acceptance.
    // No mutation claim is opened until an individual event needs observation.
    await origin(owned);
    const acceptance=event(await step(owned,()=>source.readCommittedAcceptance(jobId,owned)));
    if(acceptance.payload.kind!=='acceptance'||acceptance.payload.jobId!==jobId)throw Error('Requested job acceptance binding conflict');
    validatePrivacyRestoreEvents([acceptance]);
    const ids=z.array(uuid).max(MAX_RECORDS).parse(await step(owned,()=>source.listUnacknowledgedJobEvents(jobId,owned)));
    if(new Set(ids).size!==ids.length)throw Error('Duplicate unacknowledged source event');
    if(!ids.length){
     const proof=await find(acceptance,'commit',owned);if(!proof)throw Error('Acknowledged job has no durable acceptance');
     await covered(proof,owned,true);
    }
    for(const id of ids)await afterCommit(id,owned,jobId);
   });
  },
 });
 return Object.freeze({port,isPoisoned:()=>poisoned,async capacity(call:JournalCall){
  const read=authority.readCapacity;
  if(!read)throw Error('Signed journal capacity is unavailable');
  return withOwnedCall(call,now,async owned=>{
   const request=authorityCall(owned);
   return envelope(await step(owned,()=>read(request)),journalCapacitySchema,request);
  });
 }});
}
