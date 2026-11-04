import type {KeyObject} from 'node:crypto';
import type {PrivacyJournalEvent, PrivacyJournalHead} from './privacy-journal.js';
import {ServiceError} from './errors.js';

/** A definite contention response. The rejected call did not acquire a claim or allowance. */
export class JournalWriterBusy extends ServiceError {
 constructor(){super(503,'deletion_journal_busy','The deletion journal is busy. Check any saved receipt and try again.');}
}

/** One caller-owned deadline. Every implementation must pass signal to its actual I/O. */
export interface JournalCall {
 readonly attemptId:string;
 readonly deadlineUnixMs:number;
 readonly signal:AbortSignal;
}
/** A fresh adapter-generated challenge authenticates observations, not immutable receipts. */
export interface AuthorityCall extends JournalCall { readonly requestNonce:string }
export interface DurableJournalPins {
 readonly lineage:string;
 readonly schemaDigest:string;
 readonly configurationId:string;
 readonly keyId:string;
 readonly publicKeyFingerprint:string;
 readonly sourceIdentity:string;
 readonly recordStoreIdentity:string;
 readonly recordNamespace:string;
 readonly checkpointAuthority:string;
 readonly deploymentPrincipal:string;
 readonly authorityKeyId:string;
 readonly authorityPublicKeyFingerprint:string;
}
export interface RegisteredOrigin {
 readonly lineage:string;
 readonly schemaDigest:string;
 readonly configurationId:string;
 readonly sourceIdentity:string;
 readonly fenced:boolean;
}
export type JournalTransition='intent'|'commit'|'rollback';
export type WorkerJournalKind='target_erased'|'source_pending'|'source_completed';
export interface AdmittedHead {
 readonly head:PrivacyJournalHead;
 readonly generation:number;
 readonly authorityRevision:number;
 readonly mode:'active'|'pending'|'blocked'|'recovery'|'sealed';
 readonly pendingOperation:string|null;
 readonly totalBytes:number;
}
export interface JournalCapacity {
 readonly mode:AdmittedHead['mode'];
 readonly uncertain:boolean;
 readonly usedRecords:number;
 readonly reservedRecords:number;
 readonly usedBytes:number;
 readonly reservedBytes:number;
}
export interface RecordIdentity {
 readonly seq:number;
 readonly previousHash:string;
 readonly recordHash:string;
 /** UTF-8 canonical signed v1 record plus its single LF. */
 readonly byteLength:number;
 readonly eventId:string;
 readonly payloadDigest:string;
 readonly jobId:string;
 readonly transition:JournalTransition;
}
export interface AppendTicket {
 readonly operationId:string;
 readonly generation:number;
 readonly expected:AdmittedHead;
 readonly record:RecordIdentity;
 readonly objectKey:string;
 readonly authorityExpiresAtUnixMs:number;
 readonly workerKind?:WorkerJournalKind|undefined;
}
export interface StoredRecord {
 readonly objectKey:string;
 readonly immutableVersion:string;
 readonly recordHash:string;
 readonly byteLength:number;
}
/** Strict canonical JSON body is Ed25519-signed with the constructor-pinned authority key. */
export interface AuthorityEnvelope<T> {
 readonly version:1;
 readonly domain:'ritc-privacy-journal-authority-v1';
 readonly scopeDigest:string;
 readonly authorityKeyId:string;
 readonly requestNonce:string;
 readonly value:T;
 readonly authoritySignature:string;
}
/** Immutable receipt: no freshness nonce; retries retain this exact record/storage identity. */
export interface AdmissionReceipt {
 readonly version:1;
 readonly domain:'ritc-privacy-journal-admission-v1';
 readonly scopeDigest:string;
 readonly authorityKeyId:string;
 readonly operationId:string;
 readonly admitted:AdmittedHead;
 readonly record:RecordIdentity;
 readonly stored:StoredRecord;
 readonly authoritySignature:string;
}
export type OperationInspection=
 | {readonly state:'absent';readonly operationId:string}
 | {readonly state:'pending'|'blocked';readonly operationId:string;readonly ticket:AppendTicket}
 | {readonly state:'admitted';readonly operationId:string;readonly receipt:AdmissionReceipt};

/** Constructor-scoped immutable object capability; no list, delete or overwrite authority. */
export interface ImmutableRecordTransport {
 putExact(ticket:AppendTicket,canonicalRecord:Uint8Array,call:JournalCall):Promise<StoredRecord>;
 readExact(reference:StoredRecord,call:JournalCall):Promise<Uint8Array>;
}
/**
 * Required remote semantics, not guarantees manufactured by this client:
 * strongly consistent challenge-bound reads; atomic generation/mode/head CAS and
 * event/transition index; no lease takeover; authority-clock expiry; independent
 * exact-version read + canonical/signature/schema/dependency verification at
 * publish; atomic retained receipt/head/index update. A writer cannot reset/fence.
 */
