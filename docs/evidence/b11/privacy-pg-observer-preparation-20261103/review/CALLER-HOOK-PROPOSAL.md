# Narrow caller integration proposal — parent-owned files

Candidate export (scratch only):

```ts
createPostgresCommittedSource(configuration): {
  readonly source: FixedCommittedSource;
  close(): Promise<void>;
}
```

Configuration is constructor-owned: immutable DurableJournalPins, independent public authority key, exact connection endpoint/database/user, database OID, observer-role OID, trusted migration owner name/OID and application name. No caller-supplied Pool, query function, connection URL, arbitrary SQL or SET ROLE. The source supplies the existing FixedCommittedSource contract directly to the durable journal library.

The proposed024 registration is a separate owner action. Migration installation alone creates no observer login, changes no membership, grants no app/worker access, registers no source and enables no runtime.

## Root-owned HTTP / PrivacyService call boundary

1. Produce one attempt ID, absolute deadline and AbortSignal per authorized call. Combine server deadline/request-disconnect/shutdown reasons through an actual controller; do not replace an aborted call with a fresh controller within the same operation.
2. Preserve existing authorization/provider/policy gates and exact original operation context. The adapter accepts no user-selected source or target query, only fixed event/job IDs already bound by the durable client.
3. Carry the same JournalCall through all durable phases. A Promise.race deadline alone does not cancel database/network I/O.
4. For the application's own DB transaction, check cancellation after pool acquisition and immediately before every SQL dispatch and COMMIT. This source adapter only controls its separate observer connection; it cannot cancel an unrelated application transaction on root's behalf.
5. A source error has generic message and structured `sqlDispatched` and `acknowledgementMayHaveCommitted` flags. Preserve uncertainty after an already-issued acknowledgement COMMIT; do not manufacture failure/rollback or replay a new acceptance. Reconcile the original operation/event through the existing exact retry path.
6. Shut down the adapter explicitly with close(). Do not construct it or change default availability unless independent durable record/checkpoint services, source registration, receipt trust and all existing authorization/provider/policy gates are configured. Current disabled defaults remain unchanged.

## Evidence boundaries

Actual local PostgreSQL tests are being implemented for the proposed functions/role restrictions/pool behavior/cancellation. Their independently signed authority receipts use synthetic fixture keys and synthetic remote services. Neither passing local tests nor this constructor provides real remote durability, deployment identity or provider completion.

No root-owned source files are modified by this proposal.

### Observed database provisioning prerequisite

The unchanged001–023 baseline has four legacy trigger helpers with PUBLIC EXECUTE. The strict observer capability guard rejects those additional function privileges. Actual tests remove them only in newly owned disposable databases. Before any real adapter composition, the owner must separately review the observer's effective permissions and the deployment's PUBLIC function grants. Candidate024 does not silently revoke legacy application permissions in an existing database, provision a login, or make the runtime available. This is an explicit unresolved production setup step, not a reason to weaken the guard.
