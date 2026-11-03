import assert from 'node:assert/strict';
import {createHash, generateKeyPairSync, sign} from 'node:crypto';
import {existsSync} from 'node:fs';
import test from 'node:test';

// Runs both from the staging lane and after installation under service/tests.
const installed = new URL('../dist/privacy-journal.js', import.meta.url);
const moduleURL = existsSync(installed) ? installed : new URL('../../../core/service/dist/privacy-journal.js', import.meta.url);
const {journalCanonical, journalHash, verifyPrivacyJournal} = await import(moduleURL.href);

// Fixture signatures and private keys exist only in memory and are never logged.
const signing = generateKeyPairSync('ed25519');
const unpinned = generateKeyPairSync('ed25519');
const publicKey = signing.publicKey.export({type:'spki',format:'pem'}).toString();
const origin = Object.freeze({
  lineage:'10000000-0000-4000-8000-000000000001',
  schemaDigest:'a'.repeat(64),
  configurationId:'local-protocol-fixture-v1',
});
const keyId = 'protocol-test-key';
const jobA = '20000000-0000-4000-8000-000000000001';
const jobB = '20000000-0000-4000-8000-000000000002';
const zero = '0'.repeat(64);
let nextEvent = 0;

// Independent fixture serializer/hash, rather than asking the verifier to sign
// or hash the input it will subsequently be expected to reject.
function canonical(value) {
  if (value === null || typeof value !== 'object') return JSON.stringify(value);
  if (Array.isArray(value)) return `[${value.map(canonical).join(',')}]`;
  return `{${Object.keys(value).sort().map(k => `${JSON.stringify(k)}:${canonical(value[k])}`).join(',')}}`;
}
const hash = value => createHash('sha256').update(canonical(value)).digest('hex');
const rawHash = bytes => createHash('sha256').update(bytes).digest('hex');
const clone = value => structuredClone(value);

function event(kind = 'acceptance', options = {}) {
  const eventId = options.eventId ?? `30000000-0000-4000-8000-${(++nextEvent).toString(16).padStart(12,'0')}`;
  const payload = {version:1,eventId,...origin,jobId:jobA,kind,data:{},...options};
  delete payload.payloadDigest;
  return {eventId,payloadDigest:hash(payload),payload};
}
function signed(unsigned, privateKey = signing.privateKey) {
  return {...unsigned,signature:sign(null,Buffer.from(canonical(unsigned)),privateKey).toString('base64url')};
}
function chain(entries, options = {}) {
  const records = [];
  let previousHash = zero;
  for (const [kind, candidate, extra = {}] of entries) {
    const record = signed({version:1,keyId,seq:records.length+1,previousHash,kind,event:candidate,...extra},options.privateKey);
    records.push(record);
    previousHash = hash(record);
  }
  return bundle(records);
}
function bundle(records) {
  const bytes = Buffer.from(records.map(canonical).join('\n')+'\n');
  const head = {version:1,...origin,seq:records.length,hash:records.length ? hash(records.at(-1)) : zero,fenced:true};
  return {records,bytes,trust:{...origin,keyId,publicKey,head}};
}
const check = candidate => verifyPrivacyJournal(candidate.bytes,candidate.trust);
function reject(candidate, expected, message) {
  assert.throws(() => check(candidate),expected,message);
}
function acceptance() {
  const accepted = event();
  return {accepted,entries:[['intent',accepted],['commit',accepted]]};
}
function withHead(candidate, changes) {
  return {...candidate,trust:{...candidate.trust,head:{...candidate.trust.head,...changes}}};
}

test('canonical serialization sorts object keys, preserves arrays, and has a stable SHA-256', () => {
  const value = {z:[3,{b:true,a:'é'}],a:null};
  const expected = '{"a":null,"z":[3,{"a":"é","b":true}]}';
  assert.equal(journalCanonical(value),expected);
  assert.equal(journalHash(value),createHash('sha256').update(expected).digest('hex'));
});

test('complete signed authorization/progress chain yields only committed events and exact raw bundle digest', () => {
  const a = acceptance();
  const erased = event('target_erased');
  const pending = event('source_pending');
  const completed = event('source_completed');
  const b = event('acceptance',{jobId:jobB});
  const fixture = chain([...a.entries,['commit',erased],['commit',pending],['commit',completed],['intent',b],['commit',b]]);
  const result = check(fixture);
  assert.deepEqual(result.events,[a.accepted,erased,pending,completed,b]);
  assert.deepEqual(result.head,fixture.trust.head);
  assert.equal(result.bundleDigest,rawHash(fixture.bytes));
});

