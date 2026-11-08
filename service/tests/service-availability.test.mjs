import test from 'node:test';
import assert from 'node:assert/strict';
import {createServer,request} from 'node:http';
import {createServer as tcpServer} from 'node:net';
import {execFile} from 'node:child_process';
import {promisify} from 'node:util';
import {fileURLToPath} from 'node:url';
import {createRuntime} from '../dist/runtime.js';
import {createOperationsHTTPServer} from '../dist/operations-http.js';
import {serviceAvailability} from '../dist/service-availability.js';
const run=promisify(execFile);
const body={error:{code:'service_unavailable',recovery:'Keep saved changes and try again later.'}};
async function listen(server){await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));return 'http://127.0.0.1:'+server.address().port;}
async function stop(runtime){if(runtime.server.listening)await new Promise(resolve=>runtime.server.close(resolve));await runtime.close();await runtime.close();}
function onlyAvailability(value){return new Proxy({SERVICE_MAINTENANCE:value},{get(target,key){assert.equal(key,'SERVICE_MAINTENANCE','Maintenance must not inspect database, provider, identity or cron settings');return target[key];}});}
async function unavailable(origin,path,method='GET',headers={}){
 const response=await fetch(origin+path,{method,headers:{Authorization:'Bearer invalid',Cookie:'ritc_session=fixture; ritc_auth=fixture',Origin:'https://untrusted.invalid',...headers}});
 assert.equal(response.status,503);assert.equal(response.headers.get('cache-control'),'no-store');assert.equal(response.headers.get('retry-after'),'60');
 if(method==='HEAD')assert.equal(await response.text(),'');else assert.deepEqual(await response.json(),body);
}
test('only explicit false or absent resumes serving; invalid values fail closed',()=>{
 assert.deepEqual(serviceAvailability({}),{mode:'serving'});assert.deepEqual(serviceAvailability({SERVICE_MAINTENANCE:'false'}),{mode:'serving'});
 assert.deepEqual(serviceAvailability({SERVICE_MAINTENANCE:'true'}),{mode:'maintenance',configuration:'enabled'});
 for(const value of ['','TRUE','False','1','0',' true ','false\n'])assert.deepEqual(serviceAvailability({SERVICE_MAINTENANCE:value}),{mode:'maintenance',configuration:'invalid'});
});
test('local application rejects every route and method before inspecting any other configuration',async()=>{
 for(const flag of ['true','invalid']){
  const runtime=await createRuntime(onlyAvailability(flag));assert.equal(runtime.mode,'maintenance');assert.equal(runtime.pool,undefined);
  const origin=await listen(runtime.server);
  try{for(const path of ['/health','/v1/session','/v1/households/fixture/shops/fixture/delivery-evidence','/v1/households/fixture/commands','/api','/api/index','/unknown']){
   for(const method of ['GET','POST','HEAD','OPTIONS'])await unavailable(origin,path,method);
  }}finally{await stop(runtime);}
 }
});
test('incomplete request body cannot postpone maintenance response',async()=>{
 const runtime=await createRuntime({SERVICE_MAINTENANCE:'true',DATABASE_URL:'invalid',JWT_ISSUER:'invalid',EMAIL_OTP_ENABLED:'true'}),origin=await listen(runtime.server);
 try{await new Promise((resolve,reject)=>{
  const req=request(origin+'/v1/households/fixture/commands',{method:'POST',headers:{'content-type':'not-json','content-length':'1000000000'}},res=>{
   assert.equal(res.statusCode,503);assert.equal(res.headers['retry-after'],'60');res.resume();res.once('end',resolve);
  });req.on('error',reject);req.setTimeout(2000,()=>{req.destroy();reject(Error('Waited for unsent body'));});req.flushHeaders();
 });}finally{await stop(runtime);}
});
test('operations and cron gate precedes authentication, path checks, body and runtime construction',async()=>{
 for(const flag of ['true','bad-value']){
  const runtime=createOperationsHTTPServer(onlyAvailability(flag)),origin=await listen(runtime.server);
  try{for(const path of ['/internal/maintenance','/api/maintenance','/api/maintenance?extra=true','/health','/wrong']){
   for(const method of ['GET','POST','HEAD'])await unavailable(origin,path,method,{'Content-Type':'not-json'});
  }}finally{await stop(runtime);}
 }
});
test('real TCP negative control: off reaches database startup, enabled gate never connects',async()=>{
 let connections=0;const trap=tcpServer(socket=>{connections++;socket.destroy();});await new Promise(resolve=>trap.listen(0,'127.0.0.1',resolve));
 const environment={DATABASE_URL:`postgresql://fictional:fictional@127.0.0.1:${trap.address().port}/fixture`,JWT_ISSUER:'not a URL',JWT_AUDIENCE:'fixture',JWT_JWKS_URL:'not a URL',EMAIL_OTP_ENABLED:'true'};
 try{
  const runtime=await createRuntime({...environment,SERVICE_MAINTENANCE:'true'}),origin=await listen(runtime.server);
  try{await unavailable(origin,'/health');await unavailable(origin,'/api/index','POST');assert.equal(connections,0);}finally{await stop(runtime);}
  await assert.rejects(()=>createRuntime({...environment,SERVICE_MAINTENANCE:'false'}));assert.equal(connections,1);
  await assert.rejects(()=>createRuntime(environment));assert.equal(connections,2);
 }finally{await new Promise(resolve=>trap.close(resolve));}
});
test('absent and false preserve operations authentication rather than opening privileged access',async()=>{
 for(const flag of [undefined,'false']){
  const runtime=createOperationsHTTPServer({...(flag?{SERVICE_MAINTENANCE:flag}:{}),WORKER_DATABASE_URL:'not a URL',CRON_SECRET:'x'.repeat(32)}),origin=await listen(runtime.server);
  try{const response=await fetch(origin+'/internal/maintenance');assert.equal(response.status,401);assert.deepEqual(await response.json(),{error:'unauthorized'});}finally{await stop(runtime);}
 }
});
test('actual deployed API modules use the same pre-startup gate including direct function paths',async()=>{
 const root=fileURLToPath(new URL('../../',import.meta.url));
 const code=`import assert from 'node:assert/strict';import{createServer}from'node:http';
 const{default:application}=await import('./api/index.js');const{default:handler}=await import('./api/maintenance.js');const operations=createServer(handler);
 for(const server of[application,operations]){await new Promise(r=>server.listen(0,'127.0.0.1',r));try{for(const path of['/health','/api','/api/index','/api/maintenance','/internal/maintenance','/v1/households/fixture/commands']){const r=await fetch('http://127.0.0.1:'+server.address().port+path,{method:'POST',body:'not json',headers:{Authorization:'Bearer invalid',Cookie:'ritc_session=fixture'}});assert.equal(r.status,503);assert.equal(r.headers.get('cache-control'),'no-store');assert.equal(r.headers.get('retry-after'),'60');assert.equal((await r.json()).error.code,'service_unavailable');}}finally{await new Promise(r=>server.close(r));}}console.log('deployed entry gate passed');`;
 const result=await run(process.execPath,['--input-type=module','-e',code],{cwd:root,env:{PATH:process.env.PATH,SERVICE_MAINTENANCE:'true',DATABASE_URL:'not a URL',WORKER_DATABASE_URL:'not a URL',EMAIL_OTP_ENABLED:'true',JWT_ISSUER:'invalid',JWT_AUDIENCE:'invalid',JWT_JWKS_URL:'invalid'},timeout:15000});
 assert.match(result.stdout,/deployed entry gate passed/);
});
