# Original UI09 Done timeout remains unresolved

The original eight-case shard passed seven cases and timed out after the branch field’s Done tap in the first case. Repeated animation-idle waits began before any save or calculation. The app continued replying that its main loop was idle; the available evidence does not establish the underlying cause. No retry, timeout increase, warning suppression or speculative app fix was applied.

[Original causal review](original-review.md) is an exact copy from scratch. Its relative references to full artifacts, source copies and attachments refer to `/Users/palatis/Room in the Cart/.build/CIF90Nov07/ui-09/causal-review/`, where those originals remain. [Retention receipt](retention.json) hashes the compact evidence copied here. The original full ZIP, app stdout, spindump and result bundle are deliberately retained outside Git.

The failed run remains failed, including its runner restart. Zero exported runtime warnings does not mean every raw system diagnostic is absent. Local diagnostic or toolchain qualification, if later performed, must preserve the original outcome and cannot turn nonreproduction into a causal fix.
