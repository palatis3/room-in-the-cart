import XCTest
import CoreDomain
import LocalStore
@testable import RoomInTheCart

@MainActor final class LedgerModelPerformanceSafetyTests: XCTestCase {
    private struct Document: Codable { let formatVersion: Int; let workspace: LedgerWorkspace }
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func payload(_ workspace: LedgerWorkspace) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(Document(formatVersion: 1, workspace: workspace))
    }

    func testReviewedMealCannotFollowPickupOrWorkspaceAndExactRetryAddsNoNeeds() async throws {
        let directory = try directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let model = LedgerModel(databaseURL: directory.appendingPathComponent("ledger.sqlite"))
        await model.open()
        let began = await model.startShop(title: "First pickup")
        XCTAssertTrue(began)
        let firstID = try XCTUnwrap(model.shop?.id)
        let imported = MealTemplate(title: "Family soup", ingredients: [MealIngredient(name: "Beans", quantity: nil)])
        let review = LedgerMealSaveReview(context: model.mealEditContext(template: imported, chooseNow: true), candidate: imported)

        let next = await model.startShop(title: "Second pickup")
        XCTAssertTrue(next)
        let before = model.workspace
        let wrongShop = await model.saveReviewedMeal(review)
        XCTAssertFalse(wrongShop)
        XCTAssertEqual(model.workspace, before)

        let other = LedgerModel(databaseURL: directory.appendingPathComponent("other.sqlite"))
        await other.open()
        let copied = await other.change(key: "same-pickup-ids") { $0 = before; $0.selectedShopID = firstID }
        XCTAssertTrue(copied)
        let wrongWorkspace = await other.saveReviewedMeal(review)
        XCTAssertFalse(wrongWorkspace)
        XCTAssertTrue(try XCTUnwrap(other.shop).mealOccurrences.isEmpty)

        await model.selectShop(firstID)
        let applied = await model.saveReviewedMeal(review)
        XCTAssertTrue(applied)
        XCTAssertEqual(model.shop?.mealOccurrences.map(\.id), [review.id])
        XCTAssertEqual(model.shop?.contributions.map(\.productName), ["Beans"])
        let saved = try model.exportPayload(), revision = model.revision
        let repeated = await model.saveReviewedMeal(review)
        XCTAssertTrue(repeated)
        XCTAssertEqual(try model.exportPayload(), saved)
        XCTAssertEqual(model.revision, revision)
    }

    func testReusableMealSaveRejectsReplacedOrDeletedOriginalAndCompetingCreation() async throws {
        let directory = try directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let model = LedgerModel(databaseURL: directory.appendingPathComponent("ledger.sqlite"))
        await model.open()
        let create = model.mealEditContext(template: nil, chooseNow: false)
        let original = MealTemplate(title: "Usual supper")
        let saved = await model.saveReviewedMeal(.init(context: create, candidate: original))
        XCTAssertTrue(saved)
        let competing = await model.saveReviewedMeal(.init(context: create, candidate: MealTemplate(title: "Other supper")))
        XCTAssertFalse(competing)
        XCTAssertEqual(model.workspace.mealTemplates, [original])

        let edit = model.mealEditContext(template: original, chooseNow: false)
        var first = original; first.notes = "First edit"; first.revision += 1
        var second = original; second.title = "A different edit"; second.revision += 1
        let firstReview = LedgerMealSaveReview(context: edit, candidate: first)
        let secondReview = LedgerMealSaveReview(context: edit, candidate: second)
        let accepted = await model.saveReviewedMeal(firstReview)
        XCTAssertTrue(accepted)
        let revision = model.revision
        let retried = await model.saveReviewedMeal(firstReview)
        XCTAssertTrue(retried)
        let stale = await model.saveReviewedMeal(secondReview)
        XCTAssertFalse(stale)
        XCTAssertEqual(model.revision, revision)
        XCTAssertEqual(model.workspace.mealTemplates, [first])
        let deleted = await model.change(key: "delete-usual-supper") { $0.mealTemplates.removeAll() }
        XCTAssertTrue(deleted)
        let afterDeletion = await model.saveReviewedMeal(secondReview)
        XCTAssertFalse(afterDeletion)
        XCTAssertTrue(model.workspace.mealTemplates.isEmpty)
    }

    func testCommittedCandidateMatchesDurableBytesAndReopenedWorkspace() async throws {
        let directory = try directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("ledger.sqlite")
        let model = LedgerModel(databaseURL: url)
        await model.open()
        let started = await model.startShop(title: "Reviewed capture"); XCTAssertTrue(started)
        let shopID = try XCTUnwrap(model.shop?.id)
        let line = CaptureImportLine(originalText: "two packs rice", name: "rice", packCount: 2,
            amountPerPack: Quantity(amount: try Rational(3, 2), unit: .kilogram, originalLiteral: "1.5 kg"), purpose: "dinner")
        let preview = try XCTUnwrap(model.shop).stageCaptureImport(id: UUID(), originalText: line.originalText, source: .voice, lines: [line])
        let imported = await model.editShop(key: "capture", shopID: shopID) { try $0.commitImport(preview) }
        XCTAssertTrue(imported); XCTAssertFalse(model.hasPendingSave)
        let committed = model.workspace
        let exported = try model.exportPayload()
        XCTAssertEqual(try LedgerModel.validatePayload(exported), committed)
        let store = try LedgerStore(url: url)
        let record = try await store.load()
        XCTAssertEqual(record?.payload, exported)
        let reopened = LedgerModel(databaseURL: url); await reopened.open()
        XCTAssertEqual(reopened.workspace, committed)
        XCTAssertEqual(reopened.revision, model.revision)
        let revision = model.revision
        let retried = await model.editShop(key: "capture", shopID: shopID) { try $0.commitImport(preview) }
        XCTAssertTrue(retried); XCTAssertEqual(model.revision, revision)
        XCTAssertEqual(model.workspace, committed)
    }

    func testExternalHeadRemainsAuthoritativeAfterStaleSaveAndDiscard() async throws {
        let directory = try directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("ledger.sqlite")
        let model = LedgerModel(databaseURL: url); await model.open()
        let started = await model.startShop(title: "Original"); XCTAssertTrue(started)
        let before = model.workspace, shopID = try XCTUnwrap(model.shop?.id)
        var foreign = before
        try foreign.shops[0].addManualLine(name: "Saved elsewhere", quantity: nil)
        let store = try LedgerStore(url: url)
        try await store.save(payload: payload(foreign), expectedRevision: model.revision, operationID: UUID(), savedAt: Date())
        let changed = await model.editShop(key: "stale", shopID: shopID) { try $0.addManualLine(name: "Pending", quantity: nil) }
        XCTAssertFalse(changed); XCTAssertTrue(model.hasPendingSave); XCTAssertEqual(model.workspace, before)
        await model.discardPendingSave()
        XCTAssertFalse(model.hasPendingSave); XCTAssertEqual(model.workspace, foreign)
        XCTAssertEqual(try LedgerModel.validatePayload(model.exportPayload()), foreign)
    }

    func testDecodedDomainCorruptionStillRejectsOpenAndReload() async throws {
        let directory = try directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("ledger.sqlite")
        let model = LedgerModel(databaseURL: url); await model.open()
        let started = await model.startShop(title: "Valid"); XCTAssertTrue(started)
        let before = model.workspace
        var corrupted = before; corrupted.selectedShopID = UUID()
        let bytes = try payload(corrupted)
        XCTAssertThrowsError(try LedgerModel.validatePayload(bytes))
        let store = try LedgerStore(url: url)
        try await store.save(payload: bytes, expectedRevision: model.revision, operationID: UUID(), savedAt: Date())
        await model.discardPendingSave()
        XCTAssertEqual(model.workspace, before); XCTAssertNotNil(model.error)
        let reopened = LedgerModel(databaseURL: url); await reopened.open()
        XCTAssertFalse(reopened.ready); XCTAssertNotNil(reopened.error)
        XCTAssertTrue(reopened.workspace.shops.isEmpty)
    }
}
