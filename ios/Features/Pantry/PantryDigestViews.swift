import SwiftUI
import CoreDomain

struct PantryDigestAccess {
    let scope: PantryDigestScope
    let authorized: @MainActor () -> Bool
}
private struct PantryDigestAccessKey: EnvironmentKey { static let defaultValue: PantryDigestAccess? = nil }
extension EnvironmentValues {
    var pantryDigestAccess: PantryDigestAccess? {
        get { self[PantryDigestAccessKey.self] }
        set { self[PantryDigestAccessKey.self] = newValue }
    }
}

@MainActor struct PantryDigestRuntime: ViewModifier {
    @ObservedObject var pickup: PickupModel
    @ObservedObject var access: WorkspaceAccess
    @ObservedObject var household: HouseholdModel
    @ObservedObject var child: GuardianChildCoordinator
    @ObservedObject private var store = PantryDigestStore.shared
    @Environment(\.scenePhase) private var scene
    @State private var openScope: PantryDigestScope?
    @State private var shownModel: PantryModel?
    @State private var suspended = false

    private var context: PantryDigestAccess? {
        guard scene == .active, !child.presented, pickup.pantryRouteAvailable, pickup.pantryReadIsCurrent,
              let snapshot = pickup.pantrySnapshot, let origin = pickup.sourceWorkspaceID, snapshot.state.workspaceID == origin,
              snapshot.state.active, household.projection?.grantId == nil,
              let identity = CapturePrivateIdentity.current(access: access, household: household) else { return nil }
        let scope = PantryDigestScope(origin: origin, identity: identity)
        return PantryDigestAccess(scope: scope) {
            !child.presented && pickup.pantryRouteAvailable && pickup.pantryReadIsCurrent && pickup.sourceWorkspaceID == origin &&
                household.projection?.grantId == nil && CapturePrivateIdentity.current(access: access, household: household) == identity
        }
    }
    private struct Basis: Equatable {
        let scope: PantryDigestScope?
        let revision: Int64?
        let zone: String
    }
    func body(content: Content) -> some View {
        let current = context
        content.environment(\.pantryDigestAccess, current)
            .onChange(of: household.deviceReminderPersona) { _, _ in clearScope() }
            .onChange(of: child.presented) { _, active in if active { clearScope() } }
            .onChange(of: pickup.sourceWorkspaceID) { previous, next in
                if let previous, next != nil && previous != next { clearScope() }
            }
            .task(id: Basis(scope: current?.scope, revision: pickup.pantrySnapshot?.state.revision, zone: TimeZone.current.identifier)) {
                guard let current, current.authorized(), let snapshot = pickup.pantrySnapshot else { return }
                do {
                    try await store.reconcile(current.scope, lots: snapshot.lots)
                    guard current.authorized(), !Task.isCancelled else { return }
                    suspended = false
                    acceptTap(current)
                } catch { await store.failClosed() }
            }
            .onChange(of: store.tapped) { _, _ in if let current { acceptTap(current) } }
            .sheet(isPresented: Binding(get: { openScope != nil && current?.scope == openScope && !suspended },
                                       set: { if !$0 { openScope = nil; shownModel = nil } })) {
                if let current, current.scope == openScope, current.authorized(), let shownModel {
                    NavigationStack { PantryDigestList(model: shownModel, access: current) }
                }
            }
    }
    private func acceptTap(_ access: PantryDigestAccess) {
        guard let token = store.tapped, access.authorized(), let snapshot = pickup.pantrySnapshot else { return }
        store.tapped = nil
        guard var doc = try? store.document(access.scope), doc.enabled else { return }
        doc.reconcile(snapshot.lots)
        let now = Date()
        guard doc.rules.contains(where: { rule in
            guard rule.handle == token, let zone = TimeZone(identifier: doc.digestZone),
                  let day = try? MealDay(date: now, timeZoneIdentifier: zone.identifier) else { return false }
            return day.hasSameCivilDate(as: rule.day)
        }), let model = pickup.makePantryModel() else { return }
        openScope = access.scope; shownModel = model
    }
    private func clearScope() {
        openScope = nil; shownModel = nil; store.tapped = nil; suspended = true
        Task { await store.failClosed() }
    }
}

