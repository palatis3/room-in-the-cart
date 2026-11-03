# Proposed durable port contract — API sketch only

This is a provider-neutral review artifact, not installed TypeScript or a tested adapter. It is subordinate to `RUNTIME-OPTIONS.md` and the approved journal authorization/restore design. No new network signing or import API is proposed.

```ts
// Existing names/payload/head and v1 wire records remain compatible.
// Proposed call context; exact public TypeScript form requires implementation review.
type JournalCall = Readonly<{
  attemptId: string;       // random operation identity; no client token/PII
  deadlineUnixMs: number;  // one caller-owned absolute deadline
  signal: AbortSignal;
}>;

interface DurablePrivacyJournalPort {
  readonly configurationId: string;
  beforeCommit(sqlResult: PrivacyJournalEvent, call: JournalCall): Promise<void>;
  afterCommit(eventId: string, call: JournalCall): Promise<void>;
  acknowledgeJob(jobId: string, call: JournalCall): Promise<void>;
}

// Constructor-only pins; callers cannot supply these per operation.
type DurablePins = Readonly<{
  lineage: string;
  schemaDigest: string;
  configurationId: string;
  keyId: string;
  publicKeyFingerprint: string;
  sourceIdentity: string;      // exact registered source, not an arbitrary URL
  recordNamespace: string;
  checkpointAuthority: string;
  deploymentPrincipal: string;
}>;

type AdmittedHead = Readonly<{
  head: PrivacyJournalHead;    // existing exact v1 head
  generation: string;          // transport authority, not added to v1 wire record
  authorityRevision: string;
}>;

type RecordIdentity = Readonly<{
  seq: number;
  previousHash: string;
  recordHash: string;          // SHA256 of existing canonical signed record
  byteLength: number;
  eventId: string;
  payloadDigest: string;
  jobId: string;
  transition: 'intent' | 'commit' | 'rollback';
}>;

type AppendTicket = Readonly<{
  operationId: string;
  generation: string;
  expected: AdmittedHead;
  record: RecordIdentity;
  objectKey: string;
  authorityExpiresAtUnixMs: number;
}>;

type StoredRecord = Readonly<{
  objectKey: string;
  immutableVersion: string;
  recordHash: string;
  byteLength: number;
}>;

type AdmissionReceipt = Readonly<{
  operationId: string;
  admitted: AdmittedHead;
  record: RecordIdentity;
  stored: StoredRecord;
  authorityReceipt: string;    // independently authenticated/verified receipt
}>;

interface ImmutableRecordTransport {
  // Scope is constructor-pinned; conditional create, exact duplicate only.
  putExact(ticket: AppendTicket, canonicalRecord: Uint8Array,
           call: JournalCall): Promise<StoredRecord>;
  readExact(reference: StoredRecord, call: JournalCall): Promise<Uint8Array>;
}

interface CheckpointAuthority {
  readCurrent(call: JournalCall): Promise<AdmittedHead>;
  reserve(expected: AdmittedHead, record: RecordIdentity,
          call: JournalCall): Promise<AppendTicket>;
  publish(ticket: AppendTicket, stored: StoredRecord,
          call: JournalCall): Promise<AdmissionReceipt>;
  inspectOperation(operationId: string, call: JournalCall): Promise<
    | { state: 'absent' }
    | { state: 'pending' | 'blocked'; ticket: AppendTicket }
    | { state: 'admitted'; receipt: AdmissionReceipt }
  >;
}

// A private object, never implemented by the public app/worker DB role.
interface FixedCommittedSource {
  readOrigin(call: JournalCall): Promise<RegisteredOrigin>;
  readCommittedEvent(eventId: string, call: JournalCall): Promise<PrivacyJournalEvent>;
  listUnacknowledgedJobEvents(jobId: string, call: JournalCall): Promise<string[]>;
  acknowledge(eventId: string, payloadDigest: string,
              commitRecordSeq: number, commitRecordHash: string,
              verifiedReceipt: AdmissionReceipt, call: JournalCall): Promise<void>;
}
```

`FixedCommittedSource.acknowledge` is a **trusted Node boundary** that verifies the receipt before invoking the existing private SQL acknowledgement. PostgreSQL currently checks the immutable event/digest and acknowledgement identity, not the external receipt. The sketch does not imply SQL already accepts/verifies that receipt argument. A future least-privilege observer interface requires reviewed read helpers/grants; no ordinary app/worker raw outbox access is added.

`beforeCommit` receives a candidate only from the actual SQL call in its trusted acceptance process. It is never remotely callable with arbitrary event JSON. `afterCommit` and `acknowledgeJob` resolve all payloads through `FixedCommittedSource`; no supplied target, policy Boolean, provider status or raw candidate may replace that lookup.

`attemptId` identifies one caller attempt; it is not the idempotency identity. The adapter derives a stable operation identity from pinned origin plus event ID, payload digest and transition. The authority's event/transition index finds the original receipt across process restarts and different caller attempts; random attempt IDs must not create duplicate canonical transitions.

`reserve` atomically admits only `(active mode, exact expected generation/head, no pending slot)` or returns the exact already-completed idempotent operation. It binds the writer principal and record identity to one ticket. An event ID with another digest is a conflict; an existing event transition cannot be duplicated at a fresh sequence. The authority must independently validate transition dependencies at publication and maintain event state in the same atomic operation as its head.

`publish` is not a trusted Boolean from the writer. The authority reads the exact stored version and validates the canonical signed bytes, length/hash, pinned key/source/configuration, previous chain link, event dependencies, ticket identity, still-current generation and authority-clock deadline before atomically changing head/event state. The receipt identifies the admitted record and exact storage version. Same-operation retries return the same immutable receipt. A later head does not change the original commit record identity used for SQL acknowledgement.

All transport errors that leave an uncertain slot poison the adapter and keep the origin blocked. No implicit lease expiry, reinitialization, arbitrary sequence allocation, fallback success or response-first append is permitted. Cancellation cannot erase a completed remote action. A failed phase does not imply remote absence; exact operation inspection and fixed-source recovery determine the outcome.

Under the existing approved contract, an acknowledgement already sent before timeout may complete later and permit worker eligibility if the exact committed observation and independent head were durable first. The original status capability recovers that safely committed result. Strictly preventing eligibility after an HTTP timeout is an optional new product rule, not a required SQL guard or blocker for this contract.

Operator `beginFence`, recovery append and `seal` intentionally do not appear on the ordinary interfaces. They require separately held recovery authority, persistent generation fencing, completion of the monotonic SQL source fence and exact source reconciliation before rollback/final sealed head. Ordinary writer credentials cannot clear that state.
