import assert from 'node:assert/strict';
import {createHash, generateKeyPairSync, randomUUID, sign, verify} from 'node:crypto';

// Independent test-side canonical encoder and hashes. Never import the adapter's
// encoder or receipt verifier to manufacture the expected result.
export function canonical(value) {
  if (value === null || typeof value !== 'object') return JSON.stringify(value);
  if (Array.isArray(value)) return `[${value.map(canonical).join(',')}]`;
  return `{${Object.keys(value).sort().map(key => `${JSON.stringify(key)}:${canonical(value[key])}`).join(',')}}`;
}
export const digest = value => createHash('sha256').update(canonical(value)).digest('hex');
export const bytesDigest = value => createHash('sha256').update(value).digest('hex');
export const clone = value => structuredClone(value);
export const zero = '0'.repeat(64);

export function keys() {
  const pair = generateKeyPairSync('ed25519');
  const publicKey = pair.publicKey.export({type:'spki', format:'pem'}).toString();
  return {...pair, publicKeyPEM:publicKey, fingerprint:bytesDigest(pair.publicKey.export({type:'spki',format:'der'}))};
}

export function acceptedEvent(origin, options = {}) {
  const householdId = options.householdId ?? randomUUID();
  const memberId = options.memberId ?? randomUUID();
  const at = '2026-11-03T12:00:00.000Z';
  const identityHash = 'a'.repeat(64);
  const binding = {household_id:householdId,member_id:memberId,kind:'adult',state:'active',organizer:true,can_contribute:true,erased_at:null,identity_hash:identityHash};
  const payload = {
    version:1,eventId:options.eventId ?? randomUUID(),...origin,jobId:options.jobId ?? randomUUID(),kind:'acceptance',
    data:{
      identityHash,receiptHash:'b'.repeat(64),requestDigest:'c'.repeat(64),acceptedAt:at,
      receiptDays:1,markerDays:2,receiptUntil:'2026-11-04T12:00:00.000Z',markerUntil:'2026-11-05T12:00:00.000Z',
      attestation:{configurationId:origin.configurationId,authenticatedAt:at,authenticatedMethod:'otp',providerAvailability:'configured_adapter_passed',appleGate:'availability_contract_passed',sqlAdultScopeCheck:'passed',policy:{receiptRetentionDays:1,erasureMarkerRetentionDays:2,verifiedBackupRetentionDays:1},sessionBindingHash:'d'.repeat(64),checkedAt:at},
      targets:[{householdId,memberId,kind:'self_adult',binding}],
      effects:[{table:'member',key:`${householdId}/${memberId}`,before:binding,after:{...binding,state:'revoked',organizer:false,can_contribute:false}}],
    },
  };
  return {eventId:payload.eventId,payloadDigest:digest(payload),payload};
}

export function progressEvent(acceptance, kind = 'target_erased', changes = {}) {
  const {householdId,memberId} = acceptance.payload.data.targets[0];
  const payload = {
    ...acceptance.payload,eventId:randomUUID(),kind,
    data:kind === 'target_erased'
      ? {householdId,memberId,retiredPurchases:[],erasedAt:'2026-11-03T12:01:00.000Z'}
      : {appErasedAt:'2026-11-03T12:01:00.000Z',providerErasedAt:kind === 'source_completed' ? '2026-11-03T12:02:00.000Z' : null,completedAt:kind === 'source_completed' ? '2026-11-03T12:02:00.000Z' : null,receiptUntil:'2026-11-04T12:00:00.000Z',markerUntil:'2026-11-05T12:00:00.000Z'},
    ...changes,
  };
  return {eventId:payload.eventId,payloadDigest:digest(payload),payload};
}

export function gate() {
  let resolve, reject;
  const promise = new Promise((ok, bad) => {resolve=ok;reject=bad;});
  return {promise,resolve,reject};
}

export function assertCanonicalRecord(bytes, publicKey, expected) {
  const raw = Buffer.from(bytes);
  const parsed = JSON.parse(raw.toString('utf8'));
  assert.equal(raw.toString('utf8'),canonical(parsed)+'\n');
  assert.deepEqual(Object.keys(parsed).sort(),['event','keyId','kind','previousHash','seq','signature','version']);
  const {signature,...unsigned}=parsed;
  assert.equal(parsed.version,1);
  assert(verify(null,Buffer.from(canonical(unsigned)),publicKey,Buffer.from(signature,'base64url')));
  assert.equal(parsed.seq,expected.seq);
  assert.equal(parsed.previousHash,expected.previousHash);
  assert.equal(digest(parsed),expected.recordHash);
  assert.equal(parsed.event.eventId,expected.eventId);
  assert.equal(parsed.event.payloadDigest,expected.payloadDigest);
  assert.equal(parsed.event.payload.jobId,expected.jobId);
  assert.equal(parsed.kind,expected.transition);
  assert.equal(digest(parsed.event.payload),parsed.event.payloadDigest);
  return parsed;
}

export function signEnvelope(body, authorityPrivateKey) {
  return {...body,signature:sign(null,Buffer.from(canonical(body)),authorityPrivateKey).toString('base64url')};
}

export function checkCall(call) {
  assert(call && typeof call.attemptId === 'string');
  assert(call.signal instanceof AbortSignal);
  if (call.signal.aborted || Date.now() >= call.deadlineUnixMs) throw Error('Fixture call cancelled or expired');
}

export function call(options = {}) {
  const controller = new AbortController();
  const value={attemptId:randomUUID(),deadlineUnixMs:Date.now()+4000,signal:controller.signal,...options};
  Object.defineProperty(value,'controller',{value:controller});
  return value;
}
