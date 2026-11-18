#if DEBUG && DINNER_DECISION_UI_FIXTURE
import SwiftUI
import CoreDomain

/// The dedicated offline test build seeds reviewed evidence and a named adult seat.
@MainActor enum DinnerDecisionUIFixture {
    static func workspace(id: UUID) throws -> LedgerWorkspace {
        let now = Date(), shopID = UUID()
        var shop = ShoppingLedger(id: shopID, title: "Mercado", basis: .init(branch: "Main"))
        var state = DinnerPlanningState()
        let auth = DinnerDecisionUIFixture.access(shopID, workspace: id, now: now)
        let boundary = ProcessInfo.processInfo.arguments.contains("--ui-testing-guest-boundary")
        let family = ServingGroup(name: "Cena", servings: try Rational(boundary ? 3 : 2))
        let lunch = ServingGroup(name: "Almuerzo", servings: .one, isProtected: true)
        func quantity(_ n: Int64) throws -> Quantity { try Quantity(amount: Rational(n), unit: .count, originalLiteral: String(n)) }
        let rice = MealTemplate(title: "Arroz", servings: try Rational(boundary ? 4 : 3), ingredients: [.init(name: "Peppers",quantity: try quantity(boundary ? 8 : 6))], servingGroups: [family,lunch])
        let tacos = MealTemplate(title: "Tacos", servings: family.servings, ingredients: [.init(name: "Peppers",quantity: try quantity(4))])
        for template in [rice,tacos] { try state.accept(.init(id: UUID(), template: template, acceptedAt: now),access: auth,at: now) }
        let meal = try shop.chooseMeal(rice,at: now)
        let contributionID = shop.mealOccurrences[0].ingredientContributionIDs[0]
        try state.setPortionBindings([
            .init(occurrenceID: meal, contributionID: contributionID, groupID: family.id, quantity: try quantity(boundary ? 3 : 1), servings: family.servings),
            .init(occurrenceID: meal, contributionID: contributionID, groupID: lunch.id, quantity: try quantity(5), servings: lunch.servings)
        ],for: meal,ledger: shop,access: auth,at: now)
        var workspace = LedgerWorkspace(shops: [shop],selectedShopID: shop.id,dinnerPlanning: state)
        if boundary {
            let lineID = shop.lines[0].id
            let need = try LedgerPackRequirement.review(shop: shop, lineID: lineID, bindings: state.portionBindings)
            let offer = PackOffer(id: "eight", label: "8", usableQuantity: try quantity(8), price: Money(minorUnits: 240))
            let other = PackOffer(id: "single", label: "1", usableQuantity: try quantity(1), price: Money(minorUnits: 90))
            let selection = try LedgerPackSelection(workspaceID: id, shop: shop, lineID: lineID,
                request: .init(itemName: need.name, needed: need.quantity, protectedAmount: need.protectedQuantity, offerA: offer, offerB: other),
                selectedOfferID: offer.id, at: now, source: "Local fixture", bindings: state.portionBindings)
            try workspace.recordPackSelection(selection, workspaceID: id)
        }
        return workspace
    }

