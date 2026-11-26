import CoreDomain
import Foundation
import LocalStore
import SwiftUI
import UserNotifications

@MainActor struct CookingSessionContext {
    let key: CookingSessionKey
    let authorize: () -> Bool
}

@MainActor enum CookingSessionResources {
    static var isTesting: Bool {
        SurfaceRuntimeIsolation.usesUITestWorkspace(launchArguments: ProcessInfo.processInfo.arguments)
    }
    static func store() -> CookingSessionStore {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let appFolder = isTesting ? "UITestWorkspace" : "RoomInTheCart"
        return CookingSessionStore(directory: support.appendingPathComponent(appFolder + "/CookingSessions", isDirectory: true))
    }
    static func eraseUnretainedRecipes(retaining ids: Set<UUID>) throws {
        let removed = try store().eraseUnretainedRecipes(retaining: ids)
        if !isTesting { CookingSessionAlerts.remove(removed) }
    }
    static func erase(workspace: UUID) throws {
        let removed = try store().erase(workspace: workspace)
        if !isTesting { CookingSessionAlerts.remove(removed) }
    }
}

@MainActor enum CookingSessionAlerts {
    // A resumed deadline has its own request. Finishing an older scheduler call
    // cannot remove a newer alert for the same timer.
    private static func identifier(_ timer: CookingTimer) -> String? {
        timer.deadline.map { "cooking." + timer.id.uuidString + "." + String($0.timeIntervalSince1970.bitPattern) }
    }
    static func remove(_ timers: [CookingTimer]) {
        let ids = timers.compactMap(identifier)
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ids)
    }
    static func schedule(_ timer: CookingTimer, ask: Bool, current: () -> Bool) async -> Bool {
        guard timer.alert, let id = identifier(timer), let deadline = timer.deadline, current() else { return false }
        let center = UNUserNotificationCenter.current()
        var permission = await center.notificationSettings().authorizationStatus
        if permission == .notDetermined, ask, current() {
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
            permission = await center.notificationSettings().authorizationStatus
        }
        guard [.authorized, .provisional, .ephemeral].contains(permission), current() else { return false }
        let interval = deadline.timeIntervalSinceNow
        guard interval > 0 else { return true }
        let message = UNMutableNotificationContent()
        message.title = recordsText("Cooking timer")
        message.body = recordsText("Your cooking timer is ready.")
        message.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, interval), repeats: false)
        do { try await center.add(UNNotificationRequest(identifier: id, content: message, trigger: trigger)) }
        catch { return false }
        guard current() else { remove([timer]); return false }
        return true
    }
}

@MainActor final class CookingSessionModel: ObservableObject {
    @Published private(set) var session: CookingSession?
    @Published private(set) var ready = false
    @Published var message: String?
    let context: CookingSessionContext
    let count: Int
    private let store: CookingSessionStore
    private let clock: () -> Date
    private let schedule: (CookingTimer, Bool, @escaping @MainActor () -> Bool) async -> Bool
    private let removeAlerts: ([CookingTimer]) -> Void

    init(context: CookingSessionContext, count: Int, store: CookingSessionStore, clock: @escaping () -> Date = Date.init,
         schedule: @escaping (CookingTimer, Bool, @escaping @MainActor () -> Bool) async -> Bool,
         removeAlerts: @escaping ([CookingTimer]) -> Void) {
        self.context = context; self.count = count; self.store = store; self.clock = clock
        self.schedule = schedule; self.removeAlerts = removeAlerts
    }
    convenience init(context: CookingSessionContext, count: Int) {
        let test = CookingSessionResources.isTesting
        self.init(context: context, count: count, store: CookingSessionResources.store(), schedule: { timer, ask, current in
            guard !test else { return false }
            return await CookingSessionAlerts.schedule(timer, ask: ask, current: current)
        }, removeAlerts: { if !test { CookingSessionAlerts.remove($0) } })
    }

    func load() {
        guard context.authorize() else { retire(); return }
        do {
            session = try store.load(context.key, stepCount: count)
            ready = true
        } catch {
            ready = false; session = nil
            message = recordsText("Could not reopen this cooking session. Try again.")
        }
    }
    func retire() { ready = false; session = nil; message = nil }
    @discardableResult private func edit(_ change: (inout CookingSession) throws -> Void) -> Bool {
        guard ready, context.authorize() else { retire(); return false }
        do {
            var next = session ?? CookingSession()
            try change(&next)
            try store.replace(session, with: next, for: context.key, stepCount: count)
            session = next; message = nil
            return true
        } catch {
            load()
            message = recordsText("The cooking session changed or could not be saved. Review the current timers and try again.")
            return false
        }
    }
    func saveAmounts(_ amounts: CookingStepAmounts?, replacing prior: CookingStepAmounts?, ingredientCount: Int) -> Bool {
        edit { session in
            guard session.stepAmounts == prior else { throw CookingSessionError.stale }
            try amounts?.validate(stepCount: count, ingredientCount: ingredientCount)
            session.stepAmounts = amounts
        }
    }
    func choose(_ index: Int) { _ = edit { $0.step = index } }
    func start(minutes: Int, alert: Bool) async {
        guard (session?.timers.count ?? 0) < 8 else {
            message = recordsText("Remove a finished timer before adding another. You can keep eight timers."); return
        }
        guard edit({ try $0.start(minutes: minutes, step: $0.step, alert: alert, at: clock()) }),
              let timer = session?.timers.last else { return }
        await enableAlert(timer, ask: true)
    }
    func pause(_ timer: CookingTimer) {
        if edit({ state in
            guard state.timers.contains(timer) else { throw CookingSessionError.stale }
            try state.pause(timer.id, at: clock())
        }) { removeAlerts([timer]) }
    }
    func resume(_ timer: CookingTimer) async {
        guard edit({ state in
            guard state.timers.contains(timer) else { throw CookingSessionError.stale }
            try state.resume(timer.id, at: clock())
        }),
              let running = session?.timers.first(where: { $0.id == timer.id }) else { return }
        await enableAlert(running, ask: false)
    }
    func cancel(_ timer: CookingTimer) {
        if edit({ state in
            guard state.timers.contains(timer) else { throw CookingSessionError.stale }
            state.remove(timer.id)
        }) { removeAlerts([timer]) }
    }
    func end() -> Bool {
        guard ready, context.authorize() else { retire(); return false }
        do {
            var retained = session
            if retained?.stepAmounts == nil { retained = nil }
            else { retained?.step = 0; retained?.timers = [] }
            try store.replace(session, with: retained, for: context.key, stepCount: count)
            removeAlerts(session?.timers ?? [])
            session = nil
            return true
        } catch { load(); message = recordsText("Could not end this cooking session. Try again."); return false }
    }
    func reconcileAlerts() async {
        for timer in session?.timers ?? [] where timer.deadline != nil && timer.remaining(at: clock()) > 0 {
            await enableAlert(timer, ask: false)
        }
    }
    private func enableAlert(_ timer: CookingTimer, ask: Bool) async {
        guard timer.alert else { return }
        let current = { @MainActor [weak self] in
            guard let self, self.context.authorize(), let saved = try? self.store.load(self.context.key, stepCount: self.count) else { return false }
            return saved.timers.contains(timer)
        }
        let scheduled = await schedule(timer, ask, current)
        if !scheduled, current() { message = recordsText("The timer is running. Alerts are unavailable. Reopen cooking mode to check it.") }
    }
}
