import XCTest
import CoreDomain

final class DinnerWeekRolloverTests: XCTestCase {
    func testReopeningAfterMidnightKeepsTheOriginalDinnerAndLunch() throws {
        try verifyReopening(
            from: MealDay(year: 2026, month: 11, day: 4, timeZoneIdentifier: "GMT"),
            to: MealDay(year: 2026, month: 11, day: 5, timeZoneIdentifier: "GMT")
        )
    }

    func testReopeningInJanuaryKeepsTheDecemberDinnerAndLunch() throws {
        try verifyReopening(
            from: MealDay(year: 2026, month: 12, day: 31, timeZoneIdentifier: "GMT"),
            to: MealDay(year: 2027, month: 1, day: 1, timeZoneIdentifier: "GMT")
        )
    }

    func testReopeningAfterNewYorkFallBackKeepsTheOriginalDinnerAndLunch() throws {
        try verifyReopening(
            from: MealDay(year: 2026, month: 10, day: 31, timeZoneIdentifier: "America/New_York"),
            to: MealDay(year: 2026, month: 11, day: 1, timeZoneIdentifier: "America/New_York"),
            reopenHour: 3, expectedOffsetChange: -3_600
        )
    }

    private func verifyReopening(from originalDay: MealDay, to defaultDay: MealDay,
                                 reopenHour: Int = 0, expectedOffsetChange: Int = 0) throws {
        let zone = try XCTUnwrap(TimeZone(identifier: originalDay.timeZoneIdentifier))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let savedAt = try XCTUnwrap(calendar.date(bySettingHour: 23, minute: 59, second: 0,
                                                 of: XCTUnwrap(originalDay.date)))
        let reopenedAt = try XCTUnwrap(calendar.date(bySettingHour: reopenHour, minute: 1, second: 0,
                                                     of: XCTUnwrap(defaultDay.date)))
        XCTAssertEqual(try MealDay(date: savedAt, timeZoneIdentifier: zone.identifier), originalDay)
        XCTAssertEqual(try MealDay(date: reopenedAt, timeZoneIdentifier: zone.identifier), defaultDay)
        XCTAssertEqual(zone.secondsFromGMT(for: reopenedAt) - zone.secondsFromGMT(for: savedAt), expectedOffsetChange)

        var pickup = ShoppingLedger(title: "Fictional family pickup")
        var basis = pickup.basis
        basis.timeZoneIdentifier = zone.identifier
        try pickup.updateBasis(basis, at: savedAt)
        let shopID = pickup.id
        let workspaceID = UUID()
        func access(at date: Date) -> DinnerAccessContext {
            DinnerAccessContext(scope: .local(workspaceID: workspaceID), actorID: "Mia", shopID: shopID,
                assignedShopperID: "Mia", canPlan: true, canReadBudget: true, hasPaidTools: false,
                roleRevision: 1, verifiedAt: date, validUntil: date.addingTimeInterval(300), sharedCommitAuthorized: false)
        }
        let dinner = PlannedDinner(template: MealTemplate(title: "Roasted veggie tacos", servings: try Rational(4),
            ingredients: [MealIngredient(name: "Corn tortillas", quantity: Quantity(amount: try Rational(8),
                unit: .count, originalLiteral: "8"))]), day: originalDay)
        let quantity = Quantity(amount: try Rational(2), unit: .count, originalLiteral: "2")
        let lunch = DinnerReservation(name: "Flour tortillas", quantity: quantity, purpose: "School lunch", day: originalDay)
        var planning = DinnerPlanningState()
        let preview = try DinnerPlanningEngine.preview(changes: [.choose(dinner), .reserve(lunch)], tool: .manual,
            ledger: pickup, state: planning, access: access(at: savedAt), phase: .draft, at: savedAt)
        try DinnerPlanningEngine.apply(preview.proposal, ledger: &pickup, state: &planning,
            access: access(at: savedAt), phase: .draft, at: savedAt)
        let saved = LedgerWorkspace(shops: [pickup], selectedShopID: shopID, dinnerPlanning: planning)
        let reopened = try JSONDecoder().decode(LedgerWorkspace.self, from: JSONEncoder().encode(saved))
        try reopened.validate()
        let restoredPickup = try XCTUnwrap(reopened.shops.first { $0.id == shopID })

        let defaultWeek = try DinnerPlanningEngine.week(start: defaultDay, ledger: restoredPickup,
            state: reopened.dinnerPlanning, access: access(at: reopenedAt), at: reopenedAt)
        XCTAssertEqual(defaultWeek.days.first?.day, defaultDay)
        XCTAssertTrue(defaultWeek.days.flatMap(\.meals).isEmpty)
        XCTAssertTrue(defaultWeek.days.flatMap(\.protectedContributionIDs).isEmpty)
        XCTAssertTrue(defaultWeek.unscheduled.isEmpty)

        let originalWeek = try DinnerPlanningEngine.week(start: originalDay, ledger: restoredPickup,
            state: reopened.dinnerPlanning, access: access(at: reopenedAt), at: reopenedAt)
        XCTAssertEqual(originalWeek.days.first?.day, originalDay)
        XCTAssertEqual(originalWeek.days.first?.meals.map(\.id), [dinner.occurrenceID])
        XCTAssertEqual(originalWeek.days.first?.protectedContributionIDs, [lunch.contributionID])
        let savedLunch = try XCTUnwrap(restoredPickup.contributions.first { $0.id == lunch.contributionID })
        XCTAssertEqual(savedLunch.productName, "Flour tortillas")
        XCTAssertEqual(savedLunch.quantity, quantity)
        XCTAssertEqual(savedLunch.source, .protectedNeed(purpose: "School lunch"))
    }
}
