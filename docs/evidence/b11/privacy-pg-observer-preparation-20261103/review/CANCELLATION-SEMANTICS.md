# Required actual PostgreSQL cancellation semantics

Read from the installed pg 8.23.1 implementation, not inferred from a QueryConfig `signal` field:

- pg-pool `release(error)` removes the checked-out client and calls client.end.
- pg client.end force-destroys an active non-pipelined query's socket; a pipelined active query instead waits for drain. The adapter must construct its own fixed Pool with pipeline:false.
- Socket destruction is not proof PostgreSQL instantly stops an already dispatched statement. A blocked server can detect the closed socket later. Bound server work with statement_timeout and idle_in_transaction_session_timeout; each per-call transaction must have no dispatch after the call deadline/abort.
- If the pool acquisition completes after caller cancellation, discard that client with zero SQL dispatch. Reject the waiting call promptly and attach cleanup to the eventual pool result.
- Check the absolute deadline and call-owned AbortSignal after acquisition and immediately before every actual client.query call, including BEGIN/configuration/catalog guard/observer function/COMMIT. An earlier check before an awaited step is insufficient.
- On cancellation destroy/quarantine the connection. Do not enqueue ROLLBACK behind a blocked query and pretend it cancelled that query. The server transaction must eventually roll back when the connection or statement deadline is observed.
- A COMMIT already dispatched may have succeeded despite a lost response. Preserve uncertainty and reconcile the original event and independently authenticated receipt on retry; do not assert abort erased a committed acknowledgement.

Actual tests must observe prompt client rejection, backend disappearance within a bounded interval, no committed acknowledgement after an aborted uncommitted blocked statement, clean next-connection retry, and acknowledgement idempotency after an actual committed transaction with lost response. Synthetic remote receipt infrastructure remains labeled synthetic; the SQL transport, role checks and transaction behavior are real local PostgreSQL.
