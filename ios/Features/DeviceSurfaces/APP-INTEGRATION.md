# DeviceSurfaces app integration boundary

The new app-owned coordinator is `ios/App/DeviceSurfacesComposition.swift`. Its supporting private journal, actual LedgerModel adapter, route store and UI live in `ios/Features/DeviceSurfaces`. The package change adds serialized reminder erasure. Root/generator/extension Info.plist ownership remains with the parent; preserve the parent’s nonempty extension display names.

Create a retained `@StateObject` with `DeviceSurfacesComposition()` (optional `directory`, `bundle`, and `clock` are test injection points). The SwiftUI app delegate adaptor installs the notification delegate during launch. Bind the composition and the delegate before opening the workspace so an early notification can wait as an opaque handle:

```swift
surfaces.bind(ledger: ledger, pickup: pickup, household: household, access: access,
              sceneActive: scenePhase == .active)
notificationDelegate.bind { handle in surfaces.receiveReminderTap(handle) }
await model.open()
await ledger.open()
await pickup.load()
await surfaces.foreground()
```

Pass it through the root environment or explicitly. Add a navigation entry with `DeviceSurfacesEntry(composition: surfaces)`; its selected-text and local-reminder destinations are implemented. At the root:

```swift
.onOpenURL { surfaces.handle(url: $0) }
.sheet(item: $surfaces.destination) { destination in
    NavigationStack {
        DeviceSurfacesDestination(composition: surfaces, destination: destination,
                                  ledger: ledger, pickup: pickup, household: household)
    }
}
```

Call `background()` before the root locks the workspace and `foreground()` after the active adult workspace opens. Discard pending adult taps when the child boundary takes over. Call `scopeChanged()` for actual persona changes and sign-out. Ordinary household suspension conceals the projection while retaining its last reminder scope. A signed-in unlock rechecks that scope against the enrolled device before using it again. The coordinator observes the live models without replacing the membership-owned `HouseholdModel.onScopeChange`.

Records cleanup hooks are `eraseLedgerWorkspace(_:) async throws` and `erasePickupRecord(workspaceID:recordID:) async throws`. Pass those into `RecordsErasureCleanup`; await capture-correction cleanup separately in the parent’s combined ledger closure. Do not swallow errors: the existing confirmed-deletion journal must stay pending when any source cleanup fails. Repeated cleanup is idempotent. Startup reconciles retirement IDs and pickup tombstones before showing the inbox; missing raw-text group access during referenced cleanup throws rather than claiming erasure.

The private review stores the full returned preview, edited/original text, digest, scope, decisions and phase before commit. Exact receipt verification precedes inbox acknowledgment. Explicit stale-review recovery reloads the actual ledger and retains up to three previously confirmed attempts under the same operation UUID, so a racing old receipt is recognized without a duplicate import. Exceeding the bound fails closed; discard and submit a new intentional share if another review is needed. Receipt lookup never restages random operation identity after a crash.

Reminders are selected from current unfilled offers and unhandled deferrals. A deferral expiry requires explicit review and does not create a meal date. Current source revision gates scheduling and reopening. Generic notifications contain only a random handle. The coordinator consumes it after current authorization and source reconciliation. A late offer opens Await pickup while its fill remains unknown. A recorded receipt removes that offer from reminder eligibility. Missing, revoked or expired deferrals fail closed.

Executed scratch evidence: `integration-tests.log` has 14 passes, including two tests with the real LedgerModel and SQLite store, exact crash/restart receipt recovery, scope loss, interruption, changed replay, stale-review refresh and racing old receipts. `device-surfaces-tests.log` has 25 passes including serialized cancellation and erasure/version checks. `ios-verification.json` records the full app SDK typecheck with staged overrides and exact file hashes. Native tests can be copied from `NativeDeviceSurfacesTests.swift`; they are not claimed executed on iOS until the parent runs them.

Remaining acceptance gates: parent root hooks and generated build; rendered selected-text/duplicate-edit/restart journeys; actual share hosts, locked widget/AppIntent taps and notification permission/delivery/late taps; VoiceOver, large text, both languages and physical devices. Apple membership/signing remains deferred by user instruction. This batch does not implement printing or aisle-order customization.

Reminder erasure retains only an opaque reminder UUID receipt (maximum 10,000) after cancelling OS registration and deleting private persona/target/time/body data. A database trigger also blocks replay by an older writer. These receipts prevent late initial saves from resurrecting an erased reminder; they are not account-erasure receipts.

DEBUG UI-test isolation: the composition initializer accepts optional `launchArguments` (default ProcessInfo arguments). `--ui-testing` selects `UITestWorkspace/DeviceSurfacesPrivate`, test-local inbox/widget files, and a denied/no-op scheduler. It does not resolve App Groups, assign a live notification delegate, or reload WidgetCenter. Explicit `directory` still wins and is never reset by flags. Only the automatically selected test directory may be removed by `--reset-test-workspace`; redirected test roots fail closed. Native composition fixtures must explicitly pass `launchArguments: ["--ui-testing"]` as well as their temporary directory.

Automatic reconciliation requires both ledger and pickup models ready, neither saving nor holding an uncertain save, and no pending whole-ledger deletion. It rechecks the same workspace/revisions after awaits and before destructive cleanup. Explicit Records erasure remains its separate throwing path. Binding before model opens is supported without inferring orphan routes or cancelling pending reminders.
