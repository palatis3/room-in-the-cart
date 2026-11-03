import Foundation
import HouseholdClient

@MainActor final class HouseholdExitModel: ObservableObject {
    private let service: HouseholdService
    private let vault: any RefreshTokenVault
    private var generation = UUID()
    private var subject: String?
    @Published private(set) var preview: DeletionPreview?
    @Published private(set) var selected: DeletionPreview.Household?
    @Published private(set) var pending: HouseholdExitIntent?
    @Published private(set) var busy = false
    @Published private(set) var needsSignIn = false
    @Published private(set) var notice: String?
    @Published var choices = DeletionChoices()

    init(service: HouseholdService, vault: any RefreshTokenVault) {
        self.service = service
        self.vault = vault
    }
    func clear() {
        generation = UUID()
        subject = nil; selected = nil; pending = nil; preview = nil
        choices = .init(); needsSignIn = false; notice = nil
    }
    private func saved() throws -> [String: HouseholdExitIntent] {
        guard let value = try vault.read() else { return [:] }
        return try JSONDecoder().decode([String: HouseholdExitIntent].self, from: Data(value.utf8))
    }
    private func write(_ intents: [String: HouseholdExitIntent]) throws {
        if intents.isEmpty { try vault.clear() }
        else { try vault.write(String(decoding: JSONEncoder().encode(intents), as: UTF8.self)) }
    }
    func forget(subject: String) throws {
        var intents = try saved()
        if intents.removeValue(forKey: subject) != nil { try write(intents) }
        if self.subject == subject { pending = nil }
    }
    func review(subject: String) async {
        guard !busy else { return }
        clear()
        self.subject = subject
        busy = true; defer { busy = false }
        let start = generation
        do {
            pending = try saved()[subject]
            if pending != nil { return }
            let value = try await service.deletionPreview(subject: subject)
            guard start == generation else { return }
            preview = value
            needsSignIn = value.reauthenticationRequired
        } catch {
            guard start == generation else { return }
            failure(error)
        }
    }
    func select(_ household: DeletionPreview.Household) {
        guard preview?.households.contains(where: { $0.householdId == household.householdId && $0.state == "active" }) == true else { return }
        selected = household; choices = .init()
    }
    var canLeave: Bool {
        guard let preview, let selected, pending == nil else { return false }
        return (try? choices.exit(selected, in: preview)) != nil
    }
    func confirm(subject: String) async -> HouseholdExitIntent? {
        guard !busy, self.subject == subject, canLeave, let selected, let preview else { return nil }
        do {
            var intents = try saved()
            if let existing = intents[subject] { pending = existing; return nil }
            let intent = try HouseholdExitIntent(subject: subject, household: selected, preview: preview, choices: choices)
            intents[subject] = intent
            try write(intents)
            pending = intent
        } catch {
            notice = ht("The exit request has not been sent. Unlock this phone so it can save the request and try again.")
            return nil
        }
        return await send(subject: subject)
    }

    func send(subject: String) async -> HouseholdExitIntent? {
        guard !busy, self.subject == subject, let intent = pending, intent.subject == subject else { return nil }
        busy = true; defer { busy = false }
        let start = generation
        do { try await service.leaveHousehold(intent) }
        catch {
            guard start == generation else { return nil }
            failure(error)
            if case let ClientError.service(status, _, _, _) = error, [404, 409, 422].contains(status) {
                do { try forget(subject: subject); selected = nil; preview = nil; choices = .init() }
                catch { notice = ht("Unlock this phone to update the saved household exit request.") }
            }
            return nil
        }
        do { try forget(subject: subject) }
        catch { if generation == start { notice = ht("You left this household. Unlock this phone to clear the saved request.") } }
        if generation == start {
            selected = nil; preview = nil; choices = .init(); needsSignIn = false
            if pending == nil { notice = ht("You left this household. Your account is still active.") }
        }
        return intent
    }

    private func failure(_ error: Error) {
        switch error as? ClientError {
        case .sessionNeeded: needsSignIn = true; notice = ht("Sign in again with a new email code before leaving a household.")
        case .service(409, "guardian_disposition_required", _, _):
            notice = ht("Resolve sole guardianship before leaving. Leaving a household cannot erase a child profile.")
        case .service(let status, _, _, _) where [404, 409, 422].contains(status):
            notice = ht("The household or its responsibilities changed. Review the current memberships before leaving.")
        default:
            notice = pending == nil ? ht("Could not load your memberships. Check your connection and try again.") :
                ht("The service has not confirmed the exit. Retry the saved request to check the same action.")
        }
    }
}
