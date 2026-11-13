import XCTest
import CoreDomain
@testable import RoomInTheCart

final class LedgerReadableRecordTests: XCTestCase {
    private struct Document: Encodable {
        let formatVersion = 1
        let workspace: LedgerWorkspace
    }

    @MainActor func testShopSeparatesOutstandingItemsFromHandledHistoryAndRetainsImportDecisions() throws {
        let date = Date(timeIntervalSince1970: 1_793_664_000)
        let basis = ShopBasis(branch: "Maple Street", slot: date, timeZoneIdentifier: "America/New_York")
        var shop = ShoppingLedger(title: "After school", basis: basis)
        let salsa = try shop.addManualLine(name: "Salsa verde", quantity: nil, at: date)
        try shop.handle(lineID: salsa, by: "Alex", at: date)
        try shop.setChecked(lineID: salsa, checked: true, at: date)
        let preview = try shop.stageImport(text: "2 cups lentils\nsalt to taste", source: .paste)
        try shop.commitImport(preview, decisions: [preview.lines[1].id: .skip], at: date)
        let fraction = Quantity(amount: try Rational(1, 3), unit: .cup, originalLiteral: "one third of a cup")
        _ = try shop.addProtectedNeed(name: "Arroz", quantity: fraction, purpose: "Tuesday lunch", at: date)
        let workspace = LedgerWorkspace(shops: [shop], mealTemplates: [MealTemplate(title: "Library only")], selectedShopID: shop.id)
        let scoped = try RecordsNativeCodec.ledgerScope(workspace, shop: shop)
        let text = try LedgerReadableRecord.text(RecordsNativeCodec.canonical(Document(workspace: scoped)))
        let sections = text.components(separatedBy: "\n" + ledgerText("List history") + "\n")
        XCTAssertEqual(sections.count, 2)
        let active = try XCTUnwrap(sections.first), history = try XCTUnwrap(sections.last)
        XCTAssertTrue(active.contains("Arroz"))
        XCTAssertTrue(active.contains("Tuesday lunch"))
        XCTAssertTrue(active.contains("one third of a cup"))
        XCTAssertTrue(active.contains(pQuantity(fraction)))
        XCTAssertTrue(active.contains(ledgerDate(date, zone: "America/New_York")))
        XCTAssertFalse(active.contains("Salsa verde"))
        XCTAssertTrue(history.contains("Salsa verde"))
        XCTAssertTrue(history.contains(ledgerText("Quantity unresolved")))
        XCTAssertTrue(history.contains(ledgerText("Checked at")))
        XCTAssertTrue(history.contains(ledgerFormat("Handled by %@", "Alex")))
        XCTAssertTrue(history.contains("2 cups lentils · " + ledgerText("Added as a separate line")))
        XCTAssertTrue(history.contains("salt to taste · " + ledgerText("Skipped")))
        XCTAssertFalse(text.contains("Library only"))
        XCTAssertFalse(text.contains("contributionIDs"))
    }

