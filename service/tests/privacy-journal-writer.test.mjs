import assert from 'node:assert/strict';
import {createHash,generateKeyPairSync,sign} from 'node:crypto';
import {existsSync} from 'node:fs';
import {chmod,mkdir,mkdtemp,readFile,rm,stat,writeFile} from 'node:fs/promises';
import {join} from 'node:path';
import test from 'node:test';

const installed = new URL('../dist/privacy-journal.js',import.meta.url);
const moduleURL = existsSync(installed) ? installed : new URL('../../../core/service/dist/privacy-journal.js',import.meta.url);
const {createLocalPrivacyJournal,verifyPrivacyJournal} = await import(moduleURL.href);
const pins = Object.freeze({lineage:'40000000-0000-4000-8000-000000000001',schemaDigest:'b'.repeat(64),configurationId:'local-writer-fixture-v1',keyId:'writer-test-key'});
const jobA = '50000000-0000-4000-8000-000000000001';
const jobB = '50000000-0000-4000-8000-000000000002';
const zero = '0'.repeat(64);
let nextEvent = 0;
function canonical(value) {
  if (value === null || typeof value !== 'object') return JSON.stringify(value);
  if (Array.isArray(value)) return `[${value.map(canonical).join(',')}]`;
  return `{${Object.keys(value).sort().map(k => `${JSON.stringify(k)}:${canonical(value[k])}`).join(',')}}`;
}
const hash = value => createHash('sha256').update(canonical(value)).digest('hex');
const clone = value => structuredClone(value);
function event(kind = 'acceptance',options = {}) {
  const eventId = options.eventId ?? `60000000-0000-4000-8000-${(++nextEvent).toString(16).padStart(12,'0')}`;
  const {keyId:unused,...origin} = pins;
  const payload = {version:1,eventId,...origin,jobId:jobA,kind,data:{},...options};
  return {eventId,payloadDigest:hash(payload),payload};
}
function recordsFor(entries,privateKey) {
  let previousHash = zero;
  return entries.map(([kind,e,extra = {}],index) => {
    const unsigned = {version:1,keyId:pins.keyId,seq:index+1,previousHash,kind,event:e,...extra};
    const record = {...unsigned,signature:sign(null,Buffer.from(canonical(unsigned)),privateKey).toString('base64url')};
    previousHash = hash(record);
    return record;
  });
}
const bytesFor = records => Buffer.from(records.map(canonical).join('\n')+'\n');
function headFor(records,fenced = false) {
  const {keyId:unused,...origin} = pins;
  return {version:1,...origin,seq:records.length,hash:records.length ? hash(records.at(-1)) : zero,fenced};
}
async function optionalBytes(path) {
  try { return await readFile(path); } catch (e) { if (e.code === 'ENOENT') return null; throw e; }
}

