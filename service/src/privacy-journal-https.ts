import {randomUUID,timingSafeEqual} from 'node:crypto';
import type {IncomingMessage,RequestListener} from 'node:http';
import {Agent,request} from 'node:https';
import {z} from 'zod';
import {PrivacyCall,privacyHTTPCall,privacyPhase} from './privacy-call.js';
import {
 admittedSchema,durableJournalScopeDigest,identitySchema,inspectionSchema,journalCapacitySchema,receiptSchema,storedSchema,ticketSchema,workerKindSchema,workerKindsSchema,
} from './privacy-journal-durable.js';
import type {
 CheckpointAuthority,DurableJournalPins,DurableUncertaintyStore,ImmutableRecordTransport,JournalCall,
} from './privacy-journal-durable-contract.js';
import {JournalWriterBusy} from './privacy-journal-durable-contract.js';
import {MAX_JOURNAL_BYTES as maxRecordBytes} from './privacy-journal-limits.js';

const path='/v1/journal';
const maxEncodedBytes=4*Math.ceil(maxRecordBytes/3),maxBody=maxEncodedBytes+8192;
const hash=z.string().regex(/^[0-9a-f]{64}$/);
const tokenSchema=z.string().regex(/^[A-Za-z0-9_-]{43}$/).refine(value=>Buffer.from(value,'base64url').toString('base64url')===value);
const encoded=z.string().min(4).max(maxEncodedBytes);
const operationSchema=z.object({scopeDigest:hash,eventId:z.string().uuid(),transition:z.enum(['intent','commit'])}).strict();
const claimSchema=operationSchema.extend({claimId:z.string().uuid()});
const commandSchema=z.discriminatedUnion('action',[
 z.object({action:z.literal('current'),nonce:hash}).strict(),
 z.object({action:z.literal('capacity'),nonce:hash}).strict(),
 z.object({action:z.literal('inspect'),nonce:hash,id:hash}).strict(),
 z.object({action:z.literal('reserve'),nonce:hash,head:admittedSchema,record:identitySchema,workerKind:workerKindSchema.optional()}).strict(),
 z.object({action:z.literal('worker_capacity'),jobId:z.string().uuid(),kinds:workerKindsSchema}).strict(),
 z.object({action:z.literal('publish'),nonce:hash,ticket:ticketSchema,stored:storedSchema}).strict(),
 z.object({action:z.literal('put'),ticket:ticketSchema,bytes:encoded}).strict(),
 z.object({action:z.literal('read'),stored:storedSchema}).strict(),
 z.object({action:z.literal('begin'),operation:operationSchema}).strict(),
 z.object({action:z.literal('begin_intent'),operation:operationSchema,recordByteBound:z.number().int().min(1).max(maxRecordBytes)}).strict(),
 z.object({action:z.literal('complete'),claim:claimSchema,proof:receiptSchema}).strict(),
]);
const envelopeSchema=z.object({version:z.literal(1),scopeDigest:hash,attemptId:z.string().min(1).max(100),
 deadlineUnixMs:z.number().int().positive().max(Number.MAX_SAFE_INTEGER),command:commandSchema}).strict();
const responseSchema=z.object({value:z.unknown()}).strict();
const busyResponse=z.object({error:z.literal('journal_writer_busy')}).strict();
type Command=z.infer<typeof commandSchema>;
const canRefuseWriter=(action:Command['action'])=>action==='begin'||action==='begin_intent'||action==='worker_capacity';
interface Ports {readonly authority:CheckpointAuthority;readonly records:ImmutableRecordTransport;readonly uncertainty:DurableUncertaintyStore}

function bytes(value:string):Buffer{
 const data=Buffer.from(value,'base64');
 if(data.length>maxRecordBytes||data.toString('base64')!==value)throw Error('Invalid canonical journal bytes');
 return data;
}
async function readJSON(message:IncomingMessage):Promise<unknown>{
 const declared=message.headers['content-length'];
 if(!declared||!/^\d+$/.test(declared)||Number(declared)>maxBody)throw Error('Bounded journal message required');
 const chunks:Buffer[]=[];let count=0;
 for await(const value of message){
  const chunk=Buffer.isBuffer(value)?value:Buffer.from(value);count+=chunk.length;
  if(count>maxBody)throw Error('Journal message too large');
  chunks.push(chunk);
 }
 if(count!==Number(declared))throw Error('Incomplete journal message');
 return JSON.parse(new TextDecoder('utf-8',{fatal:true}).decode(Buffer.concat(chunks)));
}

