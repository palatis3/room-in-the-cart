import {randomUUID} from 'node:crypto';
import type {IncomingMessage,ServerResponse} from 'node:http';
import type {Database,Transaction} from './database.js';
import type {JournalCall} from './privacy-journal-durable-contract.js';
import {ServiceError} from './errors.js';

const stopped=()=>new ServiceError(503,'deletion_unavailable','Keep the original deletion receipt and check its status before trying again.');

/** A server-owned absolute budget; nested phases can shorten, never renew it. */
export class PrivacyCall {
 readonly call:JournalCall;
 private readonly controller=new AbortController();
 private readonly timer:ReturnType<typeof setTimeout>;
 private readonly parentAbort:()=>void;
 private readonly parent:AbortSignal|undefined;
 constructor(parent?:JournalCall,budgetMs=15_000,attemptId:string=randomUUID()) {
  if(!Number.isSafeInteger(budgetMs)||budgetMs<1||budgetMs>25_000)throw Error('Bounded privacy call required');
  if(parent&&(!(parent.signal instanceof AbortSignal)||!Number.isSafeInteger(parent.deadlineUnixMs)||typeof parent.attemptId!=='string'||!parent.attemptId.length||parent.attemptId.length>100))throw Error('Invalid privacy call context');
  const deadlineUnixMs=Math.min(parent?.deadlineUnixMs??Infinity,Date.now()+budgetMs);
  this.parent=parent?.signal;this.parentAbort=()=>this.cancel();
  this.call=Object.freeze({attemptId:parent?.attemptId??attemptId,deadlineUnixMs,signal:this.controller.signal});
  if(this.parent?.aborted||deadlineUnixMs<=Date.now())this.cancel();
  else this.parent?.addEventListener('abort',this.parentAbort,{once:true});
  this.timer=setTimeout(()=>this.cancel(),Math.max(0,deadlineUnixMs-Date.now()));
 }
 cancel():void {if(!this.controller.signal.aborted)this.controller.abort(stopped());}
 check():void {if(Date.now()>=this.call.deadlineUnixMs)this.cancel();if(this.call.signal.aborted)throw stopped();}
 async run<T>(work:(call:JournalCall)=>Promise<T>):Promise<T> {
  this.check();let rejectAbort:(()=>void)|undefined;
  const aborted=new Promise<never>((_,reject)=>{rejectAbort=()=>reject(stopped());this.call.signal.addEventListener('abort',rejectAbort,{once:true});});
  try {
   // Attach cancellation before invoking work. The callee receives this same
   // signal and must stop its own next side effect after an outstanding I/O.
   const result=await Promise.race([Promise.resolve().then(()=>{this.check();return work(this.call);}),aborted]);
   this.check();return result;
  } finally {if(rejectAbort)this.call.signal.removeEventListener('abort',rejectAbort);}
 }
 dispose():void {clearTimeout(this.timer);this.parent?.removeEventListener('abort',this.parentAbort);}
}

export async function privacyPhase<T>(parent:JournalCall,work:(call:JournalCall)=>Promise<T>,budgetMs=5000):Promise<T> {
 const scope=new PrivacyCall(parent,budgetMs);try{return await scope.run(work);}finally{scope.dispose();}
}

/** Incoming request completion is normal; premature response/socket close is not. */
export function privacyHTTPCall(req:IncomingMessage,res:ServerResponse,attemptId:string):PrivacyCall {
 const scope=new PrivacyCall(undefined,15_000,attemptId);
 const requestClosed=()=>{if(!req.complete)scope.cancel();};
 const responseClosed=()=>{if(!res.writableFinished)scope.cancel();};
 req.once('close',requestClosed);res.once('close',responseClosed);
 const dispose=scope.dispose.bind(scope);
 scope.dispose=()=>{req.removeListener('close',requestClosed);res.removeListener('close',responseClosed);dispose();};
 if(req.destroyed&&!req.complete||res.destroyed)scope.cancel();
 return scope;
}

/**
 * One exclusively leased, non-pipelined connection. Aborting discards that
 * connection, rather than passing an unsupported signal option to pg.query.
 * An already-dispatched COMMIT can be uncertain; callers retain their receipt.
 */
export async function withPrivacyClient<T>(pool:Database,parent:JournalCall,work:(db:Transaction)=>Promise<T>):Promise<T> {
 const scope=new PrivacyCall(parent);let client:Transaction|undefined,released=false,abandoned=false,inFlight=false;
 const release=(discard=false)=>{if(client&&!released){released=true;client.release(discard||undefined);}};
 const abort=()=>{abandoned=true;release(true);};
 scope.call.signal.addEventListener('abort',abort,{once:true});
 try {
  const leased=await scope.run(()=>Promise.resolve().then(()=>{scope.check();return pool.connect();}).then(value=>{
   client=value;
   if(abandoned||scope.call.signal.aborted){release(true);throw stopped();}
   scope.check();return value;
  }));
  if((leased as Transaction&{pipeline?:boolean}).pipeline)throw Error('Privacy operations require a non-pipelined connection');
  const guarded=new Proxy(leased,{get(target,key){
   if(key==='query')return (...args:unknown[])=>{
    if(released||abandoned)return Promise.reject(stopped());
    if(inFlight)return Promise.reject(Error('Privacy queries must be awaited sequentially'));
    inFlight=true;
    return scope.run(()=>{
     if(typeof args[0]!=='string'||args.length>2||args[1]!==undefined&&!Array.isArray(args[1]))throw Error('Privacy queries require the promise SQL API');
     scope.check();return target.query(args[0],args[1] as unknown[]|undefined);
    }).finally(()=>{inFlight=false;});
   };
   if(key==='release')return ()=>{throw Error('Privacy call owns its connection lease');};
   const value=Reflect.get(target,key,target);return typeof value==='function'?value.bind(target):value;
  }});
  return await scope.run(()=>work(guarded));
 } catch(error) {abandoned=true;release(true);throw error;}
 finally {abandoned=true;scope.call.signal.removeEventListener('abort',abort);release(inFlight);scope.dispose();}
}