struct PantryDigestList: View {
    @ObservedObject var model: PantryModel
    let access: PantryDigestAccess
    @ObservedObject private var store = PantryDigestStore.shared
    @State private var message: String?
    @State private var busy = false
    @State private var time = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: Date()) ?? Date()

    var body: some View {
        Form {
            if access.authorized(), let snapshot = model.snapshot, snapshot.state.workspaceID == access.scope.origin,
               let doc = currentDocument(snapshot.lots) {
                Section(pantryText("Foods to check")) {
                    if doc.rules.isEmpty { Text(pantryText("Choose a batch in My Pantry and set a check date.")) }
                    ForEach(doc.rules.sorted { $0.day.iso8601 < $1.day.iso8601 }, id: \.lotID) { rule in
                        if let lot = snapshot.lots.first(where: { $0.id == rule.lotID }) {
                            NavigationLink { PantryDigestDayEditor(model: model, access: access, lot: lot) } label: {
                                LabeledContent(lot.name, value: rule.day.iso8601)
                            }
                        }
                    }
                }
                Section(pantryText("Daily notification")) {
                    DatePicker(pantryText("Digest time"), selection: $time, displayedComponents: .hourAndMinute)
                        .accessibilityIdentifier("pantry.digest.time")
                    Text(pantryText("One private notification groups foods checked on the same day. Your food names stay in My Pantry."))
                    LabeledContent(pantryText("Saved digest time zone"), value: doc.digestZone)
                    Text(pantryFormat("Saving the time uses %@. Check dates keep their calendar day when you travel. If the clock skips the chosen time, the digest arrives at the next valid time.", TimeZone.current.identifier))
                    Button(pantryText(doc.enabled ? "Save digest time" : "Turn on daily notifications")) {
                        update(enabled: true)
                    }.accessibilityIdentifier("pantry.digest.enable")
                    if doc.enabled {
                        Button(pantryText("Turn off daily notifications")) { update(enabled: false) }
                    }
                    if store.notificationsUnavailable {
                        Text(pantryText("Notifications are unavailable. Your check dates are still here."))
                    }
                }.disabled(busy)
            } else if model.busy { ProgressView() }
            else { Text(pantryText("Unlock the authorized private workspace to view pantry food.")) }
            if let message { Text(message).accessibilityIdentifier("pantry.digest.status") }
        }
        .privacySensitive().navigationTitle(pantryText("Use soon"))
        .task {
            if model.snapshot == nil { await model.load() }
            if access.authorized(), let doc = try? store.document(access.scope) {
                time = Calendar.current.date(bySettingHour: doc.minute / 60, minute: doc.minute % 60, second: 0, of: Date()) ?? time
            }
        }
    }
    private func currentDocument(_ lots: [InventoryLot]) -> PantryDigestDocument? {
        guard var doc = try? store.document(access.scope) else { return nil }
        doc.reconcile(lots)
        return doc
    }
    private func update(enabled: Bool) {
        guard !busy, access.authorized() else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                let parts = Calendar.current.dateComponents([.hour,.minute], from: time)
                try await store.setAlerts(access.scope, enabled: enabled, minute: (parts.hour ?? 9) * 60 + (parts.minute ?? 0)) {
                    access.authorized() && model.snapshot?.state.workspaceID == access.scope.origin
                }
                if access.authorized() { message = pantryText(enabled ? "Daily notifications are on." : "Daily notifications are off.") }
            } catch PantryDigestFailure.denied {
                message = pantryText("Notifications are unavailable. Your check dates are still here.")
            } catch { message = pantryText("Could not update the digest. Review and try again.") }
        }
    }
}

struct PantryDigestDayEditor: View {
    @ObservedObject var model: PantryModel
    let access: PantryDigestAccess
    let lot: InventoryLot
    @State private var date = Date()
    @State private var zone = TimeZone.current
    @State private var message: String?
    @State private var busy = false
    @ObservedObject private var store = PantryDigestStore.shared

    var body: some View {
        Form {
            if access.authorized(), model.snapshot?.state.workspaceID == access.scope.origin,
               model.snapshot?.lots.first(where: { $0.id == lot.id }) == lot {
                Text(verbatim: lot.name)
                DatePicker(pantryText("Check this food on"), selection: $date, displayedComponents: .date)
                    .environment(\.timeZone, zone)
                Text(verbatim: zone.identifier)
                Text(pantryText("Choose a day to check the batch. A check date does not indicate food safety."))
                Button(pantryText("Save check date")) { save(remove: false) }.accessibilityIdentifier("pantry.digest.saveDate")
                if (try? store.document(access.scope).rules.contains { $0.lotID == lot.id }) == true {
                    Button(pantryText("Remove check date")) { save(remove: true) }
                }
            } else { Text(pantryText("This food is unavailable. Return to My Pantry and refresh.")) }
            if let message { Text(message).accessibilityIdentifier("pantry.digest.dateStatus") }
        }
        .disabled(busy).privacySensitive().navigationTitle(pantryText("Batch check date"))
        .task {
            if access.authorized(), let existing = try? store.document(access.scope).rules.first(where: { $0.lotID == lot.id }),
               let day = existing.day.date, let savedZone = TimeZone(identifier: existing.day.timeZoneIdentifier) {
                date = day; zone = savedZone
            }
        }
    }
    private func save(remove: Bool) {
        guard !busy, access.authorized() else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                try await model.verifyDigestLot(lot, origin: access.scope.origin)
                guard access.authorized() else { throw PantryDigestFailure.changed }
                let day = remove ? nil : try MealDay(date: date, timeZoneIdentifier: zone.identifier)
                try await store.saveDay(access.scope, lot: lot, day: day, authorized: access.authorized)
                if access.authorized() { message = pantryText(remove ? "Check date removed." : "Check date saved.") }
            } catch PantryDigestFailure.capacity {
                message = pantryText("This device can keep check dates for 32 batches. Remove a date before adding another.")
            } catch { message = pantryText("Could not update the digest. Review and try again.") }
        }
    }
}
