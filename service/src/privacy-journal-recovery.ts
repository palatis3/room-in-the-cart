import {createHash,createPublicKey,randomUUID,sign,verify,type KeyObject} from 'node:crypto';
import {z} from 'zod';
import type {Database,Transaction} from './database.js';
import {withPrivacyClient} from './privacy-call.js';
import {
 journalCanonical,journalHash,validatePrivacyRestoreEvents,verifyPrivacyJournal,verifyPrivacyJournalPrefix,
 type PrivacyJournalEvent,type PrivacyJournalHead,
} from './privacy-journal.js';
import {
 admittedSchema,durableJournalPinsSchema,durableJournalPublicKeyFingerprint,durableJournalScopeDigest,recordSchema,storedSchema,ticketSchema,verifyDurableAdmissionReceipt,
} from './privacy-journal-durable.js';
import type {DurableJournalPins,JournalCall,StoredRecord} from './privacy-journal-durable-contract.js';
import {MAX_JOURNAL_BYTES as MAX_BYTES,MAX_JOURNAL_RECORDS as MAX_RECORDS,MAX_RESTORE_JSON_BYTES,MAX_SOURCE_EVENT_BYTES} from './privacy-journal-limits.js';

const hash=z.string().regex(/^[0-9a-f]{64}$/),uuid=z.string().uuid();
const databaseOid=z.string().regex(/^[1-9][0-9]{0,9}$/).refine(value=>Number(value)<=4294967295);
const identity=z.object({database:z.string().min(1).max(63),databaseOid,owner:z.string().min(1).max(63),ownerOid:databaseOid}).strict();
const heldSchema=z.object({attemptId:z.string().min(1).max(100),claim:z.object({scopeDigest:hash,eventId:uuid,
 transition:z.enum(['intent','commit']),claimId:uuid}).strict()}).strict();
const eventSchema=recordSchema.shape.event;
const sealSchema=z.object({version:z.literal(1),domain:z.literal('ritc-privacy-journal-seal-v1'),scopeDigest:hash,
 authorityKeyId:z.string().min(1).max(100),generation:z.number().int().min(2),head:admittedSchema.shape.head,
 bundleDigest:hash,sourceEventsDigest:hash,sourceDatabaseOid:databaseOid,retiredReservation:hash.nullable(),
 retiredClaim:uuid.nullable(),authoritySignature:z.string().regex(/^[A-Za-z0-9_-]{86}$/)}).strict();
const successorSchema=z.object({version:z.literal(1),domain:z.literal('ritc-privacy-journal-successor-v1'),
 predecessorLineage:uuid,predecessorScopeDigest:hash,predecessorSealDigest:hash,
 successorLineage:uuid,successorScopeDigest:hash,sourceIdentity:z.string().min(1).max(200),sourceDatabaseOid:databaseOid,
 authoritySignature:sealSchema.shape.authoritySignature}).strict();
const windowTrustSchema=z.object({startScopeDigest:hash,terminalSealDigest:hash}).strict();
type DatabaseIdentity=z.infer<typeof identity>;
type RecoverySeal=z.infer<typeof sealSchema>;
type Record=z.infer<typeof recordSchema>;
const equal=(a:unknown,b:unknown)=>journalCanonical(a)===journalCanonical(b);

function publicTrust(pins:DurableJournalPins,writer:KeyObject,authority:KeyObject){
 if(writer.type!=='public'||authority.type!=='public'||durableJournalPublicKeyFingerprint(writer)!==pins.publicKeyFingerprint||
  durableJournalPublicKeyFingerprint(authority)!==pins.authorityPublicKeyFingerprint||pins.authorityPublicKeyFingerprint===pins.publicKeyFingerprint)throw Error('Independent pinned public keys required');
 return {lineage:pins.lineage,schemaDigest:pins.schemaDigest,configurationId:pins.configurationId,keyId:pins.keyId,
  publicKey:writer.export({type:'spki',format:'pem'}).toString()};
}