/** Serve only on the independently operated HTTPS service, with one pinned writer credential. */
export function journalAuthorityHandler(configuration:Ports&{readonly pins:DurableJournalPins;readonly writerToken:string}):RequestListener{
 const credential=Buffer.from('Bearer '+tokenSchema.parse(configuration.writerToken));
 const scopeDigest=durableJournalScopeDigest(configuration.pins);
 const {authority,records,uncertainty}=configuration;
 let active=0;
 async function dispatch(command:Command,call:JournalCall):Promise<unknown>{
  switch(command.action){
   case 'current':return authority.readCurrent({...call,requestNonce:command.nonce});
   case 'capacity':{
    if(!authority.readCapacity)throw Error('Journal capacity is unavailable');
    return authority.readCapacity({...call,requestNonce:command.nonce});
   }
   case 'inspect':return authority.inspectOperation(command.id,{...call,requestNonce:command.nonce});
   case 'reserve':return authority.reserve(command.head,command.record,{...call,requestNonce:command.nonce},command.workerKind);
   case 'worker_capacity':{
    if(!authority.reserveWorkerCapacity)throw Error('Worker capacity unavailable');
    return authority.reserveWorkerCapacity(command.jobId,command.kinds,call);
   }
   case 'publish':return authority.publish(command.ticket,command.stored,{...call,requestNonce:command.nonce});
   case 'put':return records.putExact(command.ticket,bytes(command.bytes),call);
   case 'read':return Buffer.from(await records.readExact(command.stored,call)).toString('base64');
   case 'begin':return uncertainty.begin(command.operation,call);
   case 'begin_intent':{
    if(!uncertainty.beginIntent)throw Error('Intent capacity preflight unavailable');
    return uncertainty.beginIntent(command.operation,command.recordByteBound,call);
   }
   case 'complete':await uncertainty.complete(command.claim,command.proof,call);return null;
  }
 }
 return async(req,res)=>{
  const respond=(status:number,value:unknown)=>{
   if(res.destroyed||res.writableEnded)return;
   const body=JSON.stringify(value);
   res.writeHead(status,{'Content-Type':'application/json','Content-Length':Buffer.byteLength(body),'Cache-Control':'no-store'});
   res.end(body);
  };
  const reject=(status:number)=>{
   if(res.destroyed||res.writableEnded)return;
   res.setHeader('Connection','close');respond(status,{error:'journal_unavailable'});
  };
  if(req.method!=='POST'||req.url!==path){reject(404);return;}
  const presented=Buffer.from(req.headers.authorization??'');
  if(presented.length!==credential.length||!timingSafeEqual(presented,credential)){reject(401);return;}
  if(req.headers['content-type']!=='application/json'){reject(415);return;}
  if(active>=4){reject(503);return;}
  active++;
  const transport=privacyHTTPCall(req,res,randomUUID());
  const stopBody=()=>{if(!req.complete)req.destroy();};
  transport.call.signal.addEventListener('abort',stopBody,{once:true});
  try{
   const input=await transport.run(async()=>envelopeSchema.parse(await readJSON(req)));
   if(input.scopeDigest!==scopeDigest){reject(403);return;}
   const call={attemptId:input.attemptId,deadlineUnixMs:Math.min(input.deadlineUnixMs,transport.call.deadlineUnixMs),signal:transport.call.signal};
   try{
    const value=await privacyPhase(call,phase=>dispatch(input.command,phase));
    respond(200,{value});
   }catch(error){
    if(error instanceof JournalWriterBusy&&canRefuseWriter(input.command.action))respond(409,{error:'journal_writer_busy'});
    else throw error;
   }
  }catch{reject(503);}
  finally{transport.call.signal.removeEventListener('abort',stopBody);transport.dispose();active--;}
 };
}

