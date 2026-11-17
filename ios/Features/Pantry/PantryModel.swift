import Combine
import Foundation
import CoreDomain
import LocalStore

/// Private, app-owned presentation state. The repository rechecks live authority
/// on every suspension; the generation also prevents a revoked view republishing a result.
@MainActor
final class PantryModel: ObservableObject {
    enum Phase: Equatable { case idle, ready, migrationRequired, accessDenied, unavailable }
    enum Notice: Equatable { case saved, saveFailed, stale, loadFailed, invalidEntry, reservationReviewRequired, changeTooLarge }
    enum Action { case haveEnough, someLeft, opened, move(InventoryLocation), usedUp, recount(String, UnitOfMeasure) }
    typealias Pending = PantryPendingStore.Entry

    @Published private(set) var snapshot: PantryRepository.Snapshot?
    @Published private(set) var review: PantryRepository.Review?
    @Published private(set) var pending: Pending?
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var notice: Notice?
    @Published private(set) var busy = false
    @Published private(set) var requiresFreshReview = false
    @Published private(set) var savedLotID: UUID?
    @Published private(set) var pendingWasCommitted = false
    private let repository: PantryRepository
    private let clock: () -> Date
    private let willMutateOrRecover: (@MainActor () -> Void)?
    private let didSave: (@MainActor () async -> Void)?
    private var generation = UUID()

    init(repository: PantryRepository, clock: @escaping () -> Date = Date.init,
         willMutateOrRecover: (@MainActor () -> Void)? = nil,
         didSave: (@MainActor () async -> Void)? = nil) {
        self.repository = repository
        self.clock = clock
        self.willMutateOrRecover = willMutateOrRecover
        self.didSave = didSave
    }

    var canEdit: Bool { phase == .ready && snapshot != nil && !busy && pending == nil && review == nil && !requiresFreshReview }

    func accessLost() {
        generation = UUID()
        snapshot = nil; review = nil; pending = nil; savedLotID = nil
        phase = .accessDenied; notice = nil; busy = false; requiresFreshReview = false; pendingWasCommitted = false
    }

    func load() async {
        guard !busy else { return }
        let token = generation
        busy = true
        defer { if token == generation { busy = false } }
        // A refresh invalidates an uncommitted preview, but never changes an
        // uncertain save's original command or reviewed global revision.
        if pending == nil { review = nil }
        do {
            if repository.pendingStore != nil {
                let stored = try repository.readPending()
                if let original = pending ?? stored {
                    pending = original
                    willMutateOrRecover?()
                    let recovery = try await repository.recoverPending(original, at: clock())
                    guard token == generation else { return }
                    try await adopt(recovery, token: token)
                    return
                }
            }
            let current = try await repository.loadForEditing(at: clock())
            guard token == generation else { return }
            snapshot = current; phase = .ready
            if pending == nil { notice = nil; requiresFreshReview = false }
        } catch {
            guard token == generation else { return }
            fail(error, saving: false)
        }
    }

