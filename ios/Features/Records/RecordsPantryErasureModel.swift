import Combine
import Foundation

@MainActor final class RecordsPantryErasureModel: ObservableObject {
    typealias Authorization = RecordsToolsModel.Authorization
    typealias Selection = PantryErasureDependencies.Selection
    typealias Outcome = PantryErasureCoordinator.Outcome
    typealias Blocker = PantryErasureCoordinator.Blocker

    struct Choice: Identifiable {
        let selection: Selection
        let title: String

        var id: String {
            switch selection {
            case .lot(let id, _): return "lot." + id.uuidString
            case .pickup(let id, _, _): return "pickup." + id.uuidString
            case .wholeOrigin: return "whole"
            }
        }
    }

    struct Pickup: Identifiable {
        let id: UUID
        let title: String
    }

    struct Review: Identifiable {
        let id: UUID
        let selection: Selection
        var sharedReceiptCount: Int = 0
        var aliasCount: Int = 0
        var receiptRevisionCount: Int = 0
        let foodNames: [String]
        let pickups: [Pickup]
        let collateralPickups: [Pickup]
        let retainedReceiptFoodNames: [String]
        let affectedReservationNames: [String]
        let copyIDs: [UUID]
        let pendingFileCount: Int
        let blockers: Set<Blocker>
        let canCommit: Bool
        /// Captures the coordinator and its exact verified review. Display rows
        /// cannot be translated back into a larger deletion command.
        let apply: @MainActor () async throws -> Outcome
    }

    struct Actions {
        let choices: @MainActor () async throws -> [Choice]
        let prepare: @MainActor (Selection) async throws -> Review
        let recoverCleanup: @MainActor () async throws -> Outcome?
    }

    enum Notice: Equatable { case stale, unavailable, failed, cleanupPending, deleted, noPendingCleanup }

    @Published private(set) var choices: [Choice] = []
    @Published private(set) var review: Review?
    @Published private(set) var busy = false
    @Published private(set) var notice: Notice?
    @Published private(set) var listed = false
    private let beginAuthorization: () -> Authorization?
    private let makeActions: (@escaping Authorization) throws -> Actions
    private var generation = UUID()
    private var authorization: Authorization?
    private var actions: Actions?

    init(beginAuthorization: @escaping () -> Authorization?,
         makeActions: @escaping (@escaping Authorization) throws -> Actions) {
        self.beginAuthorization = beginAuthorization
        self.makeActions = makeActions
    }

    convenience init(beginAuthorization: @escaping () -> Authorization?,
                     coordinator: @escaping (@escaping Authorization) throws -> PantryErasureCoordinator) {
        self.init(beginAuthorization: beginAuthorization, makeActions: { authorize in
            let coordinator = try coordinator(authorize)
            return Actions(choices: {
                try await coordinator.choices().map { Choice(selection: $0.selection, title: $0.title) }
            }, prepare: { selection in
                let value = try await coordinator.prepare(selection)
                guard value.pickupIDs.count == value.pickupTitles.count,
                      value.collateralPickupIDs.count == value.collateralPickupTitles.count else {
                    throw PantryErasureCoordinator.Failure.invalid
                }
                return Review(id: value.id, selection: value.selection, sharedReceiptCount: value.sharedReceiptCount, aliasCount: value.aliasCount, receiptRevisionCount: value.receiptRevisionCount, foodNames: value.foodNames,
                    pickups: zip(value.pickupIDs, value.pickupTitles).map(Pickup.init),
                    collateralPickups: zip(value.collateralPickupIDs, value.collateralPickupTitles).map(Pickup.init),
                    retainedReceiptFoodNames: value.retainedReceiptFoodNames, affectedReservationNames: value.affectedReservationNames,
                    copyIDs: value.copyIDs, pendingFileCount: value.pendingFileCount, blockers: value.blockers,
                    canCommit: value.canCommit, apply: { try await coordinator.commit(value) })
            }, recoverCleanup: { try await coordinator.recoverCleanup() })
        })
    }

    func redactReviewedContent() {
        choices = []
        review = nil
        listed = false
    }
    func invalidate() {
        generation = UUID()
        authorization = nil
        actions = nil
        redactReviewedContent()
        notice = nil
    }

    private func begin() throws -> Actions {
        invalidate()
        let id = generation
        guard let authorized = beginAuthorization(), authorized() else { throw PantryErasureCoordinator.Failure.unauthorized }
        let bound: Authorization = { [weak self] in self?.generation == id && authorized() }
        let actions = try makeActions(bound)
        authorization = bound
        self.actions = actions
        return actions
    }

    func load() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            let actions = try begin()
            let id = generation
            do {
                let choices = try await actions.choices()
                guard current(id) else { return }
                self.choices = choices
                listed = true
            } catch { handle(error, generation: id) }
        } catch { fail(error) }
    }

    func prepare(_ choice: Choice) async {
        let id = generation
        guard !busy, review == nil, current(id), let actions,
              choices.contains(where: { $0.selection == choice.selection }) else { return }
        notice = nil
        busy = true
        defer { busy = false }
        do {
            let result = try await actions.prepare(choice.selection)
            guard current(id) else { return }
            guard result.selection == choice.selection else { throw PantryErasureCoordinator.Failure.stale }
            review = result
        } catch { handle(error, generation: id) }
    }

    func cancelReview() {
        guard !busy else { return }
        review = nil
    }

    func commit(reviewID: UUID) async {
        let id = generation
        guard !busy, let review, review.id == reviewID, current(id), review.canCommit,
              review.blockers.isEmpty, review.collateralPickups.isEmpty else { return }
        busy = true
        defer { busy = false }
        do {
            let result = try await review.apply()
            guard current(id) else { return }
            finish(result)
        } catch { handle(error, generation: id) }
    }

    func recoverCleanup() async {
        guard !busy, notice == .cleanupPending else { return }
        busy = true
        defer { busy = false }
        do {
            let actions = try begin()
            let id = generation
            do {
                let result = try await actions.recoverCleanup()
                guard current(id) else { return }
                finish(result)
            } catch { handle(error, generation: id) }
        } catch { fail(error) }
    }

    private func finish(_ result: Outcome?) {
        invalidate()
        switch result {
        case .deleted: notice = .deleted
        case .cleanupPending: notice = .cleanupPending
        case nil: notice = .noPendingCleanup
        }
    }

    private func current(_ id: UUID) -> Bool {
        guard generation == id else { return false }
        guard authorization?() == true else {
            invalidate()
            notice = .unavailable
            return false
        }
        return true
    }

    private func handle(_ error: Error, generation id: UUID) {
        guard current(id) else { return }
        fail(error)
    }

    private func fail(_ error: Error) {
        invalidate()
        switch error as? PantryErasureCoordinator.Failure {
        case .stale, .blocked: notice = .stale
        case .unauthorized: notice = .unavailable
        case .cleanupPending: notice = .cleanupPending
        default: notice = .failed
        }
    }
}