/** Pinned, direct HTTPS client. The app holds no checkpoint database or signing credential. */
export function createHTTPSJournalAuthority(configuration:{readonly pins:DurableJournalPins;readonly origin:string;
 readonly writerToken:string;readonly ca?:string}):Ports&{close():void}{
 const base=new URL(configuration.origin);
 if(base.protocol!=='https:'||base.pathname!=='/'||base.username||base.password||base.search||base.hash)throw Error('Fixed HTTPS journal origin required');
 const endpoint=new URL(path,base),scopeDigest=durableJournalScopeDigest(configuration.pins);
 const credential='Bearer '+tokenSchema.parse(configuration.writerToken);
 const agent=new Agent({keepAlive:true,maxSockets:4,rejectUnauthorized:true,minVersion:'TLSv1.2',
  ...(configuration.ca?{ca:configuration.ca}:{})});
 let closed=false;
 async function send<T>(command:Command,parent:JournalCall,schema:z.ZodType<T>):Promise<T>{
  if(closed)throw Error('Journal connection closed');
  const scope=new PrivacyCall(parent,5000);
  try{return await scope.run(call=>new Promise<T>((resolve,reject)=>{
   const body=JSON.stringify({version:1,scopeDigest,attemptId:call.attemptId,deadlineUnixMs:call.deadlineUnixMs,command});
   if(Buffer.byteLength(body)>maxBody){reject(Error('Journal message too large'));return;}
   scope.check();
   const req=request(endpoint,{agent,method:'POST',signal:call.signal,headers:{Authorization:credential,
    'Content-Type':'application/json','Content-Length':Buffer.byteLength(body)}},res=>{
    if(res.statusCode===409&&res.headers['content-type']==='application/json'&&canRefuseWriter(command.action)){
     readJSON(res).then(value=>{busyResponse.parse(value);reject(new JournalWriterBusy());}).catch(reject);return;
    }
    if(res.statusCode!==200||res.headers['content-type']!=='application/json'){
     res.destroy();reject(Error('Independent journal request rejected'));return;
    }
    readJSON(res).then(value=>resolve(schema.parse(responseSchema.parse(value).value))).catch(reject);
   });
   req.once('error',reject);req.end(body);
  }));}finally{scope.dispose();}
 }
 const signed=<T>(value:z.ZodType<T>)=>z.object({version:z.literal(1),domain:z.literal('ritc-privacy-journal-authority-v1'),
  scopeDigest:hash,authorityKeyId:z.string().min(1).max(100),requestNonce:hash,value,
  authoritySignature:z.string().regex(/^[A-Za-z0-9_-]{86}$/)}).strict();
 const current=signed(admittedSchema),inspect=signed(inspectionSchema),reserve=signed(ticketSchema),capacity=signed(journalCapacitySchema);
 const authority:CheckpointAuthority={
  readCurrent:call=>send({action:'current',nonce:call.requestNonce},call,current),
  readCapacity:call=>send({action:'capacity',nonce:call.requestNonce},call,capacity),
  inspectOperation:(id,call)=>send({action:'inspect',nonce:call.requestNonce,id},call,inspect),
  reserve:(head,record,call,workerKind)=>send({action:'reserve',nonce:call.requestNonce,head,record,workerKind},call,reserve),
  reserveWorkerCapacity:(jobId,kinds,call)=>send({action:'worker_capacity',jobId,kinds:[...kinds]},call,z.boolean()),
  publish:(ticket,stored,call)=>send({action:'publish',nonce:call.requestNonce,ticket,stored},call,receiptSchema),
 };
 const records:ImmutableRecordTransport={
  putExact:(ticket,content,call)=>{
   if(content.byteLength!==ticket.record.byteLength||content.byteLength>maxRecordBytes)throw Error('Immutable record length conflict');
   return send({action:'put',ticket,bytes:Buffer.from(content).toString('base64')},call,storedSchema);
  },
  readExact:async(stored,call)=>bytes(await send({action:'read',stored},call,encoded)),
 };
 const uncertainty:DurableUncertaintyStore={
  begin:(operation,call)=>send({action:'begin',operation},call,claimSchema),
  beginIntent:(operation,recordByteBound,call)=>send({action:'begin_intent',operation,recordByteBound},call,claimSchema.nullable()),
  async complete(claim,proof,call){await send({action:'complete',claim,proof},call,z.null());},
 };
 return Object.freeze({authority:Object.freeze(authority),records:Object.freeze(records),uncertainty:Object.freeze(uncertainty),
  close(){closed=true;agent.destroy();}});
}
