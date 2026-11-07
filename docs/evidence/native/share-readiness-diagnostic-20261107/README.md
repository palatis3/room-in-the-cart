# Share readiness failure capture

The two system-share cancellation tests now capture a screenshot and structural readiness facts immediately after the existing 15-second readiness check fails, before slower hierarchy retrieval or Reduce Motion restoration changes the visible state. The failed waiter result is retained and passed to the original assertion; query, timeout, cancellation, frozen-basket and restart assertions are unchanged.

This is test-only diagnostic instrumentation. The original hosted failures remain failures and no product or selector fix is claimed. Review of original activities and bounded video frames showed delayed share-panel presentation, but the retained screenshots could not establish the panel's exact state at the failed readiness decision. The new capture supplies that missing boundary on a future failure.

The entire candidate FreeJourneyUITests.swift typechecked with Swift 5 mode, DEBUG, arm64 iOS 17 simulator target and the locally installed Xcode SDK: exit 0, empty diagnostic log. The manifest pins the unchanged source outside this helper edit. This is compile-time validation, not native execution or proof that the failure branch has run. Fresh hosted native validation remains pending.

The earlier Dinner theme regression evidence binds commit 11f522b. This later change affects only the share-readiness helper; neither Dinner test invokes it. No product code or permanent test inventory was changed here.

The preparation manifest and original failure review retain their historical validation labels; the separate root typecheck receipts record the later check. Original archives, results, raw logs and bounded video evidence remain unchanged in scratch storage. No raw Records evidence is included.
