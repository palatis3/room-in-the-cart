import {certifiedBackupExpiry, timestamp} from './backup-expiry.mjs';
import {createHash} from 'node:crypto';
import {readPrivateFile} from './journal-authority-config.mjs';

const day = 24 * 60 * 60 * 1000;
const sha256 = bytes => createHash('sha256').update(bytes).digest('hex');

export function assertCaptureCurrent(captured, now = Date.now(), expires = captured + 30 * day) {
  if (!Number.isFinite(captured) || !Number.isFinite(expires) || expires > captured + 30 * day || now < captured || now >= expires) {
    throw Error('Backup is outside its verified recovery window (maximum 720 hours); keep quarantine closed');
  }
}

// The receipt digest comes from the custodian independently of the restore inputs.
// The original manifest binds source time to the actual dump bytes, even after copying.
export async function restoreCaptureProof(paths, dumpDigest, receiptPin) {
  if (!/^[0-9a-f]{64}$/.test(receiptPin ?? '')) throw Error('Independent verified backup receipt digest required');
  const receiptBytes = await readPrivateFile(paths.verifiedReceiptPath, 1024 * 1024);
  if (sha256(receiptBytes) !== receiptPin) throw Error('Verified backup receipt pin conflict');
  const receipt = JSON.parse(receiptBytes);
  const manifestBytes = await readPrivateFile(paths.captureManifestPath, 1024 * 1024);
  const manifestDigest = sha256(manifestBytes);
  const manifest = JSON.parse(manifestBytes);
  const entries = Object.values(receipt.sources ?? {}).filter(source => source?.sourceManifestSHA256 === manifestDigest);
  if (receipt.state !== 'verified' || receipt.temporaryAccessRemoved !== true || entries.length !== 1) {
    throw Error('No unique verified source backup');
  }
  const source = entries[0];
  if (source.sourceRestore?.rowsAndCatalogMatched !== true || source.downloadRestore?.rowsAndCatalogMatched !== true ||
      source.sourceRestore.rows !== source.downloadRestore.rows || source.sourceRestore.tables !== source.downloadRestore.tables ||
      source.uncachedDownloadMatched !== true || source.privateStore !== true ||
      typeof source.project !== 'string' || source.project !== manifest.project || manifest.sourceSnapshotReadOnly !== true ||
      manifest.verifiedTLS !== true || ![manifest.hashes?.['full.dump'],manifest.hashes?.['selected.dump']].includes(dumpDigest) ||
      source.originalSnapshotUTC !== manifest.snapshotStartedAtOrBeforeExport) {
    throw Error('Backup verification, original capture or dump binding conflict');
  }
  const captured = timestamp(source.originalSnapshotUTC);
  const expires=certifiedBackupExpiry(source,captured,manifest);
  assertCaptureCurrent(captured,Date.now(),expires);
  return {captured,expires,project:source.project};
}

export async function restoreCapture(paths,dumpDigest,receiptPin) {
  return (await restoreCaptureProof(paths,dumpDigest,receiptPin)).captured;
}

// Use the signed acceptance intent, including a subsequently rolled-back intent.
// Its service attestation precedes the SQL snapshot of effects and target preimages.
export function replayExpiry(records, now = Date.now()) {
  const capturedJobs = new Set();
  let expires = Infinity;
  for (const {kind,event:{payload}} of records) {
    if (kind === 'intent' && payload.kind === 'acceptance') {
      const checked = timestamp(payload.data.attestation?.checkedAt);
      const accepted = timestamp(payload.data.acceptedAt);
      if (checked > now || accepted > now) throw Error('Future replay capture; keep quarantine closed');
      expires = Math.min(expires, Math.min(checked,accepted) + 90 * day);
      capturedJobs.add(payload.jobId);
    }
    if (!capturedJobs.has(payload.jobId)) throw Error('Original replay capture unavailable; keep quarantine closed');
  }
  return expires;
}