/** Independently verify the signed seal, exact v1 chain, and every restore event. */
export function verifyIndependentRecovery(bytes:Buffer,input:unknown,pins:DurableJournalPins,writer:KeyObject,authority:KeyObject){
 const trust=publicTrust(pins,writer,authority),proof=sealSchema.parse(input);
 const {authoritySignature,...body}=proof,signature=Buffer.from(authoritySignature,'base64url');
 if(proof.scopeDigest!==durableJournalScopeDigest(pins)||proof.authorityKeyId!==pins.authorityKeyId||
  signature.toString('base64url')!==authoritySignature||!verify(null,Buffer.from(journalCanonical(body)),authority,signature))throw Error('Independent recovery seal signature or scope conflict');
 const checked=verifyPrivacyJournal(bytes,{...trust,head:proof.head});
 if(checked.bundleDigest!==proof.bundleDigest||journalHash(checked.events.map(event=>[event.eventId,event.payloadDigest]).sort(compareIds))!==proof.sourceEventsDigest)throw Error('Independent recovery bundle or source digest conflict');
 validatePrivacyRestoreEvents(checked.events);
 return {...checked,proof};
}

function successorBody(predecessor:DurableJournalPins,seal:RecoverySeal,successor:{lineage:string;sourceIdentity:string;scopeDigest:string}){
 if(predecessor.lineage===successor.lineage||predecessor.sourceIdentity!==successor.sourceIdentity)
  throw Error('A successor must use a fresh lineage of the same source');
 return {
  version:1 as const,domain:'ritc-privacy-journal-successor-v1' as const,
  predecessorLineage:predecessor.lineage,predecessorScopeDigest:seal.scopeDigest,predecessorSealDigest:journalHash(seal),
  successorLineage:successor.lineage,successorScopeDigest:successor.scopeDigest,
  sourceIdentity:predecessor.sourceIdentity,sourceDatabaseOid:seal.sourceDatabaseOid,
 };
}

function verifySuccessor(input:unknown,expected:ReturnType<typeof successorBody>,authority:KeyObject){
 const proof=successorSchema.parse(input);
 const {authoritySignature,...body}=proof;
 const signature=Buffer.from(authoritySignature,'base64url');
 if(!equal(body,expected)||signature.toString('base64url')!==authoritySignature||
  !verify(null,Buffer.from(journalCanonical(body)),authority,signature))throw Error('Journal successor signature or archive continuity conflict');
 return proof;
}

interface ArchiveSegment {
 readonly pins:DurableJournalPins;
 readonly writerPublicKey:KeyObject;
 readonly authorityPublicKey:KeyObject;
 readonly bytes:Buffer;
 readonly seal:unknown;
 readonly incomingLink?:unknown;
}

/** Verify a bounded-memory archive stream against independent backup and final-seal anchors. */
export async function verifyIndependentArchiveWindow(segments:Iterable<ArchiveSegment>|AsyncIterable<ArchiveSegment>,input:unknown){
 const trust=windowTrustSchema.parse(input),lineages=new Set<string>();
 let previous:{pins:DurableJournalPins;seal:RecoverySeal;authorityPublicKey:KeyObject}|undefined;
 let events=0;
 for await(const segment of segments){
  const pins=durableJournalPinsSchema.parse(segment.pins);
  const checked=verifyIndependentRecovery(segment.bytes,segment.seal,pins,segment.writerPublicKey,segment.authorityPublicKey);
  if(lineages.has(pins.lineage))throw Error('Repeated journal lineage');
  if(!previous){
   if(checked.proof.scopeDigest!==trust.startScopeDigest||segment.incomingLink!==undefined)throw Error('Archive window does not start at the trusted backup scope');
  }else{
   if(checked.proof.sourceDatabaseOid!==previous.seal.sourceDatabaseOid)throw Error('Journal successor source database conflict');
   verifySuccessor(segment.incomingLink,successorBody(previous.pins,previous.seal,{
    lineage:pins.lineage,sourceIdentity:pins.sourceIdentity,scopeDigest:checked.proof.scopeDigest,
   }),previous.authorityPublicKey);
  }
  lineages.add(pins.lineage);
  events+=checked.events.length;
  previous={pins,seal:checked.proof,authorityPublicKey:segment.authorityPublicKey};
 }
 if(!previous||journalHash(previous.seal)!==trust.terminalSealDigest)throw Error('Archive window does not reach the trusted final seal');
 return {segments:lineages.size,events,...trust};
}

