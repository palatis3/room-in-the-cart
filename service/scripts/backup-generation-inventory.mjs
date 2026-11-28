import {certifiedBackupExpiry,timestamp} from './backup-expiry.mjs';
import {createHash} from 'node:crypto';
import {constants} from 'node:fs';
import {lstat,open,readdir,unlink} from 'node:fs/promises';
import {dirname,join,relative,resolve,sep} from 'node:path';

const hash=bytes=>createHash('sha256').update(bytes).digest('hex');

// Entries come from independently pinned original verifier receipts. The original
// snapshot time belongs to the ciphertext and follows it to each registered location.
export function backupCutoff(entry,retirement) {
  const captured=timestamp(entry.originalSnapshotUTC);
  const cutoff=certifiedBackupExpiry(entry,captured);
  const provider=Date.parse(entry.providerExpiryUTC);
  if(!Number.isFinite(captured) || !Number.isFinite(provider) || provider<=captured || provider>cutoff ||
     !entry.privateStore || !entry.uncachedDownloadMatched ||
     entry.sourceRestore?.rowsAndCatalogMatched!==true || entry.downloadRestore?.rowsAndCatalogMatched!==true ||
     entry.sourceRestore.rows!==entry.downloadRestore.rows || entry.sourceRestore.tables!==entry.downloadRestore.tables ||
     entry.signedPutAllowsOverwrite!==false || !/^[0-9a-f]{64}$/.test(entry.ciphertextSHA256) ||
     !/^recovery\/[a-zA-Z0-9_./-]+$/.test(entry.pathname) || entry.pathname.split('/').some(x=>!x || x==='.' || x==='..') ||
     typeof entry.etag!=='string' || !entry.etag || !Number.isSafeInteger(entry.downloadedBytes) || entry.downloadedBytes<1) {
    throw Error('Original backup and restore evidence is incomplete');
  }
  if(!retirement)return cutoff;
  const removed=Date.parse(retirement.primaryNamespacesVerifiedAt);
  const limit=Date.parse(retirement.dates?.retireAllBy);
  if(typeof entry.project!=='string' || retirement.project!==entry.project || !Number.isFinite(removed) || !Number.isFinite(limit) || !retirement.sourceAndAuthorityRowsAbsent || !retirement.registeredExportsAbsent) {
    throw Error('Independent generation retirement receipt required');
  }
  // A capture begun before removal may include the generation. A later capture
  // of a stale restore is ineligible unless separately reconciled by its custodian.
  return captured<=removed ? Math.min(cutoff,limit) : cutoff;
}

async function names(adapter) {
  const paths=new Set(), cursors=new Set();
  let cursor;
  do {
    const page=await adapter.list(cursor);
    for(const item of page.blobs) {
      if(paths.has(item.pathname))throw Error('Unstable or duplicate inventory');
      paths.add(item.pathname);
    }
    if(!page.hasMore)break;
    if(!page.cursor || cursors.has(page.cursor))throw Error('Incomplete inventory pagination');
    cursor=page.cursor;cursors.add(cursor);
  } while(true);
  return paths;
}

// The custodian closes writers for the census. Unknown objects stop all removal.
// Each removal is conditional on the originally verified ETag and ends with an
// authenticated missing response plus a second complete enumeration.
export async function reconcileGenerations(adapter,generations,{remove=false,now=Date.now()}={}) {
  const entries=new Map();
  for(const generation of generations) {
    const {entry}=generation;
    const cutoffs=(generation.retirements??[]).map(receipt=>backupCutoff(entry,receipt));
    const cutoff=Math.min(backupCutoff(entry),...cutoffs);
    if(entries.has(entry.pathname) || Date.parse(entry.originalSnapshotUTC)>now)throw Error('Duplicate or future backup generation');
    entries.set(entry.pathname,{entry,cutoff:adapter.providerExpiry ? Math.min(cutoff,Date.parse(entry.providerExpiryUTC)) : cutoff});
  }
  const before=await names(adapter);
  for(const path of before)if(!entries.has(path))throw Error('Unknown backup generation');
  for(const [path,{entry,cutoff}] of entries) {
    const current=await adapter.head(path);
    if(!current) {
      if(before.has(path) || now<cutoff)throw Error('Unexpectedly missing recoverable backup');
      continue;
    }
    if(!before.has(path) || current.pathname!==path || current.etag!==entry.etag || current.size!==entry.downloadedBytes)throw Error('Backup identity changed');
  }
  if(remove)for(const [path,{entry,cutoff}] of entries) {
    if(before.has(path) && now>=cutoff)await adapter.deleteIfMatch(path,entry.etag);
  }
  const after=await names(adapter);let expiredPresent=0,expiredAbsent=0,retained=0;
  for(const path of after)if(!entries.has(path))throw Error('Concurrent unknown backup generation');
  for(const [path,{entry,cutoff}] of entries) {
    const current=await adapter.head(path);
    if(after.has(path)!==Boolean(current) || current && (current.pathname!==path || current.etag!==entry.etag || current.size!==entry.downloadedBytes)) {
      throw Error('Backup changed during reconciliation');
    }
    if(now>=cutoff) {
      if(current){if(remove)throw Error('Expired backup still present');expiredPresent++;}
      else expiredAbsent++;
    } else {
      if(!current)throw Error('Recoverable backup disappeared during reconciliation');
      if(current)retained++;
    }
  }
  return {catalogued:entries.size,retained,expiredPresent,expiredAbsent};
}