// Exact fake of the fixed owner connection, with unexpected SQL rejected. No
// PostgreSQL process, network, account, provider, or production source is used.
async function fixture(t) {
  const root = await mkdtemp('/tmp/ritc-journal-writer-test-');
  await chmod(root,0o700);
  const directory = join(root,'journal');
  await mkdir(directory,{mode:0o700});
  const file = join(directory,'journal.ndjson');
  const checkpointPath = join(root,'independent-checkpoint.json');
  const privateKeyPath = join(root,'private-key.pem');
  const signing = generateKeyPairSync('ed25519');
  await writeFile(privateKeyPath,signing.privateKey.export({type:'pkcs8',format:'pem'}),{mode:0o600});
  const source = {
    origin:{lineage:pins.lineage,schema_digest:pins.schemaDigest,configuration_id:pins.configurationId,fenced:false},
    outbox:new Map(),acks:new Map(),calls:[],
    add(e) { this.outbox.set(e.eventId,clone(e)); },
    async query(sql,args = []) {
      this.calls.push({sql,args});
      if (sql === 'SELECT lineage,schema_digest,configuration_id,fenced FROM ritc.privacy_journal_origin WHERE singleton') return {rows:[clone(this.origin)],rowCount:1};
      if (sql === 'UPDATE ritc.privacy_journal_origin SET fenced=true WHERE singleton') { this.origin.fenced = true; return {rows:[],rowCount:1}; }
      if (sql === 'SELECT event_id,payload,payload_digest FROM ritc.privacy_journal_outbox WHERE event_id=$1' || sql === 'SELECT payload,payload_digest FROM ritc.privacy_journal_outbox WHERE event_id=$1') {
        const e = this.outbox.get(args[0]);
        return {rows:e ? [{event_id:e.eventId,payload:clone(e.payload),payload_digest:e.payloadDigest}] : [],rowCount:e ? 1 : 0};
      }
      if (sql === 'SELECT 1 FROM ritc.privacy_journal_outbox WHERE event_id=$1') return {rows:this.outbox.has(args[0]) ? [{}] : [],rowCount:this.outbox.has(args[0]) ? 1 : 0};
      if (sql === 'SELECT ritc.privacy_journal_acknowledge($1,$2,$3,$4)') {
        // This assertion runs at the acknowledgement call, so a later write
        // cannot hide an acknowledgement performed before durable checkpoint.
        const checkpoint = JSON.parse(await readFile(checkpointPath,'utf8'));
        const records = (await readFile(file,'utf8')).trimEnd().split('\n').map(JSON.parse);
        assert.ok(checkpoint.seq >= args[2],'checkpoint must already cover acknowledgement');
        assert.equal(checkpoint.hash,hash(records[checkpoint.seq-1]));
        assert.equal(args[3],hash(records[args[2]-1]));
        assert.equal(args[1],this.outbox.get(args[0])?.payloadDigest);
        this.acks.set(args[0],args.slice());
        return {rows:[{}],rowCount:1};
      }
      if (sql === 'SELECT e.event_id FROM ritc.privacy_journal_outbox e WHERE NOT EXISTS(SELECT 1 FROM ritc.privacy_journal_ack a WHERE a.event_id=e.event_id) ORDER BY e.created_at,e.event_id' || sql === 'SELECT e.event_id FROM ritc.privacy_journal_outbox e WHERE e.job_id=$1 AND NOT EXISTS(SELECT 1 FROM ritc.privacy_journal_ack a WHERE a.event_id=e.event_id) ORDER BY e.created_at,e.event_id') {
        const events = [...this.outbox.values()].filter(e => !this.acks.has(e.eventId) && (!args.length || e.payload.jobId === args[0]));
        return {rows:events.map(e => ({event_id:e.eventId})),rowCount:events.length};
      }
      throw Error('Unexpected fixed-source test query: '+sql);
    },
  };
  const configuration = {...pins,source,directory,checkpointPath,privateKeyPath};
  const writers = new Set();
  const f = {
    root,directory,file,checkpointPath,privateKeyPath,source,configuration,signing,
    async open(extra = {}) { const writer = await createLocalPrivacyJournal({...configuration,...extra}); writers.add(writer); return writer; },
    async close(writer) { await writer.close(); writers.delete(writer); },
    async put(records,checkpoint = headFor(records)) {
      await writeFile(file,bytesFor(records),{mode:0o600});
      if (checkpoint !== null) await writeFile(checkpointPath,canonical(checkpoint)+'\n',{mode:0o600});
    },
    async snapshot() { return {journal:await optionalBytes(file),checkpoint:await optionalBytes(checkpointPath),acks:source.acks.size}; },
    async assertUnchanged(before) {
      assert.deepEqual(await optionalBytes(file),before.journal,'rejection must not append or rewrite journal');
      assert.deepEqual(await optionalBytes(checkpointPath),before.checkpoint,'rejection must not repin checkpoint');
      assert.equal(source.acks.size,before.acks,'rejection must not acknowledge source');
    },
  };
  t.after(async () => {
    for (const writer of writers) await writer.close().catch(() => {});
    await rm(root,{recursive:true,force:true});
  });
  return f;
}
async function rejectsStartupUnchanged(f,options,expected) {
  const before = await f.snapshot();
  await assert.rejects(() => f.open(options),expected);
  await f.assertUnchanged(before);
  assert.equal(await optionalBytes(join(f.directory,'writer.lock')),null,'failed startup releases only its own lock');
}