test('resolved rollback contributes no committed authorization or progress', () => {
  const rolledBack = event();
  assert.deepEqual(check(chain([['intent',rolledBack],['rollback',rolledBack]])).events,[]);
  const a = acceptance();
  const progress = event('target_erased');
  assert.deepEqual(check(chain([...a.entries,['intent',progress],['rollback',progress]])).events,[a.accepted]);
});

test('noncanonical NDJSON spelling and duplicate keys are rejected before use', async t => {
  const a = acceptance();
  const fixture = chain(a.entries);
  const first = canonical(fixture.records[0]);
  const second = canonical(fixture.records[1]);
  const spellings = [
    ['leading whitespace',' '+first],
    ['trailing whitespace',first+' '],
    ['unsorted keys',JSON.stringify(fixture.records[0])],
    ['duplicate outer key',first.replace('{','{"version":1,')],
    ['duplicate event key',first.replace('"event":{','"event":{"eventId":'+JSON.stringify(a.accepted.eventId)+',')],
    ['duplicate payload key',first.replace('"payload":{','"payload":{"version":1,')],
    ['duplicate data key',first.replace('"data":{}','"data":{"x":1,"x":1}')],
    ['Unicode escape alias',first.replace('local-protocol','local-\\u0070rotocol')],
  ];
  for (const [label,line] of spellings) await t.test(label,() => {
    reject({...fixture,bytes:Buffer.from(line+'\n'+second+'\n')},/Noncanonical or duplicate-key/);
  });
});

test('unknown fields in signed protocol envelopes and pinned heads fail closed', async t => {
  const a = acceptance();
  for (const level of ['record','event','payload']) await t.test(level,() => {
    const changed = clone(a.accepted);
    const extra = {};
    if (level === 'record') extra.future = true;
    if (level === 'event') changed.future = true;
    if (level === 'payload') {
      changed.payload.future = true;
      changed.payloadDigest = hash(changed.payload);
    }
    reject(chain([['intent',changed,extra],['commit',changed,extra]]));
  });
  await t.test('head',() => reject(withHead(chain(a.entries),{future:true})));
});

test('signed event ID and payload digest conflicts are rejected', async t => {
  const a = acceptance();
  await t.test('envelope eventId differs',() => {
    const changed = {...a.accepted,eventId:'30000000-0000-4000-8000-ffffffffffff'};
    reject(chain([['intent',changed],['commit',changed]]),/event digest conflict/);
  });
  await t.test('payloadDigest differs',() => {
    const changed = {...a.accepted,payloadDigest:'f'.repeat(64)};
    reject(chain([['intent',changed],['commit',changed]]),/event digest conflict/);
  });
});

test('a rehashed payload with an old signature remains unauthorized', () => {
  const a = acceptance();
  const fixture = chain(a.entries);
  const records = clone(fixture.records);
  records[0].event.payload.data = {changed:true};
  records[0].event.payloadDigest = hash(records[0].event.payload);
  reject(bundle(records),/signature rejected/);
});

test('pinned signing key and key ID are independent required checks', async t => {
  const a = acceptance();
  const fixture = chain(a.entries);
  await t.test('valid signature by unpinned Ed25519 key',() => {
    reject(chain(a.entries,{privateKey:unpinned.privateKey}),/signature rejected/);
  });
  await t.test('wrong configured public key',() => {
    reject({...fixture,trust:{...fixture.trust,publicKey:unpinned.publicKey.export({type:'spki',format:'pem'}).toString()}},/signature rejected/);
  });
  await t.test('signed unknown key ID',() => {
    reject(chain(a.entries.map(([kind,e]) => [kind,e,{keyId:'unknown-key'}])),/chain or trust conflict/);
  });
  await t.test('wrong pinned key ID',() => {
    reject({...fixture,trust:{...fixture.trust,keyId:'other-key'}},/chain or trust conflict/);
  });
  await t.test('non-Ed25519 key type',() => {
    const key = generateKeyPairSync('ec',{namedCurve:'prime256v1'}).publicKey.export({type:'spki',format:'pem'}).toString();
    reject({...fixture,trust:{...fixture.trust,publicKey:key}},/Ed25519 key required/);
  });
});

