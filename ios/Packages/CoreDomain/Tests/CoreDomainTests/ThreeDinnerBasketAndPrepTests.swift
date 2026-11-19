import XCTest
@testable import CoreDomain

final class ThreeDinnerBasketAndPrepTests: XCTestCase {
    let zone = "America/New_York"
    let now = Date(timeIntervalSince1970: 1_750_000_000)
    func day(_ day: Int) throws -> MealDay { try MealDay(year: 2026, month: 3, day: day, timeZoneIdentifier: zone) }
    func access(_ shop: ShoppingLedger, paid: Bool = true, budget: Bool = true) -> DinnerAccessContext {
        DinnerAccessContext(scope: .local(workspaceID: shop.id), actorID: "A", shopID: shop.id, assignedShopperID: "A",
            canPlan: true, canReadBudget: budget, hasPaidTools: paid, roleRevision: 1,
            verifiedAt: now, validUntil: now.addingTimeInterval(3600))
    }
    func count(_ value: Int64) throws -> Quantity {
        Quantity(amount: try Rational(value), unit: .count, originalLiteral: String(value))
    }
    func testBoundedPlansCombineSharedPacksIncludeFixedBasketAndApplyLunchOnlyOnce() throws {
        var shop = ShoppingLedger(basis: ShopBasis(timeZoneIdentifier: zone))
        let existing = try shop.addManualLine(name: "Beans", quantity: count(1), at: now)
        var state = DinnerPlanningState()
        var recipes: [AcceptedDinner] = []
        for name in ["Soup", "Tacos", "Salad", "Toast"] {
            let template = MealTemplate(title: name, servings: try Rational(3), ingredients: [
                MealIngredient(name: "Beans", quantity: try count(1))
            ], leadTimeMinutes: name == "Toast" ? 40 : 15)
            let meal = AcceptedDinner(id: UUID(), template: template, acceptedAt: now)
            try state.accept(meal, access: access(shop), at: now); recipes.append(meal)
        }
        let days = try [day(13), day(14), day(15)]
        var food = ThreeDinnerBasket.Food(name: "Beans", existingLine: existing, existingQuantity: try shop.quantity(forLineID: existing),
            members: Set(recipes.map { .init($0.id, $0.template.ingredients[0].id) }),
            offer: .init(id: "p", label: "four cans", usableQuantity: try count(4), price: Money(minorUnits: 399)), source: "Market", observedAt: now)
        func search(_ minutes: [Int?], _ budget: Int64 = 400, _ paid: Bool = true, _ read: Bool = true,
                    pins: [Int: UUID] = [:], exclude: Set<UUID> = []) throws -> [ThreeDinnerBasket.Plan] {
            try ThreeDinnerBasket.search(recipes: recipes, days: days, minutes: minutes, lunch: .one,
                budget: Money(minorUnits: budget), foods: [food], shop: shop, state: state,
                access: access(shop, paid: paid, budget: read), now: now, pins: pins, exclude: exclude)
        }
        let options = try search([nil, nil, nil])
        XCTAssertEqual(options.count, 2)
        XCTAssertNotEqual(Set(options[0].meals.map(\.id)), Set(options[1].meals.map(\.id)))
        let replacement = try search([nil, nil, nil], pins: [0: options[0].meals[0].id, 2: options[0].meals[2].id], exclude: [options[0].meals[1].id])
        XCTAssertEqual(replacement.count, 1)
        XCTAssertThrowsError(try search([nil, nil, nil], 400, false))
        XCTAssertThrowsError(try search([nil, nil, nil], 400, true, false))
        XCTAssertTrue(try search([15, 15, 15], 398).isEmpty)
        let timed = try XCTUnwrap(search([15, 15, 15]).first)
        XCTAssertEqual(timed.lines.count, 1)
        XCTAssertEqual(timed.lines.first?.packs, 1)
        XCTAssertEqual(timed.missing, 0)
        XCTAssertEqual(timed.subtotal.minorUnits, 399)
        food.offer = .init(id: "p", label: "four cans", usableQuantity: try count(4), price: nil)
        let partial = try XCTUnwrap(search([15, 15, 15], 0).first)
        XCTAssertEqual(partial.missing, 1)
        XCTAssertEqual(partial.lines.first?.packs, 1)
        food.offer = .init(id: "p", label: "free", usableQuantity: try count(4), price: .zero)
        XCTAssertEqual(try search([15, 15, 15], 0).first?.missing, 0)
        let edits = try ThreeDinnerBasket.changes(for: timed, days: days, lunch: .one, lunchName: "Lunch")
        let preview = try DinnerPlanningEngine.preview(changes: edits, tool: .threeDinnerBasket, ledger: shop, state: state, access: access(shop), phase: .draft, at: now)
        XCTAssertThrowsError(try DinnerPlanningEngine.apply(preview.proposal, ledger: &shop, state: &state, access: access(shop, budget: false), phase: .draft, at: now))
        let actor = access(shop)
        _ = try DinnerPlanningEngine.apply(preview.proposal, ledger: &shop, state: &state, access: actor, phase: .draft, at: now)
        XCTAssertEqual(shop.mealOccurrences.map(\.scheduledDay), days)
        XCTAssertEqual(shop.lines.count, 1)
        XCTAssertEqual(try shop.quantity(forLineID: existing)?.amount, try Rational(4))
        XCTAssertEqual(shop.mealOccurrences.compactMap { $0.servingGroups.first(where: \.isProtected)?.servings }, [.one, .one, .one])
        XCTAssertThrowsError(try search([nil, nil, nil]))
    }

