import XCTest
import CoreDomain
import DeviceSurfaces
import LocalStore
import RecordArchive
@testable import RoomInTheCart

@MainActor final class TonightMealModelTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func q(_ value: Int64) -> Quantity { .init(amount: try! Rational(value), unit: .count, originalLiteral: String(value)) }
    private func input(recipe: MealTemplate, food: UUID, revision: Int64 = 1, profile: MealPreferenceProfile? = nil) -> TonightMealModel.Input {
        var workspace = LedgerWorkspace(mealTemplates: [recipe])
        if let profile { try! workspace.dinnerPlanning.updateMealPreferences(profile.settings, expectedRevision: nil) }
        return .init(workspace: workspace, ledgerRevision: 1,
            basis: .init(originID: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!, inventoryRevision: revision, sourceHeads: []),
            foods: [.init(id: food, name: "Wraps", detail: "Reviewed count")],
            freeLots: [.init(id: food, foodID: food, name: "Wraps", usable: q(3), confirmedAt: now, source: .pantry)],
            unresolvedFoods: [], sources: [])
    }
    func testHomeSummaryOnlyUsesReviewedFullyCoveredMealsAndCurrentPrivateEvidence() async throws {
        let food = UUID(), ingredient = MealIngredient(name: "Wraps", quantity: q(2))
        var recipe = MealTemplate(title: "Dinner wraps", ingredients: [ingredient])
        var equipment = MealEligibilityEvidence(); equipment.requiredAppliances = []
        recipe.eligibilityEvidence = equipment
        let model = TonightMealModel()
        let unreviewed = input(recipe: recipe, food: food)
        await model.refresh(authorize: { true }, load: { unreviewed })
        try model.match(recipeID: recipe.id, ingredientID: ingredient.id, foodID: food)
        XCTAssertTrue(model.homeScreenChoices.isEmpty)
        var kitchen = MealPreferenceSettings(); kitchen.availableAppliances = []
        let reviewed = input(recipe: recipe, food: food, profile: .init(settings: kitchen))
        await model.refresh(authorize: { true }, load: { reviewed })
        XCTAssertTrue(model.homeScreenChoices.isEmpty)
        try model.match(recipeID: recipe.id, ingredientID: ingredient.id, foodID: food)
        XCTAssertEqual(model.homeScreenChoices.map(\.recipe.title), ["Dinner wraps"])
        let origin = UUID()
        let basis = try TonightHomeBasis(ledger: origin, revision: reviewed.ledgerRevision, stock: reviewed.basis)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("widget")
        let home = AdultHomeSummaryStore(directory: root.appendingPathComponent("private"), widgetDirectory: { directory }, reload: { _ in })
        let identity = CapturePrivateIdentity(actorID: UUID(), subject: nil, householdID: nil, memberID: nil, role: nil)
        let access = PantryDigestAccess(scope: .init(origin: reviewed.basis.originID, identity: identity), authorized: { true })
        try home.setEnabled(true, kind: .tonight, access: access)
        try home.update(.tonight, access: access, count: 1, reviewedTitle: recipe.title, tonightBasis: basis)
        let projection = try AdultFoodSummaryFile(directory: directory, kind: .tonight).read()
        XCTAssertEqual(projection.reviewedTitle, "Dinner wraps")
        XCTAssertTrue(home.permitsTonight(projection.route, access: access, basis: basis))
        let changed = try TonightHomeBasis(ledger: origin, revision: reviewed.ledgerRevision + 1, stock: reviewed.basis)
        XCTAssertFalse(home.permitsTonight(projection.route, access: access, basis: changed))
        try home.eraseLedger(origin)
        XCTAssertFalse(home.permitsTonight(projection.route, access: access, basis: basis))
        var settings = kitchen; settings.exclusions = ["Wraps"]
        let restricted = input(recipe: recipe, food: food, profile: .init(settings: settings))
        await model.refresh(authorize: { true }, load: { restricted })
        try model.match(recipeID: recipe.id, ingredientID: ingredient.id, foodID: food)
        XCTAssertTrue(model.homeScreenChoices.isEmpty)
    }
    func testNoShopBrowseRequiresExplicitMatchAndAllowsKnownShortfallWithoutClaimingFullCoverage() async throws {
        let food = UUID(), ingredient = MealIngredient(name: "Wraps", quantity: q(4))
        let recipe = MealTemplate(title: "Dinner", ingredients: [ingredient]), model = TonightMealModel()
        let read = input(recipe: recipe, food: food)
        await model.refresh(authorize: { true }, load: { read })
        XCTAssertTrue(model.suggestions.isEmpty)
        XCTAssertEqual(model.needsReview.map(\.recipe), [recipe])
        XCTAssertTrue(read.workspace.shops.isEmpty)
        try model.match(recipeID: recipe.id, ingredientID: ingredient.id, foodID: food)
        let review = try XCTUnwrap(model.suggestions.first)
        XCTAssertEqual(review.ingredients.first?.coverage?.shortfall, try Rational(1))
        XCTAssertFalse(review.allIngredientsCovered)
        XCTAssertTrue(TonightMealModel.canChoose(review))
        XCTAssertTrue(try XCTUnwrap(model.input).workspace.shops.isEmpty, "Browsing and matching do not create a pickup")
    }
    func testRepeatedMixedUnitShortfallUsesCoverageUnitAndUnknownIsNotZero() throws {
        let food = UUID()
        let grams = MealIngredient(name: "Rice", quantity: .init(amount: try Rational(500), unit: .gram, originalLiteral: "500"))
        let kilos = MealIngredient(name: "More rice", quantity: .init(amount: .one, unit: .kilogram, originalLiteral: "1"))
        let recipe = MealTemplate(title: "Rice dinner", ingredients: [grams, kilos])
        let lot = ConfirmedStockLot(id: food, foodID: food, name: "Rice",
            usable: .init(amount: .one, unit: .kilogram, originalLiteral: "1"), confirmedAt: now, source: .pantry)
        let review = try PantryMealMatcher.review(recipe: recipe, reviewedFoods: [grams.id: food, kilos.id: food],
            globallyFreeLots: [lot], unresolvedFoods: [], profile: nil)
        let row = try XCTUnwrap(review.ingredients.first { $0.id == kilos.id })
        let missing = try XCTUnwrap(TonightMealModel.missingQuantity(row))
        XCTAssertEqual(missing.unit, .gram)
        XCTAssertEqual(missing.amount, try Rational(500))
        XCTAssertEqual(try missing.converted(to: .kilogram).amount, try Rational(1, 2))
        let unknown = try PantryMealMatcher.review(recipe: recipe, reviewedFoods: [grams.id: food, kilos.id: food],
            globallyFreeLots: [lot], unresolvedFoods: [food], profile: nil)
        XCTAssertTrue(unknown.ingredients.allSatisfy { TonightMealModel.missingQuantity($0) == nil })
        XCTAssertFalse(TonightMealModel.canChoose(unknown))
    }
    func testCountOrPreferenceChangeClearsReviewedMatchesBeforeNewSuggestion() async throws {
        let food = UUID(), ingredient = MealIngredient(name: "Wraps", quantity: q(2))
        let recipe = MealTemplate(title: "Dinner", ingredients: [ingredient]), model = TonightMealModel()
        let read = input(recipe: recipe, food: food)
        await model.refresh(authorize: { true }, load: { read })
        try model.match(recipeID: recipe.id, ingredientID: ingredient.id, foodID: food)
        await model.refresh(authorize: { true }, load: { read })
        XCTAssertEqual(model.suggestions.count, 1)
        let changed = input(recipe: recipe, food: food, revision: 2)
        await model.refresh(authorize: { true }, load: { changed })
        XCTAssertTrue(model.matches.isEmpty); XCTAssertTrue(model.suggestions.isEmpty)
        XCTAssertThrowsError(try model.assertCurrent(read, recipe: recipe, matches: [ingredient.id: food]))
        var settings = MealPreferenceSettings(); settings.exclusions = ["Wraps"]
        let restricted = input(recipe: recipe, food: food, revision: 2, profile: .init(settings: settings))
        await model.refresh(authorize: { true }, load: { restricted })
        XCTAssertFalse(try XCTUnwrap(model.reviews.first).eligibility.eligible)
    }
    func testReadRevocationDuringSuspensionRedactsRecipeAndFoodNames() async throws {
        let food = UUID(), recipe = MealTemplate(title: "Private dinner", ingredients: [.init(name: "Wraps", quantity: q(1))])
        let read = input(recipe: recipe, food: food), model = TonightMealModel()
        var authorized = true
        await model.refresh(authorize: { authorized }, load: { authorized = false; return read })
        XCTAssertNil(model.input); XCTAssertTrue(model.reviews.isEmpty); XCTAssertTrue(model.matches.isEmpty)
    }
    func testProductDetailsAreNotBorrowedFromRecipeAndStaleFoodReviewFails() async throws {
        let food = UUID(), ingredient = MealIngredient(name: "Wraps", quantity: q(2))
        var recipe = MealTemplate(title: "Dinner", ingredients: [ingredient])
        var facts = MealEligibilityEvidence(); facts.reviewedIngredientDetails = ["Rice"]
        recipe.eligibilityEvidence = facts
        var settings = MealPreferenceSettings(); settings.exclusions = ["Milk"]
        let read = input(recipe: recipe, food: food, profile: .init(settings: settings)), model = TonightMealModel()
        await model.refresh(authorize: { true }, load: { read })
        try model.match(recipeID: recipe.id, ingredientID: ingredient.id, foodID: food)
        XCTAssertTrue(try XCTUnwrap(model.reviews.first).eligibility.unresolved.contains(.ingredientsUnknown))
        try model.reviewFood(try XCTUnwrap(read.foods.first), evidence: facts, original: read)
        XCTAssertEqual(model.suggestions.count, 1)
        let changed = input(recipe: recipe, food: food, revision: 2, profile: read.workspace.dinnerPlanning.privateMealPreferences)
        await model.refresh(authorize: { true }, load: { changed })
        XCTAssertThrowsError(try model.reviewFood(try XCTUnwrap(read.foods.first), evidence: facts, original: read))
    }
    func testPersistedImportsRemainSourcesAndErasedSourceDisappearsAfterReopen() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("recovery-v1.json"), registry = try RecoveryRegistry(url: url)
        let imported = ImportedRecipe(title: "Original saved recipe", yieldText: "serves some", ingredients: ["some wraps"])
        let record = try imported.archiveRecord(origin: "recipe-library-v1", savedAt: now)
        let envelope = try ArchiveCodec.make(records: [record], kind: .personalRecovery, origin: "recipe-library-v1", revision: "one")
        let review = try await registry.review(envelope)
        let commit = try await registry.apply(review, now: now)
        let sources = try await TonightRecipeLibrary.read(url: url, authorize: { true })
        XCTAssertEqual(sources.map(\.recipe), [imported])
        XCTAssertTrue(TonightMealModel.recipes(in: LedgerWorkspace()).isEmpty)
        try await registry.undoImport(insertedCopyIDs: commit.insertedCopyIDs)
        let after = try await TonightRecipeLibrary.read(url: url, authorize: { true })
        XCTAssertTrue(after.isEmpty)
        do { _ = try await TonightRecipeLibrary.read(url: url, authorize: { false }); XCTFail("Locked read") }
        catch { XCTAssertTrue(error is TonightMealModel.Failure) }
    }
    func testCanonicalNoShopSupplyRespectsOtherShopHoldAndUnknownRecount() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let cleanup = SQLiteFixtureDirectory(directory, test: self)
        let store = try ComparisonStore(url: directory.appendingPathComponent("pickup.sqlite"), inventoryEnabled: true)
        cleanup.track(store)
        let food = UUID()
        var journey = PickupJourney(id: UUID(), savedAt: now)
        journey.stockLots = [.init(id: food, foodID: food, name: "Wraps", usable: q(5), confirmedAt: now, source: .pantry)]
        journey.stockNeeds = [.init(id: UUID(), foodID: food, name: "Protected other dinner", amount: q(3), priority: .protected)]
        try PickupModel.validate(journey)
        _ = try await store.save(id: journey.id, title: "Other pickup", payload: JSONEncoder().encode(journey), savedAt: now)
        let mapping = try PantryLegacyMigration.map(originID: store.workspaceID,
            heads: try await store.list().map(PantryLegacyMigration.SourceHead.init), ledger: .unavailable, at: now)
        let package = try PantryMigrationPackage.build(mapping, migrationID: UUID(), sourceToken: await store.inventorySourceToken(),
            inventoryRevision: await store.inventoryState().revision, at: now)
        _ = try await store.beginInventoryMigration(package.plan)
        for chunk in package.chunks { _ = try await store.stageInventoryMigration(id: package.plan.migrationID, chunk: chunk) }
        _ = try await store.finishInventoryMigration(id: package.plan.migrationID, at: now)
        let repository = PantryRepository(store: store, authorize: { true }); cleanup.track(repository)
        let before = try await repository.load(at: now)
        let read = try TonightMealModel.input(workspace: LedgerWorkspace(), ledgerRevision: 0,
            context: .init(snapshot: before, mapping: mapping, asOf: now), sources: [])
        XCTAssertEqual(read.freeLots.first?.usable, q(2))
        XCTAssertTrue(read.workspace.shops.isEmpty)
        let lot = try XCTUnwrap(before.lots.first)
        _ = try await repository.apply(.init(id: UUID(), originID: store.workspaceID, lotID: lot.id, eventID: UUID(),
            expectedRevision: lot.revision, occurredAt: now, change: .count(.unknown, observationID: UUID())),
            reviewedInventoryRevision: before.state.revision, at: now)
        let after = try await repository.load(at: now)
        let changed = try TonightMealModel.input(workspace: LedgerWorkspace(), ledgerRevision: 0,
            context: .init(snapshot: after, mapping: mapping, asOf: now), sources: [])
        XCTAssertTrue(changed.freeLots.isEmpty); XCTAssertTrue(changed.unresolvedFoods.contains(food))
    }
}
