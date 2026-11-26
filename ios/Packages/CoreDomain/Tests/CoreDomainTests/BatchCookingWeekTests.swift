import XCTest
@testable import CoreDomain

final class BatchCookingWeekTests: XCTestCase {
    func testWeekReservesLunchesDatesShortfallAndAppliesGroceriesExactlyOnce() throws {
        let now = Date()
        var ledger = ShoppingLedger()
        let start = try MealDay(year: 2026, month: 11, day: 29, timeZoneIdentifier: ledger.basis.timeZoneIdentifier)
        let owner = UUID()
        func access(_ paid: Bool) -> DinnerAccessContext {
            .init(scope: .local(workspaceID: owner), actorID: "A", shopID: ledger.id, assignedShopperID: "A",
                  canPlan: true, canReadBudget: false, hasPaidTools: paid, roleRevision: 1, verifiedAt: now,
                  validUntil: now.addingTimeInterval(60))
        }
        let granted = access(true), free = access(false)
        let recipe = AcceptedDinner(id: UUID(), template: MealTemplate(title: "Beans", servings: try Rational(2),
            ingredients: [.init(name: "beans", quantity: Quantity(amount: try Rational(200), unit: .gram, originalLiteral: "200 g"))]), acceptedAt: now)
        var state = DinnerPlanningState()
        try state.accept(recipe, access: granted, at: now)
        let sessions: [BatchCookingWeek.Session] = [.init(offset: 0, acceptedID: recipe.id), .init(offset: 3, acceptedID: recipe.id)]
        let rows: [BatchCookingWeek.Day] = (0..<7).map { .init(diners: 3, lunches: $0 == 2 ? 2 : 0) }
        let week = try BatchCookingWeek(start: start, days: rows, sessions: sessions, lunchLabel: "Lunch")
        XCTAssertEqual(week.target(for: 0), 11)
        XCTAssertEqual(week.target(for: 1), 12)
        let gaps = try week.shortfalls(actual: [9, nil])
        XCTAssertEqual(gaps.map(\.lunches), Array(repeating: 0, count: 7))
        XCTAssertEqual(gaps.map(\.diners), [0,0,2,0,0,0,0])
        XCTAssertEqual(try week.shortfalls(actual: [1, nil])[2].lunches, 1)
        let cooked = BatchCookingWeek.MeasuredYield(made: try Rational(9), holds: [
            .lunch(try Rational(3)), .dinner(try Rational(3), offset: 2)
        ])
        let reconciled = try week.reconcile(yields: [cooked, nil], otherDinnerCoverage: Array(repeating: 0, count: 7))
        XCTAssertEqual(reconciled.gaps.map(\.diners), [0, 3, 0, 0, 0, 0, 0])
        XCTAssertEqual(reconciled.gaps.map(\.lunches), Array(repeating: 0, count: 7))
        XCTAssertThrowsError(try week.reconcile(yields: [.init(made: .one, holds: [.lunch(try Rational(2))]), nil],
                                                otherDinnerCoverage: Array(repeating: 0, count: 7)))
        XCTAssertThrowsError(try week.preview(ledger: ledger, state: state, access: free, phase: .draft, at: now))
        let preview = try week.preview(ledger: ledger, state: state, access: granted, phase: .draft, at: now)
        XCTAssertTrue(ledger.mealOccurrences.isEmpty)
        XCTAssertThrowsError(try DinnerPlanningEngine.apply(preview.proposal, ledger: &ledger, state: &state, access: free, phase: .draft, at: now))
        _ = try DinnerPlanningEngine.apply(preview.proposal, ledger: &ledger, state: &state, access: granted, phase: .draft, at: now)
        _ = try DinnerPlanningEngine.apply(preview.proposal, ledger: &ledger, state: &state, access: granted, phase: .draft, at: now)
        XCTAssertEqual(ledger.mealOccurrences.count, 2)
        XCTAssertEqual(ledger.mealOccurrences[0].servingGroups.first?.servings, try Rational(2))
        XCTAssertEqual(ledger.contributions.compactMap { $0.quantity?.amount }, try [Rational(1100), Rational(1200)])
        XCTAssertEqual(state.applyReceipts.count, 1)
        XCTAssertEqual(try JSONDecoder().decode(DinnerPlanningState.self, from: JSONEncoder().encode(state)).applyReceipts.first?.proposal.batchWeek, week)
        XCTAssertThrowsError(try week.preview(ledger: ledger, state: state, access: granted, phase: .draft, at: now))
    }

    func testConfirmedDinnerCreditIsAppliedOnceAndCannotCoverAnEarlierDayOrLunch() throws {
        let start = try MealDay(year: 2026, month: 3, day: 8, timeZoneIdentifier: "America/New_York")
        let rows: [BatchCookingWeek.Day] = (0..<7).map { .init(diners: 3, lunches: $0 == 1 ? 1 : 0, covered: $0 == 1 ? 2 : 0) }
        let week = try BatchCookingWeek(start: start, days: rows,
            sessions: [.init(offset: 1, acceptedID: UUID()), .init(offset: 4, acceptedID: UUID())], lunchLabel: "Lunch")
        XCTAssertEqual(week.target(for: 0), 8)
        XCTAssertEqual(try week.shortfalls(actual: [nil,nil]).map(\.diners), [3,0,0,0,0,0,0])
        XCTAssertEqual(try week.date(6).iso8601, "2026-03-14")
        XCTAssertEqual(try week.shortfalls(actual: [nil,nil], currentCovered: Array(repeating: 0, count: 7))[3].diners, 2)
        XCTAssertThrowsError(try BatchCookingWeek(start: start, days: [], sessions: [], lunchLabel: "Lunch"))
    }
}