    @MainActor func testSavedProposalAndAppliedReservationHaveDifferentOutcomes() throws {
        let date = Date(timeIntervalSince1970: 1_793_664_000)
        var shop = ShoppingLedger(title: "Family night")
        var plan = DinnerPlanningState()
        let scope = DinnerAccessContext.Scope.local(workspaceID: UUID())
        func access(_ person: String) -> DinnerAccessContext {
            DinnerAccessContext(scope: scope, actorID: person, shopID: shop.id, assignedShopperID: "Kim",
                canPlan: true, canReadBudget: true, hasPaidTools: true, roleRevision: 0, verifiedAt: date,
                validUntil: date.addingTimeInterval(600))
        }
        let planner = access("Ren"), shopper = access("Kim")
        let day = try MealDay(year: 2026, month: 11, day: 6, timeZoneIdentifier: "America/New_York")
        func proposal(_ need: String) throws -> DinnerProposal {
            let reservation = DinnerReservation(name: need, quantity: Quantity(amount: .one, unit: .count, originalLiteral: "1"),
                                               purpose: "Lunch", day: day)
            return try DinnerPlanningEngine.preview(changes: [.reserve(reservation)], tool: .manual,
                ledger: shop, state: plan, access: planner, phase: .draft, at: date).proposal
        }
        let applied = try proposal("Lunch pear")
        try plan.saveProposal(applied, access: planner, at: date)
        try DinnerPlanningEngine.apply(applied, ledger: &shop, state: &plan, access: shopper, phase: .draft, at: date.addingTimeInterval(60))
        let pending = try proposal("Lunch apple")
        try plan.saveProposal(pending, access: planner, at: date)
        let workspace = LedgerWorkspace(shops: [shop], dinnerPlanning: plan)
        let text = try LedgerReadableRecord.text(RecordsNativeCodec.canonical(Document(workspace: RecordsNativeCodec.ledgerScope(workspace, shop: shop))))
        let sections = text.components(separatedBy: ledgerText("Proposed by"))
        XCTAssertEqual(sections.count, 3)
        let active = try XCTUnwrap(sections.first)
        XCTAssertTrue(active.contains("Lunch pear"))
        XCTAssertTrue(active.contains(ledgerMealDay(day)))
        XCTAssertFalse(active.contains("Lunch apple"))
        let proposalText = try XCTUnwrap(sections.dropFirst().first { $0.contains("Lunch apple") })
        XCTAssertTrue(proposalText.contains("Ren"))
        XCTAssertFalse(proposalText.contains(ledgerText("Applied by")))
        let receiptText = try XCTUnwrap(sections.last)
        XCTAssertTrue(receiptText.contains("Lunch pear"))
        XCTAssertTrue(receiptText.contains(ledgerText("Applied by") + " · Kim"))
    }

    @MainActor func testSavedQuotePairRetainsEnteredTermsAndUnknownTripCash() throws {
        let date = Date(timeIntervalSince1970: 1_793_664_000)
        let shop = ShoppingLedger(title: "Compare two stores", basis: ShopBasis(cap: Money(minorUnits: 3800)))
        let access = DinnerAccessContext(scope: .local(workspaceID: UUID()), actorID: "local", shopID: shop.id,
            assignedShopperID: "local", canPlan: true, canReadBudget: true, hasPaidTools: false,
            roleRevision: 0, verifiedAt: date, validUntil: date.addingTimeInterval(60))
        var draft = DinnerQuoteEditDraft()
        draft.commitments[0].name = "Friday lunches"; draft.commitments[0].portions = "3"
        draft.commitments[0].kind = .lunch; draft.commitments[0].isProtected = true
        var first = DinnerStoreDraft()
        first.label = "Market East"; first.storeID = "Market"; first.branch = "East"
        first.observedAt = date; first.writtenSlot = "Friday at noon"; first.source = "Paper quote"
        first.total = "38"; first.allChargesIncluded = true; first.quantitiesMatched = true
        first.availability = 1; first.singleStore = true; first.tripCash = "0"; first.extraMinutes = "0"; first.alreadyPlanned = true
        draft.first = first
        var second = first
        second.id = UUID(); second.label = "Market West"; second.branch = "West"; second.total = "35"
        second.eligibilityTerms = "Loyalty card"; second.tripCash = ""; second.extraMinutes = "18"; second.alreadyPlanned = false
        draft.second = second
        var plan = DinnerPlanningState()
        try plan.saveQuotePair(draft.pair(for: shop), access: access, at: date)
        let workspace = LedgerWorkspace(shops: [shop], dinnerPlanning: plan)
        let text = try LedgerReadableRecord.text(RecordsNativeCodec.canonical(Document(workspace: RecordsNativeCodec.ledgerScope(workspace, shop: shop))))
        for fact in ["Market East", "Market West", "Paper quote", "Friday at noon", "Friday lunches", ledgerText("Protected"),
                     pTr("Whole checkout"), "Loyalty card", dinnerText("Reviewed available"), dinnerFormat("Extra minutes: %d", 18),
                     dinnerFormat("Checkout change, second minus first: %@", dinnerMoney(Money(minorUnits: -300))),
                     dinnerFormat("Checkout plus trip cash, second minus first: %@", dinnerMoney(nil)),
                     dinnerFormat("Second trip cash break-even: %@", dinnerMoney(Money(minorUnits: 300)))] {
            XCTAssertTrue(text.contains(fact), fact)
        }
        XCTAssertFalse(text.contains(ledgerText("Applied by")))
    }