function compareIds(a:readonly string[],b:readonly string[]){return a[0]!<b[0]!?-1:a[0]===b[0]?0:1;}
async function transaction<T>(pool:Database,call:JournalCall,work:(db:Transaction)=>Promise<T>):Promise<T>{
 return withPrivacyClient(pool,call,async db=>{
  try{
   await db.query('BEGIN ISOLATION LEVEL READ COMMITTED');
   await db.query("SET LOCAL synchronous_commit=on; SET LOCAL lock_timeout='4s'; SET LOCAL statement_timeout='10s'; SET LOCAL idle_in_transaction_session_timeout='10s'");
   const result=await work(db);await db.query('COMMIT');return result;
  }catch(error){await db.query('ROLLBACK').catch(()=>{});throw error;}
 });
}

async function assertOwner(db:Transaction,expected:DatabaseIdentity,schema:'ritc'|'ritc_checkpoint',relation:string){
 const row=(await db.query(`SELECT current_database() AS database,(SELECT oid::text FROM pg_database WHERE datname=current_database()) AS "databaseOid",
  session_user AS owner,(SELECT oid::text FROM pg_roles WHERE rolname=session_user) AS "ownerOid",
  (current_user=session_user AND pg_get_userbyid(c.relowner)=session_user AND NOT pg_is_in_recovery()
   AND current_setting('fsync')='on') AS allowed
  FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname=$1 AND c.relname=$2`,[schema,relation])).rows[0];
 if(!row)throw Error('Fixed recovery database relation is unavailable');
 const {allowed,...actual}=row;
 if(!allowed||!equal(actual,expected))throw Error('Fixed recovery database or owner does not match');
}

async function checkpointState(db:Transaction,lock:boolean,owner:DatabaseIdentity,pins:DurableJournalPins,scopeDigest:string){
 await assertOwner(db,owner,'ritc_checkpoint','origin');
 const installed=(await db.query(`SELECT to_regclass('ritc.privacy_journal_origin') IS NULL
  AND to_regclass('ritc_checkpoint.recovery_seal') IS NOT NULL AND to_regclass('ritc_checkpoint.worker_allowance') IS NOT NULL AND EXISTS(
  SELECT 1 FROM pg_trigger WHERE tgrelid='ritc_checkpoint.origin'::regclass AND tgname='guard_origin_recovery'
  AND tgenabled IN ('O','A') AND tgfoid=to_regprocedure('ritc_checkpoint.guard_origin_recovery()')) AS ready`)).rows[0];
 if(!installed?.ready)throw Error('Checkpoint recovery schema is incomplete');
 const row=(await db.query(`SELECT o.scope_digest,o.head,o.claim,o.pending,s.identity
  FROM ritc_checkpoint.origin o CROSS JOIN ritc_records.store s WHERE o.lineage=$1 AND s.singleton${lock?' FOR UPDATE OF o':''}`,[pins.lineage])).rows[0];
 if(!row||row.scope_digest!==scopeDigest||row.identity!==pins.recordStoreIdentity)throw Error('Recovery checkpoint registration conflict');
 const head=admittedSchema.parse(row.head),claim=heldSchema.nullable().parse(row.claim),pending=ticketSchema.nullable().parse(row.pending);
 if(head.head.lineage!==pins.lineage||head.head.schemaDigest!==pins.schemaDigest||head.head.configurationId!==pins.configurationId||
  head.pendingOperation!==(pending?.operationId??null)||claim&&claim.claim.scopeDigest!==scopeDigest||
  pending&&(!claim||claim.claim.eventId!==pending.record.eventId||claim.claim.transition!==pending.record.transition))throw Error('Recovery checkpoint state conflict');
 return {head,claim,pending};
}

