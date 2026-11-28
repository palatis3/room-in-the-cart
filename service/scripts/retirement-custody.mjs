import {createHash} from 'node:crypto';
import {spawn} from 'node:child_process';
import {constants} from 'node:fs';
import {open} from 'node:fs/promises';
import {assertCaptureCurrent,restoreCaptureProof} from './restore-capture.mjs';

const day = 86400000;

export function retentionDates(firstCapture) {
  if (!Number.isFinite(firstCapture)) throw Error('Original replay capture is unknown');
  return {
    rotateBy: new Date(firstCapture + 30 * day).toISOString(),
    retireLiveBy: new Date(firstCapture + 60 * day).toISOString(),
    retireAllBy: new Date(firstCapture + 90 * day).toISOString(),
  };
}

// The hash and the offline pg_restore projection consume the same open input.
// No additional plaintext backup file is produced, even if the process dies.
export async function recoveredRotation(config,link,pin) {
  const file=await open(config.dumpPath,constants.O_RDONLY|constants.O_NOFOLLOW);
  let child;
  try {
    const stat=await file.stat();
    if(!stat.isFile() || stat.uid!==process.getuid() || (stat.mode&0o077)!==0)throw Error('Private recovered dump required');
    child=spawn(config.pgRestore,['--data-only','--table=privacy_journal_rotation','--file=-'],
      {env:{PATH:'/usr/bin:/bin',LC_ALL:'C'},stdio:['pipe','pipe','ignore'],timeout:30000});
    const completed=new Promise(resolve=>{
      child.once('error',()=>resolve(false));
      child.once('close',code=>resolve(code===0));
    });
    const chunks=[];let outputSize=0;
    child.stdout.on('data',chunk=>{
      outputSize+=chunk.length;
      if(outputSize>8*1024*1024){child.kill('SIGKILL');return;}
      chunks.push(chunk);
    });
    // A successful projection can close its input once it reaches the selected
    // table. Finish hashing the remainder of the original file in that case.
    let closed=false,inputError=false;
    child.stdin.on('error',error=>{closed=true;if(error.code!=='EPIPE')inputError=true;});
    const hash=createHash('sha256');
    for await(const chunk of file.createReadStream({autoClose:false})) {
      hash.update(chunk);
      if(!closed && !child.stdin.destroyed)await new Promise(resolve=>{
        child.stdin.write(chunk,error=>{if(error){closed=true;if(error.code!=='EPIPE')inputError=true;}resolve();});
      });
    }
    child.stdin.end();
    if(!await completed || inputError || outputSize>8*1024*1024)throw Error('Recovered archive projection failed');
    const proof=await restoreCaptureProof(config,hash.digest('hex'),pin);
    const stdout=Buffer.concat(chunks).toString('utf8');
    const keys = ['predecessor','successor','proof'];
    let columns,matched=0;
    for (const line of stdout.split('\n')) {
      if (line.startsWith('COPY ritc.privacy_journal_rotation (')) {
        const match = /^COPY ritc\.privacy_journal_rotation \(([^)]+)\) FROM stdin;$/.exec(line);
        if (!match) throw Error('Unexpected recovery rotation table format');
        columns = match[1].split(', ');
        if (!keys.every(key=>columns.includes(key))) throw Error('Incomplete recovered rotation table');
      } else if (line === '\\.') {
        columns=undefined;
      } else if (columns) {
        const row=line.split('\t');
        if (row[columns.indexOf('predecessor')] !== link.predecessorLineage) continue;
        const proof=JSON.parse(row[columns.indexOf('proof')].replaceAll('\\\\','\\'));
        if (row[columns.indexOf('successor')] !== link.successorLineage ||
            proof.authoritySignature !== link.authoritySignature || proof.predecessorSealDigest !== link.predecessorSealDigest ||
            proof.predecessorScopeDigest !== link.predecessorScopeDigest || proof.sourceDatabaseOid !== link.sourceDatabaseOid) {
          throw Error('Independently restored source has a different rotation');
        }
        matched++;
      }
    }
    const after=await file.stat();
    if (matched !== 1 || after.size !== stat.size || after.mtimeMs !== stat.mtimeMs || after.ctimeMs !== stat.ctimeMs) {
      throw Error('Absent or unstable rotation in recovered backup');
    }
    assertCaptureCurrent(proof.captured,Date.now(),proof.expires);
    return proof;
  } finally {if(child && child.exitCode===null)child.kill();await file.close();}
}
