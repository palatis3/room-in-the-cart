// Operator-only. The live application and maintenance service never call this CLI.
import {createRequire} from 'node:module';
import {resolve} from 'node:path';
import {z} from 'zod';
import {readPrivateFile} from './journal-authority-config.mjs';
import {localBackupStore,receiptFingerprint,reconcileGenerations,vercelPrivateStore} from './backup-generation-inventory.mjs';

const pin=z.string().regex(/^[0-9a-f]{64}$/);
const artifact=z.object({path:z.string().min(1),sha256:pin}).strict();
const settings=z.object({
  sources:z.array(z.object({receipt:artifact,environment:z.enum(['staging','production']),retirements:z.array(artifact).default([]),
    localPath:z.string().min(1).optional()}).strict()).min(1),
  store:z.discriminatedUnion('type',[
    z.object({type:z.literal('private-blob'),storeId:z.string(),sdkDirectory:z.string()}).strict(),
    z.object({type:z.literal('local'),directory:z.string()}).strict(),
  ]),
}).strict();
async function read(ref) {
  const bytes=await readPrivateFile(ref.path,1024*1024);
  if(receiptFingerprint(bytes)!==ref.sha256)throw Error('Independent inventory evidence pin conflict');
  return JSON.parse(bytes);
}
try {
  const [command,config]=process.argv.slice(2);
  if(!['audit','retire'].includes(command) || process.argv.length!==4)throw Error('Use audit or retire with a scoped inventory');
  const inputs=settings.parse(await read({path:config,sha256:pin.parse(process.env.RITC_BACKUP_INVENTORY_SHA256)}));
  const generations=[],locations={};
  for(const source of inputs.sources) {
    const verified=await read(source.receipt);
    if(verified.state!=='verified' || verified.temporaryAccessRemoved!==true)throw Error('Recovery proof incomplete');
    const entry=verified.sources?.[source.environment];
    if(!entry)throw Error('No original backup');
    const retirements=await Promise.all(source.retirements.map(read));
    generations.push({entry,retirements});
    if(source.localPath)locations[entry.pathname]=source.localPath;
  }
  let adapter;
  if(inputs.store.type==='private-blob') {
    // The attended operator already pins @vercel/blob 2.9.0 in this private kit.
    const require=createRequire(resolve(inputs.store.sdkDirectory,'package.json'));
    adapter=vercelPrivateStore(require('@vercel/blob'),process.env.BLOB_READ_WRITE_TOKEN,inputs.store.storeId);
  } else {
    adapter=await localBackupStore(inputs.store.directory,generations.map(g=>g.entry),locations);
  }
  const result=await reconcileGenerations(adapter,generations,{remove:command==='retire'});
  console.log(JSON.stringify({event:'scoped_backup_inventory',...result,otherStoresVerified:false}));
} catch {console.error(JSON.stringify({event:'backup_inventory_refused'}));process.exitCode=1;}
