import {createHash} from 'node:crypto';
import {constants} from 'node:fs';
import {lstat,open,realpath,unlink} from 'node:fs/promises';
import {join} from 'node:path';
import {z} from 'zod';

const sha=bytes=>createHash('sha256').update(bytes).digest('hex');

export async function withScopeLock(pool,scope,action) {
  const client=await pool.connect();
  try {
    const lock=await client.query('SELECT pg_try_advisory_lock(hashtextextended($1,561610)) AS held',[scope]);
    if(!lock.rows[0].held)throw Error('Another generation operation is active');
    return await action(client);
  } finally {
    // Destroy the connection on release, including any advisory lock after an I/O error.
    client.release(true);
  }
}

async function fileLocator(directory,custodian) {
  z.string().uuid().parse(custodian);
  const resolved=await realpath(directory);
  const info=await lstat(directory);
  if(!info.isDirectory() || info.uid!==process.getuid() || info.mode&0o077) {
    throw Error('An owner-only canonical export directory is required');
  }
  return {path:join(resolved,'journal.ndjson'),id:sha(custodian+'\n'+resolved)};
}

export async function registerExport(db,scope,directory,custodian,digest) {
  const {id}=await fileLocator(directory,custodian);
  const state=await db.query(`SELECT o.head->>'mode' AS mode,s.details_retired_at,
      c.original_capture+interval '2160 hours'<=clock_timestamp() AS overdue
    FROM ritc_checkpoint.origin o JOIN ritc_checkpoint.recovery_seal s USING(lineage)
    LEFT JOIN ritc_checkpoint.replay_clock c USING(scope_digest) WHERE o.scope_digest=$1`,[scope]);
  const row=state.rows[0];
  if(!row || row.mode!=='sealed' || row.details_retired_at || row.overdue)throw Error('Cannot export a retired or overdue scope');
  const saved=await db.query(`INSERT INTO ritc_checkpoint.detail_export VALUES($1,$2,$3,$4)
    ON CONFLICT(scope_digest,locator_digest) DO UPDATE SET content_digest=EXCLUDED.content_digest
    WHERE ritc_checkpoint.detail_export.content_digest=EXCLUDED.content_digest RETURNING locator_digest`,[scope,custodian,id,digest]);
  if(!saved.rowCount)throw Error('Export destination already belongs to different bytes');
}

export async function retireExports(db,scope,directories,custodian) {
  const {rows}=await db.query('SELECT locator_digest,content_digest FROM ritc_checkpoint.detail_export WHERE scope_digest=$1 AND custodian_id=$2',[scope,z.string().uuid().parse(custodian)]);
  const paths=new Map();
  for(const directory of directories) {
    const locator=await fileLocator(directory,custodian);
    if(paths.has(locator.id))throw Error('Duplicate export directory');
    paths.set(locator.id,locator.path);
  }
  // Preflight the entire known set before removing anything. A different custodian
  // or an unaccounted export keeps the scope open for custody reconciliation.
  const files=[];
  for(const row of rows) {
    const path=paths.get(row.locator_digest);
    if(!path)throw Error('Registered export missing from custody inventory');
    try {
      const file=await open(path,constants.O_RDONLY|constants.O_NOFOLLOW);
      try {
        const stat=await file.stat();
        if(!stat.isFile() || stat.nlink!==1 || stat.mode&0o077 || stat.uid!==process.getuid() || stat.size>33554432)throw Error('Unsafe export copy');
        if(sha(await file.readFile())!==row.content_digest)throw Error('Registered export bytes changed');
        files.push({path,id:row.locator_digest,stat});
      } finally {await file.close();}
    } catch(error) {
      if(error.code!=='ENOENT')throw error;
      files.push({path,id:row.locator_digest});
    }
  }
  for(const [id,path] of paths) {
    if(rows.some(row=>row.locator_digest===id))continue;
    try {await lstat(path);throw Error('Unregistered export requires separate disposition');}
    catch(error){if(error.code!=='ENOENT')throw error;}
  }
  for(const file of files) {
    if(file.stat) {
      const info=await lstat(file.path);
      if(info.dev!==file.stat.dev || info.ino!==file.stat.ino || info.nlink!==1 || info.ctimeMs!==file.stat.ctimeMs)throw Error('Export changed during retirement');
      await unlink(file.path);
      const parent=await open(join(file.path,'..'),constants.O_RDONLY|constants.O_NOFOLLOW);
      try{await parent.sync();}finally{await parent.close();}
    }
    try {await lstat(file.path);throw Error('Export still present');}
    catch(error){if(error.code!=='ENOENT')throw error;}
    await db.query('DELETE FROM ritc_checkpoint.detail_export WHERE scope_digest=$1 AND locator_digest=$2',[scope,file.id]);
  }
  return rows.length;
}
