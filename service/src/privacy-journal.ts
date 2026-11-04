import {createHash,createPrivateKey,createPublicKey,sign,verify,type KeyObject} from 'node:crypto';
import {constants} from 'node:fs';
import {open,readFile,rename,mkdir,stat,unlink} from 'node:fs/promises';
import {dirname,resolve} from 'node:path';
import {z} from 'zod';
import type {Database} from './database.js';
import type {JournalCall} from './privacy-journal-durable-contract.js';

const uuid=z.string().regex(/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/),hash=z.string().regex(/^[0-9a-f]{64}$/);
export function journalCanonical(value:unknown):string{
 if(value===null||typeof value!=='object')return JSON.stringify(value);
 if(Array.isArray(value))return '['+value.map(journalCanonical).join(',')+']';
 return '{'+Object.keys(value).sort().map(key=>JSON.stringify(key)+':'+journalCanonical((value as Record<string,unknown>)[key])).join(',')+'}';
}
export const journalHash=(value:unknown)=>createHash('sha256').update(journalCanonical(value)).digest('hex');
const payloadSchema=z.object({version:z.literal(1),eventId:uuid,lineage:uuid,schemaDigest:hash,configurationId:z.string().min(1).max(100),jobId:uuid,kind:z.enum(['acceptance','target_erased','source_completed','source_pending']),data:z.record(z.string(),z.unknown())}).strict();
const eventSchema=z.object({eventId:uuid,payloadDigest:hash,payload:payloadSchema}).strict();
export type PrivacyJournalEvent=z.infer<typeof eventSchema>;
export interface PrivacyJournalPort{
 readonly configurationId:string;
 beforeCommit(candidate:PrivacyJournalEvent,call?:JournalCall):Promise<void>;
 afterCommit(eventId:string,call?:JournalCall):Promise<void>;
 acknowledgeJob(jobId:string,call?:JournalCall):Promise<void>;
}
const headSchema=z.object({version:z.literal(1),lineage:uuid,schemaDigest:hash,configurationId:z.string().min(1).max(100),seq:z.number().int().nonnegative(),hash, fenced:z.boolean()}).strict();
export type PrivacyJournalHead=z.infer<typeof headSchema>;
const recordSchema=z.object({version:z.literal(1),keyId:z.string().min(1).max(100),seq:z.number().int().positive(),previousHash:hash,kind:z.enum(['intent','commit','rollback']),event:eventSchema,signature:z.string().regex(/^[A-Za-z0-9_-]{86}$/)}).strict();
type JournalRecord=z.infer<typeof recordSchema>;
export interface JournalTrust {lineage:string;schemaDigest:string;configurationId:string;keyId:string;publicKey:string;head:PrivacyJournalHead}
const zero='0'.repeat(64),MAX_BYTES=32*1024*1024,MAX_RECORDS=10000;
function parseCanonical(text:string){const value:unknown=JSON.parse(text);if(journalCanonical(value)!==text)throw Error('Noncanonical or duplicate-key journal JSON');return value;}
function validateEvent(input:unknown):PrivacyJournalEvent{
 const e=eventSchema.parse(input);if(e.eventId!==e.payload.eventId||e.payloadDigest!==journalHash(e.payload))throw Error('Journal event digest conflict');
 return e;
}
interface JournalPins {lineage:string;schemaDigest:string;configurationId:string;keyId:string;publicKey:string}
function inspectJournal(bytes:Buffer,pins:JournalPins){
 if(bytes.length>MAX_BYTES||bytes.length&&bytes[bytes.length-1]!==10)throw Error('Truncated or oversized journal');
 const decoded=new TextDecoder('utf-8',{fatal:true}).decode(bytes);
 if(!Buffer.from(decoded,'utf8').equals(bytes))throw Error('Journal UTF-8 changed');
 const lines=bytes.length?decoded.slice(0,-1).split('\n'):[];if(lines.length>MAX_RECORDS)throw Error('Too many journal records');
 const key=createPublicKey(pins.publicKey);if(key.asymmetricKeyType!=='ed25519')throw Error('Pinned Ed25519 key required');
 let seq=0,previousHash=zero;const states=new Map<string,{state:'intent'|'commit'|'rollback';event:PrivacyJournalEvent}>(),records:JournalRecord[]=[];
 const committed=new Map<string,PrivacyJournalEvent>(),acceptances=new Map<string,PrivacyJournalEvent>();
 for(const line of lines){
  const record=recordSchema.parse(parseCanonical(line)),event=validateEvent(record.event);
  if(record.seq!==++seq||record.previousHash!==previousHash||record.keyId!==pins.keyId||event.payload.lineage!==pins.lineage||event.payload.schemaDigest!==pins.schemaDigest||event.payload.configurationId!==pins.configurationId)throw Error('Journal chain or trust conflict');
  const{signature,...unsigned}=record;
  if(Buffer.from(signature,'base64url').toString('base64url')!==signature||!verify(null,Buffer.from(journalCanonical(unsigned)),key,Buffer.from(signature,'base64url')))throw Error('Journal signature rejected');
  previousHash=journalHash(record);records.push(record);const id=event.eventId,prior=states.get(id);
  if(record.kind==='intent'){
   if(prior)throw Error('Duplicate journal intent');states.set(id,{state:'intent',event});
  }else if(record.kind==='commit'){
   if(prior&&prior.state!=='intent')throw Error('Journal event already resolved');
   if(event.payload.kind==='acceptance'&&(!prior||prior.event.payloadDigest!==event.payloadDigest))throw Error('Acceptance has no matching durable intent');
   if(prior&&prior.event.payloadDigest!==event.payloadDigest)throw Error('Intent digest changed');
   if(event.payload.kind==='acceptance'){if(acceptances.has(event.payload.jobId))throw Error('Duplicate accepted job');acceptances.set(event.payload.jobId,event);}
   else if(!acceptances.has(event.payload.jobId))throw Error('Progress has no preceding accepted authorization');
   states.set(id,{state:'commit',event});committed.set(id,event);
  }else{
   if(prior?.state!=='intent'||prior.event.payloadDigest!==event.payloadDigest)throw Error('Rollback has no matching unresolved intent');states.set(id,{state:'rollback',event});
  }
 }
 return{records,states,events:[...committed.values()],seq,hash:previousHash};
}
/** Pure verification: a valid prefix is insufficient without the pinned fenced head. */
export function verifyPrivacyJournal(bytes:Buffer,trust:JournalTrust){
 const head=headSchema.parse(trust.head);if(!head.fenced||head.lineage!==trust.lineage||head.schemaDigest!==trust.schemaDigest||head.configurationId!==trust.configurationId)throw Error('Unknown or incompatible fenced head');
 if(!bytes.length)throw Error('Missing journal');const checked=inspectJournal(bytes,trust);
 if(checked.seq!==head.seq||checked.hash!==head.hash||[...checked.states.values()].some(s=>s.state==='intent'))throw Error('Journal prefix, unresolved intent, or head conflict');
 return{events:checked.events,head,bundleDigest:createHash('sha256').update(bytes).digest('hex')};
}
async function ownerFile(path:string,allowMissing=false){
 try{const s=await stat(path);if(!s.isFile()||(s.mode&0o077)!==0||s.uid!==process.getuid?.())throw Error('Owner-only file required');}
 catch(e){if(allowMissing&&(e as NodeJS.ErrnoException).code==='ENOENT')return;throw e;}
}
function assertLocalCall(call?:JournalCall):void{
 if(call===undefined)return;
 if(!call||typeof call.attemptId!=='string'||!call.attemptId.length||call.attemptId.length>100||!Number.isSafeInteger(call.deadlineUnixMs)||!(call.signal instanceof AbortSignal))throw Error('Call-owned journal deadline and AbortSignal required');
 call.signal.throwIfAborted();if(Date.now()>=call.deadlineUnixMs)throw Error('Journal deadline exceeded');
}
function localCallEnded(call?:JournalCall){return Boolean(call&&(call.signal.aborted||Date.now()>=call.deadlineUnixMs));}
interface LocalOperation {readonly call:JournalCall|undefined;uncertainFileTail:boolean}
// Node 22 readFile/writeFile support best-effort AbortSignal buffering cancellation.
// open, sync and rename do not; their admitted OS requests may finish after abort.
async function fsyncDirectory(path:string,call?:JournalCall){
 assertLocalCall(call);const handle=await open(path,constants.O_RDONLY);
 try{assertLocalCall(call);await handle.sync();assertLocalCall(call);}finally{await handle.close();}
 assertLocalCall(call);
}
async function atomicPrivateJSON(path:string,value:unknown,call?:JournalCall){
 assertLocalCall(call);const temporary=path+'.pending';const handle=await open(temporary,constants.O_WRONLY|constants.O_CREAT|constants.O_EXCL|constants.O_NOFOLLOW,0o600);
 try{assertLocalCall(call);await handle.writeFile(journalCanonical(value)+'\n',call?{signal:call.signal}:undefined);assertLocalCall(call);await handle.sync();assertLocalCall(call);}finally{await handle.close();}
 assertLocalCall(call);await rename(temporary,path);assertLocalCall(call);await fsyncDirectory(dirname(path),call);assertLocalCall(call);
}
export interface LocalPrivacyJournalConfiguration{
 source:Database;directory:string;checkpointPath:string;privateKeyPath:string;keyId:string;lineage:string;schemaDigest:string;configurationId:string;
 /** Test-only crash injection, never enabled by ambient environment. */
 mode?:'write'|'recover_fenced';
 fault?:(point:'before_intent_sync'|'after_intent_sync'|'after_commit_append'|'before_checkpoint'|'after_checkpoint')=>void;
}
/** Fixed owner source + private key. No CLI accepts arbitrary JSON or target lists. */
export async function createLocalPrivacyJournal(configuration:LocalPrivacyJournalConfiguration){
 const directory=resolve(configuration.directory),checkpointPath=resolve(configuration.checkpointPath);
 if(dirname(checkpointPath)===directory||checkpointPath.startsWith(directory+'/'))throw Error('Independent checkpoint location required');
 await mkdir(directory,{recursive:true,mode:0o700});const ds=await stat(directory);if((ds.mode&0o077)!==0||ds.uid!==process.getuid?.())throw Error('Owner-only journal directory required');
 await ownerFile(configuration.privateKeyPath);const key=createPrivateKey(await readFile(configuration.privateKeyPath));if(key.asymmetricKeyType!=='ed25519')throw Error('Ed25519 private key required');
 const file=directory+'/journal.ndjson';await ownerFile(file,true);await ownerFile(checkpointPath,true);
 const lock=await open(directory+'/writer.lock',constants.O_WRONLY|constants.O_CREAT|constants.O_EXCL|constants.O_NOFOLLOW,0o600);
 let closed=false,poisoned=false,byteLength=0,writerFenced=configuration.mode==='recover_fenced',queue:Promise<unknown>=Promise.resolve(),records:JournalRecord[]=[];
 const publicKey=createPublicKey(key).export({format:'pem',type:'spki'}).toString();
 const pins={lineage:configuration.lineage,schemaDigest:configuration.schemaDigest,configurationId:configuration.configurationId,keyId:configuration.keyId,publicKey};
 try{
  let bytes=Buffer.alloc(0);try{bytes=await readFile(file);}catch(e){if((e as NodeJS.ErrnoException).code!=='ENOENT')throw e;}
  const checked=inspectJournal(bytes,pins);records=checked.records;byteLength=bytes.length;
  const origin=(await configuration.source.query('SELECT lineage,schema_digest,configuration_id,fenced FROM ritc.privacy_journal_origin WHERE singleton')).rows[0];
  if(origin?.lineage!==configuration.lineage||origin.schema_digest!==configuration.schemaDigest||origin.configuration_id!==configuration.configurationId)throw Error('Fixed source origin mismatch');
  const recovery=configuration.mode==='recover_fenced';
  if(recovery!==Boolean(origin.fenced))throw Error(recovery?'Recovery requires an explicitly fenced source':'Fenced source is not writable');
  let checkpoint:PrivacyJournalHead|undefined;
  try{checkpoint=headSchema.parse(parseCanonical((await readFile(checkpointPath,'utf8')).trimEnd()));}catch(e){if((e as NodeJS.ErrnoException).code!=='ENOENT')throw e;}
  if(!checkpoint&&records.length)throw Error('Existing journal has no trusted independent checkpoint');
  if(checkpoint){
   if(checkpoint.lineage!==pins.lineage||checkpoint.schemaDigest!==pins.schemaDigest||checkpoint.configurationId!==pins.configurationId||checkpoint.seq>records.length||checkpoint.hash!==(checkpoint.seq?journalHash(records[checkpoint.seq-1]):zero))throw Error('Independent checkpoint mismatch');
   if(!recovery&&(checkpoint.fenced||checkpoint.seq!==records.length))throw Error('Uncheckpointed tail requires explicit fenced recovery');
   if(recovery){
    // Tail bytes are not trusted merely because they parse or carry a signature.
    // Source is fenced; each tail transition must resolve against immutable SQL.
    for(const record of records.slice(checkpoint.seq)){
     const row=(await configuration.source.query('SELECT payload,payload_digest FROM ritc.privacy_journal_outbox WHERE event_id=$1',[record.event.eventId])).rows[0];
     if(record.kind==='rollback'){if(row)throw Error('Rollback conflicts with committed source');}
     else if(record.kind==='commit'){if(!row||row.payload_digest!==record.event.payloadDigest||journalHash(row.payload)!==record.event.payloadDigest)throw Error('Recovery source commit mismatch');}
     else if(row&&(row.payload_digest!==record.event.payloadDigest||journalHash(row.payload)!==record.event.payloadDigest))throw Error('Recovery intent mismatch');
    }
   }
  }else{
   await atomicPrivateJSON(checkpointPath,{version:1,lineage:pins.lineage,schemaDigest:pins.schemaDigest,configurationId:pins.configurationId,seq:0,hash:zero,fenced:false});
  }
 }catch(e){await lock.close();await unlink(directory+'/writer.lock');throw e;}
 const head=(fenced=false):PrivacyJournalHead=>({version:1,lineage:configuration.lineage,schemaDigest:configuration.schemaDigest,configurationId:configuration.configurationId,seq:records.length,hash:records.length?journalHash(records[records.length-1]):zero,fenced});
 const serial=<T>(fn:(operation:LocalOperation)=>Promise<T>,input?:JournalCall):Promise<T>=>{
  let call:JournalCall|undefined,dispose=()=>{},cancelled:Promise<never>|undefined;
  let operation:LocalOperation={call:undefined,uncertainFileTail:false};
  if(input!==undefined){
   try{assertLocalCall(input);}catch(error){return Promise.reject(error);}
   // Capture before queueing: neither waiting nor caller mutation renews a budget.
   const attemptId=input.attemptId,deadlineUnixMs=input.deadlineUnixMs,signal=input.signal,controller=new AbortController();
   const abort=()=>controller.abort(signal.reason??Error('Journal call aborted'));
   signal.addEventListener('abort',abort,{once:true});
   let timer:ReturnType<typeof setTimeout>;
   const expire=()=>{const remaining=deadlineUnixMs-Date.now();if(remaining<=0)controller.abort(Error('Journal deadline exceeded'));else timer=setTimeout(expire,Math.min(2_147_483_647,remaining));};
   timer=setTimeout(expire,Math.min(2_147_483_647,Math.max(0,deadlineUnixMs-Date.now())));
   call=Object.freeze({attemptId,deadlineUnixMs,signal:controller.signal});
   cancelled=new Promise<never>((_,reject)=>{const ended=()=>{if(operation.uncertainFileTail)poisoned=true;reject(controller.signal.reason??Error('Journal call aborted'));};controller.signal.addEventListener('abort',ended,{once:true});dispose=()=>{clearTimeout(timer);signal.removeEventListener('abort',abort);controller.signal.removeEventListener('abort',ended);};});
   if(signal.aborted)abort();
  }
  operation={call,uncertainFileTail:false};
  const next=queue.then(async()=>{assertLocalCall(call);if(closed)throw Error('Journal closed');if(poisoned)throw Error('Journal requires explicit fenced recovery');const value=await fn(operation);assertLocalCall(call);return value;});
  // Keep the real work serialized even when the caller has already rejected.
  queue=next.catch(()=>{});return cancelled?Promise.race([next,cancelled]).finally(dispose):next;
 };
 async function sourceQuery(sql:string,args:unknown[]=[],operation?:LocalOperation){
  const call=operation?.call;assertLocalCall(call);
  if(!call)return configuration.source.query(sql,args);
  // Pool.query may wait for a connection internally. Recheck at actual dispatch,
  // and release an eventually acquired unused connection after caller abort.
  const db=await configuration.source.connect();
  try{assertLocalCall(call);const result=await db.query(sql,args);assertLocalCall(call);return result;}finally{db.release();}
 }
 async function append(kind:JournalRecord['kind'],candidate:PrivacyJournalEvent,operation?:LocalOperation){
  const call=operation?.call;assertLocalCall(call);
  const event=validateEvent(candidate);
  const previous=records.filter(r=>r.event.eventId===event.eventId).at(-1);
  if(kind==='intent'&&previous||kind==='rollback'&&previous?.kind!=='intent'||kind==='commit'&&(previous&&previous.kind!=='intent'||event.payload.kind==='acceptance'&&!previous))throw Error('Journal transition conflict');
  if(previous&&previous.event.payloadDigest!==event.payloadDigest)throw Error('Journal transition digest conflict');if(event.payload.lineage!==configuration.lineage||event.payload.schemaDigest!==configuration.schemaDigest||event.payload.configurationId!==configuration.configurationId)throw Error('Source event trust mismatch');
  const unsigned={version:1 as const,keyId:configuration.keyId,seq:records.length+1,previousHash:head().hash,kind,event};
  const record={...unsigned,signature:sign(null,Buffer.from(journalCanonical(unsigned)),key).toString('base64url')};
  const line=journalCanonical(record)+'\n';if(records.length>=MAX_RECORDS||byteLength+Buffer.byteLength(line)>MAX_BYTES)throw Error('Local journal capacity reached');
  try{
  if(kind==='intent')configuration.fault?.('before_intent_sync');
  assertLocalCall(call);const h=await open(file,constants.O_WRONLY|constants.O_CREAT|constants.O_APPEND|constants.O_NOFOLLOW,0o600);
  try{assertLocalCall(call);if(operation)operation.uncertainFileTail=true;await h.writeFile(line,call?{signal:call.signal}:undefined);assertLocalCall(call);await h.sync();assertLocalCall(call);}finally{await h.close();}
  assertLocalCall(call);await fsyncDirectory(directory,call);assertLocalCall(call);records.push(record);byteLength+=Buffer.byteLength(line);
  if(kind==='intent')configuration.fault?.('after_intent_sync');else configuration.fault?.('after_commit_append');
  assertLocalCall(call);configuration.fault?.('before_checkpoint');assertLocalCall(call);await atomicPrivateJSON(checkpointPath,head(),call);configuration.fault?.('after_checkpoint');assertLocalCall(call);
  if(operation)operation.uncertainFileTail=false;
  }catch(error){if(operation?.uncertainFileTail||!localCallEnded(call))poisoned=true;throw error;}
 }
 async function committedEvent(eventId:string,operation?:LocalOperation){uuid.parse(eventId);const row=(await sourceQuery('SELECT event_id,payload,payload_digest FROM ritc.privacy_journal_outbox WHERE event_id=$1',[eventId],operation)).rows[0];if(!row)throw Error('Committed source event unavailable');return validateEvent({eventId:row.event_id,payloadDigest:row.payload_digest,payload:row.payload});}
 async function afterCommit(eventId:string,operation?:LocalOperation){const call=operation?.call;assertLocalCall(call);const event=await committedEvent(eventId,operation),prior=records.find(r=>r.kind==='commit'&&r.event.eventId===eventId);
  if(prior&&prior.event.payloadDigest!==event.payloadDigest)throw Error('Committed event changed');
  if(event.payload.kind==='acceptance'&&!records.some(r=>r.event.eventId===eventId&&r.event.payloadDigest===event.payloadDigest&&r.kind==='intent')&&!prior)throw Error('Committed acceptance lacks its original durable intent');
  if(!prior)await append('commit',event,operation);
  // Ack references the commit record itself; retries use the same immutable head.
  const record=prior??records[records.length-1]!;assertLocalCall(call);const checkpoint=await readFile(checkpointPath,{encoding:'utf8',...(call?{signal:call.signal}:{})});assertLocalCall(call);const cp=headSchema.parse(JSON.parse(checkpoint));
  if(cp.seq<record.seq)throw Error('Independent checkpoint pending');
  if(cp.seq>records.length||cp.hash!==(cp.seq?journalHash(records[cp.seq-1]):zero)||cp.lineage!==configuration.lineage)throw Error('Independent checkpoint conflict');
  await sourceQuery('SELECT ritc.privacy_journal_acknowledge($1,$2,$3,$4)',[eventId,event.payloadDigest,record.seq,journalHash(record)],operation);
 }
 if(configuration.mode==='recover_fenced')await atomicPrivateJSON(checkpointPath,head());
 const port:PrivacyJournalPort={configurationId:configuration.configurationId,
  beforeCommit:(candidate,call)=>serial(async operation=>{if(writerFenced)throw Error('Fenced writer cannot accept requests');const event=validateEvent(candidate),prior=records.filter(r=>r.event.eventId===event.eventId).at(-1);if(prior){if(prior.kind==='rollback'||prior.event.payloadDigest!==event.payloadDigest)throw Error('Intent event already resolved or changed');return;}await append('intent',event,operation);},call),
  afterCommit:(eventId,call)=>serial(operation=>afterCommit(eventId,operation),call),
  acknowledgeJob:(jobId,call)=>serial(async operation=>{uuid.parse(jobId);const rows=(await sourceQuery('SELECT e.event_id FROM ritc.privacy_journal_outbox e WHERE e.job_id=$1 AND NOT EXISTS(SELECT 1 FROM ritc.privacy_journal_ack a WHERE a.event_id=e.event_id) ORDER BY e.created_at,e.event_id',[jobId],operation)).rows;for(const row of rows){assertLocalCall(operation.call);await afterCommit(row.event_id,operation);}},call),
 };
 return{port,publicKey,
  async fence(){return serial(async()=>{
   // All capture/progress functions hold a SHARE row lock. This commit fences
   // every earlier transaction before absence can prove an intent rolled back.
   await configuration.source.query('UPDATE ritc.privacy_journal_origin SET fenced=true WHERE singleton');writerFenced=true;
   const rows=(await configuration.source.query('SELECT e.event_id FROM ritc.privacy_journal_outbox e WHERE NOT EXISTS(SELECT 1 FROM ritc.privacy_journal_ack a WHERE a.event_id=e.event_id) ORDER BY e.created_at,e.event_id')).rows;for(const row of rows)await afterCommit(row.event_id);
   const pending=new Map<string,PrivacyJournalEvent>();for(const r of records){if(r.kind==='intent')pending.set(r.event.eventId,r.event);else pending.delete(r.event.eventId);}
   for(const [id,event] of pending){const resolved=(await configuration.source.query('SELECT 1 FROM ritc.privacy_journal_outbox WHERE event_id=$1',[id])).rowCount;if(resolved)throw Error('Intent commit reconciliation pending');await append('rollback',event);}
   await atomicPrivateJSON(checkpointPath,head(true));return head(true);
  });},
  async close(){await queue;closed=true;await lock.close();await unlink(directory+'/writer.lock');await fsyncDirectory(directory);},
 };
}