export interface CheckpointAuthority {
 readCurrent(call:AuthorityCall):Promise<AuthorityEnvelope<AdmittedHead>>;
 readCapacity?(call:AuthorityCall):Promise<AuthorityEnvelope<JournalCapacity>>;
 inspectOperation(operationId:string,call:AuthorityCall):Promise<AuthorityEnvelope<OperationInspection>>;
 reserve(expected:AdmittedHead,record:RecordIdentity,call:AuthorityCall,workerKind?:WorkerJournalKind):Promise<AuthorityEnvelope<AppendTicket>>;
 publish(ticket:AppendTicket,stored:StoredRecord,call:AuthorityCall):Promise<AdmissionReceipt>;
 reserveWorkerCapacity?(jobId:string,kinds:readonly WorkerJournalKind[],call:JournalCall):Promise<boolean>;
}
export interface UncertaintyOperation {
 readonly scopeDigest:string;
 readonly eventId:string;
 readonly transition:'intent'|'commit';
}
export interface UncertaintyClaim extends UncertaintyOperation {
 readonly claimId:string;
}
/**
 * REQUIRED durable, strongly consistent origin guard, shared by every instance.
 * All authorized deployment scopes for one immutable source lineage MUST map to
 * the same origin lock; deploymentPrincipal/scope rotation cannot bypass a claim.
 * begin atomically persists an exclusive, non-expiring claim before returning.
 * Any outstanding claim (even the same operation) rejects begin. complete may
 * release only that exact claim after verifying the supplied durable admission
 * proof binds its scope, event ID and transition. This capability is authenticated
 * and constructor-scoped; an ordinary writer cannot delete someone else's claim.
 * Lost begin/PUT/publish responses therefore leave a blocking claim. No ordinary
 * reset, TTL or process-local implementation is sufficient. Operator reconciliation
 * requires a separate capability, absent from this interface. A complete response
 * may be lost after release; this is safe because all journal outcomes are already
 * authenticated and durable before complete is invoked.
 */
export interface DurableUncertaintyStore {
 begin(operation:UncertaintyOperation,call:JournalCall):Promise<UncertaintyClaim>;
 /** A null result is a capacity refusal. No claim was persisted. */
 beginIntent?(operation:UncertaintyOperation,recordByteBound:number,call:JournalCall):Promise<UncertaintyClaim|null>;
 complete(claim:UncertaintyClaim,proof:AdmissionReceipt,call:JournalCall):Promise<void>;
}
/** Private committed observer. Implementations must never use the public app/worker role. */
export interface FixedCommittedSource {
 readOrigin(call:JournalCall):Promise<RegisteredOrigin>;
 readCommittedEvent(eventId:string,call:JournalCall):Promise<PrivacyJournalEvent>;
 readCommittedAcceptance(jobId:string,call:JournalCall):Promise<PrivacyJournalEvent>;
 listUnacknowledgedJobEvents(jobId:string,call:JournalCall):Promise<readonly string[]>;
 /**
  * Trusted Node boundary. The adapter verifies the receipt immediately before
  * calling; a source implementation must repeat verification if it crosses any
  * additional trust boundary. SQL does not verify an external receipt. Already
  * issued acknowledgement can safely complete late; no call may start after abort.
  */
 acknowledge(eventId:string,payloadDigest:string,commitRecordSeq:number,
  commitRecordHash:string,verifiedReceipt:AdmissionReceipt,call:JournalCall):Promise<void>;
}
export interface DurablePrivacyJournalPort {
 readonly configurationId:string;
 beforeCommit(candidate:PrivacyJournalEvent,call:JournalCall):Promise<void>;
 afterCommit(eventId:string,call:JournalCall):Promise<void>;
 acknowledgeJob(jobId:string,call:JournalCall):Promise<void>;
 reserveWorkerCapacity(jobId:string,kinds:readonly WorkerJournalKind[],call:JournalCall):Promise<boolean>;
}
export interface DurablePrivacyJournalConfiguration {
 readonly pins:DurableJournalPins;
 readonly privateKey:KeyObject;
 readonly authorityPublicKey:KeyObject|string;
 readonly source:FixedCommittedSource;
 readonly records:ImmutableRecordTransport;
 readonly authority:CheckpointAuthority;
 readonly uncertainty:DurableUncertaintyStore;
 /** Injectable only for deterministic testing; production defaults to Date.now. */
 readonly clock?:{now():number};
}
