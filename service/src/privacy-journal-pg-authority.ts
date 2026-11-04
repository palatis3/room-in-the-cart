import {createHash,createPublicKey,randomUUID,sign,verify,type KeyObject} from 'node:crypto';
import {z} from 'zod';
import type {Database,Transaction} from './database.js';
import {PrivacyCall,withPrivacyClient} from './privacy-call.js';
import {journalCanonical,journalHash,validatePrivacyRestoreEvents} from './privacy-journal.js';
import {MAX_JOURNAL_BYTES as maxBytes,MAX_JOURNAL_RECORDS as maxRecords,MAX_INTENT_RESOLUTION_OVERHEAD,WORKER_RECORD_BUDGET} from './privacy-journal-limits.js';
import {
 admittedSchema,durableJournalOperationId,durableJournalPublicKeyFingerprint,durableJournalScopeDigest,
 identitySchema,recordSchema,storedSchema,ticketSchema,verifyDurableAdmissionReceipt,workerKindSchema,workerKindsSchema,
} from './privacy-journal-durable.js';
import type {
 AdmittedHead,AdmissionReceipt,AppendTicket,AuthorityCall,AuthorityEnvelope,CheckpointAuthority,
 DurableJournalPins,DurableUncertaintyStore,ImmutableRecordTransport,JournalCall,OperationInspection,
 RecordIdentity,StoredRecord,UncertaintyClaim,UncertaintyOperation,
} from './privacy-journal-durable-contract.js';
import {JournalWriterBusy} from './privacy-journal-durable-contract.js';

const hash=z.string().regex(/^[0-9a-f]{64}$/);
const uuid=z.string().uuid();
const operationSchema=z.object({scopeDigest:hash,eventId:uuid,transition:z.enum(['intent','commit'])}).strict();
const claimSchema=operationSchema.extend({claimId:uuid});
const heldSchema=z.object({claim:claimSchema,attemptId:z.string().min(1).max(100)}).strict();

function matches(a:unknown,b:unknown):boolean{return journalCanonical(a)===journalCanonical(b);}
const clockSQL="SELECT floor(extract(epoch FROM clock_timestamp())*1000)::text AS ms";
async function databaseClock(db:Transaction){return Number((await db.query(clockSQL)).rows[0]?.ms);}

async function transaction<T>(pool:Database,call:JournalCall,work:(db:Transaction)=>Promise<T>):Promise<T>{
 return withPrivacyClient(pool,call,async db=>{
  try{
   await db.query('BEGIN ISOLATION LEVEL READ COMMITTED');
   await db.query("SET LOCAL synchronous_commit=on; SET LOCAL lock_timeout='1s'; SET LOCAL statement_timeout='4s'; SET LOCAL idle_in_transaction_session_timeout='4s'");
   const value=await work(db);
   await db.query('COMMIT');
   return value;
  }catch(error){await db.query('ROLLBACK').catch(()=>{});throw error;}
 });
}

