import XCTest
import SwiftUI
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
        let inventoryURL: URL
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
    private func fixture(firstUnit: UnitOfMeasure = .count, secondUnit: UnitOfMeasure = .count,
                         firstConversion: UnitBasis? = nil, duplicatePlannedName: Bool = false) async throws -> Fixture {
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
        let inventoryURL = directory.appendingPathComponent("pickup.sqlite")
        let store = try ComparisonStore(url: inventoryURL, inventoryEnabled: true)
        cleanup.track(store)
        let names = ["Wraps", "Rice wraps"] + (duplicatePlannedName ? ["Wraps"] : [])
        let lots = names.map { _ in UUID() }
        var writes: [InventoryWrite] = []
        for (index, lot) in lots.enumerated() {
            let unit = index == 0 ? firstUnit : secondUnit
            let seed = InventoryLotSeed(foodID: UUID(), name: names[index],
                source: .manual(originID: store.workspaceID, sourceID: lot), location: index == 0 ? .cupboard : .freezer,
                unit: unit, count: .exact(Quantity(amount: try Rational(4), unit: unit, originalLiteral: "4",
                    confirmedConversion: index == 0 ? firstConversion : nil)))
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
        return Fixture(cleanup: cleanup, ledger: ledger, pickup: pickup, store: store, inventoryURL: inventoryURL, gate: gate,
            session: session, editor: editor, access: access, shop: shop.id, meal: meal, lots: lots, now: now)
    }
    private func explicitNoUse(_ model: CookCompletionEditorModel) {
        for index in model.ingredients.indices { model.ingredients[index].use = .notUsed }
        model.leftoverChoice = .none
    }

    private func cookWithLunchAndDinner(_ f: Fixture) async throws -> CookCompletion.Review {
        let editor = f.editor
        explicitNoUse(editor)
        editor.ingredients[0].use = .used
        editor.ingredients[0].parts[0].use = .measured
        editor.ingredients[0].parts[0].relation = .ingredient
        editor.ingredients[0].parts[0].lotID = f.lots[0]
        editor.ingredients[0].parts[0].amount = "1"
        editor.leftoverChoice = .recorded
        editor.addLeftover()
        editor.leftovers[0].portions = "3"
        editor.leftovers[0].lunch = "1"
        editor.leftovers[0].scheduleDinner = true
        editor.leftovers[0].dinnerPortions = "2"
        await editor.prepareReview()
        let cooked = try XCTUnwrap(editor.review)
        await editor.confirm()
        return cooked
    }

    func testImmediateUndoAtomicallyReleasesTheCooksLunchAndDinnerAndReplaysOnce() async throws {
        let f = try await fixture()
        let cooked = try await cookWithLunchAndDinner(f)
        let first = try await f.session.load(shopID: f.shop, mealID: f.meal)
        let undo = try await f.session.reviewUndo(shopID: f.shop, mealID: f.meal)
        XCTAssertEqual(undo.releasedOutputHolds, cooked.outputReservations)
        XCTAssertEqual(undo.restoredHoldCount, 0)
        try await f.session.applyUndo(undo)
        try await f.session.applyUndo(undo)
        try await f.session.apply(cooked)
        let after = try await f.session.load(shopID: f.shop, mealID: f.meal)
        XCTAssertNil(after.completed)
        XCTAssertEqual(after.inventory.state.revision, first.inventory.state.revision + 1)
        XCTAssertEqual(after.inventory.lots.first { $0.id == f.lots[0] }?.count.quantity?.amount, try Rational(4))
        let outputID = try XCTUnwrap(cooked.draft.leftovers.first?.id)
        XCTAssertEqual(after.inventory.lots.first { $0.id == outputID }?.count.quantity?.amount, .zero)
        let holds = after.inventory.reservations.filter { $0.lotID == outputID }
        XCTAssertEqual(Set(holds.map(\.id)), Set(cooked.outputReservations.map(\.id)))
        XCTAssertTrue(holds.allSatisfy { $0.state == .released && $0.revision == 2 && $0.cookedDinner?.servedAt == nil })
        XCTAssertTrue(after.inventory.availability.reservations.isEmpty)
    }

    func testCookUndoRequiresBackedUnchangedOutputHoldsAndPreservesNewDemand() async throws {
        let f = try await fixture(), cook = try await cookWithLunchAndDinner(f)
        let output = try XCTUnwrap(cook.draft.leftovers.first)
        let repo = PantryRepository(store: f.store, authorize: { f.access.allowed })
        let otherID = UUID()
        func saveOtherHold(_ state: InventoryReservationState, revision: Int64) async throws {
            let hold = InventoryReservation(id: otherID, originID: f.store.workspaceID, revision: revision,
                foodID: output.foodID, lotID: nil, name: "Another meal", amount: try quantity(1), state: state)
            let basis = try await f.store.inventoryState()
            _ = try await f.store.commitInventory(.init(workspaceID: f.store.workspaceID, operationID: UUID(),
                expectedRevision: basis.revision, request: Data([UInt8(revision)]),
                writes: [PantryPersistenceCodec.write(hold, expectedRevision: revision - 1)]), at: f.now)
        }
        try await saveOtherHold(.active, revision: 1)
        let short = try await repo.load(at: f.now)
        XCTAssertEqual(short.availability.reservations.first { $0.id == otherID }?.shortfall?.amount, .one)
        do { _ = try await f.session.reviewUndo(shopID: f.shop, mealID: f.meal); XCTFail("An unfunded new hold must survive") }
        catch PantryCookPort.Failure.changed {}
        try await saveOtherHold(.released, revision: 2)
        let clean = try await f.session.reviewUndo(shopID: f.shop, mealID: f.meal)
        let stock = try await repo.load(at: f.now)
        let lunch = try XCTUnwrap(stock.reservations.first { $0.personal != nil })
        let lot = try XCTUnwrap(stock.lots.first { $0.id == output.id })
        let release = InventoryCommand(id: UUID(), originID: f.store.workspaceID, lotID: lot.id,
            eventID: UUID(), expectedRevision: lot.revision, occurredAt: f.now,
            change: .reservation(.release(id: lunch.id, expectedRevision: lunch.revision, amount: nil)))
        _ = try await repo.apply(release, reviewedInventoryRevision: stock.state.revision, at: f.now)
        do { try await f.session.applyUndo(clean); XCTFail("Changing the lunch hold invalidates the review") }
        catch PantryCookPort.Failure.changed {}
        do { _ = try await f.session.reviewUndo(shopID: f.shop, mealID: f.meal); XCTFail("The released lunch is a separate decision") }
        catch PantryCookPort.Failure.changed {}
        let after = try await repo.load(at: f.now)
        XCTAssertEqual(after.lots.first { $0.id == output.id }?.count.quantity?.amount, try Rational(3))
        XCTAssertEqual(after.availability.lots.first { $0.id == output.id }?.held?.amount, try Rational(2))
    }

    func testCookEditorSchedulesOnlyCountedPortionsInThePrivateDinnerCalendar() async throws {
        let f = try await fixture(), editor = f.editor
        let ledgerID = try XCTUnwrap(f.ledger.sourceWorkspaceID)
        let shop = try XCTUnwrap(f.ledger.shop)
        let day = try MealDay(year: 2026, month: 11, day: 19, timeZoneIdentifier: shop.basis.timeZoneIdentifier)
        let calendar = DinnerFeatureModel(store: f.ledger, access: { id in
            DinnerAccessContext(scope: .local(workspaceID: ledgerID), actorID: "cook", shopID: id,
                assignedShopperID: "cook", canPlan: true, canReadBudget: true, hasPaidTools: false,
                roleRevision: 0, verifiedAt: f.now, validUntil: f.now.addingTimeInterval(300))
        }, phase: { _ in .draft }, clock: { f.now }, basketPrepAccess: { f.access.allowed })
        explicitNoUse(editor)
        editor.leftoverChoice = .recorded
        editor.addLeftover()
        editor.leftovers[0].portions = "3"
        editor.leftovers[0].lunch = "1"
        editor.leftovers[0].scheduleDinner = true
        editor.leftovers[0].dinnerDate = try XCTUnwrap(day.date)
        editor.leftovers[0].dinnerPortions = "3"
        await editor.prepareReview()
        XCTAssertEqual(editor.notice, .invalidPortionHolds)
        editor.leftovers[0].dinnerPortions = "2"
        await editor.prepareReview()
        XCTAssertEqual(editor.review?.outputReservations.count, 2)
        XCTAssertTrue(try calendar.currentMeals(pickup: f.pickup).cooked.isEmpty)
        await editor.confirm()
        let entry = try XCTUnwrap(calendar.currentMeals(pickup: f.pickup).cooked(on: day).first)
        XCTAssertEqual(entry.amount?.amount, try Rational(2))
        f.access.allowed = false
        XCTAssertTrue(try calendar.currentMeals(pickup: f.pickup).cooked.isEmpty)
        f.access.allowed = true
        let cancel = try XCTUnwrap(CookedDinnerChange(entry, action: .cancel))
        let port = try f.pickup.cookCompletionPort(ledger: f.ledger, authorize: { f.access.allowed })
        try await port.changeDinner(cancel)
        try await port.changeDinner(cancel)
        let refreshed = await f.pickup.refreshPantryStock()
        XCTAssertTrue(refreshed)
        XCTAssertTrue(try calendar.currentMeals(pickup: f.pickup).cooked.isEmpty)
        let batch = try XCTUnwrap(f.pickup.pantrySnapshot?.availability.lots.first { $0.id == entry.lotID })
        XCTAssertEqual(batch.remaining?.amount, try Rational(3))
        XCTAssertEqual(batch.free?.amount, try Rational(2))
        XCTAssertEqual(batch.held?.amount, .one)
        XCTAssertEqual(f.ledger.shop, shop)
    }

    func testOnlyUnsubmittedCookingChangesAreEligibleForAnInterruptionNotice() async throws {
        let f = try await fixture(), editor = f.editor
        XCTAssertFalse(editor.hasUnsavedDraft)
        let planned = editor.servings
        editor.servings = "9"
        XCTAssertTrue(editor.hasUnsavedDraft)
        editor.servings = planned
        XCTAssertFalse(editor.hasUnsavedDraft)
        explicitNoUse(editor)
        XCTAssertTrue(editor.hasUnsavedDraft)
        await editor.prepareReview()
        _ = try XCTUnwrap(editor.review)
        XCTAssertTrue(editor.hasUnsavedDraft)
        await editor.confirm()
        _ = try XCTUnwrap(editor.completed)
        XCTAssertFalse(editor.hasUnsavedDraft)
        editor.invalidate()
        XCTAssertFalse(editor.hasUnsavedDraft)
    }

    func testRemovedShoppingContributionKeepsRemainingIngredientCookableThroughRetryAndUndo() async throws {
        let f = try await fixture(), editor = f.editor
        let meal = try XCTUnwrap(editor.context?.meal)
        let kept = meal.ingredientContributionIDs[0], removed = meal.ingredientContributionIDs[1]
        let changed = await f.ledger.editShop(key: "remove-salt", shopID: f.shop) {
            try $0.removeContribution(contributionID: removed, at: f.now)
        }
        XCTAssertTrue(changed)
        await editor.reload()
        XCTAssertEqual(editor.ingredients.map(\.id), [kept])
        guard editor.ingredients.count == 1 else { return }
        explicitNoUse(editor)
        editor.ingredients[0].use = .used
        editor.ingredients[0].parts[0].use = .measured
        editor.ingredients[0].parts[0].relation = .ingredient
        editor.ingredients[0].parts[0].lotID = f.lots[0]
        editor.ingredients[0].parts[0].amount = "1"
        editor.leftoverChoice = .recorded
        editor.addLeftover()
        editor.leftovers[0].portions = "2"
        await editor.prepareReview()
        let review = try XCTUnwrap(editor.review)
        XCTAssertEqual(review.draft.meal.ingredientContributionIDs, [kept, removed])
        XCTAssertEqual(review.draft.ingredientRowIDs, [kept])
        await editor.confirm()
        try await f.session.apply(review)
        await editor.reload()
        let after = try XCTUnwrap(editor.context)
        XCTAssertEqual(after.completed, review.draft)
        XCTAssertEqual(after.inventory.lots.first { $0.id == f.lots[0] }?.count.quantity?.amount, try Rational(3))
        let leftover = try XCTUnwrap(review.draft.leftovers.first?.id)
        XCTAssertEqual(after.inventory.lots.first { $0.id == leftover }?.count.quantity?.amount, try Rational(2))
        await editor.prepareUndo()
        await editor.confirmUndo()
        let undone = try XCTUnwrap(editor.context)
        XCTAssertNil(undone.completed)
        XCTAssertEqual(undone.inventory.lots.first { $0.id == f.lots[0] }?.count.quantity?.amount, try Rational(4))
        XCTAssertEqual(undone.inventory.lots.first { $0.id == leftover }?.count.quantity?.amount, .zero)
        XCTAssertEqual(editor.ingredients.map(\.id), [kept])
    }

    func testUndoRestoresTheOriginalRemainingEstimateAndPriorUseWithoutOverwritingANewerObservation() async throws {
        let f = try await fixture(), editor = f.editor, lotID = f.lots[0]
        let repo = PantryRepository(store: f.store, authorize: { f.access.allowed })
        func observe(_ wording: String, use: InventoryUsage?) async throws {
            let snapshot = try await repo.load(at: f.now)
            let lot = try XCTUnwrap(snapshot.lots.first { $0.id == lotID })
            let observation = InventoryCountRevision(count: .someLeft, observationID: UUID(), observedAt: f.now, countWording: wording)
            let command = InventoryCommand(id: UUID(), originID: snapshot.state.workspaceID, lotID: lotID, eventID: UUID(),
                expectedRevision: lot.revision, occurredAt: f.now, change: .revise(.init(observation: observation, usage: use.map { [$0] })))
            _ = try await repo.apply(command, reviewedInventoryRevision: snapshot.state.revision, at: f.now)
        }
        func cook() async throws {
            await editor.reload()
            explicitNoUse(editor)
            editor.ingredients[0].use = .used
            editor.ingredients[0].parts[0].use = .unmeasured
            editor.ingredients[0].parts[0].relation = .ingredient
            editor.ingredients[0].parts[0].lotID = lotID
            await editor.prepareReview()
            _ = try XCTUnwrap(editor.review)
            await editor.confirm()
            _ = try XCTUnwrap(editor.completed)
        }
        let wording = "menos de media botella"
        let originalUse = InventoryUsage(id: UUID(), kind: .some)
        try await observe(wording, use: originalUse)
        try await cook()
        let undo = try await f.session.reviewUndo(shopID: f.shop, mealID: f.meal)
        XCTAssertEqual(undo.restoredInputs.first?.countWording, wording)
        let reloadedUndo = try JSONDecoder().decode(PantryCookUndoReview.self, from: JSONEncoder().encode(undo))
        try await f.session.applyUndo(reloadedUndo)
        try await f.session.applyUndo(reloadedUndo)
        let restored = try await repo.load(at: f.now)
        let restoredLot = try XCTUnwrap(restored.lots.first { $0.id == lotID })
        XCTAssertEqual(restoredLot.count, .someLeft)
        XCTAssertEqual(restoredLot.countWording, wording)
        let history = try await repo.usageHistory(lotID: lotID, basis: restored.state)
        XCTAssertEqual(history, [.init(id: originalUse.id, occurredAt: f.now, kind: .some, remainingWording: wording)])

        try await cook()
        let obsolete = try await f.session.reviewUndo(shopID: f.shop, mealID: f.meal)
        try await observe("casi vacía", use: nil)
        do { try await f.session.applyUndo(obsolete); XCTFail("Newer stock evidence was overwritten") }
        catch PantryCookPort.Failure.changed {}
        let latest = try await repo.load(at: f.now)
        XCTAssertEqual(latest.lots.first { $0.id == lotID }?.countWording, "casi vacía")
    }

    func testChangingMeasuredBatchPreservesGramsAndDeductsTheExactAmountFromKilograms() async throws {
        let f = try await fixture(firstUnit: .gram, secondUnit: .kilogram)
        let editor = f.editor
        explicitNoUse(editor)
        editor.ingredients[0].use = .used
        let partID = editor.ingredients[0].parts[0].id
        let gramBatch = try XCTUnwrap(editor.context?.inventory.lots.first { $0.id == f.lots[0] })
        let kiloBatch = try XCTUnwrap(editor.context?.inventory.lots.first { $0.id == f.lots[1] })
        editor.ingredients[0].parts[0].selectBatch(gramBatch)
        XCTAssertEqual(editor.ingredients[0].parts[0].unit, .gram)
        editor.ingredients[0].parts[0].amount = "2"
        editor.ingredients[0].parts[0].selectBatch(kiloBatch)
        XCTAssertEqual(editor.ingredients[0].parts[0].unit, .gram)
        editor.ingredients[0].parts[0].selectBatch(gramBatch)
        let suggestion = try XCTUnwrap(editor.suggestions(for: editor.ingredients[0].id).first { $0.id == kiloBatch.id })
        try editor.chooseSuggestion(suggestion, ingredientID: editor.ingredients[0].id, partID: partID)
        XCTAssertEqual(editor.ingredients[0].parts[0].amount, "2")
        XCTAssertEqual(editor.ingredients[0].parts[0].unit, .gram)
        await editor.prepareReview()
        let preview = try XCTUnwrap(editor.review)
        XCTAssertEqual(preview.draft.parts.first?.use, .lot(id: kiloBatch.id, revision: kiloBatch.revision,
            amount: Quantity(amount: try Rational(2), unit: .gram, originalLiteral: "2")))
        await editor.confirm()
        let saved = try await f.session.load(shopID: f.shop, mealID: f.meal)
        XCTAssertEqual(saved.inventory.lots.first { $0.id == gramBatch.id }?.count, gramBatch.count)
        XCTAssertEqual(saved.inventory.lots.first { $0.id == kiloBatch.id }?.count.quantity?.amount, try Rational(1999, 500))
    }

    func testChangingBatchWithIncompatibleUnitsRequiresANewMeasurement() async throws {
        let basis = UnitBasis(sourceUnit: .count, targetUnit: .gram, targetAmountPerSourceUnit: try Rational(2),
                              sourceNote: "One portion weighed two grams for this batch")
        let f = try await fixture(firstUnit: .gram, secondUnit: .kilogram, firstConversion: basis)
        let editor = f.editor
        explicitNoUse(editor)
        editor.ingredients[0].use = .used
        let source = try XCTUnwrap(editor.context?.inventory.lots.first { $0.id == f.lots[0] })
        let target = try XCTUnwrap(editor.context?.inventory.lots.first { $0.id == f.lots[1] })
        var part = editor.ingredients[0].parts[0]
        part.amount = "1/2"; part.use = .measured; part.relation = .ingredient
        part.selectBatch(source)
        XCTAssertEqual(part.amount, "1/2", "This batch has a reviewed count-to-mass conversion")
        XCTAssertEqual(part.unit, .count)
        part.selectBatch(target)
        XCTAssertEqual(part.amount, "")
        XCTAssertEqual(part.unit, .kilogram, "The old batch’s count conversion cannot be used for the new batch")
        XCTAssertTrue(part.needsNewMeasurement)
        editor.ingredients[0].parts[0] = part
        XCTAssertThrowsError(try editor.makeDraft())
        part.selectBatch(nil)
        XCTAssertFalse(part.needsNewMeasurement)
        part.selectBatch(source)
        XCTAssertFalse(part.needsNewMeasurement)
        part.amount = "2"
        XCTAssertFalse(part.needsNewMeasurement)
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

    func testReturningFromASuggestedSubstituteToTheUniquePlannedFoodClearsTheSavedSubstitution() async throws {
        let f = try await fixture(firstUnit: .cup), editor = f.editor
        explicitNoUse(editor)
        editor.ingredients[0].use = .used
        let ingredient = editor.ingredients[0].id, part = editor.ingredients[0].parts[0].id
        let suggestion = try XCTUnwrap(editor.suggestions(for: ingredient).first { $0.id == f.lots[1] })
        try editor.chooseSuggestion(suggestion, ingredientID: ingredient, partID: part)
        XCTAssertEqual(editor.ingredients[0].parts[0].substitution, "Rice wraps")

        editor.selectBatch(f.lots[0], ingredientID: ingredient, partID: part)
        XCTAssertEqual(editor.ingredients[0].parts[0].relation, .ingredient)
        XCTAssertEqual(editor.ingredients[0].parts[0].substitution, "")
        XCTAssertEqual(editor.ingredients[0].parts[0].unit, .cup)
        editor.ingredients[0].parts[0].amount = "1/2"
        await editor.prepareReview()
        let draft = try XCTUnwrap(editor.review?.draft)
        XCTAssertNil(draft.parts.first?.substitution)
        await editor.confirm()
        let saved = try await f.session.load(shopID: f.shop, mealID: f.meal)
        XCTAssertEqual(saved.completed, draft)
        XCTAssertEqual(saved.inventory.lots.first { $0.id == f.lots[0] }?.count.quantity?.amount, try Rational(7, 2))
        XCTAssertEqual(saved.inventory.lots.first { $0.id == f.lots[1] }?.count.quantity?.amount, try Rational(4))
    }

    func testChangingSuggestedBatchWithAmbiguousNamesRequiresReviewAndPreservesAnExplicitDescription() async throws {
        let f = try await fixture(duplicatePlannedName: true), editor = f.editor
        explicitNoUse(editor)
        editor.ingredients[0].use = .used
        editor.ingredients[0].parts[0].use = .unmeasured
        let ingredient = editor.ingredients[0].id, part = editor.ingredients[0].parts[0].id
        let suggestion = try XCTUnwrap(editor.suggestions(for: ingredient).first { $0.id == f.lots[1] })
        try editor.chooseSuggestion(suggestion, ingredientID: ingredient, partID: part)
        editor.selectBatch(f.lots[0], ingredientID: ingredient, partID: part)
        XCTAssertEqual(editor.ingredients[0].parts[0].relation, .undecided)
        XCTAssertThrowsError(try editor.makeDraft())

        editor.ingredients[0].parts[0].relation = .substitution
        editor.ingredients[0].parts[0].substitution = "The gluten-free wraps from the freezer"
        editor.selectBatch(f.lots[2], ingredientID: ingredient, partID: part)
        await editor.prepareReview()
        XCTAssertEqual(editor.review?.draft.parts.first?.substitution, "The gluten-free wraps from the freezer")
    }

    func testFirstPantryVisitAfterCookingWaitsForTheOtherReadAndReopensWithItsAllocations() async throws {
        let f = try await fixture()
        let cooking = try await cookWithLunchAndDinner(f)
        XCTAssertEqual(f.editor.notice, .saved)
        let shelf = try XCTUnwrap(f.pickup.makePantryModel())
        let second = try XCTUnwrap(f.pickup.makePantryModel())
        let lease = try f.gate.beginExclusiveWrite()
        // Dinner detail and the retained Pantry tab use this same exclusive lease.
        // Hold it across both appearances to make the scheduling independent of SQLite speed.
        let firstVisit = Task { await shelf.loadOnAppearance(accessAllowed: true) }
        let secondVisit = Task { await second.loadOnAppearance(accessAllowed: true) }
        let deadline = ContinuousClock.now + .seconds(3)
        while (!shelf.busy || !second.busy) && shelf.notice == nil && second.notice == nil && ContinuousClock.now < deadline {
            await Task.yield()
        }
        // SwiftUI can cancel and restart an appearance while the same retained shelf is waiting.
        XCTAssertTrue(shelf.busy)
        XCTAssertTrue(second.busy)
        firstVisit.cancel()
        let reappeared = Task { await shelf.loadOnAppearance(accessAllowed: true) }
        f.gate.endExclusiveWrite(lease)
        await reappeared.value
        await firstVisit.value
        await secondVisit.value
        let persisted = try await f.store.inventoryState()
        for model in [shelf, second] {
            let snapshot = try XCTUnwrap(model.snapshot)
            XCTAssertEqual(model.phase, .ready)
            XCTAssertNil(model.notice)
            XCTAssertEqual(snapshot.state, persisted)
            XCTAssertEqual(snapshot.lots.first { $0.id == f.lots[0] }?.count.quantity?.amount, try Rational(3))
            XCTAssertEqual(Set(snapshot.reservations.map(\.id)), Set(cooking.outputReservations.map(\.id)))
        }
        try await f.store.close()
        await shelf.load()
        XCTAssertEqual(shelf.phase, .unavailable)
        XCTAssertEqual(shelf.notice, .loadFailed)
        XCTAssertNil(shelf.snapshot)
        let reopened = try ComparisonStore(url: f.inventoryURL, inventoryEnabled: true)
        f.cleanup.track(reopened)
        let cold = try await PantryRepository(store: reopened, authorize: { true }).load(at: f.now)
        XCTAssertEqual(cold.state, persisted)
        XCTAssertEqual(cold.lots, second.snapshot?.lots)
        XCTAssertEqual(cold.reservations, second.snapshot?.reservations)
        try await reopened.close()
    }

    func testSupersededPantryAppearanceCannotPublishAfterAccessChangesWhileWaiting() async throws {
        let f = try await fixture()
        let shelf = try XCTUnwrap(f.pickup.makePantryModel())
        let lease = try f.gate.beginExclusiveWrite()
        let appearance = Task { await shelf.loadOnAppearance(accessAllowed: true) }
        let deadline = ContinuousClock.now + .seconds(3)
        while !shelf.busy && shelf.notice == nil && ContinuousClock.now < deadline { await Task.yield() }
        appearance.cancel()
        f.access.allowed = false
        shelf.accessLost()
        f.gate.endExclusiveWrite(lease)
        await appearance.value
        XCTAssertNil(shelf.snapshot)
        XCTAssertNil(shelf.notice)
        XCTAssertEqual(shelf.phase, .accessDenied)
        f.access.allowed = true
        await shelf.loadOnAppearance(accessAllowed: true)
        XCTAssertTrue(shelf.canEdit)
    }

    func testMountedPantryShelfUpdatesAfterDinnerAndKeepsAnOpenRecountUntilDismissed() async throws {
        let f = try await fixture()
        let shelf = try XCTUnwrap(f.pickup.makePantryModel())
        func amount() -> Rational? { shelf.snapshot?.lots.first { $0.id == f.lots[0] }?.count.quantity?.amount }
        func waitForShelf(_ expected: Rational) async throws {
            let deadline = ContinuousClock.now + .seconds(5)
            while (!shelf.canEdit || amount() != expected) && ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertEqual(amount(), expected)
            XCTAssertTrue(shelf.canEdit)
        }
        let controller = UIHostingController(rootView: NavigationStack {
            LivePantryHomeView(pickup: f.pickup, model: shelf, household: HouseholdModel(),
                               holdsLoadedReview: { false }, initialSheet: .constant(nil))
        })
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.windowLevel = .normal - 1
        window.rootViewController = controller
        window.isHidden = false
        defer { window.isHidden = true }

        // The mounted production shelf does its normal appearance read. It stays
        // mounted through the cook and undo, so a fresh appearance cannot mask a stale shelf.
        try await waitForShelf(Rational(4))
        _ = try await cookWithLunchAndDinner(f)
        try await waitForShelf(Rational(3))

        await shelf.prepare(lotID: f.lots[0], action: .someLeft)
        let original = try XCTUnwrap(shelf.review?.command.id)
        await f.editor.prepareUndo()
        await f.editor.confirmUndo()
        XCTAssertEqual(f.editor.notice, .undone)
        XCTAssertEqual(shelf.review?.command.id, original)
        XCTAssertEqual(amount(), try Rational(3))
        shelf.cancelReview()
        try await waitForShelf(Rational(4))
    }

    func testUsedSomeFromReviewedSubstitutePreservesChoiceAndOneHistoryRowThroughCorrectionAndUndo() async throws {
        let f = try await fixture()
        let editor = f.editor
        let repository = PantryRepository(store: f.store, authorize: { f.access.allowed })
        let lotID = f.lots[1]
        func history(_ id: UUID) async throws -> [PantryUsageHistoryRow] {
            let basis = try await f.store.inventoryState()
            return try await repository.usageHistory(lotID: id, basis: basis)
        }
        explicitNoUse(editor)
        editor.ingredients[0].use = .used
        editor.ingredients[0].parts[0].use = .unmeasured
        let partID = editor.ingredients[0].parts[0].id
        let ingredientID = editor.ingredients[0].id
        let substitute = try XCTUnwrap(editor.suggestions(for: ingredientID).first { $0.id == lotID })
        try editor.chooseSuggestion(substitute, ingredientID: ingredientID, partID: partID)
        XCTAssertEqual(editor.ingredients[0].parts[0].use, .unmeasured)
        await editor.prepareReview()
        let reviewed = try XCTUnwrap(editor.review)
        XCTAssertEqual(reviewed.draft.parts.first?.use, .lot(id: lotID, revision: substitute.lot.revision, amount: nil))
        await editor.confirm()
        try await f.session.apply(reviewed)
        let original = try await history(lotID)
        XCTAssertEqual(original, [.init(id: partID, occurredAt: reviewed.draft.cookedAt, kind: .some, remainingWording: nil)])
        let otherLot = try await history(f.lots[0])
        XCTAssertTrue(otherLot.isEmpty)

        let correction = await resolution(f)
        correction.action = .deduct
        correction.usedAmount = "1"
        await correction.prepare()
        await correction.confirm()
        let amended = try await history(lotID)
        XCTAssertEqual(amended.map(\.id), [partID])
        XCTAssertEqual(amended.first?.occurredAt, reviewed.draft.cookedAt)
        guard case .measured(let amount) = amended.first?.kind else { return XCTFail("Expected corrected cooking quantity") }
        XCTAssertEqual(amount.amount, try Rational(1))
        await editor.reload()
        await editor.prepareUndo()
        await editor.confirmUndo()
        let undone = try await history(lotID)
        XCTAssertTrue(undone.isEmpty)
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

    private func resolution(_ f: Fixture) async -> CookResolutionEditorModel {
        let model = CookResolutionEditorModel()
        await model.open(session: f.session, shopID: f.shop, mealID: f.meal, authorize: { [access = f.access] in access.allowed })
        return model
    }
    private func untrackedCompletion(_ f: Fixture, cookedAt: Date? = nil) async throws -> CookCompletionDraft {
        let model = f.editor
        explicitNoUse(model)
        model.ingredients[0].use = .used
        model.ingredients[0].parts[0].use = .untracked
        model.ingredients[0].parts[0].relation = .ingredient
        if let cookedAt { model.cookedAt = cookedAt }
        await model.prepareReview(); await model.confirm()
        return try XCTUnwrap(model.completed)
    }

    func testResolutionOutsidePantryRequiresExplicitChoiceAndUpdatesEffectiveStatus() async throws {
        let f = try await fixture(), original = try await untrackedCompletion(f)
        let model = await resolution(f)
        XCTAssertEqual(model.context?.remainingEventIDs, original.unresolvedUseIDs)
        XCTAssertThrowsError(try model.decision())
        model.action = .outsidePantry
        await model.prepare()
        let reviewed = try XCTUnwrap(model.review)
        XCTAssertNil(reviewed.before); XCTAssertNil(reviewed.after)
        model.keepEditing()
        let before = try await f.session.load(shopID: f.shop, mealID: f.meal)
        XCTAssertEqual(before.remainingUnresolvedUseIDs, original.unresolvedUseIDs)
        await model.prepare(); await model.confirm()
        XCTAssertTrue(model.context?.remainingEventIDs.isEmpty == true)
        await f.editor.reload()
        XCTAssertEqual(f.editor.completed, original, "Original unresolved history remains immutable")
        XCTAssertTrue(f.editor.remainingUnresolvedUseIDs.isEmpty)
        XCTAssertEqual(f.editor.context?.inventory.lots.first { $0.id == f.lots[0] }?.count.quantity?.amount, try Rational(4))
    }

    func testResolutionNewerCountIncludedDoesNotOfferAnotherDeduction() async throws {
        let f = try await fixture()
        _ = try await untrackedCompletion(f, cookedAt: f.now.addingTimeInterval(-10))
        let model = await resolution(f)
        model.selectLot(f.lots[0])
        XCTAssertTrue(model.actions.contains(.alreadyIncluded)); XCTAssertFalse(model.actions.contains(.deduct))
        model.action = .deduct; model.usedAmount = "1"
        XCTAssertThrowsError(try model.decision())
        model.action = .alreadyIncluded; model.usedKnown = true
        await model.prepare()
        XCTAssertEqual(model.review?.before, model.review?.after)
        await model.confirm()
        let current = try await f.session.load(shopID: f.shop, mealID: f.meal)
        XCTAssertEqual(current.inventory.lots.first { $0.id == f.lots[0] }?.revision, 1)
        XCTAssertEqual(current.inventory.lots.first { $0.id == f.lots[0] }?.count.quantity?.amount, try Rational(4))
    }

    func testResolutionMeasuredSiblingsRemainUnknownUntilEveryUseIsReviewed() async throws {
        let f = try await fixture(), editor = f.editor
        explicitNoUse(editor); editor.ingredients[0].use = .used
        editor.addPart(ingredientID: editor.ingredients[0].id)
        for index in editor.ingredients[0].parts.indices {
            editor.ingredients[0].parts[index].use = .unmeasured
            editor.ingredients[0].parts[index].relation = .ingredient
            editor.ingredients[0].parts[index].lotID = f.lots[0]
        }
        await editor.prepareReview(); await editor.confirm()
        let draft = try XCTUnwrap(editor.completed)
        let model = await resolution(f)
        XCTAssertTrue(model.batchIsFixed)
        model.selectLot(f.lots[1]); XCTAssertEqual(model.lotID, f.lots[0])
        XCTAssertTrue(model.actions.contains(.deduct))
        model.action = .deduct; model.usedAmount = "1"
        await model.prepare()
        XCTAssertEqual(model.review?.reconstructionBasis?.amount, try Rational(4))
        XCTAssertEqual(model.review?.after, .unknown)
        await model.confirm()
        XCTAssertEqual(model.context?.remainingEventIDs.count, 1)
        model.action = .deduct; model.usedAmount = "1"
        await model.prepare()
        XCTAssertEqual(model.review?.after?.quantity?.amount, try Rational(2))
        await model.confirm()
        let current = try await f.session.load(shopID: f.shop, mealID: f.meal)
        XCTAssertTrue(current.remainingUnresolvedUseIDs.isEmpty)
        XCTAssertEqual(current.completed, draft)
        XCTAssertEqual(current.inventory.lots.first { $0.id == f.lots[0] }?.count.quantity?.amount, try Rational(2))
    }

    func testResolutionContentionRetainsExactCorrectionForAuthorizedRetry() async throws {
        let f = try await fixture()
        _ = try await untrackedCompletion(f)
        let model = await resolution(f)
        model.action = .outsidePantry; await model.prepare()
        let original = try XCTUnwrap(model.review)
        let lease = try f.gate.beginExclusiveWrite()
        await model.confirm(); await model.reload()
        XCTAssertTrue(model.attempted); XCTAssertEqual(model.review, original); XCTAssertFalse(model.canEdit)
        f.gate.endExclusiveWrite(lease)
        f.access.allowed = false
        await model.confirm()
        XCTAssertEqual(model.review, original)
        f.access.allowed = true
        await model.confirm()
        XCTAssertTrue(model.context?.remainingEventIDs.isEmpty == true)
        let current = try await f.session.load(shopID: f.shop, mealID: f.meal)
        XCTAssertTrue(current.remainingUnresolvedUseIDs.isEmpty)
    }

    func testAmendedUndoShowsPreservedCountsAndRetainedCorrectionHistory() async throws {
        let f = try await fixture()
        _ = try await untrackedCompletion(f, cookedAt: f.now.addingTimeInterval(-10))
        let correction = await resolution(f)
        correction.selectLot(f.lots[0]); correction.action = .alreadyIncluded
        await correction.prepare(); await correction.confirm()
        await f.editor.reload(); await f.editor.prepareUndo()
        let undo = try XCTUnwrap(f.editor.undoReview)
        XCTAssertEqual(undo.resolvedUseCount, 1)
        XCTAssertEqual(undo.preservedCountNames, ["Wraps"])
        XCTAssertEqual(undo.restoredInputCount, 0)
        await f.editor.confirmUndo()
        XCTAssertNil(f.editor.completed)
        let current = try await f.session.load(shopID: f.shop, mealID: f.meal)
        XCTAssertEqual(current.inventory.lots.first { $0.id == f.lots[0] }?.revision, 1)
        let loadedSource = try await f.store.load(id: f.shop)
        let source = try XCTUnwrap(loadedSource)
        let journey = try JSONDecoder().decode(PickupJourney.self, from: source.payload)
        XCTAssertEqual(journey.cookedMeals?.first?.resolutions?.count, 1)
        XCTAssertEqual(journey.cookedMeals?.first?.undo?.resolvedEventIDs?.count, 1)
    }

    func testAmendedUndoReportsPhysicalRecountAndChangedDrawWithoutOverwriting() async throws {
        let f = try await fixture()
        _ = try await untrackedCompletion(f)
        let correction = await resolution(f)
        correction.selectLot(f.lots[0]); correction.action = .recount; correction.remainingAmount = "3"
        await correction.prepare(); await correction.confirm()
        await f.editor.reload(); await f.editor.prepareUndo()
        XCTAssertNil(f.editor.undoReview)
        XCTAssertEqual(f.editor.notice, .undoIndependentCount("Wraps"))
        let preserved = try await f.session.load(shopID: f.shop, mealID: f.meal)
        XCTAssertEqual(preserved.inventory.lots.first { $0.id == f.lots[0] }?.count.quantity?.amount, try Rational(3))

        let other = try await fixture(), editor = other.editor
        explicitNoUse(editor); editor.ingredients[0].use = .used
        editor.ingredients[0].parts[0].use = .unmeasured
        editor.ingredients[0].parts[0].relation = .ingredient
        editor.ingredients[0].parts[0].lotID = other.lots[0]
        await editor.prepareReview(); await editor.confirm()
        let measured = await resolution(other)
        measured.action = .deduct; measured.usedAmount = "1"
        await measured.prepare(); await measured.confirm()
        let before = try await other.session.load(shopID: other.shop, mealID: other.meal)
        let lot = try XCTUnwrap(before.inventory.lots.first { $0.id == other.lots[0] })
        let repository = PantryRepository(store: other.store, mutationGate: other.gate, authorize: { true })
        let moved = InventoryCommand(id: UUID(), originID: other.store.workspaceID, lotID: lot.id, eventID: UUID(),
            expectedRevision: lot.revision, occurredAt: other.now, change: .move(.fridge))
        _ = try await repository.apply(moved, reviewedInventoryRevision: before.inventory.state.revision, at: other.now)
        await editor.reload(); await editor.prepareUndo()
        XCTAssertNil(editor.undoReview); XCTAssertEqual(editor.notice, .undoAmendedInputChanged("Wraps"))
        let after = try await other.session.load(shopID: other.shop, mealID: other.meal)
        XCTAssertEqual(after.inventory.lots.first { $0.id == lot.id }?.location, .fridge)
        XCTAssertEqual(after.inventory.lots.first { $0.id == lot.id }?.count.quantity?.amount, try Rational(3))
    }

    func testReviewLifetimeIgnoresAmbientCancellationButRejectsClosedAndReopenedRoutes() async {
        let lifetime = CookReviewLifetime(), token = lifetime.begin()
        let callback = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return lifetime.permits(token)
        }
        let allowed = await callback.value
        XCTAssertTrue(allowed, "A cancelled rendering task does not revoke the visible adult review")
        lifetime.end(); XCTAssertFalse(lifetime.permits(token))
        let reopened = lifetime.begin()
        XCTAssertFalse(lifetime.permits(token), "Old suspended actions cannot regain authority on reopen")
        XCTAssertTrue(lifetime.permits(reopened))
    }
}
