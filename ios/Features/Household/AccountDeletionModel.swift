import Foundation
import HouseholdClient

@MainActor final class AccountDeletionModel: ObservableObject {
    @Published private(set) var preview: DeletionPreview?
    @Published var choices = DeletionChoices()
    @Published private(set) var receipts: [DeletionReceipt] = []
    @Published private(set) var statuses: [UUID: DeletionStatus] = [:]
    @Published private(set) var missing: Set<UUID> = []
    @Published private(set) var busy = false
    @Published private(set) var notice: String?
    @Published private(set) var needsSignIn = false
    enum Submission { case accepted, uncertain, rejected }
    private let service: HouseholdService
    private let store: DeletionReceipts
    private var reviewedSubject: String?
    private var generation = UUID()

    init(service: HouseholdService, vault: any RefreshTokenVault) {
        self.service = service
        store = DeletionReceipts(vault: vault)
    }

    func clearReview() {
        generation = UUID()
        reviewedSubject = nil
        preview = nil
        choices = .init()
        needsSignIn = false
        notice = nil
    }

    func readReceipts() {
        do { receipts = try store.saved() }
        catch { notice = ht("Unlock this phone and try reading the deletion receipt again.") }
    }

    func review(subject: String) async {
        guard !busy else { return }
        clearReview()
        busy = true
        defer { busy = false }
        let start = generation
        do {
            let result = try await service.deletionPreview(subject: subject)
            guard generation == start else { return }
            preview = result
            reviewedSubject = subject
            needsSignIn = result.reauthenticationRequired
        } catch {
            guard generation == start else { return }
            describe(error)
        }
    }

    func canSubmit(subject: String) -> Bool {
        guard reviewedSubject == subject, let preview, !needsSignIn,
              (try? choices.dispositions(for: preview)) != nil else { return false }
        return receipts.filter { $0.subject == subject }.allSatisfy { missing.contains($0.id) }
    }

    func submit(subject: String) async -> Submission {
        guard !busy, canSubmit(subject: subject), let preview else { return .rejected }
        busy = true
        defer { busy = false }
        let start = generation
        do {
            let decisions = try choices.dispositions(for: preview)
            let receipt: DeletionReceipt
            do {
                receipt = try store.prepare(subject: subject)
                receipts = try store.saved()
            } catch {
                notice = ht("Your request has not been sent. Unlock this phone so it can save a deletion receipt, then try again.")
                return .rejected
            }
            missing.remove(receipt.id)
            let status = try await service.requestDeletion(receipt: receipt, households: decisions)
            statuses[receipt.id] = status
            clearReview()
            return .accepted
        } catch {
            if generation == start {
                clearReview()
                describe(error)
            }
            switch error as? ClientError {
            case .transport, .invalidResponse, .cancelled: return .uncertain
            case .service(let code, let name, _, _) where code >= 500 && name != "deletion_unavailable": return .uncertain
            default: return .rejected
            }
        }
    }

    func check(_ receipt: DeletionReceipt) async -> Bool {
        guard !busy else { return false }
        busy = true
        defer { busy = false }
        notice = nil
        missing.remove(receipt.id)
        do {
            statuses[receipt.id] = try await service.deletionStatus(receipt)
            return true
        } catch ClientError.service(404, _, _, _) {
            clearReview()
            missing.insert(receipt.id)
            notice = ht("No status is available for this receipt. It may have expired or the request may not have reached the service. You can check again. If you can still sign in, review the request again.")
        } catch {
            notice = ht("Status could not be checked. Your receipt is saved on this phone. Try again.")
        }
        return false
    }

    func forget(_ receipt: DeletionReceipt) {
        guard !busy, statuses[receipt.id]?.status == .complete || missing.contains(receipt.id) else { return }
        do {
            try store.remove(receipt.id)
            statuses.removeValue(forKey: receipt.id)
            missing.remove(receipt.id)
            notice = nil
            readReceipts()
        } catch { notice = ht("Unlock this phone and try reading the deletion receipt again.") }
    }

    private func describe(_ error: Error) {
        switch error as? ClientError {
        case .sessionNeeded:
            needsSignIn = true
            notice = ht("Sign in again with a new email code, then review deletion within five minutes.")
        case .service(_, "deletion_unavailable", _, _):
            notice = ht("Account deletion is currently unavailable. Check again later.")
        case .service(409, _, _, _):
            notice = ht("Household responsibilities changed. Check the receipt, then review the current choices again.")
        default:
            notice = ht("The service could not confirm this action. Check any saved receipt before trying again.")
        }
    }
}