test('interior removal, reorder, duplication, sequence gaps, and bad links fail', async t => {
  const a = acceptance();
  const fixture = chain([...a.entries,['commit',event('target_erased')],['commit',event('source_pending')]]);
  const r = fixture.records;
  for (const [label,records] of [
    ['remove interior',[r[0],r[2],r[3]]],
    ['reorder interior',[r[0],r[2],r[1],r[3]]],
    ['duplicate interior',[r[0],r[1],r[1],r[2],r[3]]],
  ]) await t.test(label,() => reject(bundle(records),/chain or trust conflict/));
  await t.test('signed sequence gap',() => reject(chain([['intent',a.accepted],['commit',a.accepted,{seq:3}]]),/chain or trust conflict/));
  await t.test('signed wrong previousHash',() => reject(chain([['intent',a.accepted],['commit',a.accepted,{previousHash:'b'.repeat(64)}]]),/chain or trust conflict/));
});

test('an authentic earlier prefix is valid only for its own head and cannot satisfy the final pinned head', () => {
  const a = acceptance();
  const early = chain(a.entries);
  const b = event('acceptance',{jobId:jobB});
  const final = chain([...a.entries,['intent',b],['commit',b]]);
  assert.deepEqual(check(early).events,[a.accepted]);
  assert.equal(check(final).events.length,2);
  reject({...early,trust:final.trust},/prefix, unresolved intent, or head conflict/);
  reject({...final,trust:early.trust},/prefix, unresolved intent, or head conflict/);
});

test('a completely signed competing branch cannot satisfy the independently pinned final head', () => {
  const a = acceptance();
  const progress = event('target_erased',{data:{observation:'original'}});
  const original = chain([...a.entries,['commit',progress]]);
  const alternate = event('target_erased',{eventId:progress.eventId,data:{observation:'fork'}});
  const fork = chain([...a.entries,['commit',alternate]]);
  assert.equal(check(fork).events.length,2);
  assert.notEqual(fork.trust.head.hash,original.trust.head.hash);
  reject({...fork,trust:original.trust},/head conflict/);
});

test('unresolved intent and invalid commit/rollback dependencies never authorize events', async t => {
  const a = event();
  const changed = event('acceptance',{eventId:a.eventId,data:{changed:true}});
  const cases = [
    ['unresolved intent',[['intent',a]],/unresolved intent/],
    ['acceptance without intent',[['commit',a]],/no matching durable intent/],
    ['rollback without intent',[['rollback',a]],/no matching (?:unresolved )?intent/],
    ['rollback digest changed',[['intent',a],['rollback',changed]],/no matching (?:unresolved )?intent/],
    ['commit after rollback',[['intent',a],['rollback',a],['commit',a]],/no matching durable intent|already resolved/],
    ['rollback after commit',[['intent',a],['commit',a],['rollback',a]],/no matching (?:unresolved )?intent/],
    ['new intent after rollback',[['intent',a],['rollback',a],['intent',a]],/Duplicate journal intent/],
    ['commit digest changed',[['intent',a],['commit',changed]],/no matching durable intent|Intent digest changed/],
  ];
  for (const [label,entries,error] of cases) await t.test(label,() => reject(chain(entries),error));
});

test('duplicate intents, commits, and accepted jobs fail even with correct signatures and head', async t => {
  const a = acceptance();
  const b = event();
  await t.test('intent',() => reject(chain([['intent',a.accepted],['intent',a.accepted]]),/Duplicate journal intent/));
  await t.test('commit',() => reject(chain([...a.entries,['commit',a.accepted]]),/Duplicate journal commit|already resolved/));
  await t.test('accepted job',() => reject(chain([...a.entries,['intent',b],['commit',b]]),/Duplicate accepted job/));
});

test('every progress kind requires preceding committed acceptance of its exact job', async t => {
  for (const kind of ['target_erased','source_pending','source_completed']) {
    await t.test(kind+' has no acceptance',() => reject(chain([['commit',event(kind)]]),/no preceding accepted authorization/));
    await t.test(kind+' precedes later acceptance',() => {
      const a = acceptance();
      reject(chain([['commit',event(kind)],...a.entries]),/no preceding accepted authorization/);
    });
    await t.test(kind+' has another job acceptance',() => {
      const a = acceptance();
      reject(chain([...a.entries,['commit',event(kind,{jobId:jobB})]]),/no preceding accepted authorization/);
    });
  }
});

test('rolled-back acceptance does not authorize subsequent progress', () => {
  const a = event();
  reject(chain([['intent',a],['rollback',a],['commit',event('target_erased')]]),/no preceding accepted authorization/);
});

test('terminal rollback prevents reopening progress events that otherwise need no intent', async t => {
  for (const kind of ['target_erased','source_pending','source_completed']) await t.test(kind,() => {
    const a = acceptance();
    const progress = event(kind);
    reject(chain([...a.entries,['intent',progress],['rollback',progress],['commit',progress]]),/already resolved/);
  });
});

