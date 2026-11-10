import Foundation
import SwiftUI
import HouseholdClient

@MainActor protocol SharedRequestUndoFlowAccess: SharedTrackingFlowAccess {
    func sendRequestUndo(_ operation: PendingOperation) async throws
    func requestUndoHistory(shop: ShopperShop, beforeRevision: Int?) async throws -> SharedRequestUndoHistory
    func requestUndoCandidate(shop: ShopperShop, targetOperationID: SharedDemandID) async throws -> SharedRequestUndoCandidate
    func requestUndoPreview(shop: ShopperShop, candidate: SharedRequestUndoCandidate, packs: [SharedDemandPackReview], acceptOverage: Bool, acceptUnknown: Bool) async throws -> SharedRequestUndoReview
    func requestUndoPrepare(_ review: SharedRequestUndoReview) async throws -> PendingOperation
}
extension SharedRequestUndoFlowAccess where Self: SharedTrackingServiceOwner {
    func requestUndoHistory(shop: ShopperShop, beforeRevision: Int?) async throws -> SharedRequestUndoHistory { try await trackingService.requestAcceptanceHistory(shop: shop, beforeRevision: beforeRevision) }
    func requestUndoCandidate(shop: ShopperShop, targetOperationID: SharedDemandID) async throws -> SharedRequestUndoCandidate { try await trackingService.requestAcceptanceUndoCandidate(shop: shop, targetOperationID: targetOperationID) }
    func requestUndoPreview(shop: ShopperShop, candidate: SharedRequestUndoCandidate, packs: [SharedDemandPackReview], acceptOverage: Bool, acceptUnknown: Bool) async throws -> SharedRequestUndoReview {
        try await trackingService.previewRequestAcceptanceUndo(shop: shop, candidate: candidate, packs: packs, acceptOverage: acceptOverage, acceptUnknown: acceptUnknown)
    }
    func requestUndoPrepare(_ review: SharedRequestUndoReview) async throws -> PendingOperation { try await trackingService.prepareRequestAcceptanceUndo(review) }
}
@MainActor final class SharedRequestUndoFlowModel: ObservableObject {
    @Published private(set) var history: [SharedRequestUndoHistoryItem] = []
    @Published private(set) var next: Int?
    @Published private(set) var shop: ShopperShop?
    @Published private(set) var candidate: SharedRequestUndoCandidate?
    @Published private(set) var review: SharedRequestUndoReview?
    @Published private(set) var busy = false
    @Published private(set) var notice: String?
    @Published private(set) var submitted = false
    @Published var gate = TrackingReviewGate()
    @Published var acceptOverage = false { didSet { if oldValue != acceptOverage { review = nil } } }
    @Published var acceptUnknown = false { didSet { if oldValue != acceptUnknown { review = nil } } }
    @Published var packs: [TrackingPackEntry] = [] { didSet { if oldValue != packs { review = nil; gate.reset() } } }
    let access: any SharedRequestUndoFlowAccess
    private var generation = UUID()
    private var lease: UUID?
    init(access: any SharedRequestUndoFlowAccess) { self.access = access }
    var permitted: Bool { lease == access.trackingLease && access.trackingAllowed && shop == access.trackingShop }
    var pending: Bool { access.trackingPending }
    var moneyAccepted: Bool {
        guard let candidate else { return false }
        return (candidate.afterCheckout.status != "overCap" || acceptOverage) &&
            ((!["unresolved", "scopeMismatch"].contains(candidate.afterCheckout.status) && candidate.afterCheckout.scope == "wholeCheckout") || acceptUnknown)
    }
    func clear() {
        generation = UUID(); lease = nil; history = []; next = nil; shop = nil; candidate = nil; review = nil
        packs = []; gate.reset(); acceptOverage = false; acceptUnknown = false; busy = false; submitted = false; notice = nil
    }
    func load(target: SharedDemandID? = nil, more: Bool = false) async {
        guard !busy else { return }
        if !more { clear() }
        guard !pending, access.trackingAllowed, let current = access.trackingShop else { return }
        let token = generation, actor = access.trackingLease, cursor = more ? next : nil
        guard !more || cursor != nil else { return }
        busy = true; defer { if token == generation { busy = false } }
        do {
            let result = try await access.requestUndoHistory(shop: current, beforeRevision: cursor)
            guard token == generation, actor == access.trackingLease, access.trackingAllowed, current == access.trackingShop else { return }
            shop = current; lease = actor
            if more { history += result.items.filter { item in !history.contains { $0.operationId == item.operationId } } }
            else { history = result.items }
            next = result.nextBeforeRevision.flatMap(Int.init)
        } catch { fail(error, token: token) }
        if token == generation { busy = false }
        if let target, token == generation, permitted { await select(target) }
    }
    func select(_ target: SharedDemandID) async {
        guard !busy, !pending, permitted, let shop else { return }
        generation = UUID(); let token = generation
        candidate = nil; review = nil; gate.reset(); packs = []; acceptOverage = false; acceptUnknown = false
        busy = true; defer { if token == generation { busy = false } }
        do {
            let value = try await access.requestUndoCandidate(shop: shop, targetOperationID: target)
            guard token == generation, permitted else { return }
            packs = value.action.body.lines.map { row in
                var pack = TrackingPackEntry(id: .init(UUID(uuidString: row.lineId)!), name: row.originalItem)
                if case .partition(let state) = value.foodAfter { pack.usable = .init(state.packReviews.first { $0.lineId == pack.id }?.usablePerPack) }
                return pack
            }
            candidate = value; notice = nil
        } catch { fail(error, token: token) }
    }
    func pack(_ id: SharedDemandID) -> Binding<TrackingPackEntry> {
        let token = generation, empty = TrackingPackEntry(id: id, name: "")
        return Binding(get: { [weak self] in
            guard let self, self.generation == token, self.permitted else { return empty }; return self.packs.first { $0.id == id } ?? empty
        }, set: { [weak self] value in
            guard let self, self.generation == token, self.permitted, !self.busy, !self.pending,
                  value.id == id, let index = self.packs.firstIndex(where: { $0.id == id }) else { return }
            self.packs[index] = value
        })
    }
    func preview() async {
        guard !busy, !pending, permitted, gate.canApply, moneyAccepted, let shop, let candidate else { return }
        let token = generation, entries = packs, overage = acceptOverage, unknown = acceptUnknown
        busy = true; defer { if token == generation { busy = false } }
        do {
            let value = try await access.requestUndoPreview(shop: shop, candidate: candidate,
                packs: entries.map { try $0.review() }, acceptOverage: overage, acceptUnknown: unknown)
            guard token == generation, permitted, self.candidate == candidate, entries == packs,
                  acceptOverage == overage, acceptUnknown == unknown, gate.canApply else { return }
            review = value; notice = nil
        } catch { fail(error, token: token) }
    }
    func apply() async {
        guard !busy, !pending, permitted, gate.canApply, moneyAccepted, let review else { return }
        let token = generation; busy = true; defer { if token == generation { busy = false } }
        do {
            let operation = try await access.requestUndoPrepare(review)
            guard token == generation, permitted, self.review == review, gate.canApply, moneyAccepted else { return }
            try await access.sendRequestUndo(operation)
            guard token == generation else { return }
            candidate = nil; self.review = nil; packs = []; history = []; gate.reset(); submitted = true
            notice = ru("Confirmed. The complete request acceptance was undone.")
        } catch { fail(error, token: token) }
    }
    func editAgain() { review = nil; gate.reset() }
    private func fail(_ error: Error, token: UUID) {
        guard token == generation else { return }; review = nil; gate.reset()
        switch error as? ClientError {
        case .accessEnded, .sessionNeeded: clear(); notice = st("Shared access ended. Return to the household.")
        case .cancelled: clear(); notice = st("The review was cancelled because its scope changed. Refresh before continuing.")
        case .service(let status, _, _, _) where status == 403 || status == 404 || status == 409:
            candidate = nil; packs = []; history = []; notice = st("Needs a fresh review. Return to the shop, refresh current facts, and resolve any saved retry before starting again.")
        default: notice = pending ? st("Not confirmed. Return to the shop and retry the exact saved action.") : ru("The request Undo is not confirmed. Check every remaining pack and review again.")
        }
    }
}
func ru(_ key: String) -> String { String(localized: String.LocalizationValue(key), table: "SharedRequestUndo") }
