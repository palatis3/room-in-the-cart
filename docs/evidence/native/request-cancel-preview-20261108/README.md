# Cancel preview keeps the draft and discards consent

The real request-review flow now has a regression check for accepting an overage, cancelling the preview, and reviewing the unchanged draft. Cancel removes the preview and its Apply/consent controls, keeps the selected request, item and price, and writes nothing. A fresh server review requires fresh consent before Apply becomes available. Only after proving that reset does the test edit the retained item using the actual keyboard; changing a draft field cannot mask the consent assertion.

A complementary model test uses the real service/outbox fixture for an unknown total. It verifies that cancelled consent cannot authorize a write, the original draft fields survive, and a newly acknowledged review saves exactly once, including a repeated Apply attempt.

Both iOS 17.0 (iPhone SE third generation) and iOS 26.2 (iPhone 17 Pro), English/light/Large, pass all 20 request-pack model cases plus the new UI journey. Strict verification confirms one start and passing completion for each selected method, with zero recorded runtime warnings and zero observed animation-idle/restart messages in the supplied logs. Root reviewed all eight named screenshots. This does not establish physical VoiceOver or automatic focus-return acceptance, and it does not close the broader accessibility audit.

The first minimum-OS strict invocation used a suite selector instead of the checker’s required individual method identifiers. Native execution had already passed 21 cases. The preserved initial verification error and corrected source-derived selection show the correction; the existing result and log were revalidated without a native rerun or gate change.

The 16 CI planner checks pass. The fixture inventory is now 72 tests across the same 17 shards, with this UI case assigned once to contributor-balanced-03. Production source is unchanged by this addition. Existing source-specific unsigned Release evidence remains in the Other meals qualification record; these new tests do not claim a new distribution build.