async function assertRuntime(pool:Database,role:'ritc_checkpoint_runtime'|'ritc_record_runtime'){
 const scope=new PrivacyCall(undefined,5000);
 try{return await scope.run(call=>transaction(pool,call,async db=>{
  const {rows}=await db.query(`WITH relations AS (
   SELECT c.oid,n.nspname,c.relname FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
   WHERE (n.nspname,c.relname) IN (('ritc_records','object'),('ritc_checkpoint','admission'))
  ) SELECT current_database() AS database,
   (SELECT oid::text FROM pg_database WHERE datname=current_database()) AS oid,
   (SELECT identity FROM ritc_records.store WHERE singleton) AS store_identity,
   EXISTS(SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
    WHERE n.nspname='ritc_checkpoint' AND c.relname='worker_allowance') AS capacity_schema,
   current_user::text AS actor, (current_user=session_user AND r.rolcanlogin AND NOT r.rolsuper AND NOT r.rolbypassrls
    AND NOT r.rolcreaterole AND NOT r.rolcreatedb AND NOT r.rolreplication
    AND pg_has_role(current_user,$1,'USAGE')
    AND NOT EXISTS(SELECT 1 FROM pg_roles member WHERE pg_has_role(current_user,member.oid,'MEMBER')
     AND member.rolname NOT IN(current_user,$1::name))
    AND NOT EXISTS(SELECT 1 FROM pg_database d WHERE datname=current_database() AND pg_has_role(current_user,d.datdba,'MEMBER'))
    AND NOT EXISTS(SELECT 1 FROM pg_namespace n WHERE n.nspname IN ('ritc_checkpoint','ritc_records')
     AND (pg_has_role(current_user,n.nspowner,'MEMBER') OR has_schema_privilege(current_user,n.oid,'CREATE')))
    AND NOT EXISTS(SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
     WHERE n.nspname IN ('ritc_checkpoint','ritc_records') AND pg_has_role(current_user,c.relowner,'MEMBER'))
    AND (SELECT count(*)=2 AND bool_and(NOT has_table_privilege(current_user,oid,'DELETE,TRUNCATE,TRIGGER')
     AND NOT has_any_column_privilege(current_user,oid,'UPDATE')
     AND has_table_privilege(current_user,oid,'INSERT')=(relname='object' AND $1::name='ritc_record_runtime'
      OR relname='admission' AND $1::name='ritc_checkpoint_runtime')) FROM relations)
    AND NOT pg_is_in_recovery() AND current_setting('fsync')='on' AND current_setting('full_page_writes')='on') AS allowed
   FROM pg_roles r WHERE r.rolname=current_user`,[role]);
  const row=rows[0];if(!row?.allowed)throw Error('Separate journal runtime role and durable primary required');
  return row;
 }));
 }finally{scope.dispose();}
}

export interface PostgresJournalAuthorityConfiguration {
 readonly pins:DurableJournalPins;
 readonly writerPublicKey:KeyObject;
 readonly authorityPrivateKey:KeyObject;
 /** These pools belong only to the independent authority service. */
 readonly checkpointPool:Database;
 readonly recordPool:Database;
}

