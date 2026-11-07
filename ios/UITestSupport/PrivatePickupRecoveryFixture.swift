#if DEBUG && targetEnvironment(simulator)
import CoreDomain
import Foundation

/// Seeds only a freshly reset UI-test workspace. Relaunches use the normal saved state.
@MainActor final class PrivatePickupRecoveryFixture: ObservableObject {
    enum Phase { case idle, preparing, ready, failed }
    private enum SetupError: Error { case invalid }
    let requested = Set(["--ui-testing", "--reset-test-workspace", "--seed-private-recovery"])
        .isSubset(of: Set(ProcessInfo.processInfo.arguments))
    @Published private(set) var phase = Phase.idle

    func prepare(ledger: LedgerModel, pickup: PickupModel) async {
        guard requested, phase == .idle, ledger.ready, pickup.ready else { return }
        phase = .preparing
        do {
            guard ledger.workspace.shops.isEmpty, pickup.journeys.isEmpty else { throw SetupError.invalid }
            try await seed(ledger: ledger, pickup: pickup)
            phase = .ready
        } catch { phase = .failed }
    }

    private func seed(ledger: LedgerModel, pickup: PickupModel) async throws {
        let now = Date(), zone = "America/New_York"
        func quantity(_ count: Int64) throws -> Quantity {
            try Quantity(amount: Rational(count), unit: .count, originalLiteral: String(count))
        }
        var shop = ShoppingLedger(title: "Family pickup", basis: .init(branch: "Main", mode: .pickup, slot: now,
            timeZoneIdentifier: zone, cap: .init(minorUnits: 3800)))
        let line = try shop.addManualLine(name: "Wraps", quantity: quantity(12))
        guard let supply = shop.contributions(forLineID: line).first?.id else { throw SetupError.invalid }
        var calendar = Calendar(identifier: .gregorian)
        guard let timeZone = TimeZone(identifier: zone) else { throw SetupError.invalid }
        calendar.timeZone = timeZone
        guard let tuesday = calendar.nextDate(after: now, matching: DateComponents(hour: 12, weekday: 3), matchingPolicy: .nextTime),
              let wednesday = calendar.date(byAdding: .day, value: 1, to: tuesday) else { throw SetupError.invalid }
        for (title, count, day) in [("Tuesday tacos", Int64(6), tuesday), ("Wednesday quesadillas", 4, wednesday)] {
            let recipe = MealTemplate(title: title, servings: try Rational(count),
                ingredients: [.init(name: "Wraps", quantity: try quantity(count), exclusions: ["garlic"])],
                exclusions: ["garlic"])
            let occurrence = try shop.chooseMeal(recipe, on: day)
            guard let need = shop.mealOccurrences.first(where: { $0.id == occurrence })?.ingredientContributionIDs.first else {
                throw SetupError.invalid
            }
            try shop.linkContribution(contributionID: need, within: supply, quantity: quantity(count))
        }
        try shop.addProtectedNeed(name: "Wraps", quantity: quantity(2), purpose: "Lunch", within: supply)
        let saved = await ledger.change(key: "seed-private-recovery") { workspace in
            workspace.shops = [shop]
            workspace.selectedShopID = shop.id
        }
        guard saved else { throw SetupError.invalid }
        let checkout = try LedgerCheckoutAdapter.review(shop: shop, workspaceRevision: ledger.revision,
            previous: nil, workspaceID: ledger.sourceWorkspaceID)
        guard try await LedgerCheckoutAdapter.apply(checkout, ledger: ledger, pickup: pickup),
              await pickup.setQuote(.init(scope: .wholeCheckout, context: checkout.context,
                  pricing: .inclusiveTotal(.exact(.init(minorUnits: 600)))), cap: nil),
              await pickup.freeze(), await pickup.reportPlaced() else { throw SetupError.invalid }
        let key = ReceiptKey(sourceEventID: "wrap-delivery", orderLineID: line, branchID: "Main", segmentID: "one")
        let receipt = ReceiptFragment(key: key, itemName: "Wraps", received: try quantity(8), disposition: .partial, receivedAt: now)
        let observed = UsableObservation(id: UUID(), receipt: key, usable: try quantity(6), confirmedAt: now,
            confirmedMatchToOrderLine: true)
        let beans = UUID()
        guard await pickup.receive(receipt, usable: observed),
              await pickup.saveStockLot(.init(id: beans, foodID: beans, name: "Beans", usable: try quantity(4),
                  confirmedAt: now, source: .freezer), in: shop.id) else { throw SetupError.invalid }
    }
}
#endif
