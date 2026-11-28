import {createHash,createPrivateKey,createPublicKey} from 'node:crypto';
import {isAbsolute} from 'node:path';
import {z} from 'zod';
import {durableJournalPinsSchema,durableJournalScopeDigest} from '../dist/privacy-journal-durable.js';
import {journalCanonical} from '../dist/privacy-journal.js';
import {activateIndependentSuccessor,createIndependentRecovery,exportIndependentRecovery,registerIndependentSuccessor,verifyRetirementAnchor} from '../dist/privacy-journal-recovery.js';
import {PrivacyCall} from '../dist/privacy-call.js';
import {jsonFile,publicKey} from './journal-archive-window.mjs';
import {journalDatabase,journalDatabaseSchema,readPrivateFile} from './journal-authority-config.mjs';
import {assertCaptureCurrent} from './restore-capture.mjs';
import {retireExports,withScopeLock} from './retirement-exports.mjs';
import {recoveredRotation,retentionDates} from './retirement-custody.mjs';

const endpoint=z.object({connection:journalDatabaseSchema,databaseOid:z.string().regex(/^[1-9]\d*$/),
  ownerOid:z.string().regex(/^[1-9]\d*$/),ownerRole:z.string().optional()}).strict();
const path=z.string().refine(isAbsolute);
const settings=z.object({pins:durableJournalPinsSchema,successor:durableJournalPinsSchema,
  writerPublicKey:publicKey,authorityPublicKey:publicKey,source:endpoint,checkpoint:endpoint,
  captureManifestPath:path.optional(),verifiedReceiptPath:path.optional(),dumpPath:path.optional(),pgRestore:path.optional(),exportDirectories:z.array(path).max(1024).default([]),rotationKeysPath:path.optional()}).strict();

async function openOwner(config,relation) {
  const pool=journalDatabase(config.connection,'ritc-journal-retire',{max:3,ownerInventory:true});
  const identity={database:config.connection.database,databaseOid:config.databaseOid,
    owner:config.ownerRole ?? config.connection.user,ownerOid:config.ownerOid};
  try {
    const check=await pool.query(`SELECT current_database() AS database, d.oid::text AS "databaseOid",session_user AS owner,
      r.oid::text AS "ownerOid",current_user=session_user AND NOT pg_is_in_recovery() AND c.relowner=r.oid AS authorized
      FROM pg_database d,pg_roles r,pg_class c WHERE d.datname=current_database() AND r.rolname=session_user AND c.oid=$1::regclass`,[relation]);
    const {authorized,...found}=check.rows[0]??{};
    if(!authorized || journalCanonical(found)!==journalCanonical(identity))throw Error('Owner database identity conflict');
    // A filtered SELECT could incorrectly report an empty generation. Accept active
    // RLS only for a directly owned table with an unrestricted owner policy and
    // no restrictive policy. Legacy installations without that proof fail closed.
    const tables=relation==='ritc.privacy_journal_outbox' ? [
      'ritc.privacy_journal_outbox','ritc.privacy_journal_origin','ritc.privacy_journal_rotation','ritc.privacy_journal_source_registration',
      'ritc.privacy_journal_target','ritc.privacy_journal_ack','ritc.privacy_restore_run','ritc.privacy_restore_job','ritc.privacy_job',
      'ritc.privacy_target','ritc.identity_erasure','ritc.privacy_source_replay_clock',
    ] : ['ritc_checkpoint.origin','ritc_checkpoint.admission','ritc_checkpoint.worker_allowance','ritc_checkpoint.recovery_seal',
      'ritc_checkpoint.successor','ritc_checkpoint.replay_clock','ritc_checkpoint.detail_export','ritc_records.object','ritc_records.store'];
    const filtered=await pool.query(`SELECT FROM unnest($1::text[]) t(name)
      JOIN pg_class c ON c.oid=to_regclass(t.name)
      WHERE row_security_active(c.oid) AND (c.relowner<>session_user::regrole OR
       NOT EXISTS(SELECT FROM pg_policy p WHERE p.polrelid=c.oid AND p.polpermissive AND p.polcmd='*'
         AND c.relowner=ANY(p.polroles) AND pg_get_expr(p.polqual,c.oid)='true'
         AND COALESCE(pg_get_expr(p.polwithcheck,c.oid),'true')='true')
       OR EXISTS(SELECT FROM pg_policy p WHERE p.polrelid=c.oid AND NOT p.polpermissive)) LIMIT 1`,[tables]);
    if(filtered.rowCount)throw Error('Recovery owner cannot see the complete protected relation');
    return {pool,identity};
  } catch(error) {await pool.end();throw error;}
}

