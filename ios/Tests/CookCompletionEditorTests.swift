import XCTest
import CoreDomain
import LocalStore
@testable import RoomInTheCart

@MainActor final class CookCompletionEditorTests: XCTestCase {
    private final class Access { var allowed = true }
    private struct Fixture {
        let cleanup: SQLiteFixtureDirectory
        let ledger: LedgerModel
        let pickup: PickupModel
        let store: ComparisonStore
        let gate: PantryMutationGate
        let session: PantryCookSession
        let editor: CookCompletionEditorModel
        let access: Access
        let shop: UUID
        let meal: UUID
        let lots: [UUID]
        let now: Date
    }
    private func quantity(_ n: Int64) throws -> Quantity { .init(amount: try Rational(n), unit: .count, originalLiteral: String(n)) }
    private func fixture() async throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let cleanup = SQLiteFixtureDirectory(directory, test: self), now = Date().addingTimeInterval(-60)
        let gate = PantryMutationGate(), access = Access()
        let ledger = LedgerModel(databaseURL: directory.appendingPathComponent("ledger.sqlite"), clock: { now },
                                 inventoryProjectionsEnabled: true, mutationGate: gate)
        cleanup.track(ledger)
        await ledger.open()
        let backing = try XCTUnwrap(ledger.pantryBackingStore(gate: gate))
        let recipe = MealTemplate(title: "Tacos", servings: try Rational(4), ingredients: [
            .init(name: "Wraps", quantity: try quantity(4)), .init(name: "Salt", quantity: nil)])
        var shop = ShoppingLedger(title: "Dinner")
        let meal = try shop.chooseMeal(recipe, at: now)
        let saved = await ledger.change(key: "fixture") {
            $0.shops = [shop]; $0.selectedShopID = shop.id; $0.mealTemplates = [recipe]
        }
        XCTAssertTrue(saved)
        let store = try ComparisonStore(url: directory.appendingPathComponent("pickup.sqlite"), inventoryEnabled: true)
        cleanup.track(store)
        let lots = [UUID(), UUID()]
        var writes: [InventoryWrite] = []
        for (index, lot) in lots.enumerated() {
            let seed = InventoryLotSeed(foodID: UUID(), name: index == 0 ? "Wraps" : "Rice wraps",
                source: .manual(originID: store.workspaceID, sourceID: lot), location: index == 0 ? .cupboard : .freezer,
                unit: .count, count: .exact(try quantity(4)))
            let command = InventoryCommand(id: UUID(), originID: store.workspaceID, lotID: lot, eventID: UUID(),
                expectedRevision: nil, occurredAt: now, change: .create(seed, observationID: UUID()))
            writes += try PantryPersistenceCodec.writes(InventoryEngine.prepare(command, current: nil, at: now))
        }
        _ = try await store.commitInventory(.init(workspaceID: store.workspaceID, operationID: UUID(), expectedRevision: 0,
            request: Data([1]), mode: .activate, sourceToken: store.inventorySourceToken(), writes: writes), at: now)
        let pending = try PantryPickupPendingStore(directory: directory.appendingPathComponent("pending"),
            inventoryWorkspaceID: store.workspaceID, ledgerWorkspaceID: backing.workspaceID)
        let pickup = PickupModel(store: store, clock: { now }, pantry: .init(ledger: backing, pendingStore: pending,
            gate: gate, authorize: { access.allowed }))
        cleanup.track(pickup)
        await pickup.load()
        XCTAssertTrue(pickup.ready, pickup.error ?? "")
        let session = PantryCookSession(ledger: ledger, pickup: pickup, authorize: { access.allowed })
        let editor = CookCompletionEditorModel()
        await editor.open(session: session, shopID: shop.id, mealID: meal, authorize: { access.allowed })
        XCTAssertNotNil(editor.context)
        return Fixture(cleanup: cleanup, ledger: ledger, pickup: pickup, store: store, gate: gate,
            session: session, editor: editor, access: access, shop: shop.id, meal: meal, lots: lots, now: now)
    }
    private func explicitNoUse(_ model: CookCompletionEditorModel) {
        for index in model.ingredients.indices { model.ingredients[index].use = .notUsed }
        model.leftoverChoice = .none
    }

    func testExplicitChoicesSplitBatchesAndLeftoversReviewThenCommitOnce() async throws {
        let f = try await fixture(), model = f.editor
        XCTAssertThrowsError(try model.makeDraft(), "No default should mean not used or no leftovers")
        model.servings = "3"
        explicitNoUse(model)
        model.ingredients[0].use = .used
        model.ingredients[0].parts[0].use = .measured
        model.ingredients[0].parts[0].relation = .ingredient
        model.ingredients[0].parts[0].lotID = f.lots[0]
        model.ingredients[0].parts[0].amount = "1"
        model.addPart(ingredientID: model.ingredients[0].id)
        model.ingredients[0].parts[1].use = .measured
        model.ingredients[0].parts[1].relation = .substitution
        model.ingredients[0].parts[1].substitution = "Rice wraps actually used"
        model.ingredients[0].parts[1].lotID = f.lots[1]
        model.ingredients[0].parts[1].amount = "1"
        model.leftoverChoice = .recorded
        model.addLeftover(); model.leftovers[0].portions = "2"; model.leftovers[0].location = .freezer
        let original = try model.makeDraft()
        XCTAssertEqual(try model.makeDraft(), original, "Retries retain event/part/output identities")
        await model.prepareReview()
        XCTAssertNotNil(model.review); XCTAssertFalse(model.canEdit)
        let previewSource = try await f.store.load(id: f.shop)
        XCTAssertNil(previewSource, "Preview must not create a source")
        model.keepEditing()
        XCTAssertEqual(try model.makeDraft(), original)
        await model.prepareReview(); await model.confirm()
        XCTAssertEqual(model.completed, original)
        let after = try await f.session.load(shopID: f.shop, mealID: f.meal)
        XCTAssertEqual(after.inventory.lots.first { $0.id == f.lots[0] }?.count.quantity?.amount, try Rational(3))
        XCTAssertEqual(after.inventory.lots.first { $0.id == f.lots[1] }?.count.quantity?.amount, try Rational(3))
        XCTAssertEqual(after.inventory.lots.first { $0.id == original.leftovers[0].id }?.location, .freezer)
        let revision = after.inventory.state.revision
        await model.reload(); await model.confirm()
        let reopened = try await f.session.load(shopID: f.shop, mealID: f.meal)
        XCTAssertEqual(reopened.completed, original); XCTAssertEqual(reopened.inventory.state.revision, revision)
    }

    func testUnmeasuredAndUntrackedRetainDistinctUnknownUseLineage() async throws {
        let f = try await fixture(), model = f.editor
        explicitNoUse(model)
        for index in model.ingredients.indices {
            model.ingredients[index].use = .used
            model.ingredients[index].parts[0].relation = .ingredient
        }
        model.ingredients[0].parts[0].use = .unmeasured; model.ingredients[0].parts[0].lotID = f.lots[0]
        model.ingredients[1].parts[0].use = .untracked
        let draft = try model.makeDraft()
        await model.prepareReview()
        XCTAssertEqual(model.review?.unresolvedUseIDs, draft.parts.map(\.id))
        XCTAssertTrue(model.review?.needsInventoryReview == true)
        await model.confirm()
        let after = try await f.session.load(shopID: f.shop, mealID: f.meal)
        XCTAssertEqual(after.completed?.unresolvedUseIDs, draft.parts.map(\.id))
        XCTAssertEqual(after.inventory.lots.first { $0.id == f.lots[0] }?.count, .unknown)
        XCTAssertEqual(after.inventory.lots.first { $0.id == f.lots[1] }?.count.quantity?.amount, try Rational(4))
    }

    func testCancelledDraftAndRevokedConfirmationDoNotWrite() async throws {
        let f = try await fixture(), model = f.editor
        let before = try await f.store.inventoryState()
        explicitNoUse(model); await model.prepareReview()
        model.invalidate()
        XCTAssertNil(model.context); XCTAssertNil(model.review)
        let cancelled = try await f.store.inventoryState()
        XCTAssertEqual(cancelled, before)
        await model.open(session: f.session, shopID: f.shop, mealID: f.meal, authorize: { [access = f.access] in access.allowed })
        explicitNoUse(model); await model.prepareReview()
        f.access.allowed = false
        await model.confirm()
        XCTAssertNil(model.completed); XCTAssertFalse(model.canConfirm)
        let revokedSource = try await f.store.load(id: f.shop)
        XCTAssertNil(revokedSource)
    }

    func testContendedConfirmationRetainsExactReviewAndReloadCannotAssumeAbsence() async throws {
        let f = try await fixture(), model = f.editor
        explicitNoUse(model); await model.prepareReview()
        let original = try XCTUnwrap(model.review)
        let lease = try f.gate.beginExclusiveWrite()
        await model.confirm()
        XCTAssertTrue(model.attemptedApply); XCTAssertEqual(model.review, original); XCTAssertFalse(model.canEdit)
        await model.reload()
        XCTAssertTrue(model.attemptedApply); XCTAssertEqual(model.review, original)
        f.gate.endExclusiveWrite(lease)
        await model.confirm()
        XCTAssertEqual(model.completed, original.draft)
        let after = try await f.session.load(shopID: f.shop, mealID: f.meal)
        XCTAssertEqual(after.completed, original.draft)
    }

    func testCurrentProductEvidenceGatesSuggestionsButNotActualHistory() async throws {
        let f = try await fixture(), model = f.editor
        var settings = MealPreferenceSettings(); settings.exclusions = ["Milk"]
        let saved = await f.ledger.change(key: "preferences") {
            try $0.dinnerPlanning.updateMealPreferences(settings, expectedRevision: nil)
        }
        XCTAssertTrue(saved)
        await model.reload()
        let ingredient = model.ingredients[0].id
        XCTAssertTrue(model.suggestions(for: ingredient).allSatisfy { !$0.eligible && $0.issues.contains(.ingredientsUnknown) })
        let lot = try XCTUnwrap(model.context?.inventory.lots.first { $0.id == f.lots[0] })
        var facts = MealEligibilityEvidence(); facts.reviewedIngredientDetails = ["Rice"]
        try model.reviewFoodDetails(lot: lot, evidence: facts)
        let suggestion = try XCTUnwrap(model.suggestions(for: ingredient).first { $0.id == lot.id })
        XCTAssertTrue(suggestion.eligible)
        facts.reviewedIngredientDetails = ["Milk"]
        try model.reviewFoodDetails(lot: lot, evidence: facts)
        XCTAssertThrowsError(try model.chooseSuggestion(suggestion, ingredientID: ingredient, partID: model.ingredients[0].parts[0].id))
        explicitNoUse(model)
        model.ingredients[0].use = .used
        model.ingredients[0].parts[0].use = .untracked
        model.ingredients[0].parts[0].relation = .substitution
        model.ingredients[0].parts[0].substitution = "Milk actually used"
        await model.prepareReview()
        XCTAssertEqual(model.review?.draft.parts.first?.substitution, "Milk actually used",
                       "Preference mismatch cannot rewrite actual history")
        await model.reload()
        XCTAssertTrue(model.suggestions(for: model.ingredients[0].id).allSatisfy { !$0.eligible }, "Reviewed food facts do not survive refresh")
    }

    func testIndependentRecountInvalidatesConfirmationWithoutOverwritingFood() async throws {
        let f = try await fixture(), model = f.editor
        explicitNoUse(model)
        model.ingredients[0].use = .used
        model.ingredients[0].parts[0].use = .measured
        model.ingredients[0].parts[0].relation = .ingredient
        model.ingredients[0].parts[0].lotID = f.lots[0]
        model.ingredients[0].parts[0].amount = "1"
        await model.prepareReview()
        let before = try XCTUnwrap(model.context)
        let repository = PantryRepository(store: f.store, mutationGate: f.gate, authorize: { true })
        let command = InventoryCommand(id: UUID(), originID: f.store.workspaceID, lotID: f.lots[0], eventID: UUID(),
            expectedRevision: 1, occurredAt: f.now, change: .count(.exact(try quantity(2)), observationID: UUID()))
        _ = try await repository.apply(command, reviewedInventoryRevision: before.inventory.state.revision, at: f.now)
        await model.confirm()
        XCTAssertNil(model.completed); XCTAssertTrue(model.attemptedApply)
        let after = try await f.session.load(shopID: f.shop, mealID: f.meal)
        XCTAssertNil(after.completed)
        XCTAssertEqual(after.inventory.lots.first { $0.id == f.lots[0] }?.count.quantity?.amount, try Rational(2))
        await model.reload()
        XCTAssertTrue(model.canEdit); XCTAssertNil(model.review)
    }

    func testUndoRequiresSeparateReviewAndCancelKeepsSavedCooking() async throws {
        let f = try await fixture(), model = f.editor
        explicitNoUse(model)
        model.ingredients[0].use = .used
        model.ingredients[0].parts[0].use = .measured
        model.ingredients[0].parts[0].relation = .ingredient
        model.ingredients[0].parts[0].lotID = f.lots[0]
        model.ingredients[0].parts[0].amount = "1"
        model.leftoverChoice = .recorded; model.addLeftover(); model.leftovers[0].portions = "1"
        await model.prepareReview(); await model.confirm()
        let original = try XCTUnwrap(model.completed)
        await model.prepareUndo()
        let undo = try XCTUnwrap(model.undoReview)
        XCTAssertEqual(undo.restoredInputCount, 1); XCTAssertEqual(undo.removedLeftoverCount, 1)
        XCTAssertEqual(undo.restoredInputs.first?.count.quantity?.amount, try Rational(4))
        model.cancelUndo()
        XCTAssertNil(model.undoReview); XCTAssertEqual(model.completed, original)
        let retained = try await f.session.load(shopID: f.shop, mealID: f.meal)
        XCTAssertEqual(retained.completed, original)
        await model.prepareUndo(); await model.confirmUndo()
        XCTAssertNil(model.completed); XCTAssertTrue(model.canEdit)
        let after = try await f.session.load(shopID: f.shop, mealID: f.meal)
        XCTAssertNil(after.completed)
        XCTAssertEqual(after.inventory.lots.first { $0.id == f.lots[0] }?.count.quantity?.amount, try Rational(4))
        XCTAssertEqual(after.inventory.lots.first { $0.id == original.leftovers[0].id }?.count.quantity?.amount, .zero)
        XCTAssertEqual(model.ingredients.map(\.use), [.undecided, .undecided], "Undo cannot prefill a second completion")
    }
}
