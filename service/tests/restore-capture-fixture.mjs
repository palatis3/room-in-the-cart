import {createHash} from 'node:crypto';
import {writeFile} from 'node:fs/promises';
import {join} from 'node:path';

const sha256 = bytes => createHash('sha256').update(bytes).digest('hex');

export async function captureFixture(directory, dumpSHA256, captured = Date.now(), versioned) {
  const captureManifestPath = join(directory,'source-manifest.json');
  const verifiedReceiptPath = join(directory,'verified.json');
  const timestamp = new Date(captured).toISOString();
  const scope='c'.repeat(64);
  const schema=versioned ? {throughMigration:versioned.version,scopeManifestSHA256:scope} : {};
  const manifest = JSON.stringify({...schema,project:'fixture',snapshotStartedAtOrBeforeExport:timestamp,sourceSnapshotReadOnly:true,
    verifiedTLS:true,hashes:{'full.dump':dumpSHA256}});
  const restore = {rowsAndCatalogMatched:true,rows:37,tables:8,...(versioned?{registryCount:versioned.version}:{})};
  const cutoff=new Date(versioned?.expires??(captured+720*3600000)).toISOString();
  const receipt = JSON.stringify({state:'verified',temporaryAccessRemoved:true,sources:{staging:{
    project:'fixture',sourceManifestSHA256:sha256(manifest),originalSnapshotUTC:timestamp,
    restoreCutoffUTC:cutoff,...(versioned ? {journalRetentionCutoffUTC:cutoff,migrationFilesMatchedToCommit:versioned.version,scopeManifestSHA256:scope} : {}),sourceRestore:restore,downloadRestore:restore,
    privateStore:true,uncachedDownloadMatched:true,
  }}});
  await writeFile(captureManifestPath,manifest,{mode:0o600});
  await writeFile(verifiedReceiptPath,receipt,{mode:0o600});
  return {paths:{captureManifestPath,verifiedReceiptPath},pin:sha256(receipt)};
}
