# Dinner idea model boundaries

The exact compiled `DinnerFeatureModelTests` class passes **27/27**, with no skipped tests, runtime warnings or runner restarts. Two new tests use the production model, bundled idea catalog and existing in-memory store. The local Debug build uses Xcode 27.1 and iOS 26.2; exact toolchain/runtime receipts are retained.

The Free journey separates preparing and abandoning an unsaved idea, repeated save, repeated approval, cancelled choose preview and one explicit apply. Whole-workspace comparisons, commit counts and stable occurrence/contribution identities ensure these stages do not silently add groceries or duplicate a dinner. The first accepted dinner occupies the Free reusable slot. The access test uses one valid draft with absent runtime context and revoked planning permission, verifies generate/save/approve are denied without commits, and proves the same draft succeeds after access returns.

Preparation is synchronous. Abandonment here means dropping an unsaved value; this does not claim cancellation of an asynchronous service or a native Back gesture. The store is in memory, so SQLite durability and shared-role mapping require their separate evidence. The real HTTP/PostgreSQL authority suite is documented separately under `../../b11/idea-authority-20261107/`.

The first evidence replay incorrectly treated all 37 methods in the source file as members of this class; ten belong to `DinnerScenarioDraftTests`. Its strict rejection and mistaken selector list are preserved. The corrected replay uses the 27 exact compiled identifiers matching the original native `-only-testing:RoomInTheCartTests/DinnerFeatureModelTests` argument. No native rerun, test removal, timeout change or weakened assertion was used.

The same copied build contains the one-line Notes accessibility proposal and a separate S14 UI method. Its full enumeration contains 606 model tests and 54 ordinary UI tests; that inventory is not a claim that all ran locally. All three added selectors are discovered by the existing CI planner without new jobs. Build notices remain in `build-notices.txt`; they are distinct from the zero exported XCTest runtime warnings.
