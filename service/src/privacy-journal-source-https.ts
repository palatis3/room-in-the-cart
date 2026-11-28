import {randomUUID,timingSafeEqual} from 'node:crypto';
import type {RequestListener} from 'node:http';
import {Agent,request} from 'node:https';
import {z} from 'zod';
import {PrivacyCall,privacyHTTPCall,privacyPhase} from './privacy-call.js';
import {durableJournalScopeDigest,durableJournalPinsSchema,receiptSchema,recordSchema} from './privacy-journal-durable.js';
import type {DurableJournalPins,FixedCommittedSource,JournalCall} from './privacy-journal-durable-contract.js';
import {journalBearerTokenSchema,readBoundedJournalJSON,trustedSourceHeaders} from './privacy-journal-http-common.js';
import {MAX_JOURNAL_RECORDS,MAX_SOURCE_EVENT_BYTES} from './privacy-journal-limits.js';
import {journalHash} from './privacy-journal.js';

const path='/v1/source';
const maxRequestBytes=16*1024;
const maxResponseBytes=MAX_SOURCE_EVENT_BYTES+8192;
const {lineage:uuid,schemaDigest:hash}=durableJournalPinsSchema.shape;
const oid=z.string().regex(/^[1-9][0-9]{0,9}$/).refine(v=>Number(v)<=4294967295);
const databaseBindingSchema=z.object({database:z.string().min(1).max(63),databaseOid:oid,observerRoleOid:oid}).strict();
type DatabaseBinding=z.infer<typeof databaseBindingSchema>;
const commandSchema=z.discriminatedUnion('action',[
 z.object({action:z.literal('origin')}).strict(),
 z.object({action:z.literal('event'),eventId:uuid}).strict(),
 z.object({action:z.literal('acceptance'),jobId:uuid}).strict(),
 z.object({action:z.literal('unacknowledged'),jobId:uuid}).strict(),
 z.object({action:z.literal('acknowledge'),eventId:uuid,payloadDigest:hash,
  commitRecordSeq:z.number().int().min(1).max(MAX_JOURNAL_RECORDS),commitRecordHash:hash,receipt:receiptSchema}).strict(),
]);
type Command=z.infer<typeof commandSchema>;
const envelope=z.object({version:z.literal(1),requestId:uuid,scopeDigest:hash,databaseBinding:databaseBindingSchema,attemptId:z.string().min(1).max(100),
 deadlineUnixMs:z.number().int().positive().max(Number.MAX_SAFE_INTEGER),command:commandSchema}).strict();

async function dispatch(source:FixedCommittedSource,command:Command,call:JournalCall){
 switch(command.action){
  case 'origin':return source.readOrigin(call);
  case 'event':return source.readCommittedEvent(command.eventId,call);
  case 'acceptance':return source.readCommittedAcceptance(command.jobId,call);
  case 'unacknowledged':return source.listUnacknowledgedJobEvents(command.jobId,call);
  case 'acknowledge':
   await source.acknowledge(command.eventId,command.payloadDigest,command.commitRecordSeq,command.commitRecordHash,command.receipt,call);
   return null;
 }
}

export function sourceGatewayHandler(config:{
 pins:DurableJournalPins;databaseBinding:DatabaseBinding;source:FixedCommittedSource;applicationToken:string;operationsToken:string;
}):RequestListener{
 const scopeDigest=durableJournalScopeDigest(config.pins);
 const databaseBinding=databaseBindingSchema.parse(config.databaseBinding);
 const credentials=[config.applicationToken,config.operationsToken].map(token=>Buffer.from('Bearer '+journalBearerTokenSchema.parse(token)));
 if(config.applicationToken===config.operationsToken)throw Error('Separate application and operations credentials required');
 let active=0;
 return async(req,res)=>{
  const send=(status:number,body:string)=>{
   if(res.destroyed||res.writableEnded)return;
   if(status!==200)res.setHeader('Connection','close');
   res.writeHead(status,{'Content-Type':'application/json','Cache-Control':'no-store','Content-Length':Buffer.byteLength(body)});
   res.end(body);
  };
  const reject=(status:number)=>send(status,'{"error":"source_unavailable"}');
  if(req.method!=='POST'||req.url!==path)return reject(404);
  const token=Buffer.from(req.headers.authorization??'');
  if(!credentials.some(credential=>token.length===credential.length&&timingSafeEqual(token,credential)))return reject(401);
  if(req.headers['content-type']!=='application/json')return reject(415);
  if(active>=4)return reject(503);
  active++;
  const transport=privacyHTTPCall(req,res,randomUUID());
  const stopReading=()=>{if(!req.complete)req.destroy();};
  transport.call.signal.addEventListener('abort',stopReading,{once:true});
  try{
   const input=envelope.parse(await transport.run(()=>readBoundedJournalJSON(req,maxRequestBytes)));
   if(input.scopeDigest!==scopeDigest||input.databaseBinding.database!==databaseBinding.database||
    input.databaseBinding.databaseOid!==databaseBinding.databaseOid||input.databaseBinding.observerRoleOid!==databaseBinding.observerRoleOid)return reject(403);
   const parent={...transport.call,deadlineUnixMs:Math.min(transport.call.deadlineUnixMs,input.deadlineUnixMs)};
   const value=await privacyPhase(parent,call=>dispatch(config.source,input.command,call));
   const body=JSON.stringify({requestId:input.requestId,scopeDigest,databaseBinding,value});
   if(Buffer.byteLength(body)>maxResponseBytes)throw Error('Source response exceeds bound');
   send(200,body);
  }catch{reject(503);}
  finally{transport.call.signal.removeEventListener('abort',stopReading);transport.dispose();active--;}
 };
}