    func testApplyRefusesLinksToAlreadyPickedRowsAndKeepsNewDemandOpen() throws {
        var shop = ShoppingLedger(basis: ShopBasis(timeZoneIdentifier: zone))
        let picked = try shop.addManualLine(name: "Milk", quantity: count(1), at: now)
        try shop.setChecked(lineID: picked, checked: true, at: now)
        let actor = access(shop)
        var state = DinnerPlanningState(), changes: [DinnerLedgerChange] = []
        for i in 0..<3 {
            let recipe = MealTemplate(title: "Recipe \(i)", ingredients: [.init(name: "Milk", quantity: try count(1))])
            let saved = AcceptedDinner(id: UUID(), template: recipe, acceptedAt: now)
            try state.accept(saved, access: actor, at: now)
            changes.append(.choose(.init(acceptedDinnerID: saved.id, template: recipe, day: try day(13 + i))))
        }
        let preview = try DinnerPlanningEngine.preview(changes: changes, tool: .threeDinnerBasket,
            ledger: shop, state: state, access: actor, phase: .draft, at: now)
        guard case .choose(var first) = changes[0] else { return XCTFail("Missing choice") }
        first.reviewedGroceryLines = [0: picked]
        changes[0] = .choose(first)
        XCTAssertThrowsError(try DinnerPlanningEngine.preview(changes: changes, tool: .threeDinnerBasket,
            ledger: shop, state: state, access: actor, phase: .draft, at: now))
        var variant = shop
        try variant.setChecked(lineID: picked, checked: false, at: now)
        try variant.updateLine(lineID: picked, name: "Milk", notes: "Lactose-free only", aisle: "", at: now)
        XCTAssertThrowsError(try DinnerPlanningEngine.preview(changes: changes, tool: .threeDinnerBasket,
            ledger: variant, state: state, access: actor, phase: .draft, at: now))
        _ = try DinnerPlanningEngine.apply(preview.proposal, ledger: &shop, state: &state, access: actor, phase: .draft, at: now)
        XCTAssertEqual(shop.lines.filter(\.isChecked).map(\.id), [picked])
        XCTAssertEqual(try shop.quantity(forLineID: picked)?.amount, .one)
        XCTAssertEqual(shop.lines.filter { !$0.isChecked }.count, 3)
    }

