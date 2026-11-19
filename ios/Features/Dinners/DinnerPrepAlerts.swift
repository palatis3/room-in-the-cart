import SwiftUI
import UserNotifications
import CoreDomain

/// Device consent is separate from the portable dinner task.
@MainActor final class DinnerPrepAlerts: ObservableObject {
    static let shared = DinnerPrepAlerts()
    static let prefix = "dinner-prep."
    struct Alert: Equatable {
        let key: String
        let date: Date
    }
    @Published private(set) var enabled: Set<String>
    @Published private(set) var failed: Set<String> = []
    private let storage = "dinner.prep.local-consent"
    private var tail: Task<Void, Never>?
    private let center = UNUserNotificationCenter.current()

    private init() { enabled = Set(UserDefaults.standard.stringArray(forKey: "dinner.prep.local-consent") ?? []) }

    static func key(workspace: UUID, task: UUID) -> String { prefix + workspace.uuidString + "." + task.uuidString }
    func setEnabled(_ value: Bool, key: String) {
        if value { enabled.insert(key) } else { enabled.remove(key) }
        UserDefaults.standard.set(Array(enabled), forKey: storage)
    }

    func permission() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound])) == true
    }

    func reconcile(_ alerts: [Alert]) {
        let prior = tail
        tail = Task {
            await prior?.value
            let requests = await center.pendingNotificationRequests().filter { $0.identifier.hasPrefix(Self.prefix) }
            let wanted = Dictionary(uniqueKeysWithValues: alerts.map { ($0.key, $0.date) })
            let stale = requests.filter { wanted[$0.identifier] == nil }.map(\.identifier)
            center.removePendingNotificationRequests(withIdentifiers: stale)
            let delivered = await center.deliveredNotifications().map(\.request.identifier)
            center.removeDeliveredNotifications(withIdentifiers: delivered.filter { $0.hasPrefix(Self.prefix) && wanted[$0] == nil })
            var failures = Set<String>()
            for alert in alerts {
                guard alert.date > Date() else { continue }
                if let request = requests.first(where: { $0.identifier == alert.key }),
                   let trigger = request.trigger as? UNCalendarNotificationTrigger, trigger.nextTriggerDate() == alert.date { continue }
                // Withdraw the older trigger even when installing the new one fails.
                center.removePendingNotificationRequests(withIdentifiers: [alert.key])
                let content = UNMutableNotificationContent()
                content.title = dinnerPlanText("Dinner prep")
                content.body = dinnerPlanText("Open Dinners to review your prep task.")
                content.sound = .default
                var calendar = Calendar(identifier: .gregorian)
                calendar.timeZone = TimeZone(secondsFromGMT: 0)!
                let parts = calendar.dateComponents([.calendar, .timeZone, .year, .month, .day, .hour, .minute, .second], from: alert.date)
                do {
                    try await center.add(.init(identifier: alert.key, content: content,
                        trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)))
                } catch { failures.insert(alert.key) }
            }
            self.failed = failures
        }
    }
}

struct DinnerPrepAlertRuntime: ViewModifier {
    @ObservedObject var ledger: LedgerModel
    @ObservedObject var pickup: PickupModel
    @ObservedObject var access: WorkspaceAccess
    @ObservedObject var household: HouseholdModel
    @ObservedObject var child: GuardianChildCoordinator
    @ObservedObject private var alerts = DinnerPrepAlerts.shared
    @Environment(\.scenePhase) private var scene

    private var desired: [DinnerPrepAlerts.Alert]? {
        guard !child.presented, household.projection?.grantId == nil,
              (household.projection?.role).map({ ["shopper", "organizer"].contains($0) }) != false else { return [] }
        guard scene == .active, access.unlocked, !household.locked, ledger.ready, pickup.ready,
              !ledger.saving, !ledger.hasPendingSave, !pickup.saving, !pickup.hasPendingSave,
              let workspace = ledger.sourceWorkspaceID else { return nil }
        guard CapturePrivateIdentity.current(access: access, household: household) != nil else { return [] }
        let now = Date()
        return ledger.workspace.dinnerPlanning.prepTasks.compactMap { task in
            let key = DinnerPrepAlerts.key(workspace: workspace, task: task.id)
            guard alerts.enabled.contains(key),
                  let meal = ledger.workspace.shops.first(where: { $0.id == task.shopID })?.mealOccurrences.first(where: { $0.id == task.occurrenceID }),
                  let date = task.alertDate(for: meal, now: now) else { return nil }
            if let journey = pickup.journeys.first(where: { $0.id == task.shopID }),
               journey.closedAt != nil || journey.mealRecovery?.domain.events.contains(where: { $0.request.target.id == meal.id }) == true ||
               journey.cookedMeals?.contains(where: { $0.isActive && $0.draft.meal.id == meal.id }) == true { return nil }
            return DinnerPrepAlerts.Alert(key: key, date: date)
        }
    }
    func body(content: Content) -> some View {
        content.onChange(of: desired, initial: true) { _, value in
            if let value { alerts.reconcile(value) }
        }
    }
}
