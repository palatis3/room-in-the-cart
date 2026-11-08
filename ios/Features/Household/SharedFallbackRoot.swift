import HouseholdClient
import SwiftUI

struct SharedFallbackRoot: View {
    @ObservedObject var shop: HouseholdShopModel
    @ObservedObject var household: HouseholdModel
    let page: SharedRecoveryPage
    @Environment(\.scenePhase) private var scene
    @State private var model: SharedFallbackModel?
    let completed: (Bool) -> Void

    private var access: FamilyDecisionAccess? {
        guard scene == .active, showsReviewedRecovery(page, model: shop, household: household),
              shop.scope.capabilities.contains("accepted_fallbacks"), shop.scope.role == "shopper",
              shop.scope.grantId == nil, let value = household.decisionAccess, value.shopID == page.shopId else { return nil }
        return value
    }

    var body: some View {
        Group {
            if let model, let access, model.live {
                SharedFallbackMenu(model: model, shop: shop, household: household, page: page,
                                   completed: completed)
                    .id(access)
            } else if access != nil { ProgressView() }
            else { Text(sharedRecoveryText("Refresh the current meal record.")) }
        }
        .navigationTitle(fallbackText("Household fallback recipes"))
        .task(id: access) { [shop, household] in
            model?.invalidate()
            model = nil
            guard let selected = access, let service = household.service else { return }
            let record = page
            let next = SharedFallbackModel(shopID: record.shopId, service: service, store: household.fallbackPendingStore) { [weak shop, weak household] in
                guard let shop, let household, household.decisionAccess == selected,
                      shop.scope.capabilities.contains("accepted_fallbacks"), shop.scope.role == "shopper", shop.scope.grantId == nil else { return false }
                return showsReviewedRecovery(record, model: shop, household: household)
            }
            model = next
            await next.load()
        }
        .onChange(of: access) { _, value in if value == nil { model?.invalidate(); model = nil } }
    }
}

private struct SharedFallbackMenu: View {
    @ObservedObject var model: SharedFallbackModel
    @ObservedObject var shop: HouseholdShopModel
    @ObservedObject var household: HouseholdModel
    let page: SharedRecoveryPage
    let completed: (Bool) -> Void

    var body: some View {
        List {
            if let library = model.library, model.live {
                NavigationLink(fallbackText("Manage accepted recipes")) {
                    SharedFallbackLibraryView(model: model, recovery: page)
                }.accessibilityIdentifier("fallback.library")
                if model.canSuggest, !library.candidates.isEmpty, model.pending == nil {
                    Section(fallbackText("Meal to repair")) {
                        ForEach(page.meals.filter { $0.needs.contains { $0.priority == "required" } }) { target in
                            NavigationLink {
                                if model.live, model.canSuggest, model.library == library {
                                    SharedFallbackOptionsView(model: model, shop: shop, household: household, page: page,
                                                              library: library, target: target, completed: completed)
                                }
                            } label: {
                                VStack(alignment: .leading) {
                                    Text(verbatim: target.title)
                                    Text(verbatim: sharedMealDayText(target.day, locale: .current) ?? target.day).font(.subheadline)
                                }
                            }.accessibilityIdentifier("fallback.target." + target.id.uuidString)
                        }
                    }
                }
            }
            if model.busy { ProgressView() }
            if let notice = model.notice { Text(verbatim: notice) }
            Button(ht("Refresh")) { Task { await model.load() } }.disabled(!model.live || model.busy)
        }

    }
}
