import {certifiedBackupExpiry} from '../scripts/backup-expiry.mjs';
import test from 'node:test';
import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {mkdtemp, readFile, rename, rm, writeFile} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {assertCaptureCurrent,replayExpiry,restoreCapture,restoreCaptureProof} from '../scripts/restore-capture.mjs';
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

test('a shortened recovery receipt binds its 087+ scope, both restores, and the signed cutoff',async t=>{
  const dir=await mkdtemp(join(tmpdir(),'ritc-tight-cap-'));
  t.after(()=>rm(dir,{recursive:true}));
  const captured=Date.now()-86400000,expires=captured+2*86400000;
  const fixture=await captureFixture(dir,dump,captured,{version:89,expires});
  const proof=await restoreCaptureProof(fixture.paths,dump,fixture.pin);
  assert.deepEqual(proof,{captured,expires,project:'fixture'});
  assert.doesNotThrow(()=>assertCaptureCurrent(captured,expires-1,proof.expires));
  assert.throws(()=>assertCaptureCurrent(captured,expires,proof.expires),/verified recovery window/);
  const receipt=JSON.parse(await readFile(fixture.paths.verifiedReceiptPath));
  const source=receipt.sources.staging;
  const manifest=JSON.parse(await readFile(fixture.paths.captureManifestPath));
  assert.equal(certifiedBackupExpiry(source,captured,manifest),expires);
  const maximum=new Date(captured+windowMs).toISOString();
  assert.equal(certifiedBackupExpiry({...source,restoreCutoffUTC:maximum,journalRetentionCutoffUTC:maximum},captured,manifest),captured+windowMs);
  for(const invalid of [
    {...source,migrationFilesMatchedToCommit:86},
    {...source,journalRetentionCutoffUTC:undefined},
    {...source,scopeManifestSHA256:'0'.repeat(64)},
    {...source,downloadRestore:{...source.downloadRestore,registryCount:88}},
    {...source,journalRetentionCutoffUTC:maximum},
    {...source,restoreCutoffUTC:new Date(captured+windowMs+1).toISOString(),journalRetentionCutoffUTC:new Date(captured+windowMs+1).toISOString()},
    {...source,restoreCutoffUTC:new Date(captured).toISOString(),journalRetentionCutoffUTC:new Date(captured).toISOString()},
  ])assert.throws(()=>certifiedBackupExpiry(invalid,captured,manifest),/cutoff conflict/);
  assert.equal(certifiedBackupExpiry({restoreCutoffUTC:maximum,migrationFilesMatchedToCommit:86},captured),captured+windowMs);
  assert.throws(()=>certifiedBackupExpiry({restoreCutoffUTC:new Date(expires).toISOString(),migrationFilesMatchedToCommit:86},captured),/cutoff conflict/);
});
