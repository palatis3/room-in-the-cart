import XCTest
import CoreDomain
import LocalStore
@testable import RoomInTheCart

@MainActor final class DinnerRepeatEvidenceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let workspaceID = UUID()
    private func q(_ n: Int64) -> Quantity { .init(amount: try! Rational(n), unit: .count, originalLiteral: String(n)) }
    private func day(_ n: Int) throws -> MealDay { try .init(year: 2026, month: 11, day: n, timeZoneIdentifier: "UTC") }
    private func access(_ shop: ShoppingLedger) -> DinnerAccessContext {
        .init(scope: .local(workspaceID: workspaceID), actorID: "me", shopID: shop.id, assignedShopperID: "me",
              canPlan: true, canReadBudget: true, hasPaidTools: true, roleRevision: 0,
              verifiedAt: now, validUntil: now.addingTimeInterval(60))
    }
    private func fixture() throws -> LedgerWorkspace {
        var prior = ShoppingLedger(title: "Prior week", basis: .init(branch: "Reviewed store", timeZoneIdentifier: "UTC"))
        let meal = MealTemplate(title: "Wraps", ingredients: [.init(name: "Wraps", quantity: q(2))])
        let id = try prior.chooseMeal(meal, at: now)
        try prior.scheduleMeal(occurrenceID: id, day: day(10), at: now)
        let target = ShoppingLedger(title: "This week", basis: .init(branch: "Reviewed store", timeZoneIdentifier: "UTC"))
        return LedgerWorkspace(shops: [prior, target], selectedShopID: target.id)
    }
    private func candidates(_ workspace: LedgerWorkspace, recovered: [UUID: RepeatWeek.Recovery] = [:]) throws -> [RepeatWeek.Candidate] {
        try RepeatWeekEngine.candidates(targetStart: day(17), workspace: workspace, recoveredMeals: recovered,
                                       access: access(XCTUnwrap(workspace.shops.last)), at: now)
    }
    private func evidence(_ workspace: LedgerWorkspace, canonical: DinnerPantrySupply.Snapshot? = nil,
                          staples: [ReviewedStaple] = [], recovered: [UUID: RepeatWeek.Recovery] = [:],
                          authorized: Set<UUID>? = nil, unknownFoodIDs: Set<UUID> = []) throws -> DinnerRepeatEvidence {
        try .build(candidates: candidates(workspace, recovered: recovered), workspace: workspace, workspaceID: workspaceID,
            authorizedShopIDs: authorized ?? Set(workspace.shops.map(\.id)), targetShopID: XCTUnwrap(workspace.selectedShopID),
            sourceDays: [day(10)], targetDays: [day(17)], staples: staples, recoveredMeals: recovered,
            canonical: canonical, unknownFoodIDs: unknownFoodIDs, asOf: now)
    }

    func testRealCanonicalFreeStockPreservesOtherShopLunchAndExcludesUnrelatedFood() async throws {
        var workspace = try fixture(), source = try XCTUnwrap(workspace.shops.first)
        let originalIngredient = try XCTUnwrap(source.mealOccurrences.first?.ingredientContributionIDs.first)
        let food = try source.addManualLine(name: "Wraps", quantity: q(12), at: now), foreign = UUID()
        let supplyID = try XCTUnwrap(source.contributions(forLineID: food).first?.id)
        try source.linkContribution(contributionID: originalIngredient, within: supplyID, quantity: q(2), at: now)
        let secondMeal = try source.chooseMeal(.init(title: "More wraps", ingredients: [.init(name: "Wraps", quantity: q(4))]), at: now)
        try source.scheduleMeal(occurrenceID: secondMeal, day: day(10), at: now)
        let secondIngredient = try XCTUnwrap(source.mealOccurrences.last?.ingredientContributionIDs.first)
        try source.linkContribution(contributionID: secondIngredient, within: supplyID, quantity: q(4), at: now)
        workspace.shops[0] = source
        var journey = PickupJourney(id: source.id, savedAt: now)
        journey.stockLots = [.init(id: food, foodID: food, name: "Wraps", usable: q(8), confirmedAt: now, source: .pantry),
                             .init(id: foreign, foodID: foreign, name: "Unrelated private food", usable: q(99), confirmedAt: now, source: .pantry)]
        var other = PickupJourney(id: UUID(), savedAt: now)
        other.originShopID = source.id; other.stockLots = journey.stockLots
        other.stockNeeds = [.init(id: UUID(), foodID: food, name: "Other shop school lunch", amount: q(3), priority: .protected)]
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let cleanup = SQLiteFixtureDirectory(directory, test: self)
        let store = try ComparisonStore(url: directory.appendingPathComponent("pickup.sqlite"), inventoryEnabled: true)
        cleanup.track(store)
        for head in [journey, other] {
            try PickupModel.validate(head)
            _ = try await store.save(id: head.id, title: "Repeat evidence", payload: JSONEncoder().encode(head), savedAt: now)
        }
        let mapping = try PantryLegacyMigration.map(originID: store.workspaceID,
            heads: try await store.list().map(PantryLegacyMigration.SourceHead.init), ledger: .unavailable, at: now)
        let package = try PantryMigrationPackage.build(mapping, migrationID: UUID(), sourceToken: await store.inventorySourceToken(),
            inventoryRevision: await store.inventoryState().revision, at: now)
        _ = try await store.beginInventoryMigration(package.plan)
        for chunk in package.chunks { _ = try await store.stageInventoryMigration(id: package.plan.migrationID, chunk: chunk) }
        _ = try await store.finishInventoryMigration(id: package.plan.migrationID, at: now)
        let repository = PantryRepository(store: store, authorize: { true }); cleanup.track(repository)
        let initial = try await repository.load(at: now)
        let supply = try DinnerPantrySupply.build(context: .init(snapshot: initial, mapping: mapping, asOf: now), shopID: source.id)
        let rows = try evidence(workspace, canonical: supply).stock
        XCTAssertEqual(rows.map(\.id), [food]); XCTAssertEqual(rows.first?.free, [q(5)])
        XCTAssertEqual(rows.first?.reserved.map(\.name), ["Other shop school lunch"])
        XCTAssertEqual(rows.first?.reserved.first?.protected, true)
        XCTAssertEqual(rows.first?.unresolved, false)
        let mealRows = try candidates(workspace)
        let selected = mealRows.map(RepeatWeek.Selection.init)
        let needs = try evidence(workspace, canonical: supply).shoppingNeeds(for: selected, candidates: mealRows)
        XCTAssertEqual(needs.count, 1)
        XCTAssertEqual(needs.first?.needed, [q(6)])
        XCTAssertEqual(needs.first?.toObtain, [q(1)], "Both meals share the same five free wraps, after the protected lunch hold.")
        XCTAssertEqual(needs.first?.unresolved, false)
        var edited = selected
        let firstIndex = try XCTUnwrap(mealRows.firstIndex { $0.source.occurrenceID != secondMeal })
        let covered = try evidence(workspace, canonical: supply).shoppingNeeds(for: [selected[firstIndex]], candidates: mealRows)
        XCTAssertEqual(covered.first?.needed, [q(2)])
        XCTAssertEqual(covered.first?.toObtain, [q(0)])
        XCTAssertEqual(covered.first?.unresolved, false, "Five free wraps cover the selected two-wrap meal without negative arithmetic.")
        edited[firstIndex].servings = try Rational(2)
        let adjusted = try evidence(workspace, canonical: supply).shoppingNeeds(for: edited, candidates: mealRows)
        XCTAssertEqual(adjusted.first?.needed, [q(8)]); XCTAssertEqual(adjusted.first?.toObtain, [q(3)])
        edited[firstIndex].ingredientEdits = [.init(contributionID: originalIngredient, quantity: nil)]
        let partial = try evidence(workspace, canonical: supply).shoppingNeeds(for: edited, candidates: mealRows)
        XCTAssertEqual(partial.first?.unresolved, true); XCTAssertEqual(partial.first?.toObtain, [])
        edited[firstIndex].ingredientEdits = [.init(contributionID: originalIngredient,
            quantity: Quantity(amount: .one, unit: .gram, originalLiteral: "1 g"))]
        let incompatible = try evidence(workspace, canonical: supply).shoppingNeeds(for: edited, candidates: mealRows)
        XCTAssertEqual(incompatible.first?.unresolved, true); XCTAssertEqual(incompatible.first?.toObtain, [])
        let unrelatedWorkspace = try fixture() // Same label, independently created line identity.
        let unmatched = try XCTUnwrap(evidence(unrelatedWorkspace, canonical: supply).stock.first)
        XCTAssertTrue(unmatched.free.isEmpty); XCTAssertTrue(unmatched.unresolved)
        let partlyUnknown = try XCTUnwrap(evidence(workspace, canonical: supply, unknownFoodIDs: [food]).stock.first)
        XCTAssertEqual(partlyUnknown.free, [q(5)])
        XCTAssertTrue(partlyUnknown.unresolved, "An independent confirmed lot does not hide a sibling's unknown count.")
        let lot = try XCTUnwrap(initial.lots.first { $0.foodID == food })
        let updated = try await repository.apply(.init(id: UUID(), originID: store.workspaceID, lotID: lot.id, eventID: UUID(),
            expectedRevision: lot.revision, occurredAt: now, change: .count(.unknown, observationID: UUID())),
            reviewedInventoryRevision: initial.state.revision, at: now)
        let unknown = try DinnerPantrySupply.build(context: .init(snapshot: updated.current, mapping: mapping, asOf: now), shopID: source.id)
        let changed = try XCTUnwrap(evidence(workspace, canonical: unknown).stock.first)
        XCTAssertTrue(changed.free.isEmpty); XCTAssertTrue(changed.unresolved)
        XCTAssertEqual(changed.reserved.map(\.id), rows.first?.reserved.map(\.id))
        XCTAssertEqual(journey.stockLots.first?.usable, q(8), "Source history cannot reactivate the copied count.")
    }

    func testUnavailablePantryIsUnknownAndNotesAndLunchesStayInAuthorizedCivilWeeks() throws {
        var workspace = try fixture()
        var prior = workspace.shops[0], target = workspace.shops[1], unrelated = ShoppingLedger(title: "Not this source")
        let dated = DinnerReservation(name: "Protected lunch", quantity: q(1), purpose: "School", day: try day(17))
        let preview = try DinnerPlanningEngine.preview(changes: [.reserve(dated)], tool: .manual, ledger: target,
            state: workspace.dinnerPlanning, access: access(target), phase: .draft, at: now)
        _ = try DinnerPlanningEngine.apply(preview.proposal, ledger: &target, state: &workspace.dinnerPlanning,
                                           access: access(target), phase: .draft, at: now)
        _ = try prior.addProtectedNeed(name: "Undated source lunch", quantity: q(1), purpose: "School", at: now)
        _ = try unrelated.addManualLine(name: "Unrelated", quantity: q(1), at: now)
        let old = DinnerWeekNote(shopID: prior.id, day: try day(10), kind: .away, text: "Prior away")
        let current = DinnerWeekNote(shopID: target.id, day: try day(17), kind: .guests, text: "Target guests")
        for (note, shop) in [(old, prior), (current, target),
            (DinnerWeekNote(shopID: target.id, day: try day(24), kind: .away, text: "Later week"), target),
            (DinnerWeekNote(shopID: unrelated.id, day: try day(17), kind: .guests, text: "Other shop guests"), unrelated)] {
            try workspace.dinnerPlanning.recordWeekNote(note, access: access(shop), at: now)
        }
        workspace.shops = [prior, unrelated, target]
        let result = try evidence(workspace, authorized: [prior.id, target.id])
        XCTAssertEqual(result.notes, [current]); XCTAssertEqual(result.priorNotes, [old])
        XCTAssertEqual(result.protectedLunches.count, 2)
        XCTAssertTrue(result.protectedLunches.contains { $0.day == nil && $0.isPriorWeek })
        XCTAssertTrue(result.protectedLunches.contains { $0.day == (try? day(17)) && !$0.isPriorWeek })
        XCTAssertTrue(try XCTUnwrap(result.stock.first).unresolved)
        XCTAssertThrowsError(try evidence(workspace, authorized: [target.id]))
    }

    func testHandledCoffeeUsesExactTargetReceiptAndNeverNameBasedStockCredit() throws {
        var workspace = try fixture()
        let coffee = try workspace.shops[0].addManualLine(name: "Coffee", quantity: q(1), at: now)
        try workspace.shops[0].approveStaple(lineID: coffee, purpose: "Breakfast", at: now)
        try workspace.shops[0].handle(lineID: coffee, by: "Last week shopper", at: now)
        let currentCoffee = try workspace.shops[1].addManualLine(name: "Coffee", quantity: q(1), at: now)
        let review = try XCTUnwrap(workspace.priorStaples(for: workspace.shops[1].id).first)
        let before = try evidence(workspace, staples: [review])
        XCTAssertEqual(before.stapleChecks.first?.status, .reviewNeeded)
        XCTAssertEqual(before.stapleChecks.first?.priorHandledBy, "Last week shopper")
        XCTAssertTrue(before.stock.contains { $0.id == coffee })
        try workspace.applyStaple(review, choice: .alreadyHandled, quantity: nil,
            handledLine: .init(lineID: currentCoffee, boughtBy: "Independent shopper"), at: now)
        let result = try evidence(workspace, staples: [review])
        XCTAssertEqual(result.stapleChecks.first?.status, .alreadyHandled)
        XCTAssertEqual(result.stapleChecks.first?.handledBy, "Independent shopper")
        XCTAssertFalse(result.stock.contains { $0.id == coffee || $0.id == currentCoffee })
        XCTAssertTrue(result.priceChecks.allSatisfy { !$0.contains("Coffee") })
        try workspace.shops[1].reopen(lineID: currentCoffee, at: now)
        XCTAssertEqual(try evidence(workspace, staples: [review]).stapleChecks.first?.status, .stale)
    }

    func testPackPriceEvidenceRejectsForeignAndStaleBindingsAndNeverReusesTotal() throws {
        var workspace = try fixture()
        let shop = workspace.shops[0], line = try XCTUnwrap(shop.lines.first?.id)
        let requirement = try LedgerPackRequirement.review(shop: shop, lineID: line)
        let request = ComparisonRequest(itemName: requirement.name, needed: requirement.quantity, protectedAmount: requirement.protectedQuantity,
            offerA: .init(id: "a", label: "Wraps", usableQuantity: q(4), price: .init(minorUnits: 125)),
            offerB: .init(id: "b", label: "Wraps", usableQuantity: q(8), price: .init(minorUnits: 200)))
        workspace.packSelections = [try .init(workspaceID: UUID(), shop: shop, lineID: line, request: request, selectedOfferID: "a", at: now, source: "Foreign shelf")]
        XCTAssertFalse(try evidence(workspace).priceChecks.joined().contains("Foreign shelf"))
        workspace.packSelections = [try .init(workspaceID: workspaceID, shop: shop, lineID: line, request: request, selectedOfferID: "a", at: now, source: "Reviewed shelf")]
        XCTAssertTrue(try evidence(workspace).priceChecks.joined().contains("Reviewed shelf"))
        var basis = shop.basis; basis.branch = "Different store"
        try workspace.shops[0].updateBasis(basis, at: now)
        let stale = try evidence(workspace).priceChecks.joined()
        XCTAssertFalse(stale.contains("Reviewed shelf")); XCTAssertTrue(stale.contains("stale"))
    }

    func testRecoveredNeedMapsExactFoodInsteadOfOriginalContributionOrMatchingName() throws {
        let workspace = try fixture(), shop = try XCTUnwrap(workspace.shops.first), meal = try XCTUnwrap(shop.mealOccurrences.first)
        let foodID = UUID(), needID = UUID()
        let ingredient = RecoveryIngredient(ingredientID: UUID(), groupID: nil, foodName: "Replacement rice",
            need: .init(id: needID, foodID: foodID, name: "Dinner", amount: q(3), priority: .required))
        let replacement = RecoveryMeal(id: meal.id, revisionID: UUID(), templateID: nil, templateVersion: nil,
            title: "Replacement dinner", servings: .one, ingredients: [ingredient], scheduledDay: try day(10), due: nil,
            timeZoneID: "UTC", exclusions: [], remainingElapsedMinutes: nil, requiredLeadMinutes: nil, advanceStepsCompleted: false)
        let template = MealTemplate(title: replacement.title, ingredients: [.init(id: needID, name: ingredient.foodName, quantity: q(3))])
        let recovered = [meal.id: RepeatWeek.Recovery(meal: replacement, template: template)]
        let result = try evidence(workspace, recovered: recovered)
        XCTAssertEqual(result.stock.map(\.id), [foodID]); XCTAssertEqual(result.stock.first?.name, "Replacement rice")
        XCTAssertTrue(result.priceChecks.first?.contains("confirmed food identity") == true)
        let rows = try candidates(workspace, recovered: recovered)
        XCTAssertThrowsError(try DinnerRepeatEvidence.build(candidates: rows, workspace: workspace, workspaceID: workspaceID,
            authorizedShopIDs: Set(workspace.shops.map(\.id)), targetShopID: XCTUnwrap(workspace.selectedShopID),
            sourceDays: [day(10)], targetDays: [day(17)], canonical: nil, asOf: now))
    }
}
