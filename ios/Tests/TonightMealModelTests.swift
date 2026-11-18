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
        try home.setEnabled(true, kind: .tonight, access: access, ledgerID: origin)
        home.refreshTonight(model, access: access, ledgerID: origin) { basis }
        let widget = try AdultFoodSummaryFile(directory: directory, kind: .tonight)
        let projection = try widget.read()
        let batchModel = TonightMealModel(batch: .init(originID: reviewed.basis.originID, lotID: food))
        await batchModel.refresh(authorize: { true }, load: { reviewed })
        home.refreshTonight(batchModel, access: access, ledgerID: origin) {
            XCTFail("A selected batch must not replace or clear the global Home Screen summary.")
            return basis
        }
        XCTAssertEqual(try widget.read(), projection)
        XCTAssertTrue(home.enabled(.tonight, scope: access.scope))
        XCTAssertEqual(projection.reviewedTitle, "Dinner wraps")
        XCTAssertTrue(home.permitsTonight(projection.route, access: access, basis: basis))
        let changed = try TonightHomeBasis(ledger: origin, revision: reviewed.ledgerRevision + 1, stock: reviewed.basis)
        XCTAssertFalse(home.permitsTonight(projection.route, access: access, basis: changed))
        let admittedConsent = try XCTUnwrap(home.tonightConsentToken(scope: access.scope, ledger: origin))
        XCTAssertNil(home.tonightConsentToken(scope: access.scope, ledger: UUID()))
        try home.invalidateLedger(origin, forget: false)
        XCTAssertEqual(home.tonightConsentToken(scope: access.scope, ledger: origin), admittedConsent)
        XCTAssertTrue(home.enabled(.tonight, scope: access.scope))
        XCTAssertFalse(home.permitsTonight(projection.route, access: access, basis: basis))
        try home.invalidateLedger(origin, forget: true)
        XCTAssertFalse(home.enabled(.tonight, scope: access.scope))
        XCTAssertFalse(home.permitsTonight(projection.route, access: access, basis: basis))
        XCTAssertNil(home.tonightConsentToken(scope: access.scope, ledger: origin))
        try home.setEnabled(true, kind: .tonight, access: access, ledgerID: origin)
        let newConsent = try XCTUnwrap(home.tonightConsentToken(scope: access.scope, ledger: origin))
        XCTAssertNotEqual(newConsent, admittedConsent)
        var settings = kitchen; settings.exclusions = ["Wraps"]
        let restricted = input(recipe: recipe, food: food, profile: .init(settings: settings))
        await model.refresh(authorize: { true }, load: { restricted })
        try model.match(recipeID: recipe.id, ingredientID: ingredient.id, foodID: food)
        XCTAssertTrue(model.homeScreenChoices.isEmpty)
    }
    func testTwentyMinuteHomeSummaryRequiresReviewedDurationInsideTheStrictLimit() async throws {
        let food = UUID(), ingredient = MealIngredient(name: "Wraps", quantity: q(2))
        var kitchen = MealPreferenceSettings()
        kitchen.availableAppliances = []
        kitchen.timeLimit = .init(maximumMinutes: 20, strict: true)
        var equipment = MealEligibilityEvidence(); equipment.requiredAppliances = []
        let model = TonightMealModel()
        for duration: Int? in [nil, 25, 20] {
            var recipe = MealTemplate(title: "Dinner wraps", ingredients: [ingredient])
            recipe.eligibilityEvidence = equipment; recipe.leadTimeMinutes = duration
            let source = input(recipe: recipe, food: food, profile: .init(settings: kitchen))
            await model.refresh(authorize: { true }, load: { source })
            try model.match(recipeID: recipe.id, ingredientID: ingredient.id, foodID: food)
            let review = try XCTUnwrap(model.reviews.first)
            switch duration {
            case nil:
                XCTAssertTrue(review.eligibility.unresolved.contains(.durationUnknown))
                XCTAssertTrue(model.homeScreenChoices.isEmpty)
            case 25:
                XCTAssertTrue(review.eligibility.blocked.contains(.durationAboveLimit))
                XCTAssertTrue(model.homeScreenChoices.isEmpty)
            default:
                XCTAssertEqual(model.homeScreenChoices.map(\.recipe.title), ["Dinner wraps"])
            }
        }
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
        var differing = recipe; differing.revision += 1; differing.ingredients[0].quantity = q(2)
        var workspace = read.workspace
        let access = DinnerAccessContext(scope: .local(workspaceID: UUID()), actorID: "owner", shopID: UUID(),
            assignedShopperID: "owner", canPlan: true, canReadBudget: false, hasPaidTools: false,
            roleRevision: 0, verifiedAt: now, validUntil: now.addingTimeInterval(30))
        try workspace.dinnerPlanning.accept(.init(id: UUID(), template: differing, acceptedAt: now), access: access, at: now)
        let ambiguous = TonightMealModel.Input(workspace: workspace, ledgerRevision: 2, basis: read.basis,
            foods: read.foods, freeLots: read.freeLots, unresolvedFoods: [], sources: [])
        await model.refresh(authorize: { true }, load: { ambiguous })
        XCTAssertTrue(model.recipes.isEmpty, "Two different saved versions must not silently choose a winner")
        XCTAssertEqual(model.conflictingRecipes.count, 2)
        let accepted = try XCTUnwrap(model.conflictingRecipes.first { $0.acceptedAt != nil })
        try model.selectVersion(accepted)
        XCTAssertEqual(model.recipes, [differing])
        XCTAssertTrue(model.matches.isEmpty, "Selecting a version requires new pantry matches")
        XCTAssertEqual(model.input?.workspace.mealTemplates, [recipe], "Selecting a source is read-only")
        let unrelated = MealTemplate(title: "Another restored recipe", ingredients: [.init(name: "Rice", quantity: q(1))])
        workspace.mealTemplates.append(unrelated)
        let reviewedCopy = MealTemplate(title: differing.title, ingredients: differing.ingredients)
        try TonightMealModel.saveReviewedTemplate(reviewedCopy, editing: differing, in: &workspace)
        XCTAssertEqual(workspace.mealTemplates, [reviewedCopy, unrelated])
        XCTAssertEqual(workspace.dinnerPlanning.acceptedDinners.first?.template, differing, "Reviewing a copy must retain the accepted original")
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
        XCTAssertEqual(try missing.converted(to: .kilogram), try Rational(1, 2))
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
        let wrap = MealIngredient(name: "Wrap", quantity: q(1))
        let sauce = MealIngredient(name: "Sauce", quantity: q(1))
        let bigger = MealIngredient(name: "Wraps", quantity: q(2))
        let first = MealTemplate(title: "First wrap", ingredients: [wrap])
        let second = MealTemplate(title: "Tortilla with sauce", ingredients: [bigger, sauce])
        let library = LedgerWorkspace(mealTemplates: [first, second])
        let read = try TonightMealModel.input(workspace: library, ledgerRevision: 0,
            context: .init(snapshot: before, mapping: mapping, asOf: now), sources: [])
        XCTAssertEqual(read.freeLots.first?.usable, q(2))
        XCTAssertTrue(read.workspace.shops.isEmpty)
        let lot = try XCTUnwrap(before.lots.first)
        let model = TonightMealModel(batch: .init(originID: store.workspaceID, lotID: lot.id))
        await model.refresh(authorize: { true }, load: { read })
        XCTAssertEqual(model.selectedLot?.id, lot.id)
        try model.match(recipeID: first.id, ingredientID: wrap.id, foodID: food)
        try model.match(recipeID: second.id, ingredientID: bigger.id, foodID: food)
        XCTAssertEqual(model.suggestions.map(\.id), [second.id, first.id])
        try model.showFollowingMeals(after: first.id)
        let next = try XCTUnwrap(model.followingMeals.first)
        XCTAssertEqual(next.id, second.id)
        XCTAssertEqual(next.batchUse?.used.amount, .one)
        XCTAssertEqual(next.batchUse?.remaining.amount, .zero)
        XCTAssertEqual(next.ingredients.first?.coverage?.shortfall, .one)
        XCTAssertEqual(next.ingredients.last?.ingredient, sauce)
        XCTAssertEqual(model.input?.freeLots.first?.usable, q(2))
        var chosen: PantryMealMatcher.Review?
        let offered = try MealChoiceSource.tonight(model, ledgerID: store.workspaceID, following: true, authorized: { true }) { chosen = $0 }
        XCTAssertEqual(offered.options.map(\.id), [second.id])
        XCTAssertThrowsError(try offered.select(first.id))
        try offered.select(second.id)
        XCTAssertEqual(chosen, next)
        let unchanged = try await repository.load(at: now)
        XCTAssertEqual(unchanged.state.revision, before.state.revision)
        XCTAssertEqual(unchanged.reservations, before.reservations)
        let wrong = TonightMealModel(batch: .init(originID: UUID(), lotID: lot.id))
        await wrong.refresh(authorize: { true }, load: { read })
        XCTAssertNil(wrong.selectedLot)
        XCTAssertTrue(wrong.suggestions.isEmpty)
        _ = try await repository.apply(.init(id: UUID(), originID: store.workspaceID, lotID: lot.id, eventID: UUID(),
            expectedRevision: lot.revision, occurredAt: now, change: .count(.unknown, observationID: UUID())),
            reviewedInventoryRevision: before.state.revision, at: now)
        let after = try await repository.load(at: now)
        let changed = try TonightMealModel.input(workspace: library, ledgerRevision: 0,
            context: .init(snapshot: after, mapping: mapping, asOf: now), sources: [])
        await model.refresh(authorize: { true }, load: { changed })
        XCTAssertFalse(offered.isCurrent())
        XCTAssertThrowsError(try offered.select(second.id))
        XCTAssertNil(model.firstRecipeID)
        XCTAssertTrue(model.followingMeals.isEmpty)
        XCTAssertTrue(model.suggestions.isEmpty)
        XCTAssertTrue(changed.freeLots.isEmpty); XCTAssertTrue(changed.unresolvedFoods.contains(food))
    }
}
