# Consent delivery diagnostic preparation

This is a diagnostic overlay for exact candidate804030e, not a product fix. It is not installed in the app sources and no diagnostic workflow or native test was dispatched. The original hosted failure remains unresolved; the unchanged local control passed on a different Xcode.

The four-file patch adds DEBUG-only, explicitly enabled structural logging around the existing Settings binding and consent store. It preserves the original getter, single synchronous write, workspace/notice rules and all test actions/assertions. No household IDs, consent keys, domain text or payloads enter its logging API. See [source review and capture plan](REVIEW.md) and [exact source/patch hashes](manifest.json).

Root compiled the overlay from isolated exact804sources with Xcode27.1 for arm64/x86_64 simulator Debug, including the original contributor/stock/carryover fixture flags. Build-for-testing passed; no simulator was created or booted and no test ran. Code signing was disabled for this compile-only check. There were16unique warning lines, all also present in the prior unchanged local control; none was introduced by this overlay. This does not establish hosted26.3 compatibility or runtime capture delivery. [Local validation](local-validation.json).

The offline reconciler passes19synthetic tests, independently replayed by root. It preserves gaps/conflicts and separates live from persisted observations. **Absent events always mean not observed, never that a setter did not run.** A healthy capture can omit an unseen suffix or entire launch. Exit0 only means a report was written. [Reconciliation contract](RECONCILIATION.md).

Before any execution, recheck exact base hashes, compile with the chosen toolchain, explicitly enable the flag in the XCTest runner and retain narrow live/export evidence separately. A hosted diagnostic must preserve the original seven-selector group, order and time limits. Do not apply this patch to another revision without review or use it to weaken the release gate.
