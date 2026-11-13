import Foundation
import Combine
import HouseholdClient

struct HistoryRuntimeScope: Equatable, Sendable {
    let generation: UUID; let subject: String; let householdID: String; let memberID: String; let currentShopID: String?
    let authorityStamp: String
    init(generation: UUID, subject: String, householdID: String, memberID: String, currentShopID: String?, authorityStamp: String = "") {
        self.generation = generation; self.subject = subject; self.householdID = householdID; self.memberID = memberID; self.currentShopID = currentShopID; self.authorityStamp = authorityStamp
    }
}
protocol HistoryServing: Sendable {
    func historyOwnedShops(cursor: String?) async throws -> HistoryOwnedShopPage
    func historyReadableShops(cursor: String?) async throws -> HistoryReadableShopPage
    func priceObservations(cursor: String?) async throws -> HistoryPriceObservationPage
    func priceObservation(observationID: String) async throws -> HistoryPriceObservation
    func budgetPeriods(cursor: String?) async throws -> HistoryBudgetPeriodPage
    func budgetPeriod(periodID: String) async throws -> HistoryPeriodResponse
    func savedBudgetPeriod(periodID: String) async throws -> HistorySavedBudgetPeriod
    func preparePriceObservation(_ observation: HistoryPriceObservation) async throws -> PriceObservationIntent
    func executePriceObservation(_ intent: PriceObservationIntent) async throws -> PriceObservationReceipt
    func prepareBudgetPeriod(_ period: HistoryBudgetPeriod, baseRevision: Int) async throws -> BudgetPeriodIntent
    func executeBudgetPeriod(_ intent: BudgetPeriodIntent) async throws -> BudgetPeriodReceipt
    func authorizePriceObservation(_ intent: PriceObservationIntent) async throws
    func authorizeBudgetPeriod(_ intent: BudgetPeriodIntent) async throws
}
extension HouseholdService: HistoryServing {}

enum HistoryReviewedWrite: Equatable {
    case observation(HistoryPriceObservation)
    case period(HistoryBudgetPeriod, baseRevision: Int)
}

@MainActor final class HistoryFeatureModel: ObservableObject {
    @Published var observationDraft = HistoryObservationDraft() { didSet { cancelReview() } }
    @Published var periodDraft: HistoryPeriodDraft? { didSet { cancelReview() } }
    @Published var approved = false
    @Published var filter = HistoryPriceFilter()
    @Published private(set) var ownedShops: [HistoryOwnedShop] = []
    @Published private(set) var ownedShopCursor: String?
    @Published private(set) var readableShopCursor: String?
    @Published private(set) var observations: [HistoryPriceObservation] = []
    @Published private(set) var observationCursor: String?
    @Published private(set) var savedObservationIDs: [String] = []
    @Published private(set) var selectedObservation: HistoryPriceObservation?
    @Published private(set) var periods: [HistoryBudgetPeriodReference] = []
    @Published private(set) var periodCursor: String?
    @Published private(set) var selectedPeriod: HistorySavedBudgetPeriod?
    @Published private(set) var periodAnalysis: HistoryPeriodResponse?
    @Published private(set) var reviewed: HistoryReviewedWrite?
    @Published private(set) var pending: HistoryPendingWrite?
    @Published private(set) var hasUnresolvedWrite = false
    @Published private(set) var busy = false
    @Published private(set) var notice: String?
    private let service: any HistoryServing
    private let store: any HistoryPersisting
    private let runtime: () -> HistoryRuntimeScope?
    private let onAccessEnded: () async -> Void
    private var scope: HistoryRuntimeScope?
    private var generation = UUID()
    private var storeEpoch: UUID?
    private var confirmedID: String?
    private var references: [HistoryStoredReference] = []
    private var seenPriceCursors = Set<String>()
    private var seenPeriodCursors = Set<String>()
    private var seenShopCursors = Set<String>()
    private var readableShopIDs = Set<String>()
    private var seenReadableCursors = Set<String>()

