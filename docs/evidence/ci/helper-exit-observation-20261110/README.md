# Owned simulator-command exit observation

Hosted42794015602 reported no libproc identity while its existing Popen still appeared live; the same owned bootstatus later exited0 without signals. The lifecycle waiter now observes that already-bound child within the original absolute deadline instead of immediately classifying missing identity as a changed identity.

Missing identity never permits sampling, signaling, respawning or a new timeout. A changed nonnull identity fails immediately, including a changed identity racing terminal observation. A missing binding fails. Normal exit0 remains required by the enclosing lifecycle; nonzero exit, output budgets, phase deadlines and existing cleanup checks remain enforced. Evidence collection records missing-identity counts and first observation without unbounded event retention.

All281portable helper controls pass, including9new regression cases. The first check passed280behavior controls and failed the frozen-source guard because reviewed code changed before its two source pins were updated; that result is retained. The final pin update changes only the runner and its test hashes. [Verification](verification.json).

All three actual workflow profiles now pass644checks each against exact commit4df31882112cb59a29e900607cbc59add01077ba, with793unchanged source inputs and50source pins. [Profile verification](profiles.json). Hosted successor42887056453 was dispatched for standalone helper control and is not yet terminal. This does not resolve the independent postboot inventory stall or establish app performance measurements.