    func prepareNewFood(name: String, existingFoodID: UUID? = nil,
                        location: InventoryLocation, amount: String, unit: UnitOfMeasure) async {
        guard canEdit, let snapshot else { return }
        do {
            let foodID: UUID
            let reviewedName: String
            if let existingFoodID {
                // Explicit selection, never a name-based identity merge.
                guard let food = snapshot.lots.first(where: { $0.foodID == existingFoodID }) else {
                    throw InventoryError.invalid("food")
                }
                foodID = existingFoodID; reviewedName = food.name
            } else {
                foodID = UUID(); reviewedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let count = try Self.count(amount, unit: unit)
            let lotID = UUID(), origin = snapshot.state.workspaceID
            let seed = InventoryLotSeed(foodID: foodID, name: reviewedName,
                source: .manual(originID: origin, sourceID: lotID), location: location, unit: unit, count: count)
            await prepare(InventoryCommand(id: UUID(), originID: origin, lotID: lotID, eventID: UUID(),
                expectedRevision: nil, occurredAt: clock(), change: .create(seed, observationID: UUID())))
        } catch { notice = .invalidEntry }
    }

    func prepare(lotID: UUID, action: Action) async {
        guard canEdit, let snapshot, let lot = snapshot.lots.first(where: { $0.id == lotID }) else { return }
        do {
            let change: InventoryChange
            switch action {
            case .haveEnough: change = .count(.haveEnough, observationID: UUID())
            case .someLeft: change = .count(.someLeft, observationID: UUID())
            case .opened: change = .opened(clock())
            case .move(let location): change = .move(location)
            case .usedUp: change = .usedUp(observationID: UUID())
            case .recount(let amount, let unit): change = .count(try Self.count(amount, unit: unit), observationID: UUID())
            }
            await prepare(InventoryCommand(id: UUID(), originID: snapshot.state.workspaceID, lotID: lot.id,
                eventID: UUID(), expectedRevision: lot.revision, occurredAt: clock(), change: change))
        } catch { notice = .invalidEntry }
    }

    func prepare(_ command: InventoryCommand) async {
        guard canEdit else { return }
        let token = generation
        busy = true; notice = nil; savedLotID = nil
        defer { if token == generation { busy = false } }
        do {
            let result = try await repository.review(command, at: clock())
            guard token == generation else { return }
            snapshot = result.before; review = result; requiresFreshReview = false
        } catch {
            guard token == generation else { return }
            if error as? InventoryError == .capacity { notice = .changeTooLarge }
            else if error is DomainError { notice = .invalidEntry }
            else if let inventoryError = error as? InventoryError, case .invalid = inventoryError { notice = .invalidEntry }
            else { fail(error, saving: false) }
        }
    }

    func cancelReview() {
        guard !busy, pending == nil, review != nil else { return }
        review = nil; notice = nil; requiresFreshReview = false
    }

    func confirmReview(acknowledgingReservations: Bool) async {
        guard !busy, pending == nil, let review else { return }
        guard review.affectedReservations.isEmpty || acknowledgingReservations else {
            notice = .reservationReviewRequired; return
        }
        pending = Pending(command: review.command, reviewedInventoryRevision: review.before.state.revision)
        pendingWasCommitted = false
        if repository.pendingStore != nil {
            do {
                pending = try repository.stagePending(review.command, reviewedInventoryRevision: review.before.state.revision)
            } catch {
                // An atomic write may have succeeded before protection failed.
                // Keep the exact candidate; retry reconciles it, never recreates
                // a missing file that another editor could have discarded.
                let stagingError = error
                do {
                    if let retained = try repository.readPending() {
                        pending = retained
                        if retained.command != review.command { self.review = nil }
                    }
                } catch { fail(error, saving: true); return }
                fail(stagingError, saving: true)
                return
            }
        }
        await retryPending()
    }

    func retryPending() async {
        guard !busy, let pending else { return }
        let token = generation
        busy = true; notice = nil
        defer { if token == generation { busy = false } }
        willMutateOrRecover?()
        do {
            if repository.pendingStore != nil {
                let recovery = try await repository.recoverPending(pending, at: clock(), commitIfUnapplied: true)
                guard token == generation else { return }
                try await adopt(recovery, token: token)
                return
            }
            let result = try await repository.apply(pending.command,
                reviewedInventoryRevision: pending.reviewedInventoryRevision, at: clock())
            guard token == generation else { return }
            snapshot = result.current; phase = .ready; self.pending = nil; review = nil
            requiresFreshReview = false; notice = .saved; savedLotID = pending.command.lotID
            await didSave?()
        } catch {
            guard token == generation else { return }
            fail(error, saving: true)
        }
    }

    /// Only a definite stale rejection can abandon a submitted intent. A transport/
    /// disk/readback failure might have committed, so it requires exact retry first.
    func discardStaleReview() async {
        guard !busy, requiresFreshReview else { return }
        if repository.pendingStore != nil, let pending {
            let token = generation
            busy = true
            defer { if token == generation { busy = false } }
            willMutateOrRecover?()
            do {
                let recovery = try await repository.recoverPending(pending, at: clock(), discardIfUnapplied: true)
                guard token == generation else { return }
                try await adopt(recovery, token: token)
            } catch {
                guard token == generation else { return }
                fail(error, saving: true)
            }
        } else {
            pending = nil; review = nil; notice = nil; requiresFreshReview = false
            await load()
        }
    }

    private func adopt(_ recovery: PantryRepository.PendingRecovery, token: UUID) async throws {
        guard token == generation else { return }
        switch recovery {
        case .waiting(let entry, let current):
            snapshot = current; phase = .ready; pending = entry; review = nil; pendingWasCommitted = false
            requiresFreshReview = current.state.revision != entry.reviewedInventoryRevision
            notice = requiresFreshReview ? .stale : .saveFailed
            await didSave?()
        case .cleared(let current):
            snapshot = current; phase = .ready; pending = nil; review = nil; savedLotID = nil
            pendingWasCommitted = false; requiresFreshReview = false; notice = nil
            await didSave?()
        case .committed(let entry, let result):
            // Current heads are adopted before durable acknowledgment. Cleanup
            // failure keeps the original pending operation blocked for exact retry.
            snapshot = result.current; phase = .ready; pendingWasCommitted = true; requiresFreshReview = false
            if let entry {
                pending = entry
                do { try repository.finishPendingAdoption(entry, result: result) }
                catch {
                    // Acknowledgment/cleanup does not decide whether the inventory
                    // changed. Readers must adopt this known current state while
                    // the exact original journal stays blocked for cleanup retry.
                    await didSave?()
                    guard token == generation else { return }
                    throw error
                }
            }
            pending = nil; review = nil; requiresFreshReview = false
            pendingWasCommitted = false; notice = .saved; savedLotID = result.receipt.heads.first { $0.key.kind == .lot }?.key.id
            await didSave?()
        }
    }

    private func fail(_ error: Error, saving: Bool) {
        if let failure = error as? PantryRepository.Failure {
            switch failure {
            case .unauthorized, .wrongWorkspace:
                accessLost(); return
            case .inactive:
                snapshot = nil; review = nil; pending = nil; phase = .migrationRequired; notice = nil; return
            case .inconsistentSnapshot, .invalidProvenance, .pendingUnavailable: break
            }
        }
        if error as? ComparisonStoreError == .erased {
            accessLost(); return
        }
        if error as? ComparisonStoreError == .staleInventory || error as? InventoryError == .stale {
            requiresFreshReview = true; notice = .stale
            return
        }
        if saving { notice = .saveFailed }
        else { snapshot = nil; phase = .unavailable; notice = .loadFailed }
    }

    private static func count(_ literal: String, unit: UnitOfMeasure) throws -> InventoryCount {
        guard literal.utf8.count <= 64 else { throw DomainError.invalidNumber }
        return try DinnerEntry.quantity(literal, unit: unit).map(InventoryCount.exact) ?? .unknown
    }
}