    init(service: any HistoryServing, store: any HistoryPersisting, runtime: @escaping () -> HistoryRuntimeScope?, onAccessEnded: @escaping () async -> Void = {}) {
        self.service = service; self.store = store; self.runtime = runtime; self.onAccessEnded = onAccessEnded
    }
    var authorized: Bool { scope != nil && scope == runtime() }
    var currentShopID: String? { authorized ? scope?.currentShopID : nil }
    var canEdit: Bool { authorized && !busy && storeEpoch != nil && !hasUnresolvedWrite }
    var canBeginObservation: Bool { canEdit && !ownedShops.isEmpty }
    var canReviewObservation: Bool { canEdit && ownedShops.contains { $0.shopId.lowercased() == observationDraft.shopID.lowercased() } }
    private func ownedCurrentShop(_ id: String?) -> String {
        guard let id, ownedShops.contains(where: { $0.shopId.lowercased() == id.lowercased() }) else { return "" }
        return id
    }
    var canEditSelectedPeriod: Bool {
        guard canEdit, let period = selectedPeriod else { return false }
        return ownsSources(of: period)
    }
    private func ownsSources(of period: HistorySavedBudgetPeriod) -> Bool {
        let owned = Set(ownedShops.map { $0.shopId.lowercased() })
        return period.period.shopIds.allSatisfy { owned.contains($0.lowercased()) }
    }
    var canApply: Bool { canEdit && reviewed != nil && approved }
    var filteredObservations: [HistoryPriceObservation] { authorized ? observations.filter(filter.matches) : [] }
    func cancelReview() { reviewed = nil; approved = false }
    func invalidate() {
        generation = UUID(); scope = nil; storeEpoch = nil
        ownedShops = []; ownedShopCursor = nil; readableShopIDs = []; readableShopCursor = nil; observations = []; observationCursor = nil; savedObservationIDs = []
        selectedObservation = nil; periods = []; periodCursor = nil; selectedPeriod = nil; periodAnalysis = nil
        observationDraft = .init(); periodDraft = nil; filter = .init(); pending = nil; hasUnresolvedWrite = false; confirmedID = nil; references = []
        cancelReview(); notice = nil; seenPriceCursors = []; seenPeriodCursors = []; seenShopCursors = []; seenReadableCursors = []
    }
    func enforceRuntime() { if scope != nil && !authorized { invalidate() } }
    private func live(_ start: UUID) -> Bool { generation == start && authorized }
    func load() async {
        guard !busy, let current = runtime() else { return }
        invalidate(); scope = current; busy = true; defer { busy = false }; let start = generation
        do {
            let epoch = await store.epoch()
            let shops = try await service.historyOwnedShops(cursor: nil)
            let readable = try await service.historyReadableShops(cursor: nil)
            let page = try await service.budgetPeriods(cursor: nil)
            let saved = try await store.read()
            guard live(start) else { return }
            let candidate = saved.pending.first { $0.matches(current) }
            hasUnresolvedWrite = candidate != nil
            ownedShops = shops.shops; ownedShopCursor = shops.nextCursor
            readableShopIDs = Set(readable.shopIds); readableShopCursor = readable.nextCursor
            periods = page.periods; periodCursor = page.nextCursor
            storeEpoch = epoch; references = saved.observations.filter { $0.matches(current) }
            refreshReferences(); observationDraft.shopID = ownedCurrentShop(current.currentShopID)
            if let candidate { try await authorize(candidate) }
            guard live(start) else { return }; pending = candidate
        } catch { if live(start) { await fail(error) } }
    }
    func loadOwnedShops(more: Bool = false) async {
        guard authorized, !busy, !more || ownedShopCursor != nil else { return }
        busy = true; defer { busy = false }; let start = generation; let cursor = more ? ownedShopCursor : nil
        if !more { ownedShops = []; ownedShopCursor = nil; savedObservationIDs = []; seenShopCursors = [] }
        do {
            try await fetchOwnedShops(cursor: cursor, generation: start)
        } catch { if live(start) { ownedShops = []; ownedShopCursor = nil; savedObservationIDs = []; await fail(error) } }
    }
    private func fetchOwnedShops(cursor: String?, generation start: UUID) async throws {
        let page = try await service.historyOwnedShops(cursor: cursor)
        guard live(start) else { throw ClientError.cancelled }
        let existing = cursor == nil ? [] : ownedShops
        if cursor == nil { seenShopCursors = [] }
        try validatePage(ids: page.shops.map(\.shopId), existing: existing.map(\.shopId), next: page.nextCursor, cursor: cursor, seen: seenShopCursors)
        ownedShops = existing + page.shops
        ownedShopCursor = page.nextCursor
        if let cursor { seenShopCursors.insert(cursor) }
        refreshReferences()
    }
    func loadReadableShops(more: Bool = false) async {
        guard authorized, !busy, !more || readableShopCursor != nil else { return }
        busy = true; defer { busy = false }; let start = generation; let cursor = more ? readableShopCursor : nil
        if !more { readableShopIDs = []; readableShopCursor = nil; savedObservationIDs = []; seenReadableCursors = [] }
        do {
            let page = try await service.historyReadableShops(cursor: cursor)
            guard live(start) else { return }
            try validatePage(ids: page.shopIds, existing: more ? Array(readableShopIDs) : [], next: page.nextCursor, cursor: cursor, seen: seenReadableCursors)
            readableShopIDs.formUnion(page.shopIds); readableShopCursor = page.nextCursor
            if let cursor { seenReadableCursors.insert(cursor) }; refreshReferences()
        } catch { if live(start) { readableShopIDs = []; readableShopCursor = nil; savedObservationIDs = []; await fail(error) } }
    }
    func loadPriceHistory(more: Bool = false) async {
        guard authorized, !busy, !more || observationCursor != nil else { return }
        busy = true; defer { busy = false }; let start = generation; let cursor = more ? observationCursor : nil
        if !more { observations = []; observationCursor = nil; seenPriceCursors = [] }
        do {
            let page = try await service.priceObservations(cursor: cursor)
            guard live(start) else { return }
            try validatePage(ids: page.observations.map(\.id), existing: more ? observations.map(\.id) : [], next: page.nextCursor, cursor: cursor, seen: seenPriceCursors)
            observations += page.observations; observationCursor = page.nextCursor; if let cursor { seenPriceCursors.insert(cursor) }; notice = nil
        } catch { if live(start) { observations = []; observationCursor = nil; await fail(error) } }
    }
    func loadPeriods(more: Bool = false) async {
        guard authorized, !busy, !more || periodCursor != nil else { return }
        busy = true; defer { busy = false }; let start = generation; let cursor = more ? periodCursor : nil
        if !more { periods = []; periodCursor = nil; seenPeriodCursors = [] }
        do {
            let page = try await service.budgetPeriods(cursor: cursor)
            guard live(start) else { return }
            try validatePage(ids: page.periods.map(\.periodId), existing: more ? periods.map(\.periodId) : [], next: page.nextCursor, cursor: cursor, seen: seenPeriodCursors)
            periods += page.periods; periodCursor = page.nextCursor; if let cursor { seenPeriodCursors.insert(cursor) }; notice = nil
        } catch { if live(start) { periods = []; periodCursor = nil; await fail(error) } }
    }
    func openObservation(_ id: String) async {
        guard authorized, !busy else { return }
        busy = true; defer { busy = false }; let start = generation; selectedObservation = nil
        do {
            let value = try await service.priceObservation(observationID: id)
            guard live(start) else { return }
            selectedObservation = value; notice = nil
            if let scope, let epoch = storeEpoch {
                let ref = HistoryStoredReference(subject: scope.subject, householdID: scope.householdID, memberID: scope.memberID, shopID: value.shopId, observationID: value.id)
                try await store.remember(ref, expectedEpoch: epoch)
                guard live(start) else { return }
                if !references.contains(ref) { references.append(ref); refreshReferences() }
            }
        } catch { if live(start) { selectedObservation = nil; await fail(error) } }
    }
    func openPeriod(_ id: String, analyze: Bool = false) async {
        guard authorized, !busy else { return }
        busy = true; defer { busy = false }; let start = generation
        // Do not let a prior full envelope survive a narrower response or failed authorization.
        selectedPeriod = nil; periodAnalysis = nil; periodDraft = nil; cancelReview()
        do {
            if analyze {
                let value = try await service.budgetPeriod(periodID: id)
                guard live(start) else { return }; periodAnalysis = value
                if case .complete(let full) = value {
                    selectedPeriod = .init(periodId: full.periodId, revision: full.revision, period: full.period)
                } else { pending = nil }
            } else {
                let value = try await service.savedBudgetPeriod(periodID: id)
                guard live(start) else { return }; selectedPeriod = value
            }
            if let selectedPeriod, !selectedPeriod.period.shopIds.isEmpty {
                // A read grant can survive loss of shopper authority. Refresh ownership
                // before offering an edit and include later pages for multi-shop plans.
                ownedShops = []; ownedShopCursor = nil
                try await fetchOwnedShops(cursor: nil, generation: start)
                while !ownsSources(of: selectedPeriod), let cursor = ownedShopCursor {
                    try await fetchOwnedShops(cursor: cursor, generation: start)
                }
            }
            notice = nil
        } catch { if live(start) { await fail(error) } }
    }
    func beginObservation() { guard canBeginObservation else { return }; observationDraft = .init(); observationDraft.shopID = ownedCurrentShop(currentShopID); selectedObservation = nil; cancelReview() }
    func beginPeriod() {
        guard canEdit else { return }
        var draft = HistoryPeriodDraft()
        let id = ownedCurrentShop(currentShopID)
        if !id.isEmpty { draft.shopIDs = [id] }
        periodDraft = draft
        selectedPeriod = nil
        periodAnalysis = nil
        cancelReview()
    }
    func canAssignPeriodShop(_ id: String) -> Bool {
        guard canEdit, let draft = periodDraft, draft.shopIDs.count < 100,
              !ownedCurrentShop(id).isEmpty else { return false }
        return !draft.shopIDs.contains { $0.lowercased() == id.lowercased() }
    }
    func assignPeriodShop(_ id: String) {
        guard canAssignPeriodShop(id) else { return }
        periodDraft?.shopIDs.append(id)
    }
    func editSelectedPeriod() { guard canEditSelectedPeriod, let selectedPeriod else { return }; periodDraft = .init(selectedPeriod); cancelReview() }
    func reviewObservation() {
        guard canReviewObservation else { return }
        do { let value = try observationDraft.dto(); guard HistoryDate.date(value.observedAt)! <= Date().addingTimeInterval(300) else { throw HistoryDraftError.invalid }; reviewed = .observation(value); approved = false; notice = nil }
        catch { cancelReview(); notice = HistoryCopy.text("Check the item, pack, price evidence, store, branch, source and observed date before reviewing.") }
    }
    func reviewPeriod() {
        guard canEdit, let periodDraft else { return }
        do { reviewed = .period(try periodDraft.dto(), baseRevision: periodDraft.baseRevision); approved = false; notice = nil }
        catch { cancelReview(); notice = HistoryCopy.text("Check the period dates, time zone, budget, assigned shops and reservation evidence before reviewing.") }
    }
    func applyReviewed() async {
        guard canApply, let action = reviewed, let epoch = storeEpoch else { return }
        busy = true; defer { busy = false }; let start = generation; notice = nil
        do {
            let value: HistoryPendingWrite
            switch action {
            case .observation(let observation): value = .observation(try await service.preparePriceObservation(observation))
            case .period(let period, let revision): value = .period(try await service.prepareBudgetPeriod(period, baseRevision: revision))
            }
            guard live(start), reviewed == action, approved else { return }
            try await store.save(value, expectedEpoch: epoch)
            guard live(start) else { return }; pending = value; hasUnresolvedWrite = true; cancelReview()
            await deliver(value, start: start, epoch: epoch)
        } catch { if live(start) { cancelReview(); await fail(error) } }
    }
    func retry() async {
        guard authorized, !busy, let pending, let epoch = storeEpoch else { return }
        busy = true; defer { busy = false }; notice = nil
        await deliver(pending, start: generation, epoch: epoch)
    }
    /// Explicit local discard after a fresh authority/status check; this does not prove or undo a server mutation.
    func clearPendingAfterStatusReview() async {
        guard authorized, !busy, let value = pending, let epoch = storeEpoch else { return }
        busy = true; defer { busy = false }; let start = generation
        do {
            try await authorize(value)
            guard live(start) else { return }
            switch value {
            case .observation(let intent):
                do { _ = try await service.priceObservation(observationID: intent.observation.id) }
                catch ClientError.service(let status, _, _, _) where status == 404 { break }
            case .period(let intent):
                do { _ = try await service.savedBudgetPeriod(periodID: intent.period.id) }
                catch ClientError.service(let status, _, _, _) where status == 404 && intent.baseRevision == 0 { break }
            }
            guard live(start) else { return }
            try await store.remove(id: value.id, expectedEpoch: epoch)
            guard live(start) else { return }
            pending = nil; hasUnresolvedWrite = false; confirmedID = nil; cancelReview()
            selectedPeriod = nil; periodAnalysis = nil; periodDraft = nil; selectedObservation = nil
            notice = HistoryCopy.text("The local retry was cleared after checking current access and record status. This does not undo a saved record or confirm the original result.")
        } catch { if live(start) { await fail(error) } }
    }
    private func deliver(_ value: HistoryPendingWrite, start: UUID, epoch: UUID) async {
        do {
            if confirmedID != value.id {
                switch value {
                case .observation(let intent): _ = try await service.executePriceObservation(intent)
                case .period(let intent): _ = try await service.executeBudgetPeriod(intent)
                }
                guard live(start) else { return }; confirmedID = value.id
            }
            try await store.complete(value, expectedEpoch: epoch)
            guard live(start) else { return }
            if case .observation(let intent) = value, let scope {
                let ref = HistoryStoredReference(subject: scope.subject, householdID: scope.householdID, memberID: scope.memberID, shopID: intent.observation.shopId, observationID: intent.observation.id)
                if !references.contains(ref) { references.append(ref); refreshReferences() }
                selectedObservation = intent.observation
            }
            pending = nil; hasUnresolvedWrite = false; confirmedID = nil; periodDraft = nil; observationDraft = .init()
            notice = HistoryCopy.text("The reviewed record was saved. Refresh its current record or analysis before making another change.")
        } catch {
            guard live(start) else { return }
            if confirmedID == value.id { notice = HistoryCopy.text("The record was saved. Retry to finish clearing its local retry record.") }
            else { await fail(error) }
        }
    }
    private func authorize(_ value: HistoryPendingWrite) async throws {
        switch value { case .observation(let intent): try await service.authorizePriceObservation(intent); case .period(let intent): try await service.authorizeBudgetPeriod(intent) }
    }
    private func refreshReferences() { savedObservationIDs = references.filter { readableShopIDs.contains($0.shopID) }.map(\.observationID) }
    private func validatePage(ids: [String], existing: [String], next: String?, cursor: String?, seen: Set<String>) throws {
        guard Set(ids).count == ids.count, Set(ids).isDisjoint(with: existing), next == nil || (next != cursor && !seen.contains(next!) && ids.contains(next!)) else { throw ClientError.invalidResponse }
    }
    private func fail(_ error: Error) async {
        switch error as? ClientError {
        case .sessionNeeded, .accessEnded:
            invalidate(); await onAccessEnded()
        case .cancelled: break
        case .service(let status, let code, _, _):
            if code == "membership_inactive" || code == "billing_unavailable" {
                observations = []; observationCursor = nil; periodAnalysis = nil; selectedPeriod = nil; periodDraft = nil; pending = nil; cancelReview()
                notice = HistoryCopy.text("History analysis and period planning need a current Household membership. Your authorized saved raw records remain available.")
            } else if status == 403 || status == 404 {
                invalidate(); notice = HistoryCopy.text("This record is unavailable in your current access. Refresh your household before trying again.")
            } else if status == 409 {
                cancelReview(); notice = HistoryCopy.text("The saved facts changed. Refresh and review a new action; an existing retry keeps its original bytes and revision.")
            } else { notice = HistoryCopy.text("The result is not confirmed. Keep the original retry and reconcile it before starting another action.") }
        default: notice = HistoryCopy.text("The result is not confirmed. Keep the original retry and reconcile it before starting another action.")
        }
    }
}
