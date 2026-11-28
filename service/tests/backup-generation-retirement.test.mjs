import test from 'node:test';
import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {link,mkdtemp,readFile,rm,writeFile} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {backupCutoff,localBackupStore,reconcileGenerations,vercelPrivateStore} from '../scripts/backup-generation-inventory.mjs';
import {retentionDates} from '../scripts/retirement-custody.mjs';

const day=86400000,first=Date.UTC(2026,0,1),now=first+90*day;
const iso=at=>new Date(at).toISOString();
const verified={rowsAndCatalogMatched:true,rows:41,tables:8};
const data=Buffer.from('Disposable encrypted-object substitute');
function generation(name,captured) {
  return {entry:{project:'fixture',pathname:'recovery/'+name+'.dmg',etag:'fixed-'+name,downloadedBytes:data.length,
    ciphertextSHA256:createHash('sha256').update(data).digest('hex'),originalSnapshotUTC:iso(captured),
    restoreCutoffUTC:iso(captured+30*day),providerExpiryUTC:iso(captured+30*day),
    sourceRestore:verified,downloadRestore:verified,signedPutAllowsOverwrite:false,privateStore:true,uncachedDownloadMatched:true}};
}

test('a late online retirement shortens the final backup horizon; verified clean captures retain their own 30 days',()=>{
  const late=generation('late',first+75*day),clean=generation('clean',first+77*day);
  const retirement={project:'fixture',dates:retentionDates(first),primaryNamespacesVerifiedAt:iso(first+76*day),sourceAndAuthorityRowsAbsent:true,registeredExportsAbsent:true};
  assert.equal(backupCutoff(late.entry,retirement),now);
  assert.equal(backupCutoff(clean.entry,retirement),first+107*day);
  assert.throws(()=>backupCutoff(late.entry,{...retirement,registeredExportsAbsent:false}),/retirement receipt/);
});

test('named local ciphertexts are removed only after a full inventory and exact digest check',async t=>{
  const root=await mkdtemp(join(tmpdir(),'ritc-backup-retire-'));
  t.after(()=>rm(root,{recursive:true,force:true}));
  const old=generation('one',now-30*day),fresh=generation('two',now-2*day),copies=[old,fresh];
  const paths={[old.entry.pathname]:'one.dmg',[fresh.entry.pathname]:'two.dmg'};
  for(const name of Object.values(paths))await writeFile(join(root,name),data,{mode:0o600});
  const adapter=await localBackupStore(root,copies.map(x=>x.entry),paths);
  await link(join(root,'one.dmg'),join(root,'unmapped-copy'));
  await assert.rejects(reconcileGenerations(adapter,copies,{remove:true,now}),/Unknown backup generation/);
  assert.deepEqual(await readFile(join(root,'one.dmg')),data);
  await rm(join(root,'unmapped-copy'));
  assert.deepEqual(await reconcileGenerations(adapter,copies,{now}),{catalogued:2,retained:1,expiredPresent:1,expiredAbsent:0});
  assert.deepEqual(await reconcileGenerations(adapter,copies,{remove:true,now}),{catalogued:2,retained:1,expiredPresent:0,expiredAbsent:1});
  assert.deepEqual(await readFile(join(root,'two.dmg')),data);
  assert.equal((await reconcileGenerations(adapter,copies,{remove:true,now})).expiredAbsent,1);
});

test('a private-store adapter paginates, checks conditional deletion, and requires authenticated absence',async()=>{
  const old=generation('old',now-30*day),fresh=generation('fresh',now-day),copies=[old,fresh];
  const rows=new Map(copies.map(({entry})=>[entry.pathname,{pathname:entry.pathname,etag:entry.etag,size:entry.downloadedBytes}]));
  class Missing extends Error {}
  let conflict=true,after=false;
  const sdk={BlobNotFoundError:Missing,
    async list(options) {
      const values=[...rows.values()].sort((a,b)=>a.pathname.localeCompare(b.pathname));
      if(!options.cursor && values.length>1)return {blobs:values.slice(0,1),hasMore:true,cursor:'next'};
      return {blobs:options.cursor?values.slice(1):values,hasMore:false};
    },
    async head(path){if(!rows.has(path)){if(after)throw Error('credential revoked');throw new Missing();}return rows.get(path);},
    async del(path,{ifMatch}){assert.equal(path,old.entry.pathname);assert.equal(ifMatch,old.entry.etag);if(conflict)throw Error('precondition failed');rows.delete(path);},
  };
  const adapter=vercelPrivateStore(sdk,'vercel_blob_rw_fixture_opaque','store_fixture');
  await assert.rejects(reconcileGenerations(adapter,copies,{remove:true,now}),/precondition/);
  conflict=false;after=true;
  await assert.rejects(reconcileGenerations(adapter,copies,{remove:true,now}),/credential revoked/);
  after=false;
  assert.deepEqual(await reconcileGenerations(adapter,copies,{remove:true,now}),{catalogued:2,retained:1,expiredPresent:0,expiredAbsent:1});
});
