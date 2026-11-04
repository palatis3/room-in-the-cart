import {createPrivateKey,createPublicKey,randomUUID} from 'node:crypto';
import {constants} from 'node:fs';
import {link,lstat,open,unlink} from 'node:fs/promises';
import {join} from 'node:path';
import {z} from 'zod';
import {PrivacyCall} from '../dist/privacy-call.js';
import {journalCanonical} from '../dist/privacy-journal.js';
import {createIndependentRecovery,exportIndependentRecovery} from '../dist/privacy-journal-recovery.js';
import {journalDatabase,journalDatabaseSchema,readPrivateFile} from './journal-authority-config.mjs';

const endpoint=z.object({connection:journalDatabaseSchema,databaseOid:z.string(),ownerOid:z.string()}).strict();
const settings=z.object({pins:z.unknown(),writerPrivateKey:z.string().min(1).max(8192),authorityPrivateKey:z.string().min(1).max(8192),
 source:endpoint,checkpoint:endpoint,exportDirectory:z.string().min(1)}).strict();
const publicKey=z.string().max(8192).regex(/^-----BEGIN PUBLIC KEY-----\r?\n/);
const exportSettings=z.object({pins:z.unknown(),writerPublicKey:publicKey,authorityPublicKey:publicKey,
 checkpoint:endpoint,sourceDatabaseOid:z.string(),exportDirectory:z.string().min(1)}).strict();

async function writeExact(path,bytes){
 const temporary=path+'.'+randomUUID()+'.pending';
 const file=await open(temporary,constants.O_WRONLY|constants.O_CREAT|constants.O_EXCL|constants.O_NOFOLLOW,0o600);
 try{
  try{await file.writeFile(bytes);await file.sync();}finally{await file.close();}
  try{await link(temporary,path);}catch(error){
   if(error.code!=='EEXIST'||!(await readPrivateFile(path,32*1024*1024)).equals(bytes))throw error;
  }
 }finally{await unlink(temporary);}
}
async function run(){
 const [command,configPath]=process.argv.slice(2);
 if(!['fence','recover','export'].includes(command)||process.argv.length!==4)throw Error('Use fence, recover or export with an owner configuration');
 const config=(command==='export'?exportSettings:settings).parse(JSON.parse(await readPrivateFile(configPath,1048576)));
 const directory=await lstat(config.exportDirectory);
 if(!directory.isDirectory()||directory.isSymbolicLink()||directory.uid!==process.getuid?.()||(directory.mode&0o077)!==0)throw Error('Owner-only recovery export directory required');
 const endpoints=[];
 const connect=endpoint=>{
  const pool=journalDatabase(endpoint.connection,'ritc-journal-recovery');endpoints.push(pool);
  return {pool,identity:{database:endpoint.connection.database,databaseOid:endpoint.databaseOid,
   owner:endpoint.connection.user,ownerOid:endpoint.ownerOid}};
 };
 const scope=new PrivacyCall(undefined,25000);
 try{
  const checkpoint=connect(config.checkpoint);
  let archive;
  if(command==='export'){
   archive=await scope.run(call=>exportIndependentRecovery({pins:config.pins,sourceDatabaseOid:config.sourceDatabaseOid,checkpoint,
    writerPublicKey:createPublicKey(config.writerPublicKey),authorityPublicKey:createPublicKey(config.authorityPublicKey)},call));
  }else{
   const operator=createIndependentRecovery({pins:config.pins,writerPrivateKey:createPrivateKey(config.writerPrivateKey),
    authorityPrivateKey:createPrivateKey(config.authorityPrivateKey),source:connect(config.source),checkpoint});
   if(command==='fence'){
    await scope.run(operator.fence);console.log(JSON.stringify({event:'journal_recovery_fenced'}));return;
   }
   archive=await scope.run(operator.recover);
  }
  const {bytes,proof}=archive;
  await writeExact(join(config.exportDirectory,'journal.ndjson'),bytes);
  await writeExact(join(config.exportDirectory,'head.json'),Buffer.from(journalCanonical(proof.head)+'\n'));
  await writeExact(join(config.exportDirectory,'seal.json'),Buffer.from(journalCanonical(proof)+'\n'));
  const handle=await open(config.exportDirectory,constants.O_RDONLY|constants.O_NOFOLLOW);
  try{await handle.sync();}finally{await handle.close();}
  console.log(JSON.stringify({event:'journal_recovery_exported',sequence:proof.head.seq,bundleDigest:proof.bundleDigest}));
 }finally{scope.dispose();await Promise.all(endpoints.map(pool=>pool.end()));}
}

try{await run();}
catch{console.error(JSON.stringify({event:'journal_recovery_action_failed'}));process.exitCode=1;}
