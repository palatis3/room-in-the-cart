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
