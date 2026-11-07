import Foundation
import HouseholdClient
import SwiftUI

@MainActor
final class SharedFallbackModel: ObservableObject {
    let shopID: UUID
    private let service: HouseholdService
    private let store: FallbackPendingStore
    private let authorized: () -> Bool
    private var generation = UUID()
    private var storeEpoch: UUID?
    private var rankingID = UUID()
    @Published private(set) var library: SharedFallbackLibrary?
    @Published private(set) var paidUntil: Date?
    @Published private(set) var pending: PendingFallbackWrite?
    @Published private(set) var ranking: SharedFallbackOptions?
    @Published private(set) var busy = false
    @Published private(set) var notice: String?

    init(shopID: UUID, service: HouseholdService, store: FallbackPendingStore, authorized: @escaping () -> Bool) {
        self.shopID = shopID
        self.service = service
        self.store = store
        self.authorized = authorized
    }

    var live: Bool { authorized() }
    var canSuggest: Bool { live && (paidUntil.map { $0 > Date() } ?? false) }
    private func current(_ token: UUID) -> Bool { generation == token && live && !Task.isCancelled }

    func invalidate() {
        generation = UUID()
        library = nil
        pending = nil
        ranking = nil
        paidUntil = nil
        storeEpoch = nil
        notice = nil
        busy = false
    }

    func expireSuggestions() {
        guard !canSuggest else { return }
        paidUntil = nil
        ranking = nil
    }

    func load() async {
        guard live, !busy else { return }
        let token = generation
        busy = true
        defer { if current(token) { busy = false } }
        do {
            try await refresh(token)
            guard current(token) else { return }
            // Retained household recipes and withdrawal remain available after membership ends.
            let expiry = try? await service.assistanceValidUntil(shopID: shopID.uuidString.lowercased())
            guard current(token) else { return }
            paidUntil = expiry
        } catch { fail(error, token: token) }
    }

    private func refresh(_ token: UUID) async throws {
        let epoch = await store.epoch()
        let fresh = try await service.acceptedFallbacks(shopID: shopID.uuidString.lowercased())
        let saved = try await store.read().first(where: { fresh.belongsToSameDevice(as: $0) })
        guard current(token), fresh.shopId == shopID else { throw ClientError.cancelled }
        storeEpoch = epoch
        library = fresh
        pending = saved
        ranking = nil
        notice = nil
    }

    func approvedIdeas(reviewed: SharedFallbackLibrary) async throws -> [SharedMealIdeaPage.Idea] {
        guard canSuggest, library == reviewed else { throw ClientError.cancelled }
        let token = generation
        let page = try await service.sharedMealIdeas(shopID: shopID)
        guard current(token), canSuggest, library == reviewed, page.shopId == shopID,
              page.shopRevision == reviewed.shopRevision, page.authorityEpoch == reviewed.authorityEpoch else { throw ClientError.cancelled }
        return page.ideas.filter { $0.state == "approved" }
    }

    func source(_ source: SharedFallbackSource, reviewed: SharedFallbackLibrary) async throws -> SharedFallbackSourcePreview {
        guard live, canSuggest, !busy, pending == nil, library == reviewed else { throw ClientError.cancelled }
        let token = generation
        busy = true
        defer { if current(token) { busy = false } }
        do {
            let result = try await service.fallbackSource(source, reviewed: reviewed)
            guard current(token), canSuggest, library == reviewed else { throw ClientError.cancelled }
            return result
        } catch {
            fail(error, token: token)
            throw error
        }
    }

    @discardableResult func save(_ edit: SharedFallbackEdit, reviewed: SharedFallbackLibrary) async -> Bool {
        guard live, !busy, pending == nil, library == reviewed, let epoch = storeEpoch else { return false }
        if case .accept = edit, !canSuggest { return false }
        let token = generation
        busy = true
        defer { if current(token) { busy = false } }
        do {
            let intent = try await service.prepareFallback(edit, reviewed: reviewed, clientKey: UUID())
            guard current(token), library == reviewed else { throw ClientError.cancelled }
            try await store.save(intent, expectedEpoch: epoch)
            guard current(token) else { throw ClientError.cancelled }
            pending = intent
            ranking = nil
            try await deliver(intent, epoch: epoch, token: token)
            return true
        } catch {
            fail(error, token: token)
            return false
        }
    }

    func retry() async {
        guard live, !busy, let pending, let library, library.belongsToSameDevice(as: pending), let epoch = storeEpoch else { return }
        let token = generation
        busy = true
        defer { if current(token) { busy = false } }
        do { try await deliver(pending, epoch: epoch, token: token) }
        catch { fail(error, token: token) }
    }

    private func deliver(_ intent: PendingFallbackWrite, epoch: UUID, token: UUID) async throws {
        _ = try await service.executeFallback(intent)
        guard current(token) else { throw ClientError.cancelled }
        try await store.complete(intent, expectedEpoch: epoch)
        guard current(token) else { throw ClientError.cancelled }
        pending = nil
        try await refresh(token)
    }

    /// A failed or stale write remains available for exact retry until the shopper checks the current registry.
    func clearRetryAfterReview(_ reviewed: SharedFallbackLibrary) async {
        guard live, !busy, let pending, let epoch = storeEpoch, library == reviewed else { return }
        let token = generation
        busy = true
        defer { if current(token) { busy = false } }
        do {
            let currentLibrary = try await service.acceptedFallbacks(shopID: shopID.uuidString.lowercased())
            guard current(token), currentLibrary == reviewed, currentLibrary.belongsToSameDevice(as: pending) else {
                if current(token) { try await refresh(token) }
                return
            }
            try await store.complete(pending, expectedEpoch: epoch)
            guard current(token) else { return }
            self.pending = nil
            notice = nil
        } catch { fail(error, token: token) }
    }

    func rank(_ reviews: [SharedFallbackReview], trip: SharedFallbackTrip?, occurrence: UUID,
              page: SharedRecoveryPage, reviewed: SharedFallbackLibrary) async {
        guard live, canSuggest, !busy, pending == nil, library == reviewed else { return }
        let token = generation
        busy = true
        discardRanking()
        let read = rankingID
        defer { if current(token) { busy = false } }
        do {
            let result = try await service.recoveryOptions(reviews, trip: trip, for: occurrence, reviewed: page, library: reviewed)
            guard current(token), rankingID == read, library == reviewed, canSuggest, let expiry = result.assistanceValidUntil, expiry > Date() else { return }
            paidUntil = expiry
            ranking = result
            notice = nil
        } catch { fail(error, token: token) }
    }

    func discardRanking() { rankingID = UUID(); ranking = nil }

    private func fail(_ error: Error, token: UUID) {
        guard current(token) else { return }
        ranking = nil
        if let failure = error as? ClientError {
            switch failure {
            case .sessionNeeded, .accessEnded:
                invalidate()
            case let .service(status, _, _, _) where [401, 403, 404, 409].contains(status):
                library = nil
                paidUntil = nil
            default: break
            }
        }
        notice = fallbackText("Refresh the household recipe list and review the current record.")
    }
}