    func testAwayNoteAndExplicitIngredientExclusions() throws {
        let shop = ShoppingLedger(basis: ShopBasis(timeZoneIdentifier: zone))
        var state = DinnerPlanningState()
        let days = try [day(13), day(14), day(15)]
        try state.recordWeekNote(.init(shopID: shop.id, day: days[0], kind: .away, text: "Out"), access: access(shop), at: now)
        XCTAssertThrowsError(try ThreeDinnerBasket.search(recipes: [], days: days, minutes: [nil, nil, nil], lunch: .zero,
            budget: nil, foods: [], shop: shop, state: state, access: access(shop), now: now)) { XCTAssertEqual($0 as? DinnerPlanningError, .reviewRequired("openNights")) }
        var blocked = MealTemplate(title: "Soup", ingredients: [.init(name: "Peanut", quantity: nil)])
        blocked.exclusions = ["Peanut"]
        XCTAssertThrowsError(try state.accept(.init(id: UUID(), template: blocked, acceptedAt: now), access: access(shop), at: now))
    }

    func testPrepCivilTimeMoveCompleteArchiveAndDisabledAlerts() throws {
        var shop = ShoppingLedger(basis: ShopBasis(timeZoneIdentifier: zone)), state = DinnerPlanningState()
        let original = try day(8)
        let id = try shop.chooseMeal(.init(title: "Beans"), on: original.date, at: now)
        let task = DinnerPrepTask(shopID: shop.id, occurrenceID: id, instruction: "Soak", daysBefore: 1, hour: 18, dinnerDay: original)
        let free = access(shop, paid: false, budget: false)
        try state.setPrep(task, replacing: nil, mealID: id, ledger: shop, expectedRevision: shop.revisionID, access: free, at: now)
        XCTAssertEqual(state.prepTasks, [task])
        let movedDay = try day(9)
        try shop.scheduleMeal(occurrenceID: id, day: movedDay, at: now)
        XCTAssertNil(task.alertDate(for: shop.mealOccurrences[0], now: now))
        let moved = task.moved(to: movedDay)
        XCTAssertEqual(try moved.dueDate().timeIntervalSince(task.dueDate()), 23 * 3600)
        try state.setPrep(moved, replacing: task, mealID: id, ledger: shop, expectedRevision: shop.revisionID, access: free, at: now)
        var complete = moved
        complete.completedAt = now
        try state.setPrep(complete, replacing: moved, mealID: id, ledger: shop, expectedRevision: shop.revisionID, access: free, at: now)
        try shop.scheduleMeal(occurrenceID: id, day: day(11), at: now)
        XCTAssertNil(complete.alertDate(for: shop.mealOccurrences[0], now: now))
        XCTAssertEqual(complete.moved(to: try day(11)), complete)
        XCTAssertThrowsError(try state.setPrep(nil, replacing: complete, mealID: id, ledger: shop, expectedRevision: shop.revisionID, access: free, at: now))
        let encoded = try JSONEncoder().encode(state)
        XCTAssertEqual(try JSONDecoder().decode(DinnerPlanningState.self, from: encoded).prepTasks, [complete])
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(DinnerPlanningState()), as: UTF8.self).contains("prepTasks"))
        let gap = DinnerPrepTask(shopID: shop.id, occurrenceID: id, instruction: "Soak", daysBefore: 1, hour: 2, dinnerDay: movedDay)
        XCTAssertThrowsError(try gap.dueDate())
        let fold = DinnerPrepTask(shopID: shop.id, occurrenceID: id, instruction: "Soak", daysBefore: 1, hour: 1,
                                  dinnerDay: try MealDay(year: 2026, month: 11, day: 2, timeZoneIdentifier: zone))
        XCTAssertThrowsError(try fold.dueDate())
    }
}