async function storedContent(db:Transaction,scopeDigest:string,references:readonly StoredRecord[]){
 if(references.length>MAX_RECORDS||references.reduce((sum,ref)=>sum+ref.byteLength,0)>MAX_BYTES)throw Error('Recovery record bounds exceeded');
 const refs=references.map((ref,index)=>({index,key:ref.objectKey,version:ref.immutableVersion,hash:ref.recordHash,bytes:ref.byteLength}));
 for(const ref of refs)if(!ref.key.startsWith(scopeDigest+'/')||!ref.key.endsWith('/'+ref.hash))throw Error('Recovery record scope conflict');
 const {rows}=await db.query(`SELECT o.content FROM jsonb_to_recordset($1::jsonb) AS r(index int,key text,version uuid,hash text,bytes int)
  LEFT JOIN ritc_records.object o ON o.object_key=r.key AND o.version=r.version AND o.record_hash=r.hash AND octet_length(o.content)=r.bytes
  ORDER BY r.index`,[JSON.stringify(refs)]);
 if(rows.length!==refs.length||rows.some((row,index)=>!Buffer.isBuffer(row.content)||row.content.at(-1)!==10||
  createHash('sha256').update(row.content.subarray(0,-1)).digest('hex')!==refs[index]?.hash))throw Error('Exact recovery record version is missing or changed');
 return rows.map(row=>row.content as Buffer);
}

async function admittedContent(db:Transaction,pins:DurableJournalPins,authority:KeyObject,scopeDigest:string){
 const {rows}=await db.query('SELECT sequence,ticket,receipt FROM ritc_checkpoint.admission WHERE lineage=$1 ORDER BY sequence LIMIT 10001',[pins.lineage]);
 const proofs=rows.map((row,index)=>{
  const receipt=verifyDurableAdmissionReceipt(row.receipt,pins,authority),ticket=ticketSchema.parse(row.ticket);
  if(row.sequence!==index+1||receipt.record.seq!==row.sequence||ticket.operationId!==receipt.operationId||
   !equal(ticket.record,receipt.record)||ticket.generation!==receipt.admitted.generation)throw Error('Admitted recovery prefix metadata conflict');
  return receipt;
 });
 return {proofs,content:await storedContent(db,scopeDigest,proofs.map(proof=>proof.stored))};
}

async function sealed(db:Transaction,head:PrivacyJournalHead,generation:number,sourceOid:string,pins:DurableJournalPins,writer:KeyObject,authority:KeyObject,scopeDigest:string){
 const row=(await db.query('SELECT proof,tail_objects FROM ritc_checkpoint.recovery_seal WHERE lineage=$1',[pins.lineage])).rows[0];
 if(!row)throw Error('Sealed recovery checkpoint is missing');
 const proof=sealSchema.parse(row.proof);
 if(!equal(head,proof.head)||proof.generation!==generation||proof.sourceDatabaseOid!==sourceOid)throw Error('Sealed recovery head conflict');
 const {content}=await admittedContent(db,pins,authority,scopeDigest);
 const tail=await storedContent(db,scopeDigest,z.array(storedSchema).max(MAX_RECORDS).parse(row.tail_objects));
 const bytes=Buffer.concat([...content,...tail]);
 const checked=verifyIndependentRecovery(bytes,proof,pins,writer,authority);
 return {bytes,proof:checked.proof};
}

export interface RecoveryConfiguration {
 readonly pins:DurableJournalPins;
 readonly writerPrivateKey:KeyObject;
 readonly authorityPrivateKey:KeyObject;
 readonly source:{readonly pool:Database;readonly identity:DatabaseIdentity};
 readonly checkpoint:{readonly pool:Database;readonly identity:DatabaseIdentity};
}