const bindingSchema=z.object({household_id:uuid,member_id:uuid,kind:z.enum(['adult','child']),state:z.enum(['active','revoked']),organizer:z.boolean(),can_contribute:z.boolean(),erased_at:z.null(),identity_hash:hash}).strict();
const targetSchema=z.object({householdId:uuid,memberId:uuid,kind:z.enum(['self_adult','explicit_sole_guardian_profile']),binding:bindingSchema,principalKnown:z.boolean().optional()}).strict();
const effectSchema=z.object({table:z.enum(['household','member','shop','shop_authority','device','replay_window','web_session','view_grant','invite','consent','guardian_relationship','billing_seat','guardian_enrollment','guardian_attempt','guardian_provider_event','guardian_child_invitation','guardian_child_claim','guardian_child_signin','guardian_native_challenge','guardian_intent','browser_auth']),key:z.string().min(36).max(256),before:z.record(z.string(),z.unknown()).nullable(),after:z.record(z.string(),z.unknown()).nullable()}).strict();
const time=z.string().datetime({offset:true});
const acceptanceSchema=z.object({identityHash:hash,receiptHash:hash,requestDigest:hash,acceptedAt:time,receiptDays:z.number().int().min(1).max(365),markerDays:z.number().int().min(1).max(3650),receiptUntil:time,markerUntil:time,attestation:z.object({configurationId:z.string().min(1).max(100),authenticatedAt:time,authenticatedMethod:z.enum(['otp','password','oauth','sso/saml']),providerAvailability:z.literal('configured_adapter_passed'),appleGate:z.literal('availability_contract_passed'),sqlAdultScopeCheck:z.literal('passed'),policy:z.object({receiptRetentionDays:z.number().int().min(1).max(365),erasureMarkerRetentionDays:z.number().int().min(1).max(3650),verifiedBackupRetentionDays:z.number().int().min(0).max(3650)}).strict(),sessionBindingHash:hash,checkedAt:time}).strict(),targets:z.array(targetSchema).max(1000),effects:z.array(effectSchema).max(10000),guardianPreimage:z.array(z.object({table:z.string(),key:z.string(),value:z.record(z.string(),z.unknown())}).strict()).max(10000).optional()}).strict();
const progressSchema=z.object({householdId:uuid,memberId:uuid,retiredPurchases:z.array(z.object({originalHash:hash}).strict()).max(10000),erasedAt:time}).strict();
const completionSchema=z.object({appErasedAt:time.nullable(),providerErasedAt:time.nullable(),completedAt:time.nullable(),receiptUntil:time,markerUntil:time}).strict();
const revoked=z.string().datetime({offset:true}).nullable();
const snapshotSchemas={
 household:z.object({household_id:uuid,archived_at:revoked}).strict(),
 member:bindingSchema,
 shop:z.object({household_id:uuid,shop_id:uuid,shopper_id:uuid,phase:z.enum(['draft','frozen','placed','closed']),revision:z.number().int().positive(),authority_epoch:z.number().int().positive(),measurement_closed_at:revoked}).strict(),
 shop_authority:z.object({household_id:uuid,shop_id:uuid,epoch:z.number().int().positive(),member_id:uuid,granted_at:time}).strict(),
 device:z.object({household_id:uuid,device_id:uuid,member_id:uuid,revoked_at:revoked,guardian_consent_id:uuid.nullable()}).strict(),
 replay_window:z.object({household_id:uuid,window_id:uuid,member_id:uuid,revoked_at:revoked}).strict(),
 web_session:z.object({household_id:uuid,member_id:uuid,credential_hash:hash,revoked_at:revoked}).strict(),
 view_grant:z.object({household_id:uuid,grant_id:uuid,created_by:uuid,recipient_id:uuid.nullable(),revoked_at:revoked}).strict(),
 invite:z.object({household_id:uuid,invite_id:uuid,created_by:uuid,redeemed_by:uuid.nullable(),revoked_at:revoked}).strict(),
 consent:z.object({household_id:uuid,consent_id:uuid,child_id:uuid,guardian_id:uuid,granted_at:time,revoked_at:revoked,evidence_hash:hash}).strict(),
 guardian_relationship:z.object({household_id:uuid,child_id:uuid,guardian_id:uuid,revoked_at:revoked,evidence_hash:hash}).strict(),
 billing_seat:z.object({household_id:uuid,slot:z.union([z.literal(1),z.literal(2)]),member_id:uuid}).strict(),
 guardian_enrollment:z.object({household_id:uuid,enrollment_id:uuid,guardian_id:uuid,child_id:uuid,state:z.enum(['awaiting_verification','verification_pending','verification_uncertain','verified','consented','child_claimed','child_approved','active','cancelled','expired','withdrawn']),revision:z.number().int().positive(),binding_hash:hash}).strict(),
 guardian_attempt:z.object({household_id:uuid,enrollment_id:uuid,attempt_id:uuid,binding_hash:hash}).strict(),
 guardian_provider_event:z.object({household_id:uuid,attempt_id:uuid,binding_hash:hash}).strict(),
 guardian_child_invitation:z.object({household_id:uuid,invite_id:uuid,enrollment_id:uuid,revoked_at:revoked,consumed_at:revoked,binding_hash:hash}).strict(),
 guardian_child_claim:z.object({household_id:uuid,claim_id:uuid,invite_id:uuid,approved_at:revoked,finished_at:revoked,revoked_at:revoked,binding_hash:hash}).strict(),
 guardian_child_signin:z.object({household_id:uuid,invite_id:uuid,binding_hash:hash}).strict(),
 guardian_native_challenge:z.object({household_id:uuid,challenge_id:uuid,invite_id:uuid,binding_hash:hash}).strict(),
 guardian_intent:z.object({household_id:uuid,enrollment_id:uuid,binding_hash:hash}).strict(),
 browser_auth:z.object({household_id:uuid,guardian_invite_id:uuid,phase:z.enum(['challenge','authenticated']),credential_hash:hash,revoked_at:revoked,email_present:z.boolean(),secret_present:z.boolean(),binding_hash:hash}).strict(),
};
const snapshotKeys:Record<keyof typeof snapshotSchemas,string[]>={household:[],member:['member_id'],shop:['shop_id'],shop_authority:['shop_id','epoch'],device:['device_id'],replay_window:['window_id'],web_session:['credential_hash'],view_grant:['grant_id'],invite:['invite_id'],consent:['consent_id'],guardian_relationship:['child_id','guardian_id'],billing_seat:['slot'],guardian_enrollment:['enrollment_id'],guardian_attempt:['enrollment_id'],guardian_provider_event:['attempt_id'],guardian_child_invitation:['invite_id'],guardian_child_claim:['claim_id'],guardian_child_signin:['invite_id'],guardian_native_challenge:['challenge_id'],guardian_intent:[],browser_auth:['credential_hash']};
/** Semantic validation runs after whole-chain verification and before SQL staging. */
export function validatePrivacyRestoreEvents(events:PrivacyJournalEvent[]){
 const accepted=new Map<string,z.infer<typeof acceptanceSchema>>();
 for(const event of events){
  validateEvent(event);
  if(event.payload.kind==='acceptance'){
   const p=acceptanceSchema.parse(event.payload.data);if(p.attestation.configurationId!==event.payload.configurationId||p.attestation.policy.receiptRetentionDays!==p.receiptDays||p.attestation.policy.erasureMarkerRetentionDays!==p.markerDays||p.attestation.policy.verifiedBackupRetentionDays>p.markerDays||p.markerDays<p.receiptDays||Date.parse(p.markerUntil)<Date.parse(p.receiptUntil))throw Error('Accepted policy or attestation conflict');
   const targetKeys=new Set<string>();for(const t of p.targets){const k=t.householdId+'/'+t.memberId;if(targetKeys.has(k)||t.householdId!==t.binding.household_id||t.memberId!==t.binding.member_id||t.kind==='self_adult'&&(t.binding.kind!=='adult'||t.binding.identity_hash!==p.identityHash)||t.kind==='explicit_sole_guardian_profile'&&t.binding.kind!=='child')throw Error('Target binding or duplicate conflict');targetKeys.add(k);}
   for(const row of p.guardianPreimage??[]){if(!row.table.startsWith('guardian_')&&row.table!=='browser_auth'||!(row.table in snapshotSchemas))throw Error('Unknown guardian projection');snapshotSchemas[row.table as keyof typeof snapshotSchemas].parse(row.value);if(!p.targets.some(t=>row.key.startsWith(t.householdId+'/')))throw Error('Guardian projection outside accepted household');}
   const effectKeys=new Set<string>();for(const e of p.effects){for(const tuple of[e.before,e.after])if(tuple!==null)snapshotSchemas[e.table].parse(tuple);const tuple=e.before??e.after!;const expectedKey=[tuple.household_id,...snapshotKeys[e.table].map(k=>tuple[k])].join('/');if(e.key!==expectedKey||journalCanonical(e.before)===journalCanonical(e.after))throw Error('Effect exact key or change conflict');const k=e.table+'/'+e.key;if(effectKeys.has(k)||e.before===null&&e.after===null||!p.targets.some(t=>e.key.startsWith(t.householdId))||e.before&&e.before.household_id!==e.key.slice(0,36)||e.after&&e.after.household_id!==e.key.slice(0,36))throw Error('Effect scope or duplicate conflict');effectKeys.add(k);}
   if(accepted.has(event.payload.jobId))throw Error('Duplicate accepted job');accepted.set(event.payload.jobId,p);
  }else{
   const p=accepted.get(event.payload.jobId);if(!p)throw Error('Missing original acceptance');
   if(event.payload.kind==='target_erased'){const progress=progressSchema.parse(event.payload.data);if(!p.targets.some(t=>t.householdId===progress.householdId&&t.memberId===progress.memberId))throw Error('Progress target outside acceptance');}
   else completionSchema.parse(event.payload.data);
  }
 }
 return events;
}
