import {execFile} from 'node:child_process';
import {randomUUID} from 'node:crypto';
import {mkdtemp,readFile,writeFile,chmod,rm} from 'node:fs/promises';
import {createServer} from 'node:https';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {promisify} from 'node:util';
import {runNativeWireTest} from './run-native-wire-test.mjs';
const run=promisify(execFile);

import {observeNativeWireCommand} from './shared-demand-native-wire.mjs';

// Identity provider and delivery interruption are fixtures. Optional beforeCommand
// commits a separate authorized real API action before dispatch, never a fake inverse.
// Every household read/preview/command reaches the original authenticated API/PG path.
export async function exerciseOperationUndoClient({service,owner,householdId,shopId,phase,targetOperationId,packs,before,privateState,dropFirstReply=false,beforeCommand=null,scenario=null,expectedMeal=null}){
 const dir=await mkdtemp(join(tmpdir(),'ritc-undo-wire-tls-'));await chmod(dir,0o700);
 const key=join(dir,'tls.key'),cert=join(dir,'tls.pem'),der=join(dir,'tls.der'),config=join(dir,'openssl.cnf'),input=join(privateState,'phase-'+phase+'-'+randomUUID()+'.json'),code=randomUUID();
 let tls,attempts=0,dropped=0;const unsuccessful=[],commands=[],candidateRequests=[],previewRequests=[];let candidateAttempts=0,previewAttempts=0,synchronizationFailed=false;
 try{
  await writeFile(config,'[req]\ndistinguished_name=dn\nx509_extensions=ext\nprompt=no\n[dn]\nCN=localhost\n[ext]\nsubjectAltName=IP:127.0.0.1\nextendedKeyUsage=serverAuth\nkeyUsage=digitalSignature,keyEncipherment\n',{mode:0o600});
  await run('openssl',['req','-x509','-newkey','rsa:2048','-sha256','-nodes','-days','1','-config',config,'-keyout',key,'-out',cert],{timeout:15000,maxBuffer:65536});await chmod(key,0o600);
  await run('openssl',['x509','-in',cert,'-outform','DER','-out',der],{timeout:15000,maxBuffer:65536});
  await writeFile(input,JSON.stringify({phase,householdId,shopId,targetOperationId,packs,before,expectedMeal}),{mode:0o600});
  const user={id:owner.subject,email:'wire@example.invalid',email_confirmed_at:new Date().toISOString()};
  tls=createServer({key:await readFile(key),cert:await readFile(cert)},async(req,res)=>{
   if(!req.url.startsWith('/auth/v1/')){
    if(req.method==='POST'&&req.url.endsWith('/demand/operation-undo-candidates')){
     candidateAttempts++;observeNativeWireCommand(req,bytes=>candidateRequests.push(bytes));
    }
    if(req.method==='POST'&&req.url.endsWith('/demand/operation-undo-previews')){
     previewAttempts++;observeNativeWireCommand(req,bytes=>previewRequests.push(bytes));
    }
    if(req.method==='POST'&&req.url.endsWith('/commands')){
     attempts++;observeNativeWireCommand(req,bytes=>commands.push(bytes));
     try{if(beforeCommand)await beforeCommand(attempts);}
     catch{synchronizationFailed=true;res.writeHead(500,{'Content-Type':'application/json'});res.end(JSON.stringify({error:{code:'fixture_synchronization_failed'}}));return;}
     if(dropFirstReply&&attempts===1){const end=res.end.bind(res);res.end=(...args)=>{if(res.statusCode===200){dropped++;res.destroy();return res;}return end(...args);};}
    }
    res.once('finish',()=>{if(res.statusCode>=400)unsuccessful.push(req.method+' '+req.url.split('?')[0].replace(/[a-f\d-]{36}/gi,'{id}')+' '+res.statusCode);});
    service.emit('request',req,res);return;
   }
   res.setHeader('Content-Type','application/json');
   if(req.method==='POST'&&req.url==='/auth/v1/verify'){
    let raw='';for await(const chunk of req)raw+=chunk;
    if(JSON.parse(raw).token===code){res.end(JSON.stringify({access_token:owner.token,refresh_token:randomUUID(),expires_in:3600,user}));return;}
   }
   if(req.method==='GET'&&req.url==='/auth/v1/user'&&req.headers.authorization==='Bearer '+owner.token){res.end(JSON.stringify(user));return;}
   res.writeHead(401);res.end('{}');
  });
  await new Promise((resolve,reject)=>tls.once('error',reject).listen(0,'127.0.0.1',resolve));
  await runNativeWireTest({suite:'SharedMealNativeWireTests',method:'testSharedMealClientAgainstPostgres',scenario:scenario??('operation-undo-'+phase),unsuccessful,
   env:{RITC_WIRE_OPERATION_UNDO_PHASE:phase,RITC_WIRE_OPERATION_UNDO_FIXTURE:input,RITC_WIRE_OPERATION_UNDO_STATE:privateState,RITC_WIRE_OPERATION_UNDO_VAULT:owner.subject,
    RITC_WIRE_PORT:String(tls.address().port),RITC_WIRE_CERT:der,RITC_WIRE_CODE:code}});
  if(synchronizationFailed)throw new Error('Native wire synchronization failed');
  return{attempts,dropped,commands,candidateAttempts,candidateRequests,previewAttempts,previewRequests};
 }finally{if(tls?.listening)await new Promise(resolve=>tls.close(resolve));await rm(dir,{recursive:true,force:true});}
}
