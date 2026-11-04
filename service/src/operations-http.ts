import {createHash,timingSafeEqual} from 'node:crypto';
import {createServer,type IncomingMessage,type ServerResponse} from 'node:http';
import {createOperationsRuntime,OPERATIONS_DEADLINE_MS} from './operations-runtime.js';

/** Authentication precedes pool construction, so public probes cannot open DB connections. */
export function createOperationsHandler(environment:NodeJS.ProcessEnv=process.env){
 let runtime:ReturnType<typeof createOperationsRuntime>|undefined;
 const secret=environment.CRON_SECRET;
 const expected=secret&&/^[A-Za-z0-9_-]{32,256}$/.test(secret)?createHash('sha256').update('Bearer '+secret).digest():undefined;
 function respond(response:ServerResponse,status:number,value:unknown){
  response.writeHead(status,{'Content-Type':'application/json; charset=utf-8','Cache-Control':'no-store','X-Content-Type-Options':'nosniff',...(status===405?{Allow:'GET'}:{})});
  response.end(JSON.stringify(value));
 }
 async function handler(request:IncomingMessage,response:ServerResponse){
  if(!['/internal/maintenance','/api/maintenance'].includes(request.url??'')){respond(response,404,{error:'unavailable'});return;}
  if(!expected){respond(response,503,{error:'operations_unavailable'});return;}
  const authorization=request.headers.authorization;
  const authorizationCount=request.rawHeaders.filter((_,index)=>index%2===0&&request.rawHeaders[index]?.toLowerCase()==='authorization').length;
  const supplied=createHash('sha256').update(typeof authorization==='string'?authorization:'').digest();
  if(authorizationCount!==1||!timingSafeEqual(expected,supplied)){respond(response,401,{error:'unauthorized'});return;}
  if(request.method!=='GET'){respond(response,405,{error:'method_not_allowed'});return;}
  if(request.headers['transfer-encoding']||request.headers['content-length']&&request.headers['content-length']!=='0'){respond(response,400,{error:'body_not_allowed'});return;}
  const signal=AbortSignal.timeout(OPERATIONS_DEADLINE_MS);
  try{
   runtime??=createOperationsRuntime(environment);
   const result=await runtime.run('run',signal);
   console.info(JSON.stringify(result));respond(response,200,result);
  }catch{
   const error=signal.aborted?'operations_deadline':'operations_unavailable';
   console.error(JSON.stringify({event:'operations_failed',error}));respond(response,503,{error});
  }
 }
 return{handler,async close(){await runtime?.close();}};
}

export function createOperationsHTTPServer(environment:NodeJS.ProcessEnv=process.env){
 const operations=createOperationsHandler(environment),server=createServer((request,response)=>{void operations.handler(request,response);});
 server.requestTimeout=5000;server.headersTimeout=5000;
 return{server,close:operations.close};
}