/** Re-export the independently retained sealed archive after source loss. */
export async function exportIndependentRecovery(configuration:{readonly pins:DurableJournalPins;readonly writerPublicKey:KeyObject;
 readonly authorityPublicKey:KeyObject;readonly sourceDatabaseOid:string;readonly checkpoint:RecoveryConfiguration['checkpoint'];
 readonly includeSuccessor?:boolean},call:JournalCall){
 const pins=Object.freeze(structuredClone(configuration.pins)),scopeDigest=durableJournalScopeDigest(pins);
 const {writerPublicKey,authorityPublicKey,checkpoint}=configuration;
 publicTrust(pins,writerPublicKey,authorityPublicKey);
 const owner=identity.parse(checkpoint.identity),sourceOid=databaseOid.parse(configuration.sourceDatabaseOid);
 return transaction(checkpoint.pool,call,async db=>{
  const {head,claim,pending}=await checkpointState(db,false,owner,pins,scopeDigest);
  if(head.mode!=='sealed'||!head.head.fenced||claim||pending)throw Error('Independent journal has no sealed archive');
  const archive=await sealed(db,head.head,head.generation,sourceOid,pins,writerPublicKey,authorityPublicKey,scopeDigest);
  if(!configuration.includeSuccessor)return archive;
  const row=(await db.query(`SELECT s.successor,s.proof,o.scope_digest
   FROM ritc_checkpoint.successor s JOIN ritc_checkpoint.origin o ON o.lineage=s.successor WHERE s.predecessor=$1`,[pins.lineage])).rows[0];
  if(!row)throw Error('The sealed archive has no registered successor');
  const successor=verifySuccessor(row.proof,successorBody(pins,archive.proof,{
   lineage:uuid.parse(row.successor),sourceIdentity:pins.sourceIdentity,scopeDigest:hash.parse(row.scope_digest),
  }),authorityPublicKey);
  return {...archive,successor};
 });
}

/** Reserve one successor in the independent database. Source activation is a separate operation. */
export async function registerIndependentSuccessor(configuration:{
 readonly pins:DurableJournalPins;
 readonly writerPublicKey:KeyObject;
 readonly authorityPrivateKey:KeyObject;
 readonly sourceDatabaseOid:string;
 readonly checkpoint:RecoveryConfiguration['checkpoint'];
 readonly successor:{readonly pins:DurableJournalPins;readonly writerPublicKey:KeyObject;readonly authorityPublicKey:KeyObject};
},call:JournalCall){
 const pins=durableJournalPinsSchema.parse(configuration.pins);
 const successor=durableJournalPinsSchema.parse(configuration.successor.pins);
 const {authorityPrivateKey,writerPublicKey,sourceDatabaseOid}=configuration;
 if(authorityPrivateKey.type!=='private')throw Error('The predecessor authority signing key is required');
 const authorityPublicKey=createPublicKey(authorityPrivateKey);
 const checkpoint={pool:configuration.checkpoint.pool,identity:identity.parse(configuration.checkpoint.identity)};
 publicTrust(successor,configuration.successor.writerPublicKey,configuration.successor.authorityPublicKey);
 if(pins.recordStoreIdentity!==successor.recordStoreIdentity)throw Error('Successor requires the same registered record store');
 const {proof:seal}=await exportIndependentRecovery({pins,writerPublicKey,authorityPublicKey,sourceDatabaseOid,checkpoint},call);
 const body=successorBody(pins,seal,{
  lineage:successor.lineage,sourceIdentity:successor.sourceIdentity,scopeDigest:durableJournalScopeDigest(successor),
 });
 const proof={...body,authoritySignature:sign(null,Buffer.from(journalCanonical(body)),authorityPrivateKey).toString('base64url')};
 return transaction(checkpoint.pool,call,async db=>{
  const {head}=await checkpointState(db,true,checkpoint.identity,pins,body.predecessorScopeDigest);
  await assertOwner(db,checkpoint.identity,'ritc_checkpoint','successor');
  const persisted=(await db.query('SELECT proof FROM ritc_checkpoint.recovery_seal WHERE lineage=$1',[pins.lineage])).rows[0];
  if(head.mode!=='sealed'||!equal(persisted?.proof,seal))throw Error('Predecessor seal changed during registration');
  const existing=(await db.query('SELECT successor,proof FROM ritc_checkpoint.successor WHERE predecessor=$1',[pins.lineage])).rows[0];
  if(existing){
   if(existing.successor!==successor.lineage||!equal(existing.proof,proof))throw Error('Predecessor already has a different successor');
   await checkpointState(db,false,checkpoint.identity,successor,body.successorScopeDigest);
   return proof;
  }
  const genesis={head:{version:1,lineage:successor.lineage,schemaDigest:successor.schemaDigest,configurationId:successor.configurationId,
   seq:0,hash:'0'.repeat(64),fenced:false},generation:1,authorityRevision:0,mode:'active',pendingOperation:null,totalBytes:0};
  await db.query('INSERT INTO ritc_checkpoint.origin(lineage,scope_digest,head) VALUES($1,$2,$3)',[successor.lineage,body.successorScopeDigest,genesis]);
  await db.query('INSERT INTO ritc_checkpoint.successor(predecessor,successor,proof) VALUES($1,$2,$3)',[pins.lineage,successor.lineage,proof]);
  return proof;
 });
}