async function originalCapture(checkpoint,scope) {
  const {rows:[row]}=await checkpoint.query('SELECT original_capture FROM ritc_checkpoint.replay_clock WHERE scope_digest=$1',[scope]);
  return row?.original_capture.valueOf() ?? null;
}

async function run() {
  const [command,file]=process.argv.slice(2);
  if(!['backup-admission','schedule','rotate-due','plan','retire-exports','retire'].includes(command) || process.argv.length!==4)throw Error('Use schedule, rotate-due, plan or retire with an owner configuration');
  const configBytes=await readPrivateFile(file,1024*1024);
  if(command==='backup-admission' && createHash('sha256').update(configBytes).digest('hex')!==process.env.RITC_BACKUP_ADMISSION_CONFIG_SHA256) {
    throw Error('Expected backup source and authority endpoints must be pinned independently');
  }
  const raw=JSON.parse(configBytes);
  const config=command==='backup-admission' ? z.object({source:endpoint,checkpoint:endpoint,
    expectedSourceIdentity:z.string().min(1).max(200)}).parse(raw) : settings.parse(raw);
  const source=await openOwner(config.source,'ritc.privacy_journal_outbox');
  let checkpoint;
  try {
    checkpoint=await openOwner(config.checkpoint,'ritc_checkpoint.origin');
    if(command==='backup-admission') {
      if((await source.pool.query('SELECT FROM ritc.privacy_restore_run LIMIT 1')).rowCount)throw Error('Restored quarantine cannot produce a fresh source backup');
      const {rows:registered}=await source.pool.query('SELECT database_oid::text AS oid,source_identity FROM ritc.privacy_journal_source_registration');
      if(registered.some(row=>row.oid!==source.identity.databaseOid || row.source_identity!==config.expectedSourceIdentity))throw Error('Restored source identity conflict');
      const {rows:outbox}=await source.pool.query('SELECT DISTINCT lineage FROM ritc.privacy_journal_outbox');
      const {rows:[catalog]}=await checkpoint.pool.query("SELECT to_regclass('ritc_checkpoint.replay_clock') IS NOT NULL AS installed");
      let clocks=[];
      if(catalog.installed) {
        clocks=(await checkpoint.pool.query(`SELECT o.lineage,c.original_capture FROM ritc_checkpoint.replay_clock c
          JOIN ritc_checkpoint.origin o USING(scope_digest) LEFT JOIN ritc_checkpoint.recovery_seal s USING(lineage)
          WHERE s.details_retired_at IS NULL`)).rows;
        const unknown=(await checkpoint.pool.query(`SELECT FROM ritc_records.object b WHERE NOT EXISTS(
          SELECT FROM ritc_checkpoint.replay_clock c WHERE c.scope_digest=split_part(b.object_key,'/',1)) LIMIT 1`)).rowCount;
        if(unknown)throw Error('Unclassified independent replay object');
      } else {
        const legacy=await checkpoint.pool.query(`SELECT EXISTS(SELECT FROM ritc_records.object)
          OR EXISTS(SELECT FROM ritc_checkpoint.admission) OR EXISTS(SELECT FROM ritc_checkpoint.worker_allowance)
          OR EXISTS(SELECT FROM ritc_checkpoint.recovery_seal WHERE tail_objects<>'[]')
          OR EXISTS(SELECT FROM ritc_checkpoint.origin WHERE claim IS NOT NULL OR pending IS NOT NULL
            OR head->'head'->>'seq' IS DISTINCT FROM '0' OR head->>'totalBytes' IS DISTINCT FROM '0') AS details`);
        if(outbox.length || legacy.rows[0].details)throw Error('Unversioned generation needs classification');
      }
      if(outbox.some(row=>!clocks.some(clock=>clock.lineage===row.lineage)) || (!registered.length && (outbox.length || clocks.length))) {
        throw Error('Unclassified source replay generation');
      }
      const times=new Map(clocks.map(row=>[row.lineage,row.original_capture.valueOf()]));
      const sourceClock=(await source.pool.query("SELECT to_regclass('ritc.privacy_source_replay_clock') IS NOT NULL AS installed")).rows[0].installed;
      if(!sourceClock) {
        const legacy=await source.pool.query(`SELECT EXISTS(SELECT FROM ritc.privacy_job) OR EXISTS(SELECT FROM ritc.privacy_target)
          OR EXISTS(SELECT FROM ritc.privacy_journal_target) OR EXISTS(SELECT FROM ritc.privacy_journal_ack)
          OR EXISTS(SELECT FROM ritc.identity_erasure) AS details`);
        if(clocks.length || legacy.rows[0].details)throw Error('Unversioned source clock');
      }
      if(sourceClock)for(const row of (await source.pool.query('SELECT lineage,original_capture FROM ritc.privacy_source_replay_clock')).rows){
        if(!times.has(row.lineage))throw Error('Source clock lacks an independent generation');
        times.set(row.lineage,Math.min(times.get(row.lineage),row.original_capture.valueOf()));
      }
      const now=Date.now(),ends=[...times.values()].map(first=>Date.parse(retentionDates(first).retireAllBy));
      const earliest=ends.length?Math.min(...ends):null;
      const allowed=earliest===null || now<earliest;
      console.log(JSON.stringify({captureAllowed:allowed,maxBackupExpiresAt:new Date(Math.min(now+720*3600000,earliest??Infinity)).toISOString(),
        earliestReplayDeadline:earliest===null?null:new Date(earliest).toISOString(),openGenerations:ends.length}));
      if(!allowed)process.exitCode=1;
      return;
    }
    const generation=config.pins.lineage,scope=durableJournalScopeDigest(config.pins);
    if(command==='schedule' || command==='rotate-due') {
      const present=await checkpoint.pool.query('SELECT FROM ritc_checkpoint.origin WHERE lineage=$1 AND scope_digest=$2',[generation,scope]);
      if(!present.rowCount)throw Error('Pinned generation missing');
      const first=await originalCapture(checkpoint.pool,scope);
      const dates=first===null ? null : retentionDates(first);
      const due=dates!==null && Date.now()>=Date.parse(dates.rotateBy)-86400000;
      if(command==='schedule' || !due){console.log(JSON.stringify({dates,rotateNow:due}));return;}
      const keys=z.object({writerPrivateKey:z.string(),authorityPrivateKey:z.string(),
        successorWriterPublicKey:publicKey,successorAuthorityPublicKey:publicKey}).strict().parse(await jsonFile(config.rotationKeysPath));
      const writerPrivateKey=createPrivateKey(keys.writerPrivateKey),authorityPrivateKey=createPrivateKey(keys.authorityPrivateKey);
      const writerPublicKey=createPublicKey(config.writerPublicKey),authorityPublicKey=createPublicKey(config.authorityPublicKey);
      const call=new PrivacyCall(undefined,25000);
      try {
        await withScopeLock(checkpoint.pool,scope,async()=>{
          const prior=await source.pool.query('SELECT proof FROM ritc.privacy_journal_rotation WHERE predecessor=$1',[generation]);
          if(!prior.rowCount) {
            const recovery=createIndependentRecovery({pins:config.pins,writerPrivateKey,authorityPrivateKey,source,checkpoint});
            await call.run(recovery.sealForRollover);
            await call.run(context=>registerIndependentSuccessor({pins:config.pins,writerPublicKey,authorityPrivateKey,
              sourceDatabaseOid:source.identity.databaseOid,checkpoint,successor:{pins:config.successor,
              writerPublicKey:createPublicKey(keys.successorWriterPublicKey),authorityPublicKey:createPublicKey(keys.successorAuthorityPublicKey)}},context));
          }
          const result=await call.run(context=>activateIndependentSuccessor({pins:config.pins,writerPublicKey,authorityPublicKey,
            source,checkpoint,successor:config.successor},context));
          console.log(JSON.stringify({dates,rotateNow:true,sourceActivated:true,changed:result.changed}));
        });
      } finally {call.dispose();}
      return;
    }
    await withScopeLock(checkpoint.pool,scope,async custody=>{
    const {rows:[anchor]}=await checkpoint.pool.query(`SELECT s.proof AS seal,l.proof AS link,s.details_retired_at AS retired
      FROM ritc_checkpoint.origin o JOIN ritc_checkpoint.recovery_seal s USING(lineage)
      JOIN ritc_checkpoint.successor l ON l.predecessor=o.lineage WHERE o.lineage=$1 AND o.scope_digest=$2
      AND o.head->>'mode'='sealed' AND o.claim IS NULL AND o.pending IS NULL`,[generation,scope]);
    if(!anchor)throw Error('Sealed predecessor and permanent successor required');
    const writer=createPublicKey(config.writerPublicKey),authority=createPublicKey(config.authorityPublicKey);
    const link=verifyRetirementAnchor(anchor.seal,anchor.link,config.pins,config.successor,writer,authority);
    const {rows:[rotation]}=await source.pool.query(`SELECT r.proof, r.activated_at AS activated FROM ritc.privacy_journal_rotation r
      JOIN ritc.privacy_journal_source_registration s ON s.singleton AND s.source_identity=r.proof->>'sourceIdentity'
      AND s.database_oid=(SELECT oid FROM pg_database WHERE datname=current_database())
      JOIN ritc.privacy_journal_origin o ON o.singleton AND o.lineage<>r.predecessor WHERE r.predecessor=$1`,[generation]);
    if(link.sourceDatabaseOid!==source.identity.databaseOid || !rotation || journalCanonical(rotation.proof)!==journalCanonical(link)) {
      throw Error('Signed successor is absent from the pinned source');
    }
    const first=await originalCapture(checkpoint.pool,scope);
    if(!anchor.retired) {
      const call=new PrivacyCall(undefined,25000);
      try {await call.run(context=>exportIndependentRecovery({pins:config.pins,writerPublicKey:writer,
        authorityPublicKey:authority,checkpoint,sourceDatabaseOid:source.identity.databaseOid,includeSuccessor:true},context));}
      finally {call.dispose();}
    }
    const dates=first===null ? null : retentionDates(first);
    const lastStaleExpiry=rotation.activated.valueOf()+720*3600000;
    const schedule={dates,lastPossiblePredecessorBackupExpiry:new Date(lastStaleExpiry).toISOString(),
      staleBackupsExpired:Date.now()>=lastStaleExpiry,lateLiveRetirement:dates!==null && Date.now()>=Date.parse(dates.retireLiveBy),
      authorityPreviouslyRetired:anchor.retired!==null};
    if(command==='plan'){console.log(JSON.stringify(schedule));return;}
    if(!schedule.staleBackupsExpired)throw Error('Recoverable pre-rotation snapshots remain');
    const {captured:recovered,expires,project}=await recoveredRotation(config,link,process.env.RITC_RESTORE_VERIFIED_RECEIPT_SHA256);
    assertCaptureCurrent(recovered,Date.now(),expires);
    // Each store commits independently. The authority remains available if the source fails.
    // A retry revalidates the successor, authenticated recovery backup, and absence in both stores.
    await retireExports(custody,scope,config.exportDirectories,process.env.RITC_JOURNAL_CUSTODIAN_ID,()=>assertCaptureCurrent(recovered,Date.now(),expires));
    const pendingExports=await custody.query('SELECT count(*)::int AS count FROM ritc_checkpoint.detail_export WHERE scope_digest=$1',[scope]);
    if(command==='retire-exports') {
      console.log(JSON.stringify({localExportsAbsent:true,registeredExportsRemaining:pendingExports.rows[0].count}));
      return;
    }
    if(pendingExports.rows[0].count)throw Error('Another custodian must reconcile its exports');
    const sourceClient=await source.pool.connect();
    try {
      await sourceClient.query('BEGIN');
      assertCaptureCurrent(recovered,Date.now(),expires);
      await sourceClient.query('SELECT ritc.privacy_retire_journal_source($1,$2,$3)',[generation,link.predecessorSealDigest,new Date(recovered)]);
      assertCaptureCurrent(recovered,Date.now(),expires);
      await sourceClient.query('COMMIT');
    } catch(error){await sourceClient.query('ROLLBACK');throw error;}
    finally{sourceClient.release();}

    const sourceRemaining=await source.pool.query('SELECT FROM ritc.privacy_journal_outbox WHERE lineage=$1 LIMIT 1',[generation]);
    if(sourceRemaining.rowCount)throw Error('Source details still present');
    assertCaptureCurrent(recovered,Date.now(),expires);
    await checkpoint.pool.query('SELECT ritc_checkpoint.retire_details($1,$2,$3)',[generation,scope,link.predecessorSealDigest]);
    const remaining=await checkpoint.pool.query(`SELECT EXISTS(SELECT FROM ritc_records.object WHERE split_part(object_key,'/',1)=$2)
      OR EXISTS(SELECT FROM ritc_checkpoint.admission WHERE lineage=$1) OR EXISTS(SELECT FROM ritc_checkpoint.worker_allowance WHERE lineage=$1)
      OR NOT EXISTS(SELECT FROM ritc_checkpoint.recovery_seal WHERE lineage=$1 AND details_retired_at IS NOT NULL AND tail_objects='[]') AS present,
      (SELECT details_retired_at FROM ritc_checkpoint.recovery_seal WHERE lineage=$1) AS retired_at`,[generation,scope]);
    if(remaining.rows[0].present)throw Error('Authority details still present');
    console.log(JSON.stringify({...schedule,sourceAndAuthorityRowsAbsent:true,registeredExportsAbsent:true,scopeDigest:scope,project,primaryNamespacesVerifiedAt:remaining.rows[0].retired_at.toISOString(),externalCopiesVerified:false}));
    });
  } finally {await checkpoint?.pool.end();await source.pool.end();}
}

try {await run();} catch(error) {
  // SQL, pg_restore output and configuration may contain private values.
  console.error(JSON.stringify({event:'journal_retirement_refused',category:
    error.message==='Recoverable pre-rotation snapshots remain' ? 'stale_backup_eligible' : 'verification_failed'}));
  process.exitCode=1;
}
