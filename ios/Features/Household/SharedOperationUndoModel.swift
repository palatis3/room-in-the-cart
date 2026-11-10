import Foundation
import Combine
import HouseholdClient

struct SharedOperationUndoAccessIdentity: Equatable {
    let householdID, memberID, shopID: String
}

@MainActor protocol SharedOperationUndoAccess: SharedDemandFlowAccess {
    var operationUndoIdentity: SharedOperationUndoAccessIdentity? { get }
    func load() async
    func retry() async
    func operationHistory(page: SharedDemandPage, beforeRevision: Int?) async throws -> SharedOperationUndoHistory
    func operationUndoCandidate(page: SharedDemandPage, target: SharedOperationUndoHistoryItem) async throws -> SharedOperationUndoCandidate
    func previewOperationUndo(page: SharedDemandPage, target: SharedOperationUndoHistoryItem, candidate: SharedOperationUndoCandidate, packs: [SharedDemandPackReview]) async throws -> SharedOperationUndoReview
    func applyOperationUndo(_ review: SharedOperationUndoReview) async throws
    func cancelOperationUndoReview()
}

/// Read-only history/candidate/review until explicit Apply. Pending commands belong
/// to the original shop outbox; this feature never caches historical source copies.
@MainActor final class SharedOperationUndoModel: ObservableObject {
    @Published private(set) var history: [SharedOperationUndoHistoryItem] = []
    @Published private(set) var nextBeforeRevision: Int?
    @Published private(set) var candidate: SharedOperationUndoCandidate?
    @Published private(set) var review: SharedOperationUndoReview?
    @Published private(set) var packs: [SharedDemandPackReview] = []
    @Published private(set) var busy = false
    @Published private(set) var failed = false
    @Published var monetaryAcknowledged = false
    private var identity: SharedOperationUndoAccessIdentity?
    private var page: SharedDemandPage?
    private var shop: ShopperShop?
    private var target: SharedOperationUndoHistoryItem?
    private var generation = UUID()
    private var applying = false
    private let access: any SharedOperationUndoAccess
    init(access: any SharedOperationUndoAccess) { self.access = access }
    var pending: Bool { access.foodPending }
    var currentShop: ShopperShop? { current ? shop : nil }
    var isApplying: Bool { applying }
    private var current: Bool { identity != nil && access.operationUndoIdentity == identity && access.canReadFood && access.foodShop == shop && !access.foodPending }
    func cancel() {
        generation = UUID(); access.cancelOperationUndoReview()
        history = []; nextBeforeRevision = nil; candidate = nil; review = nil; packs = []
        identity = nil; page = nil; shop = nil; target = nil; monetaryAcknowledged = false; busy = false; failed = false
    }
    func accessChanged() {
        guard let identity else { return }
        guard access.operationUndoIdentity == identity else { cancel(); return }
        if access.foodPending { cancel(); return } // Parent retains exact command/status.
        if let shop {
            if !access.canReadFood || access.foodShop != shop { cancel() }
        } else if let loadingShop = access.foodShop {
            // Initial load publishes its first shop before this model binds a page.
            if loadingShop.shopId != identity.shopID || loadingShop.phase != "draft" { cancel() }
        }
    }
    func editReview() {
        guard !applying else { return }
        generation = UUID(); access.cancelOperationUndoReview(); review = nil; monetaryAcknowledged = false; busy = false
    }
    func load() async {
        cancel(); identity = access.operationUndoIdentity
        guard identity != nil else { failed = true; return }
        let token = generation; busy = true
        defer { if generation == token { busy = false } }
        do {
            await access.load()
            guard generation == token, access.operationUndoIdentity == identity, access.canReadFood, !pending else { return }
            let page = try await access.readFood()
            guard generation == token, access.operationUndoIdentity == identity, access.canReadFood, let shop = access.foodShop, !pending else { return }
            let value = try await access.operationHistory(page: page, beforeRevision: nil)
            guard generation == token, access.operationUndoIdentity == identity, access.canReadFood, access.foodShop == shop, !pending else { return }
            self.page = page; self.shop = shop; history = value.items; nextBeforeRevision = value.nextBeforeRevision.flatMap(Int.init)
        } catch { fail(error, token: token) }
    }
    func loadMore() async {
        guard current, !busy, let page, let cursor = nextBeforeRevision else { return }
        let token = generation; busy = true; defer { if token == generation { busy = false } }
        do {
            let value = try await access.operationHistory(page: page, beforeRevision: cursor)
            guard token == generation, current else { if token == generation { cancel() }; return }
            guard Set(history.map(\.operationId)).isDisjoint(with: value.items.map(\.operationId)) else { throw ClientError.invalidResponse }
            history += value.items; nextBeforeRevision = value.nextBeforeRevision.flatMap(Int.init)
        } catch { fail(error, token: token) }
    }
    func select(_ item: SharedOperationUndoHistoryItem) async {
        guard current, !busy, let page, history.contains(item), item.eligibility.status == .reviewable else { return }
        access.cancelOperationUndoReview(); candidate = nil; review = nil; packs = []; monetaryAcknowledged = false
        let token = generation; busy = true; defer { if token == generation { busy = false } }
        do {
            let value = try await access.operationUndoCandidate(page: page, target: item)
            guard token == generation, current else { if token == generation { cancel() }; return }
            target = item; candidate = value
        } catch { fail(error, token: token) }
    }
    func acknowledgePack(_ pack: SharedDemandPackReview) throws {
        guard current, !applying, let candidate, candidate.packReviewLineIds.contains(pack.lineId), pack.usablePerPack != nil || pack.acceptUnresolved else { throw ClientError.configuration }
        try pack.usablePerPack?.validate()
        generation = UUID(); access.cancelOperationUndoReview(); review = nil; monetaryAcknowledged = false; busy = false
        packs.removeAll { $0.lineId == pack.lineId }; packs.append(pack)
    }
    func preview() async {
        guard current, !busy, let page, let target, let candidate else { return }
        let token = generation, entered = packs; busy = true; review = nil; monetaryAcknowledged = false
        defer { if token == generation { busy = false } }
        do {
            _ = try SharedOperationUndoPreviewRequest(candidate: candidate, packs: entered)
            let value = try await access.previewOperationUndo(page: page, target: target, candidate: candidate, packs: entered)
            guard token == generation, current, packs == entered else { if token == generation { cancel() }; return }
            review = value
        } catch { fail(error, token: token) }
    }
    func apply() async {
        guard current, !busy, monetaryAcknowledged, let review, review.request.packs == packs else { return }
        let token = generation; busy = true; applying = true
        defer { applying = false; if token == generation { busy = false } }
        do {
            try await access.applyOperationUndo(review)
            guard token == generation else { return }
            cancel() // The existing shop owns any durable pending command or receipt.
        } catch { fail(error, token: token) }
    }
    func retry() async {
        guard !busy, access.canReadFood, pending else { return }
        await access.retry() // Never regenerate a candidate, preview, key, or command.
    }
    private func fail(_ error: Error, token: UUID) {
        guard token == generation else { return }
        cancel(); failed = true
    }
}
