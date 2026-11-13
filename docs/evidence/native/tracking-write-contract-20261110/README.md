# Native tracking write integration

The reviewed twelve-file write-r2 delta is installed. A fresh full HouseholdClient package build passes190 tests, with exactly three expected real-service wire skips and no failures. All100 package source inputs match before and after execution. [Verification](verification.json).

Six typed tracking intents, complete candidate/pickup acknowledgment, Apply and separate partial-freeze review now use authenticated service methods and exact durable retry bytes. Entry session identity survives asynchronous outbox operations. Actual401/403 denial records its original invalidation before clearing the session; cleanup removes only unchanged rows in the original snapshot. Confirmed404 assignment loss is distinguished from a missing resource. Expired uncommitted previews retire only their exact operation. Held-cleanup tests preserve new same-shop work after re-enrollment.

This library integration does not enable production, implement the screens, or qualify actual service/database authority. Those flows and compound contracts remain required. Original read tests and all14 initial write tests remain, with11 additional concurrency/privacy controls. Original review findings and candidate sources are retained under `.build/SharedDemandGraphNov09/native-tracking-write-r2`.