/** Offline owner operation. No ordinary journal route accepts a recovery command or target list. */
export function createIndependentRecovery(configuration:RecoveryConfiguration){
 const pins=Object.freeze(structuredClone(configuration.pins)),scopeDigest=durableJournalScopeDigest(pins);
 const {writerPrivateKey,authorityPrivateKey}=configuration;
 if(writerPrivateKey.type!=='private'||authorityPrivateKey.type!=='private')throw Error('Owner recovery requires both protected signing keys');
 const writer=createPublicKey(writerPrivateKey),authority=createPublicKey(authorityPrivateKey),trust=publicTrust(pins,writer,authority);
 const source={pool:configuration.source.pool,identity:identity.parse(configuration.source.identity)};
 const checkpoint={pool:configuration.checkpoint.pool,identity:identity.parse(configuration.checkpoint.identity)};
 if(source.pool===checkpoint.pool)throw Error('Separate source and checkpoint connections required');

 async function sourceOrigin(db:Transaction,lock:boolean){
  await assertOwner(db,source.identity,'ritc','privacy_journal_origin');
  const row=(await db.query(`SELECT o.lineage,o.schema_digest,o.configuration_id,o.fenced,r.source_identity,r.database_oid::text
   FROM ritc.privacy_journal_origin o JOIN ritc.privacy_journal_source_registration r USING(singleton)
   WHERE o.singleton${lock?' FOR UPDATE OF o':''}`)).rows[0];
  if(!row||row.lineage!==pins.lineage||row.schema_digest!==pins.schemaDigest||row.configuration_id!==pins.configurationId||
   row.source_identity!==pins.sourceIdentity||row.database_oid!==source.identity.databaseOid)throw Error('Recovery source registration conflict');
  return row.fenced===true;
 }

 async function fence(call:JournalCall){
  // Prove the source binding before making the first irreversible change.
  await transaction(source.pool,call,db=>sourceOrigin(db,false));
  await transaction(checkpoint.pool,call,async db=>{
   const {head}=await checkpointState(db,true,checkpoint.identity,pins,scopeDigest);
   if(head.mode==='recovery'||head.mode==='sealed')return;
   if(head.head.fenced||!['active','pending','blocked'].includes(head.mode))throw Error('Unexpected checkpoint mode');
   const fenced={...head,mode:'recovery',generation:head.generation+1,authorityRevision:head.authorityRevision+1,head:{...head.head,fenced:true}};
   await db.query('UPDATE ritc_checkpoint.origin SET head=$2 WHERE lineage=$1',[pins.lineage,fenced]);
  });
  // Source capture and progress transactions hold SHARE on this row through
  // commit. The FOR UPDATE waits for their actual outcomes before fencing it.
  await transaction(source.pool,call,async db=>{
   if(!await sourceOrigin(db,true))await db.query('UPDATE ritc.privacy_journal_origin SET fenced=true WHERE singleton');
  });
 }

 async function sourceSnapshot(call:JournalCall){
  return transaction(source.pool,call,async db=>{
   if(!await sourceOrigin(db,false))throw Error('Recovery requires a committed source fence');
   const size=(await db.query(`SELECT count(*)::int AS n,COALESCE(sum(bytes),0)::text AS bytes,COALESCE(max(bytes),0) AS largest
    FROM (SELECT octet_length(payload::text) AS bytes FROM ritc.privacy_journal_outbox) events`)).rows[0];
   if(!size||size.n>MAX_RECORDS||Number(size.bytes)>MAX_RESTORE_JSON_BYTES||size.largest>MAX_SOURCE_EVENT_BYTES)throw Error('Committed recovery source exceeds bounds');
   const {rows}=await db.query(`SELECT e.event_id,e.lineage,e.job_id,e.kind,e.payload,e.payload_digest,
    a.payload_digest AS ack_digest,a.head_seq::text AS ack_seq,a.head_hash AS ack_hash
    FROM ritc.privacy_journal_outbox e LEFT JOIN ritc.privacy_journal_ack a USING(event_id)
    ORDER BY e.created_at,e.event_id`);
   if(rows.length!==size.n)throw Error('Fenced source snapshot changed');
   return rows.map(row=>{
    const event=eventSchema.parse({eventId:row.event_id,payloadDigest:row.payload_digest,payload:row.payload});
    if(event.eventId!==event.payload.eventId||event.payload.lineage!==pins.lineage||row.lineage!==pins.lineage||
     event.payload.schemaDigest!==pins.schemaDigest||event.payload.configurationId!==pins.configurationId||
     row.job_id!==event.payload.jobId||row.kind!==event.payload.kind||journalHash(event.payload)!==event.payloadDigest)throw Error('Committed source event identity conflict');
    return {event,ack:row.ack_seq===null?null:{sequence:Number(row.ack_seq),hash:row.ack_hash,digest:row.ack_digest}};
   });
  });
 }

 async function putTail(db:Transaction,records:readonly Record[]){
  const objects=records.map(record=>{
   const hash=journalHash(record),content=Buffer.from(journalCanonical(record)+'\n');
   return {key:`${scopeDigest}/${record.seq}/${hash}`,hash,content,version:randomUUID()};
  });
  if(!objects.length)return [];
  await db.query(`INSERT INTO ritc_records.object(object_key,version,record_hash,content)
   SELECT * FROM unnest($1::text[],$2::uuid[],$3::text[],$4::bytea[]) ON CONFLICT(object_key) DO NOTHING`,[
   objects.map(object=>object.key),objects.map(object=>object.version),objects.map(object=>object.hash),objects.map(object=>object.content),
  ]);
  const rows=(await db.query('SELECT object_key,version::text,record_hash,content FROM ritc_records.object WHERE object_key=ANY($1::text[])',[objects.map(object=>object.key)])).rows;
  const byKey=new Map(rows.map(row=>[row.object_key,row]));
  return objects.map(object=>{
   const row=byKey.get(object.key);
   if(!row||row.record_hash!==object.hash||!Buffer.isBuffer(row.content)||!row.content.equals(object.content))throw Error('Conflicting immutable recovery object');
   return {objectKey:object.key,immutableVersion:uuid.parse(row.version),recordHash:object.hash,byteLength:object.content.length};
  });
 }

 async function recover(call:JournalCall){
  await fence(call);
  const sourceRows=await sourceSnapshot(call),sourceById=new Map(sourceRows.map(row=>[row.event.eventId,row]));
  const sourceEventsDigest=journalHash(sourceRows.map(({event})=>[event.eventId,event.payloadDigest]).sort(compareIds));
  return transaction(checkpoint.pool,call,async db=>{
   const {head,claim,pending}=await checkpointState(db,true,checkpoint.identity,pins,scopeDigest);
   if(head.mode==='sealed'){
    const archived=await sealed(db,head.head,head.generation,source.identity.databaseOid,pins,writer,authority,scopeDigest);
    if(archived.proof.sourceEventsDigest!==sourceEventsDigest)throw Error('Sealed journal and fenced source no longer match');
    return archived;
   }
   if(head.mode!=='recovery'||!head.head.fenced)throw Error('Checkpoint recovery fence is missing');
   const {proofs,content}=await admittedContent(db,pins,authority,scopeDigest),prefix=Buffer.concat(content);
   if(prefix.length!==head.totalBytes||proofs.some(proof=>proof.admitted.generation!==head.generation-1))throw Error('Recovery prefix coverage conflict');
   const prior=verifyPrivacyJournalPrefix(prefix,{...trust,head:head.head});
   for(const [index,record] of prior.records.entries()){
    const receipt=proofs[index];
    if(!receipt||receipt.record.eventId!==record.event.eventId||receipt.record.payloadDigest!==record.event.payloadDigest||
     receipt.record.jobId!==record.event.payload.jobId||receipt.record.transition!==record.kind||receipt.record.previousHash!==record.previousHash||
     receipt.record.recordHash!==journalHash(record))throw Error('Admitted receipt and recorded bytes disagree');
    const live=sourceById.get(record.event.eventId);
    if(record.kind==='rollback'||record.kind==='intent'&&record.event.payload.kind!=='acceptance'||
     record.kind==='commit'&&!live||live&&!equal(record.event,live.event))throw Error('Admitted journal and fenced source disagree');
   }
   if(claim?.claim.transition==='commit'&&!sourceById.has(claim.claim.eventId))throw Error('Uncertain commit is absent from the pinned source');
   if(pending){
    const live=sourceById.get(pending.record.eventId);
    if(live&&(live.event.payloadDigest!==pending.record.payloadDigest||live.event.payload.jobId!==pending.record.jobId||pending.workerKind&&live.event.payload.kind!==pending.workerKind))throw Error('Pending reservation and fenced source disagree');
   }
   for(const {event,ack} of sourceRows)if(ack){
    const proof=proofs[ack.sequence-1];
    if(!proof||proof.record.transition!=='commit'||proof.record.eventId!==event.eventId||proof.record.payloadDigest!==ack.digest||proof.record.recordHash!==ack.hash)throw Error('Source acknowledgement lacks its exact admission');
   }

   const tail:Record[]=[];let previousHash=head.head.hash,seq=head.head.seq,byteLength=prefix.length;
   function append(event:PrivacyJournalEvent,kind:'commit'|'rollback'){
    const body={version:1 as const,keyId:pins.keyId,seq:++seq,previousHash,kind,event};
    const record={...body,signature:sign(null,Buffer.from(journalCanonical(body)),writerPrivateKey).toString('base64url')};
    byteLength+=Buffer.byteLength(journalCanonical(record))+1;
    if(seq>MAX_RECORDS||byteLength>MAX_BYTES)throw Error('Recovery journal capacity reached');
    previousHash=journalHash(record);tail.push(record);
   }
   // Source rows are in commit capture order. Recover accepted authorizations
   // before any progress so the existing v1 verifier can check dependencies.
   for(const acceptance of [true,false])for(const {event} of sourceRows){
    if((event.payload.kind==='acceptance')!==acceptance)continue;
    const state=prior.states.get(event.eventId);
    if(state?.state==='commit')continue;
    if(acceptance&&state?.state!=='intent')throw Error('Committed acceptance has no independently admitted intent');
    append(event,'commit');
   }
   for(const [eventId,state] of prior.states)if(state.state==='intent'&&!sourceById.has(eventId))append(state.event,'rollback');
   const bytes=Buffer.concat([prefix,...tail.map(record=>Buffer.from(journalCanonical(record)+'\n'))]);
   const finalHead={...head.head,seq,hash:previousHash,fenced:true};
   const verified=verifyPrivacyJournal(bytes,{...trust,head:finalHead});validatePrivacyRestoreEvents(verified.events);
   if(verified.events.length!==sourceRows.length)throw Error('Fenced source event coverage is incomplete');
   const body={version:1 as const,domain:'ritc-privacy-journal-seal-v1' as const,scopeDigest,authorityKeyId:pins.authorityKeyId,
    generation:head.generation,head:finalHead,bundleDigest:verified.bundleDigest,sourceDatabaseOid:source.identity.databaseOid,
    sourceEventsDigest,
    retiredReservation:pending?.operationId??null,retiredClaim:claim?.claim.claimId??null};
   const proof={...body,authoritySignature:sign(null,Buffer.from(journalCanonical(body)),authorityPrivateKey).toString('base64url')};
   verifyIndependentRecovery(bytes,proof,pins,writer,authority);
   const references=await putTail(db,tail);
   await db.query('INSERT INTO ritc_checkpoint.recovery_seal(lineage,proof,tail_objects) VALUES($1,$2,$3)',[pins.lineage,proof,JSON.stringify(references)]);
   await db.query('DELETE FROM ritc_checkpoint.worker_allowance WHERE lineage=$1',[pins.lineage]);
   await db.query('UPDATE ritc_checkpoint.origin SET head=$2,claim=NULL,pending=NULL WHERE lineage=$1',
    [pins.lineage,{...head,mode:'sealed',authorityRevision:head.authorityRevision+1,head:finalHead,pendingOperation:null,totalBytes:bytes.length}]);
   return {bytes,proof};
  });
 }
 return Object.freeze({fence,recover});
}
