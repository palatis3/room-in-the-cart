import {createHash} from 'node:crypto';
import {writeFile} from 'node:fs/promises';
import {join} from 'node:path';

const sha256 = bytes => createHash('sha256').update(bytes).digest('hex');

export async function captureFixture(directory, dumpSHA256, captured = Date.now()) {
  const captureManifestPath = join(directory,'source-manifest.json');
  const verifiedReceiptPath = join(directory,'verified.json');
  const timestamp = new Date(captured).toISOString();
  const manifest = JSON.stringify({project:'fixture',snapshotStartedAtOrBeforeExport:timestamp,sourceSnapshotReadOnly:true,
    verifiedTLS:true,hashes:{'full.dump':dumpSHA256}});
  const restore = {rowsAndCatalogMatched:true,rows:37,tables:8};
  const receipt = JSON.stringify({state:'verified',temporaryAccessRemoved:true,sources:{staging:{
    project:'fixture',sourceManifestSHA256:sha256(manifest),originalSnapshotUTC:timestamp,
    restoreCutoffUTC:new Date(captured + 720 * 3600000).toISOString(),sourceRestore:restore,downloadRestore:restore,
    privateStore:true,uncachedDownloadMatched:true,
  }}});
  await writeFile(captureManifestPath,manifest,{mode:0o600});
  await writeFile(verifiedReceiptPath,receipt,{mode:0o600});
  return {paths:{captureManifestPath,verifiedReceiptPath},pin:sha256(receipt)};
}