    @MainActor func testLibraryKeepsTemplateAcceptedVersionRotationAndDraftDistinctFromShop() throws {
        let date = Date(timeIntervalSince1970: 1_793_664_000)
        let shop = ShoppingLedger(title: "Only in shop")
        let access = DinnerAccessContext(scope: .local(workspaceID: UUID()), actorID: "local", shopID: shop.id,
            assignedShopperID: "local", canPlan: true, canReadBudget: true, hasPaidTools: true,
            roleRevision: 0, verifiedAt: date, validUntil: date.addingTimeInterval(60))
        let beans = MealTemplate(title: "Frijoles de casa", servings: try Rational(4),
            ingredients: [MealIngredient(name: "Frijoles", quantity: Quantity(amount: .one, unit: .cup, originalLiteral: "1.00")),
                          MealIngredient(name: "Caldo al gusto", quantity: nil)],
            notes: "Set one serving aside.", sourceURL: "https://example.invalid/beans", exclusions: ["sesame"],
            servingGroups: [ServingGroup(name: "Lunch", servings: .one, isProtected: true)], leadTimeMinutes: 15,
            completedSteps: ["Soaked overnight"])
        var plan = DinnerPlanningState()
        let dinner = AcceptedDinner(id: UUID(), template: beans, acceptedAt: date, acceptedFallback: true)
        try plan.accept(dinner, access: access, at: date)
        let rotation = DinnerRotation(title: "School nights", entries: [.init(acceptedDinnerID: dinner.id, dayOffset: 2, pinned: true)])
        try plan.saveRotation(rotation, access: access, at: date)
        let ingredient = MealIngredient(name: "Calabaza", quantity: nil)
        var idea = DinnerIdeaDraft(id: UUID(), requestID: UUID(), catalogVersion: "manual",
            template: MealTemplate(title: "Try squash", ingredients: [ingredient]), assumptions: ["Check squash"], createdAt: date)
        guard case let .local(workspaceID) = access.scope else { return XCTFail("Expected a local idea") }
        let pack = PackOffer(id: "small", label: "Bolsa pequeña", usableQuantity: nil, price: Money(minorUnits: 349))
        idea.supplyEvidence = [DinnerIdeaFoodEvidence(ingredient: ingredient, workspaceID: workspaceID, shopID: shop.id,
            basisRevision: shop.basisRevision, foodID: UUID(), pack: pack, source: "Farm stand label", observedAt: date)]
        try plan.saveIdea(idea, access: access, at: date)
        let workspace = LedgerWorkspace(shops: [shop], mealTemplates: [MealTemplate(title: "Old favorite")], dinnerPlanning: plan)
        let library = try XCTUnwrap(RecordsNativeCodec.ledgerLibrary(workspace))
        let text = try LedgerReadableRecord.text(RecordsNativeCodec.canonical(Document(workspace: library)))
        for fact in ["Old favorite", "Frijoles de casa", "1.00", "Caldo al gusto", ledgerText("Quantity unresolved"),
                     "https://example.invalid/beans", "Set one serving aside.", "sesame", "Lunch", ledgerText("Protected"),
                     "15", "Soaked overnight", dinnerText("Accepted fallback"), "School nights", dinnerFormat("Day %d", 3),
                     dinnerText("Pinned"), "Try squash", "Check squash", dinnerText("Availability is unconfirmed"),
                     "Calabaza", "Bolsa pequeña", "Farm stand label", dinnerMoney(Money(minorUnits: 349)),
                     dinnerFormat("Usable in one pack: %@", ledgerText("Quantity unresolved")),
                     ledgerText("Food match saved. Available quantity in this record is unknown.")] {
            XCTAssertTrue(text.contains(fact), fact)
        }
        XCTAssertFalse(text.contains("Only in shop"))
        XCTAssertFalse(text.contains("acceptedDinnerID"))
        XCTAssertThrowsError(try LedgerReadableRecord.text(Data("{}".utf8)))
    }
}
