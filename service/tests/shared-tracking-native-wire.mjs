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

// Identity provider and delivery interruption are fixtures; tracking responses and
// complete acknowledgments are observed from the actual service, never synthesized.
// Every household read/preview/command reaches the original authenticated API/PG path.
export async function exerciseTrackingClient({service,owner,householdId,shopId,phase,privateState,dropFirstReply=false,...fixture}){
 const dir=await mkdtemp(join(tmpdir(),'ritc-tracking-wire-tls-'));await chmod(dir,0o700);
 const key=join(dir,'tls.key'),cert=join(dir,'tls.pem'),der=join(dir,'tls.der'),config=join(dir,'openssl.cnf'),input=join(privateState,'phase-'+phase+'-'+randomUUID()+'.json'),code=randomUUID();
 let tls,attempts=0,dropped=0;const unsuccessful=[],commands=[],candidateRequests=[],previewRequests=[],candidateResponses=[],previewResponses=[];let candidateAttempts=0,previewAttempts=0,historyAttempts=0,catalogAttempts=0;const historyResponses=[],catalogResponses=[];
 try{
  await writeFile(config,'[req]\ndistinguished_name=dn\nx509_extensions=ext\nprompt=no\n[dn]\nCN=localhost\n[ext]\nsubjectAltName=IP:127.0.0.1\nextendedKeyUsage=serverAuth\nkeyUsage=digitalSignature,keyEncipherment\n',{mode:0o600});
  await run('openssl',['req','-x509','-newkey','rsa:2048','-sha256','-nodes','-days','1','-config',config,'-keyout',key,'-out',cert],{timeout:15000,maxBuffer:65536});await chmod(key,0o600);
  await run('openssl',['x509','-in',cert,'-outform','DER','-out',der],{timeout:15000,maxBuffer:65536});
  await writeFile(input,JSON.stringify({phase,householdId,shopId,...fixture}),{mode:0o600});
  const user={id:owner.subject,email:'wire@example.invalid',email_confirmed_at:new Date().toISOString()};
  tls=createServer({key:await readFile(key),cert:await readFile(cert)},async(req,res)=>{
   if(!req.url.startsWith('/auth/v1/')){
    const capture=(req.url.endsWith('/demand/tracking/candidates')||req.url.endsWith('/requests/operation-undo-candidates'))?candidateResponses:(req.url.endsWith('/demand/tracking/previews')||req.url.endsWith('/requests/operation-undo-previews'))?previewResponses:req.url.endsWith('/requests/operations')?historyResponses:req.url.endsWith('/demand/tracking/action-sources')?catalogResponses:null;
    if(req.method==='GET'&&req.url.endsWith('/requests/operations'))historyAttempts++;
    if(req.method==='POST'&&req.url.endsWith('/demand/tracking/action-sources'))catalogAttempts++;
    if(capture){const end=res.end.bind(res);res.end=(chunk,...args)=>{if(res.statusCode===200&&chunk){const bytes=Buffer.from(chunk);if(bytes.length>512*1024)throw new Error('tracking_wire_response_bound');capture.push(JSON.parse(bytes.toString()));}return end(chunk,...args);};}

    if(req.method==='POST'&&(req.url.endsWith('/demand/tracking/candidates')||req.url.endsWith('/requests/operation-undo-candidates'))){
     candidateAttempts++;observeNativeWireCommand(req,bytes=>candidateRequests.push(bytes));
    }
    if(req.method==='POST'&&(req.url.endsWith('/demand/tracking/previews')||req.url.endsWith('/requests/operation-undo-previews'))){
     previewAttempts++;observeNativeWireCommand(req,bytes=>previewRequests.push(bytes));
    }
    if(req.method==='POST'&&req.url.endsWith('/commands')){
     attempts++;observeNativeWireCommand(req,bytes=>commands.push(bytes));
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
  await runNativeWireTest({suite:'SharedMealNativeWireTests',method:'testSharedMealClientAgainstPostgres',scenario:'tracking-'+phase,unsuccessful,
   env:{RITC_WIRE_TRACKING_PHASE:phase,RITC_WIRE_TRACKING_FIXTURE:input,RITC_WIRE_TRACKING_STATE:privateState,RITC_WIRE_TRACKING_VAULT:owner.subject,
    RITC_WIRE_PORT:String(tls.address().port),RITC_WIRE_CERT:der,RITC_WIRE_CODE:code}});
  return{attempts,dropped,commands,candidateAttempts,candidateRequests,candidateResponses,previewAttempts,previewRequests,previewResponses,historyAttempts,historyResponses,catalogAttempts,catalogResponses};
 }finally{if(tls?.listening)await new Promise(resolve=>tls.close(resolve));await rm(dir,{recursive:true,force:true});}
}