test('actual writer checkpoints intent and commit before source acknowledgement, then fences exact head', async t => {
  const f = await fixture(t);
  const writer = await f.open();
  assert.deepEqual(JSON.parse(await readFile(f.checkpointPath,'utf8')),headFor([]));
  const accepted = event();
  await writer.port.beforeCommit(accepted);
  let records = (await readFile(f.file,'utf8')).trimEnd().split('\n').map(JSON.parse);
  assert.equal(records.length,1);
  assert.equal(records[0].kind,'intent');
  assert.equal(JSON.parse(await readFile(f.checkpointPath,'utf8')).hash,hash(records[0]));
  assert.equal(f.source.acks.size,0);
  f.source.add(accepted);
  await writer.port.afterCommit(accepted.eventId);
  records = (await readFile(f.file,'utf8')).trimEnd().split('\n').map(JSON.parse);
  assert.equal(records[1].kind,'commit');
  assert.equal(records[1].previousHash,hash(records[0]));
  assert.equal(f.source.acks.get(accepted.eventId)[2],2);
  const beforeRetry = await f.snapshot();
  await writer.port.beforeCommit(accepted);
  await writer.port.afterCommit(accepted.eventId);
  await f.assertUnchanged(beforeRetry);
  const head = await writer.fence();
  assert.equal(head.fenced,true);
  assert.deepEqual(JSON.parse(await readFile(f.checkpointPath,'utf8')),head);
  const result = verifyPrivacyJournal(await readFile(f.file),{...pins,publicKey:writer.publicKey,head});
  assert.deepEqual(result.events,[accepted]);
  const afterFence = await f.snapshot();
  await assert.rejects(() => writer.port.beforeCommit(event('acceptance',{jobId:jobB})),/cannot accept requests/);
  await f.assertUnchanged(afterFence);
  assert.equal((await stat(f.file)).mode&0o077,0);
  assert.equal((await stat(f.checkpointPath)).mode&0o077,0);
});

test('authentic checkpointed chain reopens and new records extend its exact hash', async t => {
  const f = await fixture(t);
  const a = event();
  const initial = recordsFor([['intent',a],['commit',a]],f.signing.privateKey);
  await f.put(initial);
  const writer = await f.open();
  const b = event('acceptance',{jobId:jobB});
  await writer.port.beforeCommit(b);
  f.source.add(b);
  await writer.port.afterCommit(b.eventId);
  const all = (await readFile(f.file,'utf8')).trimEnd().split('\n').map(JSON.parse);
  assert.deepEqual(all.slice(0,2),initial);
  assert.equal(all[2].previousHash,hash(initial[1]));
  assert.equal(all[3].seq,4);
});

test('startup rejects an invalid signature even when checkpoint was repinned to those bytes', async t => {
  const f = await fixture(t);
  const a = event();
  const wrongKey = generateKeyPairSync('ed25519');
  await f.put(recordsFor([['intent',a],['commit',a]],wrongKey.privateKey));
  await rejectsStartupUnchanged(f,{},/signature rejected/);
});

test('startup rejects a validly signed fork against the original independent checkpoint', async t => {
  const f = await fixture(t);
  const a = event();
  const progress = event('target_erased',{data:{observation:'original'}});
  const original = recordsFor([['intent',a],['commit',a],['commit',progress]],f.signing.privateKey);
  const changed = event('target_erased',{eventId:progress.eventId,data:{observation:'fork'}});
  const fork = recordsFor([['intent',a],['commit',a],['commit',changed]],f.signing.privateKey);
  await f.put(fork,headFor(original));
  await rejectsStartupUnchanged(f,{},/checkpoint mismatch/);
});

test('startup rejects an authentic prefix whose independent checkpoint pins a later head', async t => {
  const f = await fixture(t);
  const a = event();
  const all = recordsFor([['intent',a],['commit',a],['commit',event('target_erased')]],f.signing.privateKey);
  await f.put(all.slice(0,2),headFor(all));
  await rejectsStartupUnchanged(f,{},/checkpoint mismatch/);
});

test('an existing journal cannot acquire a new independent checkpoint on startup', async t => {
  const f = await fixture(t);
  const a = event();
  await f.put(recordsFor([['intent',a],['commit',a]],f.signing.privateKey),null);
  await rejectsStartupUnchanged(f,{},/no trusted independent checkpoint/);
});

