import {createPrivateKey,createPublicKey,randomUUID} from 'node:crypto';
import {constants} from 'node:fs';
import {link,lstat,open,unlink} from 'node:fs/promises';
import {join} from 'node:path';
import {z} from 'zod';
import {PrivacyCall} from '../dist/privacy-call.js';
import {journalCanonical,journalHash} from '../dist/privacy-journal.js';
import {MAX_JOURNAL_BYTES} from '../dist/privacy-journal-limits.js';
import {activateIndependentSuccessor,createIndependentRecovery,exportIndependentRecovery,registerIndependentSuccessor,verifyIndependentArchiveWindow} from '../dist/privacy-journal-recovery.js';
import {journalDatabase,journalDatabaseSchema,readPrivateFile} from './journal-authority-config.mjs';
import {jsonFile,publicKey,publicPins,readArchives,windowSettings} from './journal-archive-window.mjs';

const endpoint=z.object({connection:journalDatabaseSchema,databaseOid:z.string(),ownerOid:z.string()}).strict();
const settings=z.object({pins:z.unknown(),writerPrivateKey:z.string().min(1).max(8192),authorityPrivateKey:z.string().min(1).max(8192),
 source:endpoint,checkpoint:endpoint,exportDirectory:z.string().min(1)}).strict();
const exportSettings=z.object({pins:z.unknown(),writerPublicKey:publicKey,authorityPublicKey:publicKey,
 checkpoint:endpoint,sourceDatabaseOid:z.string(),exportDirectory:z.string().min(1),includeSuccessor:z.boolean().optional()}).strict();
const linkSettings=exportSettings.omit({authorityPublicKey:true,includeSuccessor:true}).extend({
 authorityPrivateKey:z.string().max(8192).regex(/^-----BEGIN PRIVATE KEY-----\r?\n/),successor:publicPins,
});
const activationSettings=publicPins.extend({source:endpoint,checkpoint:endpoint,successor:z.unknown()}).strict();

async function writeExact(path,bytes){
 const temporary=path+'.'+randomUUID()+'.pending';
 const file=await open(temporary,constants.O_WRONLY|constants.O_CREAT|constants.O_EXCL|constants.O_NOFOLLOW,0o600);
 try{
  try{await file.writeFile(bytes);await file.sync();}finally{await file.close();}
  try{await link(temporary,path);}catch(error){
   if(error.code!=='EEXIST'||!(await readPrivateFile(path,MAX_JOURNAL_BYTES)).equals(bytes))throw error;
  }
 }finally{await unlink(temporary);}
}
async function syncDirectory(path){
 const handle=await open(path,constants.O_RDONLY|constants.O_NOFOLLOW);
 try{await handle.sync();}finally{await handle.close();}
}
async function run(){
 const [command,configPath]=process.argv.slice(2);
 if(!['fence','recover','seal-for-rollover','export','link','activate','verify-window'].includes(command)||process.argv.length!==4)
  throw Error('Use fence, recover, seal-for-rollover, export, link, activate or verify-window with an owner configuration');
 const input=await jsonFile(configPath);
 if(command==='verify-window'){
  const {segments,...trust}=windowSettings.parse(input);
  const verified=await verifyIndependentArchiveWindow(readArchives(segments),trust);
  console.log(JSON.stringify({event:'journal_archive_window_verified',...verified}));
  return;
 }
 const endpoints=[];
 const connect=endpoint=>{
  const pool=journalDatabase(endpoint.connection,'ritc-journal-recovery');endpoints.push(pool);
  return {pool,identity:{database:endpoint.connection.database,databaseOid:endpoint.databaseOid,
   owner:endpoint.connection.user,ownerOid:endpoint.ownerOid}};
 };
 const scope=new PrivacyCall(undefined,25000);
 try{
  if(command==='activate'){
   const config=activationSettings.parse(input);
   const result=await scope.run(call=>activateIndependentSuccessor({
    pins:config.pins,writerPublicKey:createPublicKey(config.writerPublicKey),authorityPublicKey:createPublicKey(config.authorityPublicKey),
    source:connect(config.source),checkpoint:connect(config.checkpoint),successor:config.successor,
   },call));
   console.log(JSON.stringify({event:'journal_successor_activated',...result}));
   return;
  }
  const config=(command==='link'?linkSettings:command==='export'?exportSettings:settings).parse(input);
  const directory=await lstat(config.exportDirectory);
  if(!directory.isDirectory()||directory.isSymbolicLink()||directory.uid!==process.getuid?.()||(directory.mode&0o077)!==0)throw Error('Owner-only recovery export directory required');
  const checkpoint=connect(config.checkpoint);
  if(command==='link'){
   const proof=await scope.run(call=>registerIndependentSuccessor({
    pins:config.pins,writerPublicKey:createPublicKey(config.writerPublicKey),authorityPrivateKey:createPrivateKey(config.authorityPrivateKey),
    sourceDatabaseOid:config.sourceDatabaseOid,checkpoint,successor:{
     pins:config.successor.pins,writerPublicKey:createPublicKey(config.successor.writerPublicKey),
     authorityPublicKey:createPublicKey(config.successor.authorityPublicKey),
    },
   },call));
   await writeExact(join(config.exportDirectory,'successor.json'),Buffer.from(journalCanonical(proof)+'\n'));
   await syncDirectory(config.exportDirectory);
   console.log(JSON.stringify({event:'journal_successor_registered',predecessorSealDigest:proof.predecessorSealDigest,
    successorScopeDigest:proof.successorScopeDigest}));
   return;
  }
  let archive;
  if(command==='export'){
   archive=await scope.run(call=>exportIndependentRecovery({pins:config.pins,sourceDatabaseOid:config.sourceDatabaseOid,checkpoint,
    writerPublicKey:createPublicKey(config.writerPublicKey),authorityPublicKey:createPublicKey(config.authorityPublicKey),
    includeSuccessor:config.includeSuccessor},call));
  }else{
   const operator=createIndependentRecovery({pins:config.pins,writerPrivateKey:createPrivateKey(config.writerPrivateKey),
    authorityPrivateKey:createPrivateKey(config.authorityPrivateKey),source:connect(config.source),checkpoint});
   if(command==='fence'){
    await scope.run(operator.fence);console.log(JSON.stringify({event:'journal_recovery_fenced'}));return;
   }
   archive=await scope.run(command==='seal-for-rollover'?operator.sealForRollover:operator.recover);
  }
  const {bytes,proof}=archive;
  await writeExact(join(config.exportDirectory,'journal.ndjson'),bytes);
  await writeExact(join(config.exportDirectory,'head.json'),Buffer.from(journalCanonical(proof.head)+'\n'));
  await writeExact(join(config.exportDirectory,'seal.json'),Buffer.from(journalCanonical(proof)+'\n'));
  if(archive.successor)await writeExact(join(config.exportDirectory,'successor.json'),Buffer.from(journalCanonical(archive.successor)+'\n'));
  await syncDirectory(config.exportDirectory);
  console.log(JSON.stringify({event:'journal_recovery_exported',sequence:proof.head.seq,bundleDigest:proof.bundleDigest,sealDigest:journalHash(proof)}));
 }finally{scope.dispose();await Promise.all(endpoints.map(pool=>pool.end()));}
}

try{await run();}
catch{console.error(JSON.stringify({event:'journal_recovery_action_failed'}));process.exitCode=1;}
