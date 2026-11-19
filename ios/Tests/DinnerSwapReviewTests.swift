import XCTest
import CoreDomain
import LocalStore
@testable import RoomInTheCart

@MainActor final class DinnerSwapReviewTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func q(_ n: Int64) -> Quantity { .init(amount: try! Rational(n), unit: .count, originalLiteral: String(n)) }
    private func access(_ shopID: UUID, origin: UUID, budget: Bool = true) -> DinnerAccessContext {
        .init(scope: .local(workspaceID: origin), actorID: "me", shopID: shopID, assignedShopperID: "me",
            canPlan: true, canReadBudget: budget, hasPaidTools: true, roleRevision: 0,
            verifiedAt: now, validUntil: now.addingTimeInterval(60))
    }
    private struct Source {
        let workspace: LedgerWorkspace
        let origin: UUID
        let original: MealOccurrence
        let accepted: AcceptedDinner
        let planned: PlannedDinner
        let food: UUID
    }
    private func source() throws -> Source {
        let origin = UUID()
        var shop = ShoppingLedger(title: "Dinner shop", basis: .init(branch: "Reviewed branch"))
        let old = MealTemplate(title: "Tacos", ingredients: [.init(name: "Wraps", quantity: q(2))])
        let meal = try shop.chooseMeal(old, at: now)
        let original = try XCTUnwrap(shop.mealOccurrences.first { $0.id == meal })
        let food = try XCTUnwrap(shop.contributions.first?.lineID)
        let next = MealTemplate(title: "Two wrap dishes", ingredients: [.init(name: "Dinner wraps", quantity: q(4)), .init(name: "Extra wraps", quantity: q(4))])
        let accepted = AcceptedDinner(id: UUID(), template: next, acceptedAt: now, acceptedFallback: false)
        var state = DinnerPlanningState()
        try state.accept(accepted, access: access(shop.id, origin: origin), at: now)
        let requirement = try LedgerPackRequirement.review(shop: shop, lineID: food)
        let request = ComparisonRequest(itemName: requirement.name, needed: requirement.quantity, protectedAmount: requirement.protectedQuantity,
            offerA: .init(id: "a", label: "Two wraps", usableQuantity: q(2), price: .init(minorUnits: 125)),
            offerB: .init(id: "b", label: "Four wraps", usableQuantity: q(4), price: .init(minorUnits: 300)))
        let pack = try LedgerPackSelection(workspaceID: origin, shop: shop, lineID: food, request: request, selectedOfferID: "a", at: now, source: "Reviewed shelf")
        let workspace = LedgerWorkspace(shops: [shop], selectedShopID: shop.id, dinnerPlanning: state, packSelections: [pack])
        return Source(workspace: workspace, origin: origin, original: original, accepted: accepted,
                      planned: .init(acceptedDinnerID: accepted.id, template: next, day: original.scheduledDay), food: food)
    }
    func testBasketKeepsCheckedGroceriesSeparateFromNewMealDemand() throws {
        let basis = try source()
        var shop = try XCTUnwrap(basis.workspace.shops.first)
        try shop.setChecked(lineID: basis.food, checked: true, at: now)
        let recipe = AcceptedDinner(id: UUID(), template: MealTemplate(title: "Another dinner",
            ingredients: [.init(name: "Wraps", quantity: q(2))]), acceptedAt: now)
        let rows = try DinnerBasketGroceryDraft.prepare(recipes: [recipe], shop: shop, history: [], workspace: basis.origin)
        XCTAssertEqual(rows.count, 2)
        XCTAssertTrue(try XCTUnwrap(rows.first { $0.existingLine == basis.food }).members.isEmpty)
        XCTAssertEqual(try XCTUnwrap(rows.first { $0.existingLine == nil }).members.first?.0.recipe, recipe.id)
    }
    func testBasketPresentsCurrentShoppingNotesAndDoesNotGroupDifferentVariants() throws {
        let basis = try source()
        var shop = try XCTUnwrap(basis.workspace.shops.first)
        try shop.updateLine(lineID: basis.food, name: "Wraps", notes: "Gluten-free only", aisle: "", at: now)
        let recipe = AcceptedDinner(id: UUID(), template: MealTemplate(title: "Wrap dinner",
            ingredients: [.init(name: "Wraps", quantity: q(1))]), acceptedAt: now)
        let rows = try DinnerBasketGroceryDraft.prepare(recipes: [recipe], shop: shop, history: [], workspace: basis.origin)
        let fixed = try XCTUnwrap(rows.first { $0.existingLine == basis.food })
        XCTAssertEqual(fixed.label.notes, "Gluten-free only")
        XCTAssertTrue(fixed.members.isEmpty)
        XCTAssertEqual(rows.count, 2)
    }
    func testBasketDoesNotPriceRenamedOrEditedLineFromEarlierPackSelection() throws {
        let basis = try source(), history = basis.workspace.packSelections
        let original = try XCTUnwrap(basis.workspace.shops.first)
        func grocery(in shop: ShoppingLedger) throws -> DinnerBasketGroceryDraft {
            try XCTUnwrap(DinnerBasketGroceryDraft.prepare(recipes: [], shop: shop, history: history,
                                                           workspace: basis.origin).first { $0.existingLine == basis.food })
        }
        XCTAssertEqual(try grocery(in: original).price, "1.25")
        for (name, notes) in [("Saffron", ""), ("Wraps", "Gluten-free variant")] {
            var changed = original
            try changed.updateLine(lineID: basis.food, name: name, notes: notes, aisle: "", at: now)
            let row = try grocery(in: changed)
            XCTAssertTrue(row.price.isEmpty)
            XCTAssertNil(try row.resolved().first?.offer)
        }
    }
    private func preview(_ source: Source, budget: Bool = true) throws -> DinnerPreview {
        let shop = try XCTUnwrap(source.workspace.shops.first)
        return try DinnerSwapEngine.preview(occurrenceID: source.original.id, replacement: source.planned,
            ledger: shop, state: source.workspace.dinnerPlanning, access: access(shop.id, origin: source.origin, budget: budget), phase: .draft, at: now)
    }
    private struct Pantry {
        let cleanup: SQLiteFixtureDirectory
        let store: ComparisonStore
        let repository: PantryRepository
        let mapping: PantryLegacyMigration.Plan
    }
    private func pantry(food: UUID, shopID: UUID) async throws -> Pantry {
        var first = PickupJourney(id: shopID, savedAt: now)
        let unrelated = UUID()
        first.stockLots = [.init(id: food, foodID: food, name: "Wraps", usable: q(8), confirmedAt: now, source: .pantry),
                           .init(id: unrelated, foodID: unrelated, name: "Unrelated food", usable: q(99), confirmedAt: now, source: .pantry)]
        var second = PickupJourney(id: UUID(), savedAt: now)
        second.originShopID = first.id; second.stockLots = first.stockLots
        second.stockNeeds = [.init(id: UUID(), foodID: food, name: "Thursday protected lunch", amount: q(3), priority: .protected)]
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let cleanup = SQLiteFixtureDirectory(directory, test: self)
        let store = try ComparisonStore(url: directory.appendingPathComponent("pickup.sqlite"), inventoryEnabled: true)
        cleanup.track(store)
        for head in [first, second] {
            try PickupModel.validate(head)
            _ = try await store.save(id: head.id, title: "Swap evidence", payload: JSONEncoder().encode(head), savedAt: now)
        }
        let mapping = try PantryLegacyMigration.map(originID: store.workspaceID,
            heads: try await store.list().map(PantryLegacyMigration.SourceHead.init), ledger: .unavailable, at: now)
        let package = try PantryMigrationPackage.build(mapping, migrationID: UUID(), sourceToken: await store.inventorySourceToken(),
            inventoryRevision: await store.inventoryState().revision, at: now)
        _ = try await store.beginInventoryMigration(package.plan)
        for chunk in package.chunks { _ = try await store.stageInventoryMigration(id: package.plan.migrationID, chunk: chunk) }
        _ = try await store.finishInventoryMigration(id: package.plan.migrationID, at: now)
        let repository = PantryRepository(store: store, authorize: { true }); cleanup.track(repository)
        return .init(cleanup: cleanup, store: store, repository: repository, mapping: mapping)
    }

    func testScopedPreviewUsesGlobalFreeWrapsOnceAndRetainsProtectedLunchAndPhysicalCounts() async throws {
        let source = try source(), fixture = try await pantry(food: source.food, shopID: source.workspace.shops[0].id)
        let snapshot = try await fixture.repository.load(at: now)
        let context = PantryPackStockReview.Context(snapshot: snapshot, mapping: fixture.mapping, asOf: now)
        let supply = try DinnerPantrySupply.build(context: context, shopID: source.workspace.shops[0].id)
        let mapping = Dictionary(uniqueKeysWithValues: source.planned.template.ingredients.map { ($0.id, source.food) })
        let result = try DinnerSwapEvidence.build(preview: preview(source), original: source.original, replacement: source.planned,
            reviewedFoods: mapping, workspace: source.workspace, workspaceID: source.origin, supply: supply, canonical: context, at: now)
        let food = try XCTUnwrap(result.foods.first)
        XCTAssertEqual(result.foods.count, 1); XCTAssertEqual(food.beforeNeeded, q(2)); XCTAssertEqual(food.afterNeeded, q(8))
        XCTAssertEqual(food.free, [q(5)]); XCTAssertEqual(food.beforePacks, 0); XCTAssertEqual(food.afterPacks, 2)
        XCTAssertEqual(food.afterCost, Money(minorUnits: 250)); XCTAssertEqual(food.packagePrice, Money(minorUnits: 125))
        XCTAssertEqual(food.priceSource, "Reviewed shelf"); XCTAssertEqual(food.holds.first?.name, "Thursday protected lunch")
        XCTAssertEqual(result.retained.count, 1); XCTAssertEqual(result.retained.first?.count, .exact(q(8)))
        let unchanged = try await fixture.repository.load(at: now)
        XCTAssertEqual(unchanged.lots, snapshot.lots); XCTAssertEqual(unchanged.reservations, snapshot.reservations)
        XCTAssertEqual(source.workspace.shops[0].mealOccurrences.first, source.original)
        let redacted = try DinnerSwapEvidence.build(preview: preview(source, budget: false), original: source.original, replacement: source.planned,
            reviewedFoods: mapping, workspace: source.workspace, workspaceID: source.origin, supply: supply, canonical: context, at: now)
        XCTAssertNil(redacted.foods.first?.beforeCost); XCTAssertNil(redacted.foods.first?.afterCost); XCTAssertNil(redacted.foods.first?.packagePrice)
    }

    func testUnknownOrUnmatchedPantryDoesNotBecomeAZeroPurchaseAndForeignPriceIsExcluded() async throws {
        let source = try source(), fixture = try await pantry(food: source.food, shopID: source.workspace.shops[0].id)
        let before = try await fixture.repository.load(at: now), lot = try XCTUnwrap(before.lots.first { $0.foodID == source.food })
        let changed = try await fixture.repository.apply(.init(id: UUID(), originID: fixture.store.workspaceID, lotID: lot.id, eventID: UUID(),
            expectedRevision: lot.revision, occurredAt: now, change: .count(.unknown, observationID: UUID())),
            reviewedInventoryRevision: before.state.revision, at: now)
        let context = PantryPackStockReview.Context(snapshot: changed.current, mapping: fixture.mapping, asOf: now)
        let supply = try DinnerPantrySupply.build(context: context, shopID: source.workspace.shops[0].id)
        let matches = Dictionary(uniqueKeysWithValues: source.planned.template.ingredients.map { ($0.id, source.food) })
        let unknown = try DinnerSwapEvidence.build(preview: preview(source), original: source.original, replacement: source.planned,
            reviewedFoods: matches, workspace: source.workspace, workspaceID: source.origin, supply: supply, canonical: context, at: now)
        XCTAssertEqual(unknown.foods.first?.unresolved, true); XCTAssertNil(unknown.foods.first?.afterPacks)
        XCTAssertNil(unknown.foods.first?.afterCost); XCTAssertEqual(unknown.foods.first?.packagePrice, .init(minorUnits: 125))
        let unmatched = try DinnerSwapEvidence.build(preview: preview(source), original: source.original, replacement: source.planned,
            reviewedFoods: [:], workspace: source.workspace, workspaceID: source.origin, supply: supply, canonical: context, at: now)
        XCTAssertEqual(unmatched.foods.count, 3)
        XCTAssertTrue(unmatched.foods.allSatisfy { $0.unresolved && $0.afterPacks == nil })
        var foreign = source.workspace
        foreign.packSelections = []
        let noPrice = try DinnerSwapEvidence.build(preview: preview(source), original: source.original, replacement: source.planned,
            reviewedFoods: matches, workspace: foreign, workspaceID: source.origin, supply: supply, canonical: context, at: now)
        XCTAssertNil(noPrice.foods.first?.packagePrice); XCTAssertNil(noPrice.foods.first?.priceSource)
    }

    private final class Scope { var authorized = true; var phase = BasketPhase.draft }
    private struct Models {
        let cleanup: SQLiteFixtureDirectory
        let directory: URL
        let ledger: LedgerModel
        let pickup: PickupModel
        let model: DinnerFeatureModel
        let scope: Scope
        let target: UUID
    }
    private func models() async throws -> Models {
        let source = try source(), directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let cleanup = SQLiteFixtureDirectory(directory, test: self), instant = now
        let ledger = LedgerModel(databaseURL: directory.appendingPathComponent("ledger.sqlite"), clock: { instant })
        await ledger.open(); cleanup.track(ledger)
        let saved = await ledger.change(key: "swap-fixture") { $0 = source.workspace }
        XCTAssertTrue(saved)
        let origin = try XCTUnwrap(ledger.sourceWorkspaceID), scope = Scope()
        let pickup = PickupModel(databaseURL: directory.appendingPathComponent("pickup.sqlite"), clock: { instant })
        await pickup.load(); pickup.bindCookLedger(ledger); cleanup.track(pickup)
        let model = DinnerFeatureModel(store: ledger, access: { [scope] id in
            guard scope.authorized else { return nil }
            return .init(scope: .local(workspaceID: origin), actorID: "me", shopID: id, assignedShopperID: "me", canPlan: true,
                canReadBudget: true, hasPaidTools: true, roleRevision: 0, verifiedAt: instant, validUntil: instant.addingTimeInterval(60))
        }, phase: { [scope] _ in scope.phase }, clock: { instant })
        cleanup.track(model)
        return .init(cleanup: cleanup, directory: directory, ledger: ledger, pickup: pickup, model: model, scope: scope, target: source.original.id)
    }

    func testOptionsRecheckCurrentPreferencesScopeAndExactServingCountBeforePreview() async throws {
        let f = try await models()
        let options = try f.model.swapOptions(occurrenceID: f.target, pickup: f.pickup)
        let option = try XCTUnwrap(options.first); XCTAssertTrue(option.canChoose)
        let review = try f.model.prepareSwap(option, pickup: f.pickup)
        XCTAssertEqual(review.original.id, f.target); XCTAssertFalse(review.preview.needsPurchaseAmendment)
        XCTAssertTrue(review.foods.allSatisfy(\.unresolved))
        let differentServings = AcceptedDinner(id: UUID(), template: .init(title: "Two servings", servings: try Rational(2),
            ingredients: [.init(name: "Rice", quantity: q(2))]), acceptedAt: now, acceptedFallback: false)
        let origin = try XCTUnwrap(f.ledger.sourceWorkspaceID), shopID = try XCTUnwrap(f.ledger.shop?.id)
        let approved = await f.ledger.change(key: "approve-other-serving-count") { workspace in
            try workspace.dinnerPlanning.accept(differentServings, access: self.access(shopID, origin: origin), at: self.now)
        }
        XCTAssertTrue(approved)
        let optionsAfter = try f.model.swapOptions(occurrenceID: f.target, pickup: f.pickup)
        var proposed: UUID?
        let source = try MealChoiceSource.swap(f.model, pickup: f.pickup, occurrence: f.target, group: nil, displayed: optionsAfter,
            authorized: { f.scope.authorized }) { proposed = $0 }
        XCTAssertFalse(source.options.contains(where: { $0.id == differentServings.id }))
        let beforeAssistance = f.ledger.workspace
        try source.select(option.id)
        XCTAssertEqual(proposed, option.id)
        XCTAssertEqual(f.ledger.workspace, beforeAssistance)
        XCTAssertThrowsError(try source.select(differentServings.id))
        let mismatched = try XCTUnwrap(optionsAfter.first { $0.id == differentServings.id })
        XCTAssertFalse(mismatched.canChoose)
        if case .servingsMismatch = mismatched.issue {} else { XCTFail("Expected an explicit servings review, not silent scaling") }
        let freshOption = try XCTUnwrap(optionsAfter.first { $0.id == option.id })
        let changed = await f.ledger.change(key: "change-preference") { workspace in
            var settings = MealPreferenceSettings(); settings.availableAppliances = ["stove"]
            try workspace.dinnerPlanning.updateMealPreferences(settings, expectedRevision: nil)
        }
        XCTAssertTrue(changed)
        XCTAssertThrowsError(try f.model.prepareSwap(freshOption, pickup: f.pickup))
        let restricted = try XCTUnwrap(f.model.swapOptions(occurrenceID: f.target, pickup: f.pickup).first)
        XCTAssertFalse(restricted.canChoose); XCTAssertTrue(restricted.eligibility.unresolved.contains(.appliancesUnknown))
        XCTAssertFalse(source.isCurrent())
        XCTAssertThrowsError(try source.select(option.id))
        f.scope.authorized = false
        XCTAssertThrowsError(try source.select(option.id))
        XCTAssertThrowsError(try f.model.swapOptions(occurrenceID: f.target, pickup: f.pickup))
        XCTAssertThrowsError(try f.model.prepareSwap(restricted, pickup: f.pickup))
    }

    func testPlacedPickupCannotUsePrivateDraftSwapAndPreviewDoesNotWrite() async throws {
        let f = try await models(), before = f.ledger.workspace
        let option = try XCTUnwrap(f.model.swapOptions(occurrenceID: f.target, pickup: f.pickup).first)
        _ = try f.model.prepareSwap(option, pickup: f.pickup)
        XCTAssertEqual(f.ledger.workspace, before); XCTAssertTrue(f.pickup.journeys.isEmpty)
        f.scope.phase = .reportedPlaced
        XCTAssertThrowsError(try f.model.swapOptions(occurrenceID: f.target, pickup: f.pickup))
        XCTAssertThrowsError(try f.model.prepareSwap(option, pickup: f.pickup))
        XCTAssertEqual(f.ledger.workspace, before); XCTAssertTrue(f.pickup.journeys.isEmpty)
    }

    func testConfirmedSwapReopensAndSelectiveUndoPreservesIndependentlyPurchasedCoffee() async throws {
        let f = try await models(), original = try XCTUnwrap(f.ledger.shop?.mealOccurrences.first)
        let option = try XCTUnwrap(f.model.swapOptions(occurrenceID: f.target, pickup: f.pickup).first)
        let review = try f.model.prepareSwap(option, pickup: f.pickup)
        XCTAssertTrue(f.model.installSwap(review, pickup: f.pickup))
        let applied = await f.model.applyPreview()
        XCTAssertTrue(applied, f.model.error ?? "Swap should commit")
        let receipt = try XCTUnwrap(f.model.latestUndoableSwap(occurrenceID: f.target))
        XCTAssertNotNil(f.ledger.shop?.mealOccurrences.first { $0.id == f.target }?.removedAt)
        var coffee: UUID?
        let added = await f.ledger.change(key: "independent-coffee") { workspace in
            coffee = try workspace.shops[0].addManualLine(name: "Coffee", quantity: self.q(1), at: self.now)
            try workspace.shops[0].handle(lineID: XCTUnwrap(coffee), by: "Independent shopper", at: self.now)
        }
        XCTAssertTrue(added)
        let coffeeID = try XCTUnwrap(coffee)
        let originalCoffee = try XCTUnwrap(f.ledger.shop?.lines.first { $0.id == coffeeID })
        let instant = now
        let reopened = LedgerModel(databaseURL: f.directory.appendingPathComponent("ledger.sqlite"), clock: { instant })
        await reopened.open(); f.cleanup.track(reopened)
        let pickup = PickupModel(databaseURL: f.directory.appendingPathComponent("pickup.sqlite"), clock: { instant })
        await pickup.load(); pickup.bindCookLedger(reopened); f.cleanup.track(pickup)
        let origin = try XCTUnwrap(reopened.sourceWorkspaceID)
        let model = DinnerFeatureModel(store: reopened, access: { id in
            .init(scope: .local(workspaceID: origin), actorID: "me", shopID: id, assignedShopperID: "me", canPlan: true,
                canReadBudget: true, hasPaidTools: true, roleRevision: 0, verifiedAt: instant, validUntil: instant.addingTimeInterval(60))
        }, phase: { _ in .draft }, clock: { instant })
        f.cleanup.track(model)
        let saved = try XCTUnwrap(model.latestUndoableSwap(occurrenceID: f.target))
        XCTAssertEqual(saved.id, receipt.id)
        let undone = await model.undoSwap(saved, pickup: pickup)
        XCTAssertTrue(undone, model.error ?? "Selective Undo should preserve unrelated purchases")
        XCTAssertEqual(reopened.shop?.mealOccurrences.first { $0.id == f.target }, original)
        XCTAssertEqual(reopened.shop?.lines.first { $0.id == coffeeID }, originalCoffee)
        let afterUndo = reopened.workspace
        let retried = await model.undoSwap(saved, pickup: pickup)
        XCTAssertTrue(retried); XCTAssertEqual(reopened.workspace, afterUndo)
        XCTAssertTrue(pickup.journeys.isEmpty, "A draft swap and Undo do not fabricate pantry or checkout history")
    }
}