test('startup binds every checkpoint origin field and rejects signed chain gaps', async t => {
  for (const [field,value] of Object.entries({lineage:'40000000-0000-4000-8000-ffffffffffff',schemaDigest:'f'.repeat(64),configurationId:'different-configuration'})) await t.test(field,async t => {
    const f = await fixture(t);
    const a = event();
    const records = recordsFor([['intent',a],['commit',a]],f.signing.privateKey);
    await f.put(records,{...headFor(records),[field]:value});
    await rejectsStartupUnchanged(f,{},/checkpoint mismatch/);
  });
  await t.test('signed chain gap',async t => {
    const f = await fixture(t);
    const a = event();
    await f.put(recordsFor([['intent',a],['commit',a,{previousHash:'f'.repeat(64)}]],f.signing.privateKey));
    await rejectsStartupUnchanged(f,{},/chain or trust conflict/);
  });
});

test('startup rejects signed invalid event dependencies before any acknowledgement', async t => {
  for (const kind of ['commit_after_rollback','commit_without_intent','progress_without_acceptance']) await t.test(kind,async t => {
    const f = await fixture(t);
    const a = event();
    const entries = kind === 'commit_after_rollback' ? [['intent',a],['rollback',a],['commit',a]] : kind === 'commit_without_intent' ? [['commit',a]] : [['commit',event('target_erased')]];
    await f.put(recordsFor(entries,f.signing.privateKey));
    await rejectsStartupUnchanged(f,{},/already resolved|no matching durable intent|no preceding accepted authorization/);
  });
});

test('normal startup quarantines both committed and unresolved uncheckpointed tails', async t => {
  for (const kind of ['commit','intent']) await t.test(kind,async t => {
    const f = await fixture(t);
    const a = event();
    const tail = event(kind === 'commit' ? 'target_erased' : 'acceptance',{jobId:jobB});
    // A progress tail belongs to the preceding accepted job.
    if (kind === 'commit') { tail.payload.jobId = jobA; tail.payloadDigest = hash(tail.payload); }
    const records = recordsFor([['intent',a],['commit',a],[kind,tail]],f.signing.privateKey);
    await f.put(records,headFor(records.slice(0,2)));
    await rejectsStartupUnchanged(f,{},/explicit fenced recovery/);
  });
});

test('explicit recovery requires a fenced fixed source, while normal writes reject a fenced source', async t => {
  await t.test('recovery with unfenced source',async t => {
    const f = await fixture(t);
    await rejectsStartupUnchanged(f,{mode:'recover_fenced'},/explicitly fenced source/);
  });
  await t.test('write with fenced source',async t => {
    const f = await fixture(t);
    f.source.origin.fenced = true;
    await rejectsStartupUnchanged(f,{},/Fenced source is not writable/);
  });
  await t.test('write with a fenced checkpoint',async t => {
    const f = await fixture(t);
    const a = event();
    const records = recordsFor([['intent',a],['commit',a]],f.signing.privateKey);
    await f.put(records,headFor(records,true));
    await rejectsStartupUnchanged(f,{},/explicit fenced recovery/);
  });
});

test('explicit recovery proves each uncheckpointed commit against fixed source before advancing head', async t => {
  const f = await fixture(t);
  const a = event();
  const progress = event('target_erased');
  const records = recordsFor([['intent',a],['commit',a],['commit',progress]],f.signing.privateKey);
  await f.put(records,headFor(records.slice(0,2)));
  f.source.origin.fenced = true;
  f.source.add(progress);
  const writer = await f.open({mode:'recover_fenced'});
  assert.deepEqual(JSON.parse(await readFile(f.checkpointPath,'utf8')),headFor(records));
  const before = await f.snapshot();
  await assert.rejects(() => writer.port.beforeCommit(event('acceptance',{jobId:jobB})),/cannot accept requests/);
  await f.assertUnchanged(before);
  const head = await writer.fence();
  assert.equal(f.source.acks.has(progress.eventId),true);
  assert.deepEqual(verifyPrivacyJournal(await readFile(f.file),{...pins,publicKey:writer.publicKey,head}).events,[a,progress]);
});

test('recovery rejects absent or conflicting fixed-source commits without repinning bytes', async t => {
  for (const mismatch of ['absent','digest','payload']) await t.test(mismatch,async t => {
    const f = await fixture(t);
    const a = event();
    const progress = event('target_erased');
    const records = recordsFor([['intent',a],['commit',a],['commit',progress]],f.signing.privateKey);
    await f.put(records,headFor(records.slice(0,2)));
    f.source.origin.fenced = true;
    if (mismatch !== 'absent') {
      const conflicting = clone(progress);
      if (mismatch === 'digest') conflicting.payloadDigest = 'f'.repeat(64);
      if (mismatch === 'payload') conflicting.payload.data = {changed:true};
      f.source.add(conflicting);
    }
    await rejectsStartupUnchanged(f,{mode:'recover_fenced'},/Recovery source commit mismatch/);
  });
});

