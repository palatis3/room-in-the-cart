import Foundation
import SwiftUI
import HouseholdClient

@MainActor protocol SharedTrackingFlowAccess: AnyObject {
    var trackingShop: ShopperShop? { get }
    var trackingAllowed: Bool { get }
    var trackingLease: UUID { get }
    var trackingPending: Bool { get }
    var trackingSelectionID: UUID? { get }
    func sendTracking(_ operation: PendingOperation, selectionID: UUID?) async throws
    func readTracking(shopID: UUID) async throws -> SharedTrackingPage
    func trackingSources(page: SharedTrackingPage, action: SharedDemandAction, requestPreview: ShopperPreview?) async throws -> SharedTrackingActionSources
    func candidateTracking(page: SharedTrackingPage, kind: SharedTrackingIntentKind, requestPreview: ShopperPreview?, actionSources: SharedTrackingActionSources?) async throws -> SharedTrackingCandidateReview
    func historyTracking(page: SharedTrackingPage) async throws -> SharedTrackingHistory
    func acceptTracking(_ candidate: SharedTrackingCandidateReview, acceptOverage: Bool, acceptUnknown: Bool) async throws -> SharedTrackingAcceptedReview
    func prepareTracking(_ accepted: SharedTrackingAcceptedReview) async throws -> PendingOperation
    func freezeTracking(page: SharedTrackingPage) async throws -> PendingOperation
}
@MainActor protocol SharedTrackingServiceOwner: SharedTrackingFlowAccess { var trackingService: HouseholdService { get } }
extension SharedTrackingServiceOwner {
    func readTracking(shopID: UUID) async throws -> SharedTrackingPage { try await trackingService.sharedTracking(shopID: shopID) }
    func candidateTracking(page: SharedTrackingPage, kind: SharedTrackingIntentKind, requestPreview: ShopperPreview?, actionSources: SharedTrackingActionSources?) async throws -> SharedTrackingCandidateReview {
        try await trackingService.sharedTrackingCandidate(page: page, kind: kind, requestPreview: requestPreview, actionSources: actionSources)
    }
    func trackingSources(page: SharedTrackingPage, action: SharedDemandAction, requestPreview: ShopperPreview?) async throws -> SharedTrackingActionSources { try await trackingService.sharedTrackingActionSources(page: page, action: action, requestPreview: requestPreview) }
    func historyTracking(page: SharedTrackingPage) async throws -> SharedTrackingHistory { try await trackingService.sharedTrackingHistory(page: page) }
    func acceptTracking(_ candidate: SharedTrackingCandidateReview, acceptOverage: Bool, acceptUnknown: Bool) async throws -> SharedTrackingAcceptedReview { try await trackingService.acceptSharedTrackingCandidate(candidate, acceptOverage: acceptOverage, acceptUnknown: acceptUnknown) }
    func prepareTracking(_ accepted: SharedTrackingAcceptedReview) async throws -> PendingOperation { try await trackingService.prepareSharedTrackingApply(accepted) }
    func freezeTracking(page: SharedTrackingPage) async throws -> PendingOperation { try await trackingService.prepareSharedTrackingFreeze(page: page) }
}

