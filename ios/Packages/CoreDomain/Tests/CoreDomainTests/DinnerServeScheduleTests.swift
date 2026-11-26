import XCTest
@testable import CoreDomain

final class DinnerServeScheduleTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let zone = "America/Mexico_City"

    private func schedule(shop: UUID = UUID(), meal: UUID = UUID()) throws -> DinnerServeSchedule {
        let day = try MealDay(date: now, timeZoneIdentifier: zone)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: zone))
        let seven = try XCTUnwrap(calendar.date(bySettingHour: 19, minute: 0, second: 0, of: now))
        return .init(shopID: shop, occurrenceID: meal, dinnerDay: day, serveAt: seven, availableMinutes: 30, dishes: [
            .init(name: "Vegetables", steps: [
                .init(instruction: "Preheat", minutes: 10, equipment: .oven),
                .init(instruction: "Roast", minutes: 25, equipment: .oven)
            ]),
            .init(name: "Bread", steps: [.init(instruction: "Bake", minutes: 20, equipment: .oven)]),
            .init(name: "Rice", steps: [.init(instruction: "Simmer", minutes: 30, equipment: .burner)])
        ])
    }

    func testBackwardSequenceSharesOvenAndOverlapsBurnerThenReschedules() throws {
        var plan = try schedule()
        let rows = try plan.sequence()
        XCTAssertEqual(rows.count, 4)
        let oven = rows.filter { $0.step.equipment == .oven }
        for (first, second) in zip(oven, oven.dropFirst()) { XCTAssertLessThanOrEqual(first.end, second.start) }
        XCTAssertEqual(oven.compactMap { $0.dish == "Vegetables" ? $0.step.instruction : nil }, ["Preheat", "Roast"])
        let rice = try XCTUnwrap(rows.first { $0.dish == "Rice" })
        XCTAssertEqual(rice.end, plan.serveAt)
        XCTAssertEqual(plan.serveAt.timeIntervalSince(rice.start), 30 * 60)
        XCTAssertEqual(rows.first?.start, plan.serveAt.addingTimeInterval(-55 * 60))
        XCTAssertLessThan(try XCTUnwrap(rows.first).start, plan.earliestStart)
        plan.serveAt.addTimeInterval(45 * 60)
        plan.availableMinutes = 60
        let revised = try plan.sequence()
        XCTAssertEqual(revised.map(\.id), rows.map(\.id))
        XCTAssertEqual(revised.map(\.start), rows.map { $0.start.addingTimeInterval(45 * 60) })
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(revised.first).start, plan.earliestStart)
        plan.dishes[0].steps[0].minutes = 0
        XCTAssertThrowsError(try plan.sequence())
    }

    func testMovingTheDinnerPausesPreviouslyScheduledStepsAndMovingServeTimeUpdatesThem() throws {
        var shop = ShoppingLedger(basis: ShopBasis(timeZoneIdentifier: zone))
        let id = try shop.chooseMeal(.init(title: "Cena"), on: now, at: now)
        var plan = try schedule(shop: shop.id, meal: id)
        let before = plan.serveAt.addingTimeInterval(-7200)
        let original = try XCTUnwrap(shop.mealOccurrences.first)
        let old = plan.pendingSteps(for: original, now: before)
        XCTAssertEqual(old.count, 4)
        plan.serveAt.addTimeInterval(3600)
        let moved = plan.pendingSteps(for: original, now: before)
        XCTAssertEqual(moved.map(\.start), old.map { $0.start.addingTimeInterval(3600) })
        XCTAssertTrue(plan.pendingSteps(for: original, now: plan.serveAt).isEmpty)
        let tomorrow = try MealDay(date: now.addingTimeInterval(86400), timeZoneIdentifier: zone)
        try shop.scheduleMeal(occurrenceID: id, day: tomorrow, at: now)
        XCTAssertTrue(plan.pendingSteps(for: try XCTUnwrap(shop.mealOccurrences.first), now: before).isEmpty)
    }

    func testSaveChecksLiveAccessAndPreservesLegacyManualPrepOnLapse() throws {
        var shop = ShoppingLedger(basis: ShopBasis(timeZoneIdentifier: zone))
        let meal = try shop.chooseMeal(.init(title: "Cena"), on: now, at: now)
        let plan = try schedule(shop: shop.id, meal: meal)
        let revision = shop.revisionID
        let workspace = UUID()
        func access(_ paid: Bool, actor: String = "cook") -> DinnerAccessContext {
            .init(scope: .local(workspaceID: workspace), actorID: actor, shopID: shop.id, assignedShopperID: "cook",
                  canPlan: true, canReadBudget: false, hasPaidTools: paid, roleRevision: 1, verifiedAt: now, validUntil: now.addingTimeInterval(60))
        }
        var state = DinnerPlanningState()
        func save(_ value: DinnerServeSchedule?, _ prior: DinnerServeSchedule?, _ context: DinnerAccessContext) throws {
            try state.setServeSchedule(value, replacing: prior, mealID: meal, ledger: shop, expectedRevision: revision, access: context, at: now)
        }
        XCTAssertThrowsError(try save(plan, nil, access(false)))
        XCTAssertThrowsError(try save(plan, nil, access(true, actor: "helper")))
        try save(plan, nil, access(true))
        let savedRevision = state.revisionID
        try save(plan, nil, access(true))
        XCTAssertEqual(savedRevision, state.revisionID)
        let manual = DinnerPrepTask(shopID: shop.id, occurrenceID: meal, instruction: "Soak beans", daysBefore: 1, hour: 7, dinnerDay: plan.dinnerDay)
        try state.setPrep(manual, replacing: nil, mealID: meal, ledger: shop, expectedRevision: revision, access: access(false), at: now)
        var edit = plan
        edit.serveAt.addTimeInterval(3600)
        XCTAssertThrowsError(try save(edit, nil, access(true)))
        XCTAssertThrowsError(try save(edit, plan, access(false)))
        try save(edit, plan, access(true))
        let bytes = try JSONEncoder().encode(state)
        XCTAssertEqual(try JSONDecoder().decode(DinnerPlanningState.self, from: bytes), state)
        struct OldPlanningReader: Decodable { let prepTasks: [DinnerPrepTask]? }
        XCTAssertThrowsError(try JSONDecoder().decode(OldPlanningReader.self, from: bytes))
        try save(nil, edit, access(false))
        XCTAssertEqual(state.prepTasks, [manual])
        XCTAssertEqual(try JSONDecoder().decode(OldPlanningReader.self, from: JSONEncoder().encode(state)).prepTasks, [manual])
    }
}