export function vercelPrivateStore(sdk,token,expectedStore) {
  if(typeof token!=='string' || !/^vercel_blob_rw_/.test(token) || !/^store_[A-Za-z0-9]+$/.test(expectedStore) ||
    token.split('_')[3]?.toLowerCase()!==expectedStore.slice(6).toLowerCase())throw Error('Private store identity conflict');
  const options=()=>({token,abortSignal:AbortSignal.timeout(12000)});
  return {
    providerExpiry:true,
    list:cursor=>sdk.list({...options(),limit:1000,...(cursor?{cursor}:{})}),
    async head(path) {
      try{return await sdk.head(path,options());}
      catch(error){if(error instanceof sdk.BlobNotFoundError)return null;throw error;}
    },
    deleteIfMatch:(path,etag)=>sdk.del(path,{...options(),ifMatch:etag}),
  };
}

// Local custody uses a dedicated root containing only registered ciphertexts.
// The complete tree is scanned, and hard links/symlinks cannot count as disposal.
export async function localBackupStore(root,entries,locations={}) {
  const rootStat=await lstat(root);
  if(!rootStat.isDirectory() || rootStat.uid!==process.getuid() || rootStat.mode&0o077)throw Error('Private local custody root required');
  const paths=new Map(entries.map(e=>[e.pathname,e]));
  const namesForFiles=new Map(entries.map(e=>[locations[e.pathname]??e.pathname,e.pathname]));
  if(namesForFiles.size!==entries.length)throw Error('Duplicate local backup location');
  const local=path=>{
    const out=resolve(root,locations[path]??path),inside=relative(root,out);
    if(!inside || inside.startsWith('..'+sep) || inside==='..')throw Error('Invalid custody path');
    return out;
  };
  async function head(path) {
    let file;
    try {file=await open(local(path),constants.O_RDONLY|constants.O_NOFOLLOW);}
    catch(error){if(error.code==='ENOENT')return null;throw error;}
    try {
      const before=await file.stat();
      if(!before.isFile() || before.nlink!==1 || before.uid!==process.getuid() || before.mode&0o077)throw Error('Unsafe local backup');
      const h=createHash('sha256');
      for await(const bytes of file.createReadStream({autoClose:false}))h.update(bytes);
      const after=await file.stat(),entry=paths.get(path);
      if(!entry || before.ino!==after.ino || before.ctimeMs!==after.ctimeMs || h.digest('hex')!==entry.ciphertextSHA256)throw Error('Local backup ciphertext changed');
      return {pathname:path,etag:entry.etag,size:after.size,ino:after.ino,ctime:after.ctimeMs};
    } finally {await file.close();}
  }
  return {
    async list() {
      const pending=[root],blobs=[];
      while(pending.length)for(const item of await readdir(pending.pop(),{withFileTypes:true})) {
        const path=join(item.parentPath,item.name);
        if(item.isDirectory())pending.push(path);
        else if(item.isFile())blobs.push({pathname:namesForFiles.get(relative(root,path))??'unregistered-local-file'});
        else throw Error('Unknown custody object type');
      }
      return {blobs,hasMore:false};
    },
    head,
    async deleteIfMatch(path,etag) {
      const current=await head(path),file=local(path),actual=await lstat(file);
      if(!current || current.etag!==etag || actual.ino!==current.ino || actual.ctimeMs!==current.ctime || actual.nlink!==1)throw Error('Local backup changed');
      await unlink(file);
      const parent=await open(dirname(file),constants.O_RDONLY|constants.O_NOFOLLOW);
      try{await parent.sync();}finally{await parent.close();}
    }
  };
}

export const receiptFingerprint=hash;