export function createHTTPSCommittedSource(config:{pins:DurableJournalPins;databaseBinding:DatabaseBinding;origin:string;token:string;ca?:string;
 getVercelTrustedSourceToken?:()=>Promise<string>}):{source:FixedCommittedSource;close():Promise<void>}{
 const base=new URL(config.origin);
 if(base.protocol!=='https:'||base.pathname!=='/'||base.username||base.password||base.search||base.hash)throw Error('Fixed HTTPS source origin required');
 const endpoint=new URL(path,base);
 const pins=durableJournalPinsSchema.parse(config.pins);
 const scopeDigest=durableJournalScopeDigest(pins);
 const binding=databaseBindingSchema.parse(config.databaseBinding);
 const expectedBinding=z.object({database:z.literal(binding.database),databaseOid:z.literal(binding.databaseOid),
  observerRoleOid:z.literal(binding.observerRoleOid)}).strict();
 const credential='Bearer '+journalBearerTokenSchema.parse(config.token);
 const getTrustedToken=config.getVercelTrustedSourceToken;
 const agent=new Agent({keepAlive:true,maxSockets:4,rejectUnauthorized:true,minVersion:'TLSv1.2',...(config.ca?{ca:config.ca}:{})});
 let closed=false;
 async function send<T>(command:Command,parent:JournalCall,schema:z.ZodType<T>):Promise<T>{
  const call=new PrivacyCall(parent,5000);
  try{return await call.run(async phase=>{
   const requestId=randomUUID();
   const body=JSON.stringify({version:1,requestId,scopeDigest,databaseBinding:binding,attemptId:phase.attemptId,deadlineUnixMs:phase.deadlineUnixMs,command:commandSchema.parse(command)});
   const size=Buffer.byteLength(body);
   if(size>maxRequestBytes||closed)throw Error('Source request unavailable');
   const headers={Authorization:credential,'Content-Type':'application/json','Content-Length':size,...await trustedSourceHeaders(getTrustedToken)};
   call.check();
   if(closed)throw Error('Source connection closed');
   return await new Promise<T>((resolve,reject)=>{
    const req=request(endpoint,{agent,method:'POST',headers,signal:phase.signal},res=>{
     if(res.statusCode!==200||res.headers['content-type']!=='application/json'){
      res.destroy();reject(Error('Source request rejected'));return;
     }
     readBoundedJournalJSON(res,maxResponseBytes).then(raw=>{
      const response=z.object({requestId:z.literal(requestId),scopeDigest:z.literal(scopeDigest),databaseBinding:expectedBinding,value:schema}).strict().parse(raw);
      resolve(response.value);
     }).catch(error=>{res.destroy();reject(error);});
    });
    req.once('error',reject);req.end(body);
   });
  });}finally{call.dispose();}
 }
 const origin=z.object({lineage:z.literal(pins.lineage),schemaDigest:z.literal(pins.schemaDigest),configurationId:z.literal(pins.configurationId),
  sourceIdentity:z.literal(pins.sourceIdentity),fenced:z.literal(false)}).strict();
 const event=recordSchema.shape.event.refine(e=>e.eventId===e.payload.eventId&&e.payloadDigest===journalHash(e.payload)&&
  e.payload.lineage===pins.lineage&&e.payload.schemaDigest===pins.schemaDigest&&e.payload.configurationId===pins.configurationId);
 const source:FixedCommittedSource={
  readOrigin:call=>send({action:'origin'},call,origin),
  readCommittedEvent:(eventId,call)=>send({action:'event',eventId},call,event.refine(e=>e.eventId===eventId)),
  readCommittedAcceptance:(jobId,call)=>send({action:'acceptance',jobId},call,event.refine(e=>e.payload.kind==='acceptance'&&e.payload.jobId===jobId)),
  listUnacknowledgedJobEvents:(jobId,call)=>send({action:'unacknowledged',jobId},call,z.array(uuid).max(MAX_JOURNAL_RECORDS).refine(ids=>new Set(ids).size===ids.length)),
  async acknowledge(eventId,payloadDigest,commitRecordSeq,commitRecordHash,receipt,call){
   // A lost response leaves the outcome unknown. Retrying the exact signed receipt is safe.
   await send({action:'acknowledge',eventId,payloadDigest,commitRecordSeq,commitRecordHash,receipt},call,z.null());
  },
 };
 return {source:Object.freeze(source),async close(){closed=true;agent.destroy();}};
}