/** Internal backing service. The app receives only the scoped protocol ports. */
export async function createPostgresJournalAuthority(configuration:PostgresJournalAuthorityConfiguration):Promise<{
 readonly authority:CheckpointAuthority;readonly records:ImmutableRecordTransport;readonly uncertainty:DurableUncertaintyStore;
}>{
 const pins=Object.freeze(structuredClone(configuration.pins)),scopeDigest=durableJournalScopeDigest(pins);
 const {writerPublicKey,authorityPrivateKey,checkpointPool,recordPool}=configuration;
 if(writerPublicKey.type!=='public'||authorityPrivateKey.type!=='private'||
  durableJournalPublicKeyFingerprint(writerPublicKey)!==pins.publicKeyFingerprint||
  durableJournalPublicKeyFingerprint(authorityPrivateKey)!==pins.authorityPublicKeyFingerprint||
  pins.authorityPublicKeyFingerprint===pins.publicKeyFingerprint)throw Error('Separate pinned journal writer and checkpoint keys required');
 const authorityPublicKey=createPublicKey(authorityPrivateKey);
 const [checkpoint,objects]=await Promise.all([
  assertRuntime(checkpointPool,'ritc_checkpoint_runtime'),
  assertRuntime(recordPool,'ritc_record_runtime'),
 ]);
 if(!checkpoint.capacity_schema||!objects.capacity_schema||checkpoint.actor===objects.actor||checkpoint.oid!==objects.oid||checkpoint.database!==objects.database||
  checkpoint.store_identity!==pins.recordStoreIdentity||objects.store_identity!==pins.recordStoreIdentity)throw Error('Distinct journal roles on the registered authority database required');

 function envelope<T>(value:T,call:AuthorityCall):AuthorityEnvelope<T>{
  const body={version:1 as const,domain:'ritc-privacy-journal-authority-v1' as const,scopeDigest,
   authorityKeyId:pins.authorityKeyId,requestNonce:hash.parse(call.requestNonce),value};
  return {...body,authoritySignature:sign(null,Buffer.from(journalCanonical(body)),authorityPrivateKey).toString('base64url')};
 }
 const objectKey=(record:RecordIdentity)=>`${scopeDigest}/${record.seq}/${record.recordHash}`;
 function verifyReceipt(proof:unknown){return verifyDurableAdmissionReceipt(proof,pins,authorityPublicKey);}
 function decodeRecord(bytes:Buffer,identity:RecordIdentity){
  if(bytes.length!==identity.byteLength||bytes.at(-1)!==10)throw Error('Immutable journal record length conflict');
  const line=new TextDecoder('utf-8',{fatal:true}).decode(bytes.subarray(0,-1));
  const record=recordSchema.parse(JSON.parse(line));
  const {signature,...body}=record,{event}=body,proof=Buffer.from(signature,'base64url');
  if(!Buffer.from(line+'\n').equals(bytes)||journalCanonical(record)!==line||journalHash(record)!==identity.recordHash||
   record.seq!==identity.seq||record.previousHash!==identity.previousHash||record.kind!==identity.transition||record.keyId!==pins.keyId||
   event.eventId!==identity.eventId||event.payloadDigest!==identity.payloadDigest||event.payload.jobId!==identity.jobId||
   event.payload.lineage!==pins.lineage||event.payload.schemaDigest!==pins.schemaDigest||event.payload.configurationId!==pins.configurationId||
   proof.toString('base64url')!==signature||!verify(null,Buffer.from(journalCanonical(body)),writerPublicKey,proof))throw Error('Immutable journal record signature or identity conflict');
  return event;
 }
 async function load(db:Transaction,lock:'read'|'share'|'write'){
  const suffix=lock==='write'?' FOR UPDATE':lock==='share'?' FOR SHARE':'';
  const row=(await db.query('SELECT scope_digest,head,claim,pending FROM ritc_checkpoint.origin WHERE lineage=$1'+suffix,[pins.lineage])).rows[0];
  if(!row||row.scope_digest!==scopeDigest)throw Error('Independent journal origin is unregistered or pinned to another deployment');
  const head=admittedSchema.parse(row.head),claim=heldSchema.nullable().parse(row.claim),pending=ticketSchema.nullable().parse(row.pending);
  if(head.head.lineage!==pins.lineage||head.head.schemaDigest!==pins.schemaDigest||head.head.configurationId!==pins.configurationId||
   head.pendingOperation!==(pending?.operationId??null)||pending&&(!claim||!['pending','blocked','recovery'].includes(head.mode)))throw Error('Persisted journal origin conflict');
  return {head,claim,pending};
 }
 type Origin=Awaited<ReturnType<typeof load>>;
 function assertActive(state:Origin){
  if(state.head.head.fenced||state.head.mode!=='active'||state.pending)throw Error('Independent journal origin is blocked');
 }
 const writerBusy=Symbol('writer busy');
 async function writerTransaction<T>(call:JournalCall,work:(db:Transaction,state:Origin)=>Promise<T>):Promise<T>{
  const result=await transaction(checkpointPool,call,async db=>{
   const state=await load(db,'write').catch(error=>{
    // This is the initial lock read. No write for this command was dispatched.
    if(error?.code==='55P03')throw new JournalWriterBusy();
    throw error;
   });
   if(!state.head.head.fenced&&state.claim&&(
    state.head.mode==='active'||state.head.mode==='pending'&&state.pending&&
     state.pending.authorityExpiresAtUnixMs>await databaseClock(db)
   ))return writerBusy;
   assertActive(state);
   return work(db,state);
  });
  if(result===writerBusy)throw new JournalWriterBusy();
  return result;
 }
 function assertHeld(state:Origin,identity:RecordIdentity,call:JournalCall){
  if(!state.claim||state.claim.attemptId!==call.attemptId||state.claim.claim.scopeDigest!==scopeDigest||
   state.claim.claim.eventId!==identity.eventId||state.claim.claim.transition!==identity.transition)throw Error('Journal uncertainty claim does not cover this attempt');
 }
 async function admission(db:Transaction,operationId:string){
  const row=(await db.query('SELECT ticket,receipt FROM ritc_checkpoint.admission WHERE lineage=$1 AND operation_id=$2',[pins.lineage,operationId])).rows[0];
  return row?{ticket:ticketSchema.parse(row.ticket),receipt:verifyReceipt(row.receipt)}:undefined;
 }
 async function exactBytes(db:Transaction,stored:StoredRecord){
  const key=stored.objectKey;
  if(!key.startsWith(scopeDigest+'/')||!key.endsWith('/'+stored.recordHash))throw Error('Immutable object scope conflict');
  const row=(await db.query('SELECT record_hash,content FROM ritc_records.object WHERE object_key=$1 AND version=$2',[key,uuid.parse(stored.immutableVersion)])).rows[0];
  const bytes=row?.content;
  if(!Buffer.isBuffer(bytes)||row?.record_hash!==stored.recordHash||bytes.length!==stored.byteLength||bytes.at(-1)!==10||
   createHash('sha256').update(bytes.subarray(0,-1)).digest('hex')!==stored.recordHash)throw Error('Exact immutable record version is unavailable');
  return bytes;
 }
 async function validateRecord(db:Transaction,bytes:Buffer,ticket:AppendTicket){
  const event=decodeRecord(bytes,ticket.record);
  if(event.payload.kind==='acceptance'){
   if(ticket.workerKind)throw Error('Worker allowance cannot admit an acceptance');
   validatePrivacyRestoreEvents([event]);
   if(ticket.record.transition==='commit'){
    const intent=await admission(db,durableJournalOperationId(scopeDigest,event.eventId,event.payloadDigest,'intent'));
    if(!intent||!matches(decodeRecord(await exactBytes(db,intent.receipt.stored),intent.receipt.record),event))throw Error('Acceptance commit lacks the original intent');
   }
  }else{
   if(ticket.record.transition!=='commit')throw Error('Progress must be a commit observation');
   const row=(await db.query("SELECT receipt FROM ritc_checkpoint.admission WHERE lineage=$1 AND job_id=$2 AND event_kind='acceptance' AND transition='commit'",[pins.lineage,event.payload.jobId])).rows[0];
   if(!row)throw Error('Progress lacks the original accepted authorization');
   if(ticket.workerKind!==event.payload.kind)throw Error('Committed worker event does not match its capacity allowance');
   const receipt=verifyReceipt(row.receipt);
   validatePrivacyRestoreEvents([decodeRecord(await exactBytes(db,receipt.stored),receipt.record),event]);
  }
  return event;
 }
 async function reservedCapacity(db:Transaction){
  const row=(await db.query(`SELECT count(*)::int AS count,COALESCE(sum(bytes),0)::text AS bytes FROM (
   SELECT (i.receipt->'record'->>'byteLength')::int+$2::int AS bytes FROM ritc_checkpoint.admission i
   WHERE i.lineage=$1 AND i.transition='intent' AND NOT EXISTS(SELECT 1 FROM ritc_checkpoint.admission c
    WHERE c.lineage=i.lineage AND c.event_id=i.event_id AND c.transition='commit')
   UNION ALL SELECT bytes FROM ritc_checkpoint.worker_allowance WHERE lineage=$1
  ) reserved`,[pins.lineage,MAX_INTENT_RESOLUTION_OVERHEAD])).rows[0];
  return {count:Number(row.count),bytes:Number(row.bytes)};
 }
 async function assertPending(db:Transaction,state:Origin,ticket:AppendTicket,call:JournalCall){
  assertHeld(state,ticket.record,call);
  if(state.head.head.fenced||state.head.mode!=='pending'||!matches(state.pending,ticket)||
   state.head.generation!==ticket.generation||ticket.authorityExpiresAtUnixMs<=await databaseClock(db))throw Error('Journal reservation expired or changed');
 }

 async function beginClaim(input:UncertaintyOperation,call:JournalCall,intentBound?:number){
   const operation=operationSchema.parse(input);
   if(operation.scopeDigest!==scopeDigest)throw Error('Journal uncertainty scope conflict');
   if(intentBound!==undefined&&operation.transition!=='intent')throw Error('Intent capacity preflight requires an intent claim');
   return writerTransaction(call,async(db,state)=>{
    if(intentBound!==undefined){
     const existing=await db.query("SELECT 1 FROM ritc_checkpoint.admission WHERE lineage=$1 AND event_id=$2 AND transition='intent'",[pins.lineage,operation.eventId]);
     if(!existing.rowCount){
      const reserved=await reservedCapacity(db);
      if(state.head.head.seq+reserved.count+2>maxRecords||state.head.totalBytes+reserved.bytes+2*intentBound+MAX_INTENT_RESOLUTION_OVERHEAD>maxBytes)return null;
     }
    }
    const claim={...operation,claimId:randomUUID()};
    await db.query('UPDATE ritc_checkpoint.origin SET claim=$2 WHERE lineage=$1',[pins.lineage,{claim,attemptId:call.attemptId}]);
    return claim;
   });
 }
 const uncertainty:DurableUncertaintyStore={
  async begin(input,call){
   const claim=await beginClaim(input,call);
   if(!claim)throw Error('Journal uncertainty claim unavailable');
   return claim;
  },
  beginIntent(input,bound,call){
   return beginClaim(input,call,z.number().int().min(1).max(maxBytes).parse(bound));
  },
  async complete(input,proof,call){
   const claim=claimSchema.parse(input),receipt=verifyReceipt(proof);
   if(claim.scopeDigest!==scopeDigest||claim.eventId!==receipt.record.eventId||claim.transition!==receipt.record.transition)throw Error('Journal uncertainty receipt conflict');
   await transaction(checkpointPool,call,async db=>{
    const state=await load(db,'write');assertActive(state);
    if(!matches(state.claim,{claim,attemptId:call.attemptId}))throw Error('Journal uncertainty claim changed');
    const original=await admission(db,receipt.operationId);
    if(!matches(original?.receipt,receipt))throw Error('Journal uncertainty receipt was not persisted');
    await db.query('UPDATE ritc_checkpoint.origin SET claim=NULL WHERE lineage=$1',[pins.lineage]);
   });
  },
 };
 const authority:CheckpointAuthority={
  async readCapacity(call){
   hash.parse(call.requestNonce);
   return transaction(checkpointPool,call,async db=>{
    const {head,pending,claim}=await load(db,'share'),reserved=await reservedCapacity(db);
    const expired=pending&&pending.authorityExpiresAtUnixMs<=await databaseClock(db);
    return envelope({mode:expired&&head.mode==='pending'?'blocked' as const:head.mode,uncertain:Boolean(claim||pending),
     usedRecords:head.head.seq,reservedRecords:reserved.count,usedBytes:head.totalBytes,reservedBytes:reserved.bytes},call);
   });
  },
  async reserveWorkerCapacity(jobInput,kindsInput,call){
   const jobId=uuid.parse(jobInput),kinds=workerKindsSchema.parse(kindsInput);
   return writerTransaction(call,async(db,state)=>{
    const rows=(await db.query("SELECT event_kind FROM ritc_checkpoint.admission WHERE lineage=$1 AND job_id=$2 AND transition='commit' AND event_kind IN ('acceptance','source_completed')",[pins.lineage,jobId])).rows;
    if(!rows.some(row=>row.event_kind==='acceptance')||rows.some(row=>row.event_kind==='source_completed'))throw Error('Worker allowance requires an accepted unfinished job');
    const existing=(await db.query('SELECT event_kind FROM ritc_checkpoint.worker_allowance WHERE lineage=$1 AND job_id=$2',[pins.lineage,jobId])).rows;
    const needed=kinds.filter(kind=>!existing.some(row=>row.event_kind===kind));
    if(!needed.length)return true;
    const reserved=await reservedCapacity(db),bytes=needed.map(kind=>WORKER_RECORD_BUDGET[kind]);
    if(state.head.head.seq+reserved.count+needed.length>maxRecords||state.head.totalBytes+reserved.bytes+bytes.reduce((total,size)=>total+size,0)>maxBytes)return false;
    await db.query('INSERT INTO ritc_checkpoint.worker_allowance(lineage,job_id,event_kind,bytes) SELECT $1,$2,event_kind,bytes FROM unnest($3::text[],$4::int[]) a(event_kind,bytes)',[pins.lineage,jobId,needed,bytes]);
    return true;
   });
  },
  async readCurrent(call){
   hash.parse(call.requestNonce);
   return transaction(checkpointPool,call,async db=>{
    const {head,pending}=await load(db,'read');
    const expired=pending&&pending.authorityExpiresAtUnixMs<=await databaseClock(db);
    return envelope(expired&&head.mode==='pending'?{...head,mode:'blocked'}:head,call);
   });
  },
  async inspectOperation(input,call){
   const operationId=hash.parse(input);hash.parse(call.requestNonce);
   return transaction(checkpointPool,call,async db=>{
    const {head,pending}=await load(db,'share'),existing=await admission(db,operationId);
    let value:OperationInspection={state:'absent',operationId};
    if(existing)value={state:'admitted',operationId,receipt:existing.receipt};
    else if(pending?.operationId===operationId)value={state:head.mode==='pending'&&pending.authorityExpiresAtUnixMs>await databaseClock(db)?'pending':'blocked',operationId,ticket:pending};
    return envelope(value,call);
   });
  },
  async reserve(expectedInput,identityInput,call,kindInput){
   const expected=admittedSchema.parse(expectedInput),record=identitySchema.parse(identityInput);hash.parse(call.requestNonce);
   const workerKind=workerKindSchema.optional().parse(kindInput);
   if(record.transition==='rollback')throw Error('Ordinary journal writer cannot reserve rollback');
   if(workerKind&&record.transition!=='commit')throw Error('Worker allowance requires a commit observation');
   return transaction(checkpointPool,call,async db=>{
    const state=await load(db,'write');assertActive(state);assertHeld(state,record,call);
    const head=state.head;
    if(!matches(head,expected)||record.seq!==head.head.seq+1||record.previousHash!==head.head.hash||
     record.seq>maxRecords||head.totalBytes+record.byteLength>maxBytes)throw Error('Journal head compare-and-set conflict');
    const operationId=durableJournalOperationId(scopeDigest,record.eventId,record.payloadDigest,record.transition);
    const previous=(await db.query('SELECT receipt FROM ritc_checkpoint.admission WHERE lineage=$1 AND event_id=$2',[pins.lineage,record.eventId])).rows.map(row=>verifyReceipt(row.receipt).record);
    if(previous.some(prior=>prior.payloadDigest!==record.payloadDigest||prior.jobId!==record.jobId||prior.transition!=='intent'||record.transition!=='commit'))throw Error('Journal event transition conflict');
    // Every admitted intent must still fit its commit or rollback even if this
    // process dies. A progress observation cannot consume a reserved slot.
    const {count,bytes}=await reservedCapacity(db);
    let workerBytes=0;
    if(workerKind){
     const allowance=(await db.query('SELECT bytes FROM ritc_checkpoint.worker_allowance WHERE lineage=$1 AND job_id=$2 AND event_kind=$3',[pins.lineage,record.jobId,workerKind])).rows[0];
     if(!allowance||allowance.bytes<record.byteLength)throw Error('Committed worker event exceeds its reserved capacity');
     workerBytes=allowance.bytes;
    }
    const resolved=previous[0],newIntent=record.transition==='intent';
    const reserveCount=count+(newIntent?1:resolved?-1:0)-(workerKind?1:0);
    const reserveBytes=bytes+(newIntent?record.byteLength+MAX_INTENT_RESOLUTION_OVERHEAD:resolved?-(resolved.byteLength+MAX_INTENT_RESOLUTION_OVERHEAD):0)-workerBytes;
    if(record.seq+reserveCount>maxRecords||head.totalBytes+record.byteLength+reserveBytes>maxBytes)throw Error('Journal capacity must cover intent resolution');
    const now=await databaseClock(db),authorityExpiresAtUnixMs=Math.min(now+3500,call.deadlineUnixMs-1);
    if(authorityExpiresAtUnixMs<=now)throw Error('Insufficient time for journal reservation');
    const ticket={operationId,generation:head.generation,expected:head,record,objectKey:objectKey(record),authorityExpiresAtUnixMs,...(workerKind?{workerKind}:{})};
    await db.query('UPDATE ritc_checkpoint.origin SET head=$2,pending=$3 WHERE lineage=$1',
     [pins.lineage,{...head,mode:'pending',pendingOperation:operationId},ticket]);
    return envelope(ticket,call);
   });
  },
  async publish(input,reference,call){
   const ticket=ticketSchema.parse(input),stored=storedSchema.parse(reference);hash.parse(call.requestNonce);
   return transaction(checkpointPool,call,async db=>{
    const state=await load(db,'write'),existing=await admission(db,ticket.operationId);
    if(existing){
     if(!matches(existing.ticket,ticket)||!matches(existing.receipt.stored,stored))throw Error('Admitted journal operation conflict');
     return existing.receipt;
    }
    await assertPending(db,state,ticket,call);
    if(ticket.objectKey!==stored.objectKey||ticket.record.recordHash!==stored.recordHash||ticket.record.byteLength!==stored.byteLength)throw Error('Reserved immutable object identity conflict');
    const event=await validateRecord(db,await exactBytes(db,stored),ticket);
    const prior=state.head,record=ticket.record;
    const admitted:AdmittedHead={...prior,mode:'active',pendingOperation:null,authorityRevision:prior.authorityRevision+1,
     head:{...prior.head,seq:record.seq,hash:record.recordHash},totalBytes:prior.totalBytes+record.byteLength};
    const body={version:1 as const,domain:'ritc-privacy-journal-admission-v1' as const,scopeDigest,authorityKeyId:pins.authorityKeyId,
     operationId:ticket.operationId,admitted,record,stored};
    const receipt:AdmissionReceipt={...body,authoritySignature:sign(null,Buffer.from(journalCanonical(body)),authorityPrivateKey).toString('base64url')};
    await db.query('INSERT INTO ritc_checkpoint.admission(lineage,operation_id,event_id,job_id,transition,event_kind,sequence,ticket,receipt) VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9)',
     [pins.lineage,ticket.operationId,record.eventId,record.jobId,record.transition,event.payload.kind,record.seq,ticket,receipt]);
    if(ticket.workerKind){
     const used=await db.query('DELETE FROM ritc_checkpoint.worker_allowance WHERE lineage=$1 AND job_id=$2 AND event_kind=$3 AND bytes>=$4',
      [pins.lineage,record.jobId,ticket.workerKind,record.byteLength]);
     if(used.rowCount!==1)throw Error('Committed worker capacity allowance changed');
     if(ticket.workerKind==='source_completed')await db.query('DELETE FROM ritc_checkpoint.worker_allowance WHERE lineage=$1 AND job_id=$2',[pins.lineage,record.jobId]);
    }
    const changed=await db.query('UPDATE ritc_checkpoint.origin SET head=$2,pending=NULL WHERE lineage=$1 AND floor(extract(epoch FROM clock_timestamp())*1000)<$3::bigint',
     [pins.lineage,admitted,ticket.authorityExpiresAtUnixMs]);
    if(changed.rowCount!==1)throw Error('Journal reservation expired before publication');
    return receipt;
   });
  },
 };
 const records:ImmutableRecordTransport={
  async putExact(input,content,call){
   const ticket=ticketSchema.parse(input);
   if(content.byteLength!==ticket.record.byteLength)throw Error('Immutable record length conflict');
   const bytes=Buffer.from(content);
   await transaction(checkpointPool,call,async db=>{
    await assertPending(db,await load(db,'share'),ticket,call);
    await validateRecord(db,bytes,ticket);
   });
   return transaction(recordPool,call,async db=>{
    await db.query('INSERT INTO ritc_records.object(object_key,version,record_hash,content) VALUES($1,$2,$3,$4) ON CONFLICT(object_key) DO NOTHING',
     [ticket.objectKey,randomUUID(),ticket.record.recordHash,bytes]);
    const {version,record_hash,content:existing}=(await db.query('SELECT version::text,record_hash,content FROM ritc_records.object WHERE object_key=$1',[ticket.objectKey])).rows[0]??{};
    if(record_hash!==ticket.record.recordHash||!Buffer.isBuffer(existing)||!existing.equals(bytes))throw Error('Immutable record already exists with different content');
    return {objectKey:ticket.objectKey,immutableVersion:uuid.parse(version),recordHash:record_hash,byteLength:bytes.length};
   });
  },
  async readExact(input,call){
   const stored=storedSchema.parse(input);
   return transaction(recordPool,call,db=>exactBytes(db,stored));
  },
 };
 return Object.freeze({authority:Object.freeze(authority),records:Object.freeze(records),uncertainty:Object.freeze(uncertainty)});
}
