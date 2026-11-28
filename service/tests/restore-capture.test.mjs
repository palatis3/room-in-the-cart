import test from 'node:test';
import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {mkdtemp, readFile, rename, rm, writeFile} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {assertCaptureCurrent,replayExpiry,restoreCapture} from '../scripts/restore-capture.mjs';
import {captureFixture} from './restore-capture-fixture.mjs';

const windowMs=720 * 3600000;
const dump='a'.repeat(64);

test('capture eligibility expires at exactly 720 hours, including between replay and gate',()=>{
  const captured=1000;
  assert.doesNotThrow(()=>assertCaptureCurrent(captured,captured));
  assert.doesNotThrow(()=>assertCaptureCurrent(captured,captured+windowMs-1));
  assert.throws(()=>assertCaptureCurrent(captured,captured+windowMs),/quarantine/);
  assert.throws(()=>assertCaptureCurrent(captured,captured-1),/quarantine/);
});

test('a copied dump needs the independent original receipt and cannot refresh it by replacing either file',async t=>{
  const dir=await mkdtemp(join(tmpdir(),'ritc-capture-'));
  t.after(()=>rm(dir,{recursive:true}));
  const captured=Date.now()-60000;
  const {paths,pin}=await captureFixture(dir,dump,captured);
  assert.equal(await restoreCapture(paths,dump,pin),captured);
  await assert.rejects(restoreCapture(paths,dump,undefined),/receipt digest/);
  await assert.rejects(restoreCapture(paths,'b'.repeat(64),pin),/dump binding/);
  const originalReceipt=await readFile(paths.verifiedReceiptPath);
  const manifest=JSON.parse(await readFile(paths.captureManifestPath));
  manifest.snapshotStartedAtOrBeforeExport=new Date().toISOString();
  await writeFile(join(dir,'concurrent-manifest.json'),JSON.stringify(manifest),{mode:0o600});
  await rename(join(dir,'concurrent-manifest.json'),paths.captureManifestPath);
  await assert.rejects(restoreCapture(paths,dump,pin),/verified source/);
  const changed=JSON.parse(originalReceipt);
  changed.sources.staging.sourceManifestSHA256=createHash('sha256').update(JSON.stringify(manifest)).digest('hex');
  await writeFile(paths.verifiedReceiptPath,JSON.stringify(changed));
  await assert.rejects(restoreCapture(paths,dump,pin),/receipt pin/);
  const stale=await captureFixture(dir,dump,Date.now()-windowMs-1000);
  await assert.rejects(restoreCapture(stale.paths,dump,stale.pin),/quarantine/);
});

test('the earliest original intent bounds every copy even when it rolled back or committed after a newer intent',()=>{
  const now=Date.now(), earlier=now - 90 * 86400000;
  function record(kind,jobId,at) {
    return {kind,event:{payload:{jobId,kind:'acceptance',data:{acceptedAt:new Date(at+20).toISOString(),
      attestation:{checkedAt:new Date(at).toISOString()}}}}};
  }
  const records=[record('intent','older',earlier),record('intent','newer',now-300),
    record('commit','newer',now-300),record('rollback','older',earlier)];
  assert.equal(replayExpiry(records,now),now);
  assert.equal(replayExpiry(structuredClone(records),now+1000),now);
  assert.equal(replayExpiry([],now),Infinity);
  assert.throws(()=>replayExpiry([records[2]],now),/Original replay capture/);
  assert.throws(()=>replayExpiry([record('intent','future',now+1)],now),/Future/);
});
