import SwiftUI
import HouseholdClient

struct HouseholdShopSelector: View {
    @ObservedObject var household: HouseholdModel
    @Environment(\.dismiss) private var dismiss
    @State private var owned = false
    @State private var shops: [HouseholdShopChoice] = []
    @State private var cursor: UUID?
    @State private var busy = false
    @State private var failed = false
    @State private var loadID = UUID()
    var body: some View {
        Form {
            if !household.locked, let scope = household.projection, scope.grantId == nil {
                Picker(ht("Show shops"), selection: $owned) {
                    Text(ht("Active shops")).tag(false)
                    Text(ht("Shops assigned to me")).tag(true)
                }
                ForEach(shops) { shop in
                    Button {
                        Task { await household.selectShop(shop.id); dismiss() }
                    } label: {
                        VStack(alignment: .leading) {
                            if let date = serviceDate(shop.createdAt) { Text(date.formatted(date: .abbreviated, time: .shortened)) }
                            Text(shop.role == "shopper" ? ht("Assigned shopper") : ht("Contributor"))
                            Text(phaseName(shop.phase))
                            Text(verbatim: String(shop.id.uuidString.suffix(8))).font(.caption.monospaced())
                        }
                    }
                }
                if failed { Button(ht("Retry loading shops")) { Task { await load(more: false) } } }
                else if !busy && shops.isEmpty { Text(ht("No shops in this view.")) }
                if cursor != nil { Button(ht("Load more shops")) { Task { await load(more: true) } } }
                if busy { ProgressView() }
                Button(ht("Use household overview")) { Task { await household.selectShop(nil); dismiss() } }
            }
        }.navigationTitle(ht("Choose shared shop"))
        .disabled(busy || household.busy)
        .task(id: owned) { await load(more: false) }
        .onDisappear { loadID = UUID() }
    }
    private func phaseName(_ phase: String) -> String {
        switch phase { case "draft": return ht("Draft shared shop"); case "frozen": return ht("Frozen shared shop")
        case "placed": return ht("Order reported placed"); default: return ht("Closed shop") }
    }
    @MainActor private func load(more: Bool) async {
        guard let service = household.service, let scope = household.projection, scope.grantId == nil, !household.locked else { return }
        let id = UUID(); loadID = id
        if !more { shops = []; cursor = nil }
        busy = true; failed = false
        defer { if loadID == id { busy = false } }
        do {
            let page = try await service.selectableShops(closedAndOwned: owned, cursor: cursor)
            guard loadID == id, !Task.isCancelled, household.projection == scope, !household.locked else { return }
            let prior = Set(shops.map(\.id))
            shops.append(contentsOf: page.shops.filter { !prior.contains($0.id) }); cursor = page.nextCursor
        } catch { if loadID == id { shops = []; cursor = nil; failed = true } }
    }
}

struct SharedShopAssignmentView: View {
    @ObservedObject var household: HouseholdModel
    @ObservedObject var model: HouseholdShopModel
    @Environment(\.dismiss) private var dismiss
    @State private var assignment: ShopperAssignment?
    @State private var failed = false
    private var shopID: UUID? {
        guard !household.locked, model.authorized, model.scope.grantId == nil, model.scope.capabilities.contains("household_admin"),
              model.scope == household.projection else { return nil }
        return model.scope.shopId.flatMap(UUID.init(uuidString:))
    }
    var body: some View {
        Form {
            if let assignment, shopID == assignment.shopId {
                if let current = assignment.adults.first(where: { $0.id == assignment.shopperId }) {
                    LabeledContent(ht("Current shopper"), value: current.label)
                }
                if assignment.phase != "closed" {
                    Section(ht("Choose the next shopper")) {
                        ForEach(assignment.adults.filter { $0.id != assignment.shopperId }) { adult in
                            Button(adult.label) { model.reviewTransfer(assignment, to: adult.id); if model.review?.transfer != nil { dismiss() } }
                        }
                        if assignment.adults.count < 2 { Text(ht("Invite another adult to the household before transferring this shop.")) }
                    }
                }
            }
            if failed { Text(ht("The shopper assignment could not be loaded.")) }
            Button(ht("Refresh shopper assignment")) { Task { await load() } }
        }.task(id: shopID) { await load() }.navigationTitle(ht("Change assigned shopper"))
    }
    @MainActor private func load() async {
        assignment = nil; failed = false
        guard let shopID, let service = household.service else { return }
        do {
            let value = try await service.shopperAssignment(shopID: shopID)
            guard self.shopID == shopID, !Task.isCancelled else { return }
            assignment = value
        } catch { if self.shopID == shopID { failed = true } }
    }
}
