import {createHash} from 'node:crypto';
import {readPrivateFile} from './journal-authority-config.mjs';

const day = 24 * 60 * 60 * 1000;
const sha256 = bytes => createHash('sha256').update(bytes).digest('hex');

function timestamp(value) {
  const match = typeof value === 'string' && /^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})(?:\.\d{1,6})?(?:Z|[+-]\d{2}:\d{2})$/.exec(value);
  const millis = match ? Date.parse(value) : NaN;
  // Check the calendar part in its own zone before converting an explicit offset.
  const calendar = match ? Date.parse(match[1] + 'Z') : NaN;
  if (!Number.isFinite(millis) || !Number.isFinite(calendar) || new Date(calendar).toISOString().slice(0,19) !== match[1]) {
    throw Error('An original capture time with a valid offset is required');
  }
  return millis;
}

export function assertCaptureCurrent(captured, now = Date.now()) {
  if (!Number.isFinite(captured) || now < captured || now >= captured + 30 * day) {
    throw Error('Backup is outside the original 720-hour recovery window; keep quarantine closed');
  }
}

// The receipt digest comes from the custodian independently of the restore inputs.
// The original manifest binds source time to the actual dump bytes, even after copying.
export async function restoreCapture(paths, dumpDigest, receiptPin) {
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
  if (timestamp(source.restoreCutoffUTC) !== captured + 30 * day) throw Error('Verified backup recovery cutoff conflict');
  assertCaptureCurrent(captured);
  return captured;
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
