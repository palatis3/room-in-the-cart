# Faster feedback without reducing release coverage

The release workflow now runs cheap Linux source validation before its six
native-containing paths. Its final gate requires the preflight to succeed.
The five global macOS slots and every existing full-suite selection remain.

The shared shard runner accepts `LOCAL_TEST_DIAGNOSTICS=never` only outside CI.
Default/hosted behavior stays `on-failure`. The switch affects verbose system
capture, preserving the original tests, deadlines, result bundle and strict
checks. The motivating retained Spanish layout failure took193.448s in the test
and800.080585s for the command, with an owned `simctl diagnose --timeout=600` child.
That is an observed bottleneck, not a measured speedup for the new option.

The read-only CI reporter uses exact SHA/run/attempt identity, paginates jobs and
reports failed and longest steps without downloading full logs. Completed
summaries are cached atomically; live results are refreshed. It has no dispatch,
retry or cancellation operation. Possible duplicate runs and repeated failed
steps are triage hints, not proof of identical scope or a shared root cause.

## Verification

- 274 Python checks passed in8.553s, including actual shard-entrypoint tests with
 fake native executables, unchanged failure exits, CI policy rejection,
 paginated report collection, exact-attempt cache invalidation, concurrent cache
 writers and failing/skipped release preflight gates.
- Pinned actionlint1.7.12 plus the repository validator passed; all17 native queue
 nodes are independently validated. Shell syntax passed.
- Live read-only run and SHA queries returned billing run42544579944 at
 `d1705d920595be12a3eb8c378f50ad04dbf65ccd`, seven completed successful jobs.
 The retained report is evidence that the reporter works against GitHub; that
 earlier run did not execute this new release preflight.
- No new native/hosted test or deployment was launched for these workflow edits.
 Hosted scheduling and end-to-end savings remain unmeasured.

Keep one coordinator for dispatches, one owner per independent failure, targeted
checks first and a combined full PR/release regression at the final revision.
See [operating instructions](../../../CI-VALIDATION.md).

## Follow-up: compact triage and measured scheduling review

`ci_feedback.py --format text` now presents exact run/revision/attempt, status
counts, every unsuccessful or unfinished job (including skips/cancellations
without failed steps), and the five longest execution windows. Full JSON remains
the default. The report retains read-only behavior and terminal-cache semantics;
its timing list is not a critical-path calculation.

All 276 Python checks passed in 7.779s; actionlint plus the repository validator
passed all 17 queue nodes. Live read-only reporting of run42544579944 attempt1
shows seven successful jobs atd1705d920595be12a3eb8c378f50ad04dbf65ccd.
This is reporter validation, not a hosted run of the new workflow code.

Independent review found no further scheduling edit justified by retained
measurements: product archives already skip recompression, fixture profiles start
independently, and five-slot utilization was91.22%. Native-wire's service setup
and Postgres setup took only7s and9s respectively in the reviewed run. The next
comparable full batch should measure savings before further sharding/caching.
The default operating loop is now prominent in docs/CI-VALIDATION.md. No new
hosted/native run, retry, cancellation or deployment was triggered here.
