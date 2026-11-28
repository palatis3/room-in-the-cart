import {execFileSync} from 'node:child_process';
import {randomBytes,randomUUID} from 'node:crypto';
import {mkdtemp,readFile,rm,writeFile} from 'node:fs/promises';
import {createServer} from 'node:https';
import {join} from 'node:path';
import {tmpdir} from 'node:os';
import {createHTTPSCommittedSource,sourceGatewayHandler} from '../dist/privacy-journal-source-https.js';

export async function startSourceGateway({pins,source,observer,authorityPublicKey,observeRequest,wrapHandler}){
 const databaseBinding=observer?{database:observer.connection.database,databaseOid:observer.databaseOid,observerRoleOid:observer.observerRoleOid}:
  {database:'fixture',databaseOid:'1',observerRoleOid:'2'};
 const directory=await mkdtemp(join(tmpdir(),'ritc-source-https-'));
 const config=join(directory,'tls.cnf'),key=join(directory,'key.pem'),cert=join(directory,'cert.pem');
 let server;
 try{
  await writeFile(config,'[req]\nprompt=no\ndistinguished_name=dn\nx509_extensions=ext\n[dn]\nCN=localhost\n[ext]\nbasicConstraints=critical,CA:TRUE\nsubjectAltName=IP:127.0.0.1\n');
  execFileSync('openssl',['req','-new','-x509','-nodes','-newkey','rsa:2048','-days','1','-config',config,'-keyout',key,'-out',cert],{stdio:'pipe',timeout:10_000});
  const ca=await readFile(cert,'utf8');
  const applicationToken=randomBytes(32).toString('base64url'),operationsToken=randomBytes(32).toString('base64url');
  let handler;
  if(observer){
   const config={pins,authorityPublicKey,applicationToken,operationsToken,observer};
   const prior=process.env.JOURNAL_SOURCE_GATEWAY_JSON;
   try{
    process.env.JOURNAL_SOURCE_GATEWAY_JSON=JSON.stringify(config);
    const entry=new URL('../../source-gateway-vercel/api/source.js',import.meta.url);
    entry.searchParams.set('fixture',randomUUID());
    handler=(await import(entry.href)).default;
   }finally{
    if(prior===undefined)delete process.env.JOURNAL_SOURCE_GATEWAY_JSON;
    else process.env.JOURNAL_SOURCE_GATEWAY_JSON=prior;
   }
  }else{
   handler=sourceGatewayHandler({pins,databaseBinding,source,applicationToken,operationsToken});
  }
  if(wrapHandler)handler=wrapHandler(handler);
  server=createServer({key:await readFile(key),cert:ca},(req,res)=>{observeRequest?.(req);return handler(req,res);});
  await new Promise((resolve,reject)=>{server.once('error',reject);server.listen(0,'127.0.0.1',resolve);});
  const origin='https://127.0.0.1:'+server.address().port;
  const client=createHTTPSCommittedSource({pins,databaseBinding,origin,ca,token:applicationToken});
  return {source:client.source,databaseBinding,ca,origin,applicationToken,operationsToken,async close(){
   await client.close();
   server.closeAllConnections();
   await new Promise(resolve=>server.close(resolve));
  }};
 }catch(error){server?.close();throw error;}
 finally{await rm(directory,{recursive:true,force:true});}
}
