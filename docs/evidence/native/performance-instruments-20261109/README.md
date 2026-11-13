# App-scoped Instruments control — November 9, 2026

The original local scroll test ran against preserved products with no test-command,
plan, source, measurement, assertion or checker changes. A separate Instruments
`os_signpost` collector attached only to the verified new AUT PID on the owned
simulator, with a 180-second requested limit and a unique readiness notification.
PID, UID, exact start time, executable hash/UUID and full app-bundle bytes matched
before attachment. A separate notification round-trip control passed.

**Capture did not qualify.** No readiness notification arrived. The original test
passed in 175.379 wrapper seconds; strict and required-metric validation passed.
The trace process remained live after the app and test finished and after SIGINT.
Root verified its exact identity and the AUT's absence before sending SIGTERM.
The tracer exited 1; all native processes are terminal. No other process was stopped.

The retained partial trace contains only `Trace1.run/RunIssues.storedata`, with no
issue rows. Export from a preserved copy exits 10: `Document Missing Template Error`.
A one-second sample shows the collector waiting in its recording run loop; that
does not establish the cause. No supported collection fix or non-emission conclusion
follows. A successful native wrapper exit must not be read as successful capture.

Original result/source/product manifests remain unchanged; XCTest inspection used
a verified clone. Five scroll durations and three five-sample memory series remain
present. Animation hitch samples are unavailable. Instrumented timing is not an
approved baseline. No hosted repeat or plan/checker workaround was dispatched.

[Exact measurements, cleanup and retained original hashes](verification.json).