test('recovery cannot promote a rollback contradicted by committed fixed-source evidence', async t => {
  const f = await fixture(t);
  const a = event();
  const rolled = event('acceptance',{jobId:jobB});
  const records = recordsFor([['intent',a],['commit',a],['intent',rolled],['rollback',rolled]],f.signing.privateKey);
  await f.put(records,headFor(records.slice(0,2)));
  f.source.origin.fenced = true;
  f.source.add(rolled);
  await rejectsStartupUnchanged(f,{mode:'recover_fenced'},/Rollback conflicts with committed source/);
});

test('unresolved recovered intent stays unverifiable until fenced source proves rollback', async t => {
  const f = await fixture(t);
  const a = event();
  const pending = event('acceptance',{jobId:jobB});
  const records = recordsFor([['intent',a],['commit',a],['intent',pending]],f.signing.privateKey);
  await f.put(records,headFor(records.slice(0,2)));
  f.source.origin.fenced = true;
  const writer = await f.open({mode:'recover_fenced'});
  // A fenced flag alone cannot turn the unresolved bytes into authorization.
  assert.throws(() => verifyPrivacyJournal(bytesFor(records),{...pins,publicKey:writer.publicKey,head:headFor(records,true)}),/unresolved intent/);
  const head = await writer.fence();
  const all = (await readFile(f.file,'utf8')).trimEnd().split('\n').map(JSON.parse);
  assert.equal(all.at(-1).kind,'rollback');
  assert.equal(all.at(-1).event.eventId,pending.eventId);
  assert.deepEqual(verifyPrivacyJournal(await readFile(f.file),{...pins,publicKey:writer.publicKey,head}).events,[a]);
});

test('fenced recovery reconciles a matching durable acceptance intent with committed source', async t => {
  const f = await fixture(t);
  const a = event();
  const b = event('acceptance',{jobId:jobB});
  const records = recordsFor([['intent',a],['commit',a],['intent',b]],f.signing.privateKey);
  await f.put(records,headFor(records.slice(0,2)));
  f.source.origin.fenced = true;
  f.source.add(b);
  const writer = await f.open({mode:'recover_fenced'});
  const head = await writer.fence();
  assert.equal(f.source.acks.has(b.eventId),true);
  assert.equal(head.seq,4);
  assert.deepEqual(verifyPrivacyJournal(await readFile(f.file),{...pins,publicKey:writer.publicKey,head}).events,[a,b]);
});

test('a terminal rollback cannot be reopened by either beforeCommit or afterCommit', async t => {
  const f = await fixture(t);
  const rolled = event();
  await f.put(recordsFor([['intent',rolled],['rollback',rolled]],f.signing.privateKey));
  const writer = await f.open();
  const before = await f.snapshot();
  await assert.rejects(() => writer.port.beforeCommit(rolled),/already resolved|transition conflict/);
  f.source.add(rolled);
  await assert.rejects(() => writer.port.afterCommit(rolled.eventId),/transition conflict/);
  await f.assertUnchanged(before);
});

test('owner-only key, checkpoint, journal, and directory permissions are enforced', async t => {
  for (const part of ['privateKeyPath','checkpointPath','file','directory']) await t.test(part,async t => {
    const f = await fixture(t);
    const a = event();
    await f.put(recordsFor([['intent',a],['commit',a]],f.signing.privateKey));
    await chmod(f[part],part === 'directory' ? 0o755 : 0o644);
    await rejectsStartupUnchanged(f,{},/Owner-only/);
  });
});

test('a second writer cannot take an existing lock and does not remove the first lock', async t => {
  const f = await fixture(t);
  const first = await f.open();
  const before = await f.snapshot();
  await assert.rejects(() => f.open(),{code:'EEXIST'});
  await f.assertUnchanged(before);
  assert.notEqual(await optionalBytes(join(f.directory,'writer.lock')),null);
  await first.port.beforeCommit(event());
  assert.equal((await readFile(f.file,'utf8')).trimEnd().split('\n').length,1);
});