test('all pinned origin fields bind both head and every signed payload', async t => {
  const a = acceptance();
  const fixture = chain(a.entries);
  const changes = {lineage:'10000000-0000-4000-8000-ffffffffffff',schemaDigest:'f'.repeat(64),configurationId:'different-configuration'};
  for (const [field,value] of Object.entries(changes)) {
    await t.test(field+' head/config mismatch',() => reject({...fixture,trust:{...fixture.trust,[field]:value}},/incompatible fenced head/));
    await t.test(field+' payload/config mismatch',() => reject({...fixture,trust:{...fixture.trust,[field]:value,head:{...fixture.trust.head,[field]:value}}},/chain or trust conflict/));
  }
});

test('unfenced, missing, future-version, wrong sequence, or wrong hash heads fail', async t => {
  const fixture = chain(acceptance().entries);
  await t.test('unfenced',() => reject(withHead(fixture,{fenced:false}),/incompatible fenced head/));
  await t.test('missing',() => reject({...fixture,trust:{...fixture.trust,head:undefined}}));
  await t.test('future version',() => reject(withHead(fixture,{version:2})));
  await t.test('sequence',() => reject(withHead(fixture,{seq:fixture.trust.head.seq+1}),/head conflict/));
  await t.test('hash',() => reject(withHead(fixture,{hash:'f'.repeat(64)}),/head conflict/));
});

test('empty, oversized, or over-count bundles fail within fixed limits', async t => {
  const fixture = chain(acceptance().entries);
  await t.test('empty',() => reject({...fixture,bytes:Buffer.alloc(0)},/Truncated or oversized|Missing journal/));
  await t.test('more than 32 MiB',() => {
    const bytes = Buffer.alloc(32*1024*1024+1,10);
    reject({...fixture,bytes},/Truncated or oversized/);
  });
  await t.test('more than 10,000 records',() => reject({...fixture,bytes:Buffer.from('\n'.repeat(10001))},/Too many journal records/));
});

test('truncation, ambiguous line framing, BOM, and incomplete JSON fail', async t => {
  const fixture = chain(acceptance().entries);
  const first = canonical(fixture.records[0]);
  const cases = [
    ['missing final LF',fixture.bytes.subarray(0,-1)],
    ['partial final record with LF',Buffer.concat([fixture.bytes.subarray(0,fixture.bytes.length-15),Buffer.from('\n')])],
    ['missing complete suffix',Buffer.from(first+'\n')],
    ['internal blank line',Buffer.from(first+'\n\n'+canonical(fixture.records[1])+'\n')],
    ['CRLF',Buffer.from(fixture.bytes.toString().replaceAll('\n','\r\n'))],
    ['extra terminal LF',Buffer.concat([fixture.bytes,Buffer.from('\n')])],
    ['UTF-8 BOM',Buffer.concat([Buffer.from([0xef,0xbb,0xbf]),fixture.bytes])],
  ];
  for (const [label,bytes] of cases) await t.test(label,() => reject({...fixture,bytes}));
});

test('malformed UTF-8 must not normalize into an authentic signed bundle', () => {
  const a = acceptance();
  a.accepted.payload.data = {text:'\ufffd'};
  a.accepted.payloadDigest = hash(a.accepted.payload);
  const fixture = chain(a.entries);
  assert.equal(check(fixture).events.length,1,'canonical UTF-8 replacement character itself is valid');
  const bytes = Buffer.from(fixture.bytes.toString('hex').replaceAll('efbfbd','80'),'hex');
  assert.notEqual(rawHash(bytes),rawHash(fixture.bytes));
  reject({...fixture,bytes},undefined,'invalid UTF-8 must fail before decoding can normalize signed content');
});

test('signature base64url is a unique canonical encoding, including unused final bits', () => {
  const fixture = chain(acceptance().entries);
  const records = clone(fixture.records);
  const signature = records.at(-1).signature;
  const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_';
  const index = alphabet.indexOf(signature.at(-1));
  assert.equal(index%16,0,'64-byte Ed25519 signatures have four unused final base64url bits');
  records.at(-1).signature = signature.slice(0,-1)+alphabet[index+1];
  assert.deepEqual(Buffer.from(records.at(-1).signature,'base64url'),Buffer.from(signature,'base64url'));
  reject(bundle(records),undefined,'noncanonical signature encoding must not be accepted as a distinct signed record');
});
