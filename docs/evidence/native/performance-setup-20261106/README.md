# Performance simulator preparation

The previous freshness check treated every nonzero get_app_container result as app absence, including infrastructure errors. The new helper first requires a successful installed-app inventory, converts its property list with macOS plutil, validates its shape and explicitly rejects the app's presence. Launch leaves the pasteboard alone; rendered/scroll seed the unchanged fixture once.

The JSON receipt records a stage before starting each command and its outcome afterward. If the existing eight-minute workflow deadline kills a hung command, the last active stage remains visible. Inventory contents and fixture text are not included in the receipt. No retries, sleep, installation, app changes, test changes or performance-limit changes were added.

All207script tests pass, including8new setup tests. Those tests inject failures at boot, inventory, conversion and pasteboard, reject malformed inventory and existing apps, and verify that failures stop later commands. Actual macOS plutil accepted representative OpenStep input. Workflow lint and independent review pass. This is local harness validation; no new simulator or hosted acceptance run was performed. [Validation](validation.json) · [Review](REVIEW.md).

Original804scroll setup failure remains retained and its exact subcommand is unknown. This change improves correctness and future attribution; it does not establish a fix for the observed timeout or the earlier missing scroll metric.
