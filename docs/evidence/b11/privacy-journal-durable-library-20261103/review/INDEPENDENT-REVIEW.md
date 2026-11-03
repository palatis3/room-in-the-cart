# Independent option A review

Verdict: no remaining concrete blocking finding in the frozen provider-neutral
scratch library reviewed here. This is a local client-library review, not
production readiness or remote durability approval.

Review scope is the provider-neutral scratch adapter, its actual tests, and the
minimum service/shared-validation hooks. The production repository was read only.
No provider, resources, credentials, deployment, SQL membership, runtime
availability, or deletion processing was changed by this review.

Authoritative source reviewed:

- `docs/evidence/b11/privacy-journal-runtime-design-20261103/RUNTIME-OPTIONS.md`
- `docs/evidence/b11/privacy-journal-runtime-design-20261103/PORT-CONTRACT.md`
- `service/src/privacy-journal.ts`
- `service/src/privacy.ts`
- `service/migrations/022_privacy_journal.sql`

## Review findings resolved before final validation

1. **High priority: private witness PEM accepted as a public key.** The original
   factory and standalone receipt verifier called `createPublicKey(string)`,
   which can silently derive a public key from private PEM. That could admit
   independent checkpoint signing material into the application process. The
   final `pinnedPublicKey` accepts only public `KeyObject` or public SPKI PEM;
   factory and standalone verifier also reject shared signer/witness keys.
   Constructor and standalone-verifier regression cases pass.
2. **High priority: historical intent receipt bypassed current authority state.**
   The original retry path returned an earlier admitted intent without checking
   the fresh active head. During authority fencing before the SQL fence finishes,
   the source can legitimately remain unfenced while a fresh operation inspection
   still returns a historical receipt. The final `beforeCommit` calls `covered`
   for both existing and newly published intents before guard completion. Tests
   reject recovery/sealed state, active generation rollover, and a fence between
   publication and phase completion. The test agent retained the initial red
   reproduction separately; the final independent run is green.
3. **Authorization binding tightened during review.** Strict progress validation
   now requires the original committed acceptance to match its admitted commit
   receipt and exact signed object bytes before a new progress PUT. A different,
   self-consistent acceptance with the same job cannot substitute content or
   targets. Both changed-content and changed-target regressions pass.

## Final code and test checks

- The trusted signer snapshots constructor pins and caller event, validates the
  strict shared payload schemas before remote reservation, and exposes no HTTP
  route or generic remote signing service. It must still be wired only to the
  actual trusted SQL acceptance callback.
- Head/operation/ticket observations bind a fresh adapter-generated nonce, exact
  domain, scope and authority key. Receipts are independently signed immutable
  proofs binding record identity, admitted head, object key/version, hash and
  length. Canonical v1 records, signatures and LF are retained.
- Committed observations are event-ID-only lookups through the fixed source.
  Returned event IDs, requested job IDs, original acceptance, envelope digests and
  constructor pins are checked. Strict content and original authorization checks
  precede progress storage.
- SQL acknowledgement starts only after the committed record and independent
  admission are durable and freshly covered. It uses the original commit record
  sequence/hash on retry even after later heads. The code checks the owned call
  immediately before invoking the source acknowledgement capability.
- A caller-linked `AbortController` owns the absolute deadline and passes its
  signal into every injected operation. Phase checks prevent a late result from
  starting the next side effect. The automatic-deadline test observes actual
  cancellation of the in-flight transport signal. The race bounds the client
  continuation as well; it does not undo a remote mutation already accepted.
- The required shared non-expiring uncertainty claim starts before mutable
  per-event work. Lost reserve/PUT/publish responses leave a claim that blocks
  reconstructed instances. Completion requires the held claim and exact
  authenticated event/transition proof. A lost completion response can permit
  exact retry only after the required outcome was already safely known.
- Contract text requires every authorized deployment scope for one immutable
  origin to share that same guard. Ordinary interfaces provide no reset,
  automatic lease takeover, generation fence, rollback or seal capability.
- Append checks the authenticated global 10,000-record and 32-MiB limits before
  PUT. Empty acknowledged-job reconciliation remains a repeatable read-only
  success after the ordinary acceptance path.
- Source/job substitution, stale observations, changed event digests, altered
  signed receipts/tickets, wrong storage versions, unrelated completion proofs,
  delayed fenced PUTs, automatic deadline and cancellation cases are covered.

Independent validation used the existing local Node v22.14.0 and TypeScript
5.7.3 tools; no downloads or heavy builds were run:

```text
tsc --noEmit -p service/tsconfig.json: exit 0
node --test service/tests/privacy-journal-durable.test.mjs: 89/89 passed
```

The independent full TAP is `independent-adapter-tests.tap`; candidate and
authoritative-source hashes are in `reviewed-candidate.json`. The review changed
only files under this `review/` directory. It did not edit library or tests.

## Necessary integration boundaries remain explicit

The existing SQL acknowledgement checks immutable event/digest and exact replay
identity; it does not verify an external receipt. The future private source
wrapper must verify receipt authenticity and expected event/digest/sequence/hash
at any additional trust boundary. It must check cancellation after asynchronous
connection acquisition and immediately before actual SQL dispatch. Merely
entering the source method before abort does not authorize sending a queued SQL
acknowledgement after abort. An acknowledgement already sent while valid may
safely complete late under the approved contract.

The original `PrivacyService` still needs a separately reviewed call-owned
end-to-end deadline, actual request-disconnect signal and immediate pre-COMMIT
check. Existing gate order and status-capability verification must remain. The
current `pg` path is not proved cancellable by the injected source interface.
Bounded private observer read helpers/grants, if needed, remain separate review
work; no SQL signature, LOGIN, password, membership or ordinary raw outbox access
was changed here. The shared-hook proposal preserves runtime unavailability and
cleanup-only maintenance.

The checkpoint and uncertainty interfaces are required remote semantics. The
client cannot manufacture atomic CAS, independently retained history, persistent
claims, credential isolation, exact-version immutable storage or transport
cancellation in an implementation that does not provide them. Provider-specific
work and an approved real remote rehearsal must prove those properties and
latency against the existing phase/SQL/request limits. The test backend is
in-memory shared state, including its committed source and acknowledgement
model. Canonical restore compatibility uses a synthetic pinned fenced head; it
does not implement operator sealing or remote disaster recovery. No real provider
or PostgreSQL operation is invoked by this focused suite. Operator recovery must
complete the monotonic SQL source fence before source absence can justify
rollback; these ordinary interfaces do not implement that recovery workflow.

The approved late-ack behavior is retained. A stricter rule forbidding worker
eligibility after an HTTP timeout was not introduced as a review requirement.

