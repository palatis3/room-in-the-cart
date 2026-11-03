// TEST MODELS ONLY: serialized state is a simulation, not durable remote storage.
import {createHash,createPublicKey,sign,verify} from 'node:crypto';
import {actual,copy,ZERO,operationId,checkCall,assertOrigin,verifyHead} from './contract-runtime.mjs';

export class Scheduler {
 #now=1000;#rules=new Map();log=[];
 now=()=>this.#now;
 advance(ms){this.#now+=ms;}
 fail(label,message='Injected '+label){this.#add(label,{fail:message});}
 pause(label){
  let reached,release;const seen=new Promise(r=>{reached=r;}),gate=new Promise(r=>{release=r;});
  this.#add(label,{reached,gate});return{reached:seen,release};
 }
 #add(label,rule){const rules=this.#rules.get(label)??[];rules.push(rule);this.#rules.set(label,rules);}
 async point(label){
  this.log.push({label,at:this.#now});const rule=this.#rules.get(label)?.shift();
  if(rule?.reached){rule.reached();await rule.gate;}if(rule?.fail)throw Error(rule.fail);
 }
}

export function createDeterministicRecordStore({scheduler,snapshot,recordNamespace}){
 const state=snapshot?JSON.parse(snapshot):{objects:{}};
 function exact(ref){const object=state.objects[ref.objectKey];if(!object||object.ref.immutableVersion!==ref.immutableVersion||object.ref.recordHash!==ref.recordHash||object.ref.byteLength!==ref.byteLength)throw Error('Exact stored version unavailable');return object;}
 return Object.freeze({writer:Object.freeze({async putExact(ticket,bytes,call){
  checkCall(call,scheduler);await scheduler.point('store.beforePut');
  if(ticket.objectKey!==recordNamespace+'/'+ticket.generation+'/'+ticket.record.seq+'/'+ticket.record.recordHash)throw Error('Fixed storage namespace/ticket binding rejected');
  // Once the remote request has been accepted, caller cancellation cannot undo it.
  const text=Buffer.from(bytes).toString('utf8'),record=JSON.parse(text);
  if(actual.hash(record)!==ticket.record.recordHash||bytes.length!==ticket.record.byteLength)throw Error('Stored bytes do not match ticket');
  const encoded=Buffer.from(bytes).toString('base64'),existing=state.objects[ticket.objectKey];
  if(existing&&existing.bytes!==encoded)throw Error('Conditional create conflict');
  if(!existing)state.objects[ticket.objectKey]={bytes:encoded,ref:{objectKey:ticket.objectKey,immutableVersion:createHash('sha256').update(bytes).digest('hex'),recordHash:ticket.record.recordHash,byteLength:bytes.length}};
  await scheduler.point('store.afterPut');return copy(state.objects[ticket.objectKey].ref);
 }}),reader:Object.freeze({async readExact(ref,call){checkCall(call,scheduler);return Buffer.from(exact(ref).bytes,'base64');}}),control:Object.freeze({
  snapshot:()=>JSON.stringify(state),references:()=>Object.values(state.objects).map(o=>copy(o.ref)),
  corrupt(ref,mutate){const object=exact(ref);object.bytes=Buffer.from(mutate(Buffer.from(object.bytes,'base64'))).toString('base64');},
 })});
}

export function createDeterministicAuthority({pins,publicKey,authorityPrivateKey,recordReader,scheduler,snapshot}){
 const authorityPublicKey=createPublicKey(authorityPrivateKey);
 const state=snapshot?JSON.parse(snapshot):{generation:1,revision:0,mode:'active',head:{version:1,lineage:pins.lineage,schemaDigest:pins.schemaDigest,configurationId:pins.configurationId,seq:0,hash:ZERO,fenced:false},pending:null,admitted:[],events:{},abandoned:[],totalBytes:0};
 const attest=body=>({...copy(body),authorityReceipt:sign(null,Buffer.from(actual.canonical(body)),authorityPrivateKey).toString('base64url')});
 const current=()=>attest({head:copy(state.head),generation:String(state.generation),authorityRevision:String(state.revision),mode:state.pending?'pending':state.mode});
 function mode(recovery){if(state.mode!==(recovery?'recovery':'active'))throw Error('Checkpoint authority mode/fence rejected');}
 function stable(record){return operationId(pins,record.eventId,record.payloadDigest,record.transition);}
 function known(eventId,digest,transition){
  const prior=state.events[eventId];if(prior&&prior.event.payloadDigest!==digest)throw Error('Event ID digest conflict');
  if(state.pending?.record.eventId===eventId){
   if(state.pending.record.payloadDigest!==digest)throw Error('Event ID digest conflict');throw Error('Uncertain pending operation; fenced recovery required');
  }
  return copy(prior?.receipts[transition]);
 }
 function validateTransition(record,recovery){
  const event=record.event,prior=state.events[event.eventId];
  if(event.eventId!==event.payload.eventId||actual.hash(event.payload)!==event.payloadDigest||event.payload.lineage!==pins.lineage||event.payload.schemaDigest!==pins.schemaDigest||event.payload.configurationId!==pins.configurationId)throw Error('Journal event trust mismatch');
  if(prior&&prior.event.payloadDigest!==event.payloadDigest)throw Error('Event ID digest conflict');
  const committed=Object.values(state.events).filter(e=>e.state==='commit').map(e=>e.event);
  if(record.kind==='intent'){
   if(prior||event.payload.kind!=='acceptance')throw Error('Intent transition conflict');
   actual.validateEvents([...committed,event]);
  }else if(record.kind==='commit'){
   if(prior&&prior.state!=='intent')throw Error('Commit transition conflict');
   if(event.payload.kind==='acceptance'&&prior?.state!=='intent')throw Error('Acceptance lacks admitted intent');
   actual.validateEvents([...committed,event]);
  }else if(record.kind==='rollback'){
   if(!recovery||prior?.state!=='intent')throw Error('Rollback requires fenced recovery');
  }else throw Error('Unknown transition');
 }
 async function validateBytes(ticket,stored,call,recovery){
  const bytes=await recordReader.readExact(stored,call);
  const decoded=new TextDecoder('utf-8',{fatal:true}).decode(bytes),record=JSON.parse(decoded);
  if(actual.canonical(record)+'\n'!==decoded||!Buffer.from(decoded).equals(bytes))throw Error('Noncanonical record bytes');
  if(Object.keys(record).sort().join(',')!=='event,keyId,kind,previousHash,seq,signature,version')throw Error('Record fields rejected');
  if(record.version!==1||record.keyId!==pins.keyId||record.seq!==state.head.seq+1||record.previousHash!==state.head.hash||!Number.isSafeInteger(record.seq))throw Error('Record chain rejected');
  const {signature,...unsigned}=record;
  if(typeof signature!=='string'||!/^[A-Za-z0-9_-]{86}$/.test(signature)||Buffer.from(signature,'base64url').toString('base64url')!==signature||!verify(null,Buffer.from(actual.canonical(unsigned)),publicKey,Buffer.from(signature,'base64url')))throw Error('Journal signature rejected');
  const identity={seq:record.seq,previousHash:record.previousHash,recordHash:actual.hash(record),byteLength:bytes.length,eventId:record.event.eventId,payloadDigest:record.event.payloadDigest,jobId:record.event.payload.jobId,transition:record.kind};
  if(actual.canonical(identity)!==actual.canonical(ticket.record)||stored.objectKey!==ticket.objectKey||stored.recordHash!==identity.recordHash||stored.byteLength!==identity.byteLength)throw Error('Ticket/object binding rejected');
  validateTransition(record,recovery);return record;
 }
 function api(recovery){return Object.freeze({
  async readCurrent(call){checkCall(call,scheduler);mode(recovery);return current();},
  async findTransition(eventId,digest,transition,call){checkCall(call,scheduler);mode(recovery);return known(eventId,digest,transition);},
  async reserve(expected,record,call){
   checkCall(call,scheduler);await scheduler.point('authority.beforeReserve');mode(recovery);verifyHead(expected,pins,authorityPublicKey);
   const prior=known(record.eventId,record.payloadDigest,record.transition);if(prior)throw Error('Use original transition receipt');
   if(state.pending||expected.generation!==String(state.generation)||expected.authorityRevision!==String(state.revision)||actual.canonical(expected.head)!==actual.canonical(state.head))throw Error('Head CAS conflict');
   if(record.transition==='rollback'&&!recovery)throw Error('Ordinary rollback forbidden');
   if(record.seq!==state.head.seq+1||record.previousHash!==state.head.hash||state.head.seq>=10000||state.totalBytes+record.byteLength>32*1024*1024)throw Error('Sequence or capacity rejected');
   const id=stable(record),ticket={operationId:id,generation:String(state.generation),expected:copy(expected),record:copy(record),objectKey:pins.recordNamespace+'/'+state.generation+'/'+record.seq+'/'+record.recordHash,authorityExpiresAtUnixMs:Math.min(call.deadlineUnixMs-1,scheduler.now()+3500)};
   if(ticket.authorityExpiresAtUnixMs<=scheduler.now())throw Error('Insufficient authority deadline');
   state.pending=copy(ticket);state.revision++;await scheduler.point('authority.afterReserve');return copy(ticket);
  },
  async publish(ticket,stored,call){
   checkCall(call,scheduler);await scheduler.point('authority.beforePublish');mode(recovery);
   if(!state.pending||actual.canonical(state.pending)!==actual.canonical(ticket)||ticket.generation!==String(state.generation)||scheduler.now()>=ticket.authorityExpiresAtUnixMs)throw Error('Stale ticket, generation or authority deadline');
   const record=await validateBytes(ticket,stored,call,recovery);
   // No asynchronous boundary between the final condition check and atomic update.
   if(ticket.generation!==String(state.generation)||state.pending?.operationId!==ticket.operationId||scheduler.now()>=ticket.authorityExpiresAtUnixMs)throw Error('Publication lost authority');
   state.head={...state.head,seq:record.seq,hash:actual.hash(record)};state.revision++;state.totalBytes+=stored.byteLength;state.pending=null;
   const receipt=attest({operationId:ticket.operationId,admitted:current(),record:copy(ticket.record),stored:copy(stored)});
   const entry=state.events[record.event.eventId]??{event:copy(record.event),state:null,receipts:{}};entry.state=record.kind;entry.receipts[record.kind]=copy(receipt);state.events[record.event.eventId]=entry;state.admitted.push(copy(receipt));
   await scheduler.point('authority.afterPublish');return copy(receipt);
  },
  async inspectOperation(operationId,call){
   checkCall(call,scheduler);const receipt=state.admitted.find(r=>r.operationId===operationId);
   return receipt?{state:'admitted',receipt:copy(receipt)}:state.pending?.operationId===operationId?{state:'pending',ticket:copy(state.pending)}:{state:'absent'};
  },
 });}
 const ordinary=api(false),recoveryBase=api(true);
 const recovery=Object.freeze({...recoveryBase,
  async beginFence(call){checkCall(call,scheduler);if(state.mode==='sealed')throw Error('Sealed origin is terminal');if(state.mode==='recovery')return current();state.generation++;state.revision++;state.mode='recovery';if(state.pending)state.abandoned.push(state.pending);state.pending=null;scheduler.log.push({label:'authority.fence',at:scheduler.now()});return current();},
  async unresolvedIntents(call){checkCall(call,scheduler);mode(true);return Object.values(state.events).filter(e=>e.state==='intent').map(e=>copy(e.event));},
  async seal(origin,call){checkCall(call,scheduler);mode(true);assertOrigin(origin,pins);if(!origin.fenced||state.pending||Object.values(state.events).some(e=>e.state==='intent'))throw Error('Cannot seal unresolved/unfenced origin');state.head.fenced=true;state.mode='sealed';state.revision++;return current();},
 });
 return Object.freeze({writer:ordinary,recovery,reader:Object.freeze({
  head:()=>current(),
  receiptCovers:receipt=>state.admitted.some(r=>actual.canonical(r)===actual.canonical(receipt)),
  async materialize(call){const parts=[];for(const receipt of state.admitted)parts.push(await recordReader.readExact(receipt.stored,call));return Buffer.concat(parts);},
 }),control:Object.freeze({snapshot:()=>JSON.stringify(state),state:()=>copy(state),canonicalReferences:()=>state.admitted.map(r=>copy(r.stored))})});
}

/** Fake SQL state only. No JWT/session/provider/adult/guardian authorization proof. */
export function createFakeSQLSource({pins,scheduler,receiptCovers,snapshot,clientCapability}){
 const state=snapshot?JSON.parse(snapshot):{origin:{lineage:pins.lineage,schemaDigest:pins.schemaDigest,configurationId:pins.configurationId,sourceIdentity:pins.sourceIdentity,fenced:false},committed:[],acks:{},fenceRequested:false};
 let active=0,waiters=[];const heldCapability=clientCapability??Symbol('client-held synthetic status capability');
 function settleFence(){if(state.fenceRequested&&!active){state.origin.fenced=true;scheduler.log.push({label:'source.fenceCommitted',at:scheduler.now()});for(const done of waiters)done();waiters=[];}}
 function event(eventId){const e=state.committed.find(e=>e.eventId===eventId);if(!e)throw Error('Committed source event unavailable');return e;}
 const source=Object.freeze({
  async readOrigin(call){checkCall(call,scheduler);return copy(state.origin);},
  async readCommittedEvent(eventId,call){checkCall(call,scheduler);await scheduler.point('source.beforeRead');return copy(event(eventId));},
  async readCommittedAcceptance(jobId,call){checkCall(call,scheduler);const e=state.committed.find(e=>e.payload.jobId===jobId&&e.payload.kind==='acceptance');if(!e)throw Error('Original committed acceptance unavailable');return copy(e);},
  async hasCommittedEvent(eventId,call){checkCall(call,scheduler);if(!state.origin.fenced)throw Error('Absence cannot prove rollback before source fence');scheduler.log.push({label:'source.fencedAbsenceRead',at:scheduler.now()});return state.committed.some(e=>e.eventId===eventId);},
  async listUnacknowledgedJobEvents(jobId,call){checkCall(call,scheduler);return state.committed.filter(e=>e.payload.jobId===jobId&&!state.acks[e.eventId]).map(e=>e.eventId);},
  async listUnacknowledgedEvents(call){checkCall(call,scheduler);return state.committed.filter(e=>!state.acks[e.eventId]).map(e=>e.eventId);},
  async acknowledge(eventId,digest,seq,hash,receipt,call){
   checkCall(call,scheduler);const e=event(eventId);
   if(e.payloadDigest!==digest||receipt.record.transition!=='commit'||receipt.record.eventId!==eventId||receipt.record.payloadDigest!==digest||receipt.record.seq!==seq||receipt.record.recordHash!==hash||!receiptCovers(receipt))throw Error('Acknowledgement precedes exact admitted durable commit');
   const next={payloadDigest:digest,headSeq:seq,headHash:hash};if(state.acks[eventId]&&actual.canonical(state.acks[eventId])!==actual.canonical(next))throw Error('Acknowledgement identity conflict');
   // Models an already-sent SQL command: expiry cannot undo its execution.
   await scheduler.point('source.beforeAckCommit');state.acks[eventId]=next;scheduler.log.push({label:'source.ackCommitted',at:scheduler.now(),eventId});await scheduler.point('source.afterAckCommit');
  },
  async fence(call){checkCall(call,scheduler);state.fenceRequested=true;settleFence();if(!state.origin.fenced)await new Promise(done=>waiters.push(done));checkCall(call,scheduler);},
 });
 const eligible=jobId=>!state.origin.fenced&&state.committed.some(e=>e.payload.jobId===jobId&&e.payload.kind==='acceptance')&&!state.committed.some(e=>e.payload.jobId===jobId&&!state.acks[e.eventId]);
 return Object.freeze({source,control:Object.freeze({
  begin(candidate){if(state.origin.fenced||state.fenceRequested)throw Error('Source is fencing/fenced');active++;let done=false;return Object.freeze({sqlResult:()=>copy(candidate),commit(){if(done)throw Error('Transaction resolved');if(state.origin.fenced)throw Error('Source fenced');const prior=state.committed.find(e=>e.eventId===candidate.eventId);if(prior&&prior.payloadDigest!==candidate.payloadDigest)throw Error('Immutable source conflict');if(!prior)state.committed.push(copy(candidate));done=true;active--;scheduler.log.push({label:'source.commit',at:scheduler.now(),eventId:candidate.eventId});settleFence();},rollback(){if(done)return;done=true;active--;scheduler.log.push({label:'source.rollback',at:scheduler.now()});settleFence();}});},
  eligible,heldCapability,
  receiptStatus(jobId,capability){if(capability!==heldCapability)throw Error('Original client capability required');return{jobExists:state.committed.some(e=>e.payload.jobId===jobId),workerEligible:eligible(jobId)};},
  snapshot:()=>JSON.stringify(state),state:()=>copy(state),
 })});
}
