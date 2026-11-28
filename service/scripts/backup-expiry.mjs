export function timestamp(value) {
  const match = typeof value === 'string' && /^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})(?:\.\d{1,6})?(?:Z|[+-]\d{2}:\d{2})$/.exec(value);
  const millis = match ? Date.parse(value) : NaN;
  // Check the calendar part in its own zone before converting an explicit offset.
  const calendar = match ? Date.parse(match[1] + 'Z') : NaN;
  if (!Number.isFinite(millis) || !Number.isFinite(calendar) || new Date(calendar).toISOString().slice(0,19) !== match[1]) {
    throw Error('An original capture time with a valid offset is required');
  }
  return millis;
}

// Original attended receipts attest exactly 720 hours. A newer custodian can
// further shorten that deadline only with the explicit, version-bound replay cap.
export function certifiedBackupExpiry(source,captured,manifest) {
  const maximum=captured+720*3600000,cutoff=timestamp(source.restoreCutoffUTC);
  const version=source.migrationFilesMatchedToCommit;
  if(cutoff===maximum && source.journalRetentionCutoffUTC===undefined &&
     (version===undefined || Number.isSafeInteger(version) && version>0 && version<87))return cutoff;
  if(cutoff<=captured || cutoff>maximum || !Number.isSafeInteger(source.migrationFilesMatchedToCommit) ||
    source.migrationFilesMatchedToCommit<87 || source.sourceRestore?.registryCount!==version || source.downloadRestore?.registryCount!==version || !/^[0-9a-f]{64}$/.test(source.scopeManifestSHA256??'') ||
    source.journalRetentionCutoffUTC!==source.restoreCutoffUTC || (manifest &&
    (manifest.throughMigration!==source.migrationFilesMatchedToCommit || manifest.scopeManifestSHA256!==source.scopeManifestSHA256 ||
     manifest.journalRetentionCutoffUTC!==undefined && manifest.journalRetentionCutoffUTC!==source.restoreCutoffUTC))) {
    throw Error('Verified backup recovery cutoff conflict');
  }
  return cutoff;
}