@MainActor final class SharedTrackingFlowModel: ObservableObject {
    @Published private(set) var page: SharedTrackingPage?
    @Published private(set) var shop: ShopperShop?
    @Published private(set) var candidate: SharedTrackingCandidateReview?
    @Published private(set) var history: SharedTrackingHistory?
    @Published private(set) var actionSources: SharedTrackingActionSources?
    @Published var acceptOverage = false
    @Published var acceptUnknown = false
    @Published private(set) var busy = false
    @Published private(set) var submitted = false
    @Published private(set) var notice: String?
    @Published var gate = TrackingReviewGate()
    @Published var draft = TrackingFlowDraft() { didSet { if draft != oldValue { candidate = nil; gate.reset() } } }
    let access: any SharedTrackingFlowAccess
    let request: TrackingRequestContext?
    let edited: ShopperShopCandidate?
    let mealEdit: SharedDemandMealEdit?
    let freezing: Bool
    let selectionID: UUID?
    private var generation = UUID()
    private var lease: UUID?
    init(access: any SharedTrackingFlowAccess, request: TrackingRequestContext? = nil,
         edited: ShopperShopCandidate? = nil, mealEdit: SharedDemandMealEdit? = nil, freezing: Bool = false, selectionID: UUID? = nil) {
        self.access = access; self.request = request; self.edited = edited; self.mealEdit = mealEdit; self.freezing = freezing; self.selectionID = request?.id ?? selectionID
    }
    var permitted: Bool { access.trackingSelectionID == selectionID && access.trackingAllowed && access.trackingLease == lease && access.trackingShop == shop }
    var pending: Bool { access.trackingPending }
    var moneyAccepted: Bool {
        guard let budget = candidate?.candidate.disclosure.money.after else { return false }
        return (budget.status != "overCap" || acceptOverage) && ((!["unresolved", "scopeMismatch"].contains(budget.status) && budget.scope == "wholeCheckout") || acceptUnknown)
    }
    func entry<Value>(_ path: WritableKeyPath<TrackingFlowDraft, Value>, empty: Value) -> Binding<Value> {
        let token = generation
        return Binding(get: { [weak self] in
            guard let self, self.generation == token, self.permitted else { return empty }; return self.draft[keyPath: path]
        }, set: { [weak self] value in
            guard let self, self.generation == token, self.permitted, !self.busy, !self.pending, !self.submitted else { return }
            self.draft[keyPath: path] = value
        })
    }
    func factEntry<Value>(id: SharedDemandID, path: WritableKeyPath<TrackingFactEntry, Value>, empty: Value) -> Binding<Value> {
        let entries = entry(\.facts, empty: [])
        return Binding(get: { entries.wrappedValue.first { $0.id == id }?[keyPath: path] ?? empty }, set: { value in
            var rows = entries.wrappedValue
            guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
            rows[index][keyPath: path] = value; entries.wrappedValue = rows
        })
    }
    func row<Row: Identifiable>(_ path: WritableKeyPath<TrackingFlowDraft, [Row]>, id: Row.ID, empty: Row) -> Binding<Row> {
        let rows = entry(path, empty: [])
        return Binding(get: { rows.wrappedValue.first { $0.id == id } ?? empty }, set: { value in
            var entries = rows.wrappedValue
            guard value.id == id, let index = entries.firstIndex(where: { $0.id == id }) else { return }
            entries[index] = value; rows.wrappedValue = entries
        })
    }
    func clear() {
        generation = UUID(); lease = nil; page = nil; shop = nil; candidate = nil; history = nil
        draft = .init(); gate.reset(); actionSources = nil; acceptOverage = false; acceptUnknown = false; busy = false; submitted = false; notice = nil
    }
    func load() async {
        guard !busy else { return }; clear()
        let token = generation, owner = access.trackingLease
        guard access.trackingSelectionID == selectionID, access.trackingAllowed, !pending, let current = access.trackingShop,
              let id = UUID(uuidString: current.shopId) else { return }
        busy = true; defer { if generation == token { busy = false } }
        do {
            let value = try await access.readTracking(shopID: id)
            guard generation == token, owner == access.trackingLease, access.trackingSelectionID == selectionID, access.trackingAllowed,
                  access.trackingShop == current else { return }
            var catalog: SharedTrackingActionSources?
            if value.status == .legacy, request != nil || mealEdit != nil {
                let action = request?.action ?? .patch(.init(quote: edited?.quote ?? current.quote, lines: edited?.lines ?? current.lines,
                    mealEdit: mealEdit, reviewedStoreBasisRevision: edited?.reviewedStoreBasisRevision))
                catalog = try await access.trackingSources(page: value, action: action, requestPreview: request?.reviewed.preview)
                guard generation == token, owner == access.trackingLease, access.trackingSelectionID == selectionID,
                      access.trackingAllowed, access.trackingShop == current else { return }
            }
            let entered = try TrackingFlowDraft(page: value, shop: current, request: request, edited: edited, actionSources: catalog)
            shop = current; page = value; lease = owner; actionSources = catalog; draft = entered
        } catch { fail(error, token: token) }
    }
    func preview(_ kind: SharedTrackingIntentKind? = nil) async {
        guard !busy, !pending, permitted, let page, let shop else { return }
        let token = generation, entered = draft
        busy = true; defer { if token == generation { busy = false } }
        do {
            let intent = try kind ?? entered.intent(page: page, shop: shop, request: request, edited: edited, mealEdit: mealEdit, actionSources: actionSources)
            let value = try await access.candidateTracking(page: page, kind: intent, requestPreview: request?.reviewed.preview, actionSources: actionSources)
            guard generation == token, permitted, entered == draft else { return }
            candidate = value; gate.reset(); acceptOverage = false; acceptUnknown = false; notice = nil
        } catch { fail(error, token: token) }
    }
    func loadHistory() async {
        guard !busy, !pending, permitted, let page else { return }
        let token = generation; busy = true; defer { if token == generation { busy = false } }
        do {
            let value = try await access.historyTracking(page: page)
            guard generation == token, permitted else { return }; history = value
        } catch { fail(error, token: token) }
    }
    func undo(_ item: SharedTrackingHistoryItem) async {
        guard history?.items.contains(item) == true, item.status == .current_preview_required, item.reviewRoute == .tracking else { return }
        do { await preview(.firstAdoptionUndo(targetOperationId: item.operationId,
            packs: try draft.packs.filter(\.includeForUndo).map { try $0.review() })) }
        catch { fail(error, token: generation) }
    }
    func rebind() async {
        guard let page else { return }
        do { await preview(try draft.rebind(page: page)) } catch { fail(error, token: generation) }
    }
    func editAgain() { candidate = nil; gate.reset(); acceptOverage = false; acceptUnknown = false; notice = nil }
    func apply() async {
        guard !busy, !pending, permitted, gate.canApply, moneyAccepted, let candidate else { return }
        let token = generation, overage = acceptOverage, unknown = acceptUnknown; busy = true; defer { if token == generation { busy = false } }
        do {
            let accepted = try await access.acceptTracking(candidate, acceptOverage: overage, acceptUnknown: unknown)
            guard token == generation, permitted, self.candidate == candidate, gate.canApply, moneyAccepted, acceptOverage == overage, acceptUnknown == unknown else { return }
            let operation = try await access.prepareTracking(accepted)
            guard token == generation, permitted, self.candidate == candidate, gate.canApply, moneyAccepted, acceptOverage == overage, acceptUnknown == unknown else { return }
            try await access.sendTracking(operation, selectionID: selectionID)
            guard token == generation else { return }; finish()
        } catch { fail(error, token: token) }
    }
    func freeze() async {
        guard freezing, !busy, !pending, permitted, gate.canApply, let page, page.freezeReview != nil else { return }
        let token = generation; busy = true; defer { if token == generation { busy = false } }
        do {
            let operation = try await access.freezeTracking(page: page)
            guard token == generation, permitted, self.page == page, gate.canApply else { return }
            try await access.sendTracking(operation, selectionID: selectionID)
            guard token == generation else { return }; finish()
        } catch { fail(error, token: token) }
    }
    private func finish() {
        page = nil; shop = nil; candidate = nil; history = nil; actionSources = nil; draft = .init(); gate.reset(); acceptOverage = false; acceptUnknown = false; submitted = true
        notice = st("Confirmed. Return to the shared shop for the updated revision.")
    }
    private func fail(_ error: Error, token: UUID) {
        guard token == generation else { return }; candidate = nil; gate.reset()
        switch error as? ClientError {
        case .sessionNeeded, .accessEnded:
            clear(); notice = st("Shared access ended. Return to the household.")
        case .cancelled:
            clear(); notice = st("The review was cancelled because its scope changed. Refresh before continuing.")
        case .service(let status, _, _, _) where status == 409 || status == 404 || status == 403:
            page = nil; shop = nil; history = nil; draft = .init()
            notice = st("Needs a fresh review. Return to the shop, refresh current facts, and resolve any saved retry before starting again.")
        default:
            notice = pending ? st("Not confirmed. Return to the shop and retry the exact saved action.") : st("Check the entered facts and try reviewing again. Unknown amounts may stay unknown.")
        }
    }
}
func st(_ key: String) -> String { String(localized: String.LocalizationValue(key), table: "SharedTracking") }