    private static let start = Date().addingTimeInterval(-1)
    static func access(_ shopID: UUID, workspace: UUID, now: Date) -> DinnerAccessContext {
        let until = start.addingTimeInterval(3600)
        let seat = MembershipSnapshot(householdID: "family", purchaserID: "owner", revision: 1, status: .active,
            expiresAt: until, graceExpiresAt: nil, verifiedAt: start, validUntil: until,
            seats: [.init(userID: "shopper", displayName: "Sam", isAdult: true)])
        return DinnerAccessContext(scope: .local(workspaceID: workspace),actorID: "shopper",shopID: shopID,assignedShopperID: "shopper",
            canPlan: true,canReadBudget: true,hasPaidTools: seat.hasPaidAccess(for: "shopper",now: now),roleRevision: 1,verifiedAt: start,validUntil: until)
    }
    static func prepareCheckout(_ model: DinnerFeatureModel, pickup: PickupModel) async {
        guard let shop = model.shop, let selection = model.workspace.packSelections.first, let quantity = selection.purchasedQuantity else { return }
        let cost = CostEvidence.exact(Money(minorUnits: 240))
        let context = CheckoutContext(storeID: "Main", branchID: "Main", mode: .pickup, slot: "Friday", commitmentsID: shop.id, observedAt: Date(), source: "Local fixture")
        let line = BasketLine(id: selection.lineID, name: selection.request.itemName, quantity: quantity, expectedCost: cost)
        guard await pickup.start(from: [line], shopID: shop.id, context: context, ledgerBasis: shop.basis,
                                 ledgerSourceRevisionID: shop.revisionID, ledgerPackSelections: [selection]) else { return }
        let zero = CostEvidence.exact(Money(minorUnits: 0))
        let fee = CheckoutFee(id: "fee", rule: .waivedAt(threshold: Money(minorUnits: 400), belowThreshold: .exact(Money(minorUnits: 150)), basis: .eligibleItemsBeforeDiscounts))
        _ = await pickup.setQuote(CheckoutQuote(scope: .wholeCheckout, context: context, pricing: .components(
            lines: [.init(id: line.id, name: line.name, cost: cost)], lineSetComplete: true, fees: [fee], discounts: [], tax: zero, deposits: zero)), cap: nil)
    }
    static func seed(_ draft: inout DinnerScenarioDraft, shop: ShoppingLedger, state: DinnerPlanningState) throws -> DinnerLibraryPairings? {
        guard let target = draft.meals.first(where: { !$0.protected })?.id else { return nil }
        var library = try DinnerLibraryPairings.prepare(&draft,target: target,shop: shop,state: state)
        var food = DinnerFoodEvidenceDraft(name: "Peppers")
        food.packLabel = "Three"; food.packAmount = "3"; food.packPrice = "3"; food.availability = 1; food.yieldReviewed = true
        draft.foods = [food]
        for index in draft.matches.indices { draft.matches[index].foodID = food.id }
        for index in library.candidates.indices { library.candidates[index].hands = "10"; library.candidates[index].lead = "15" }
        for index in draft.baseline.indices { draft.baseline[index].cost = "2" }
        if ProcessInfo.processInfo.arguments.contains("--ui-testing-dinner-cost") {
            draft.essentials = [DinnerBaselineCostDraft(id: UUID(), name: "Laundry soap", cost: "4.50", feeEligible: false)]
        }
        draft.fee = "1"; draft.feeThreshold = "7"; draft.tax = "0"; draft.deposits = "0"; draft.availableMinutes = "30"
        draft.currentHands = "10"; draft.currentLead = "10"; draft.store = "Market"; draft.source = "Reviewed"
        draft.recipeYieldsReviewed = true; draft.baselineComplete = true; draft.baselineExcludesComparedRecipes = true
        return library
    }
}

@main struct DinnerDecisionUIFixtureApp: App {
    @StateObject private var ledger: LedgerModel
    @StateObject private var pickup: PickupModel
    @StateObject private var household: HouseholdModel
    @StateObject private var access: WorkspaceAccess
    @State private var model: DinnerFeatureModel?
    @State private var setupError: String?

    init() {
        let name = "DinnerDecision-" + UUID().uuidString
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        _ledger = StateObject(wrappedValue: LedgerModel(databaseURL: directory.appendingPathComponent("ledger.sqlite")))
        _pickup = StateObject(wrappedValue: PickupModel(databaseURL: directory.appendingPathComponent("pickup.sqlite")))
        _household = StateObject(wrappedValue: HouseholdModel(outboxURL: directory.appendingPathComponent("outbox.json")))
        _access = StateObject(wrappedValue: WorkspaceAccess(defaults: UserDefaults(suiteName: name)!))
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if let model {
                    NavigationStack { DinnerWorkspaceView(model: model, startPickup: {}) { EmptyView() } }
                        .environmentObject(ledger)
                        .environmentObject(pickup)
                        .environmentObject(household)
                        .environmentObject(access)
                } else if let setupError {
                    Text(verbatim: setupError)
                } else { ProgressView() }
            }.task { await prepare() }
        }
    }

    private func prepare() async {
        guard ProcessInfo.processInfo.arguments.contains("--ui-testing"), model == nil, setupError == nil else { return }
        await ledger.open()
        await pickup.load()
        guard ledger.ready, pickup.ready, let id = ledger.sourceWorkspaceID,
              await ledger.change(key: "dinner-decision-fixture", { $0 = try DinnerDecisionUIFixture.workspace(id: id) }) else {
            setupError = ledger.error ?? pickup.error ?? "Dinner fixture setup failed"
            return
        }
        pickup.bindCookLedger(ledger)
        let dinner = DinnerFeatureModel(store: ledger, access: { DinnerDecisionUIFixture.access($0, workspace: id, now: Date()) },
                                        phase: { _ in .draft })
        await DinnerDecisionUIFixture.prepareCheckout(dinner, pickup: pickup)
        model = dinner
    }
}
#endif
