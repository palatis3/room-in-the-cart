import Foundation
import HouseholdClient

@MainActor final class FamilyDecisionModel: ObservableObject {
    let access: FamilyDecisionAccess
    private let service: HouseholdService
    private let store: HistoryPendingStore
    private let currentAccess: () -> FamilyDecisionAccess?
    private var epoch: UUID?
    @Published private(set) var busy = false
    @Published private(set) var notice: String?
    @Published private(set) var shops: [HistoryOwnedShop] = []
    @Published private(set) var shopCursor: String?
    @Published private(set) var refs: [FamilyDecisionReference] = []
    @Published private(set) var pending: FamilyDecisionIntent?
    @Published private(set) var record: FamilyDecisionRecord?
    @Published private(set) var results: [FamilyDecisionRecord] = []
    @Published private(set) var cursor: UUID?
    @Published private(set) var searched = false
    @Published private(set) var lastWrite: UUID?
    private var filters: [String?] = [nil,nil,nil]
    init(access: FamilyDecisionAccess, service: HouseholdService, store: HistoryPendingStore,
         currentAccess: @escaping () -> FamilyDecisionAccess?) {
        self.access = access; self.service = service; self.store = store; self.currentAccess = currentAccess
    }
    private var live: Bool { access == currentAccess() }
    var canWrite: Bool { live && !busy && pending == nil && epoch != nil }
    func load() async {
        await run {
            let epoch = await self.store.epoch()
            let page = try await self.service.historyOwnedShops()
            guard self.live else { return }
            self.shops = page.shops; self.shopCursor = page.nextCursor; self.epoch = epoch
            try await self.readReferences()
        }
    }
    func moreShops() async {
        guard let next = shopCursor else { return }
        await run {
            let page = try await self.service.historyOwnedShops(cursor: next)
            guard self.live else { return }
            guard !page.shops.contains(where: { item in self.shops.contains { $0.id == item.id } }),
                  page.nextCursor != next else { throw ClientError.invalidResponse }
            self.shops += page.shops; self.shopCursor = page.nextCursor
            try await self.readReferences()
        }
    }
    private func readReferences() async throws {
        let cache = try await store.read().familyDecisions ?? .init()
        guard live else { return }
        pending = cache.pending.first(where: access.matches)
        let visible = Set(shops.compactMap { UUID(uuidString: $0.id) })
        refs = cache.records.filter { access.matches($0) && visible.contains($0.shopID) }
    }
    func open(shopID: UUID, id: UUID) async {
        await run {
            self.record = nil
            let record = try await self.service.familyDecision(shopID: shopID, id: id)
            if self.live { self.record = record }
        }
    }
    func search(dish: String?, product: String?, occasion: String?, more: Bool = false) async {
        if more && (cursor == nil || filters != [dish,product,occasion]) { return }
        await run {
            if !more {
                self.results = []; self.record = nil; self.cursor = nil; self.searched = false
                self.filters = [dish,product,occasion]
            }
            let page = try await self.service.familyDecisions(dish: dish, product: product, occasion: occasion, cursor: more ? self.cursor : nil)
            guard self.live else { return }
            let previous = Set(self.results.map(\.id))
            guard !page.decisions.contains(where: { previous.contains($0.id) }) else { throw ClientError.invalidResponse }
            self.results += page.decisions; self.cursor = page.nextCursor; self.searched = true
        }
    }
    func closeRecord() { record = nil }
    func forgetSearch() { results = []; cursor = nil; searched = false }
    func save(shopID: UUID, recordID: UUID?, action: FamilyDecisionAction) async {
        guard canWrite, let epoch else { return }
        await run {
            let intent = try await self.service.prepareFamilyDecision(shopID: shopID, id: recordID, action: action)
            guard self.live, self.access.matches(intent) else { throw ClientError.cancelled }
            try await self.store.stageDecision(intent, expectedEpoch: epoch)
            guard self.live else { return }
            self.pending = intent
            try await self.deliver(intent, epoch: epoch)
        }
    }
    func retry() async {
        guard let pending, let epoch else { return }
        await run { try await self.deliver(pending, epoch: epoch) }
    }
    private func deliver(_ intent: FamilyDecisionIntent, epoch: UUID) async throws {
        guard live else { throw ClientError.cancelled }
        let saved = try await service.executeFamilyDecision(intent)
        guard live else { return }
        try await store.finishDecision(intent, confirmed: true, expectedEpoch: epoch)
        guard live else { return }
        record = saved; lastWrite = intent.id; forgetSearch()
        try await readReferences()
    }
    func discardRetry() async {
        guard let pending, let epoch else { return }
        await run {
            try await self.store.finishDecision(pending, confirmed: false, expectedEpoch: epoch)
            try await self.readReferences()
        }
    }
    private func run(_ operation: () async throws -> Void) async {
        guard !busy, live else { return }
        busy = true; notice = nil; defer { busy = false }
        do { try await operation() }
        catch {
            guard live else { return }
            switch error {
            case ClientError.service(403,"membership_inactive",_,_):
                results = []; cursor = nil; searched = false
                notice = HistoryCopy.text("History search and lasting preferences require an active adult planning seat. Saved decisions can still be opened.")
            case ClientError.accessEnded, ClientError.sessionNeeded, ClientError.service(404,_,_,_):
                record = nil; results = []; refs = []; cursor = nil; searched = false
                notice = HistoryCopy.text("This decision is unavailable in your current shop or account. Check access again.")
            case ClientError.service(409,_,_,_):
                record = nil; forgetSearch()
                notice = HistoryCopy.text("This decision changed. Discard the old retry and reopen the record before reviewing a new change.")
            case ClientError.cancelled: break
            default: notice = HistoryCopy.text("The change could not be confirmed. Keep the original retry or refresh the records.")
            }
        }
    }
}
