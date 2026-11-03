import XCTest
import CoreDomain
import LocalStore
import SQLite3
@testable import RoomInTheCart

final class AppModelTests: XCTestCase {
    @MainActor
    func testDamagedComparisonDoesNotHideHealthyRecordAfterRelaunch() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("local.sqlite")
        let store = try ComparisonStore(url: url)
        let draft = makeDraft(unknownSecondYield: false)
        let healthy = try await store.save(id: draft.id, title: draft.item,
            payload: JSONEncoder().encode(SavedPayload(draft: draft)), savedAt: Date())
        let damagedID = UUID()
        try await store.save(id: damagedID, title: "Damaged", payload: Data([1]), savedAt: Date())
        try await store.close()
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        let query = "DROP TRIGGER immutable_revision_update; UPDATE comparison_revisions SET envelope = x'7B' WHERE comparison_id = '\(damagedID.uuidString)'"
        let status = sqlite3_exec(db, query, nil, nil, nil)
        sqlite3_close(db)
        XCTAssertEqual(status, SQLITE_OK)
        let before = try Data(contentsOf: url)
        let app = AppModel(databaseURL: url)
        await app.open()
        XCTAssertTrue(app.ready)
        XCTAssertNil(app.error)
        XCTAssertEqual(app.records, [healthy])
        XCTAssertEqual(app.unavailableRecords.map(\.id), [damagedID])
        XCTAssertEqual(try app.decode(try XCTUnwrap(app.records.first)), draft)
        await app.refresh()
        XCTAssertEqual(app.unavailableRecords.count, 1)
        try await app.store?.close()
        XCTAssertEqual(try Data(contentsOf: url), before)
    }

    @MainActor
    func testDecimalQuantityParsingIsExactAndRetainsSourceLiteral() throws {
        let cases: [(String, Int64, Int64)] = [
            ("0", 0, 1), ("0.1", 1, 10), ("12.5000", 25, 2),
            ("0.000001", 1, 1_000_000), (" 001.2500 \n", 5, 4)
        ]
        for (literal, numerator, denominator) in cases {
            let quantity = try XCTUnwrap(ComparisonModel.quantity(literal, .kilogram))
            XCTAssertEqual(quantity.amount, try Rational(numerator, denominator), literal)
            XCTAssertEqual(quantity.originalLiteral, literal)
            XCTAssertEqual(quantity.unit, .kilogram)
        }
        XCTAssertNil(try ComparisonModel.rational(" \n\t"))
        XCTAssertNil(try ComparisonModel.quantity("", .count))
    }

    @MainActor
    func testParserRejectsSignsGroupingExponentsAndMalformedNumbers() {
        let invalid = ["-1", "+1", "−1", "1,000", "1,25", "1 000", "1e3", "1E-3",
                       ".5", "1.", "1.2.3", "NaN", "Infinity", "$2.00", "1/2", "2 cups",
                       "0.0000001", "１２", "١٢", "1\0", "1234567890123456789012345"]
        for literal in invalid {
            XCTAssertThrowsError(try ComparisonModel.rational(literal), literal)
            XCTAssertThrowsError(try ComparisonModel.money(literal), literal)
        }
    }

    @MainActor
    func testUSDParserUsesExactCentsAndRejectsMoreThanTwoDecimalPlaces() throws {
        let cases: [(String, Int64)] = [("0", 0), ("0.01", 1), ("0.10", 10), ("3.49", 349), (" 003.40 ", 340)]
        for (literal, cents) in cases {
            XCTAssertEqual(try ComparisonModel.money(literal), Money(minorUnits: cents), literal)
        }
        for literal in ["0.001", "3.499", "1.000", "1.230", "0.000000"] {
            XCTAssertThrowsError(try ComparisonModel.money(literal), literal)
        }
        XCTAssertNil(try ComparisonModel.money("  "))
    }

    @MainActor
    func testKnownComparisonSaveCloseReopenRecomputesIdenticalAnswer() async throws {
        try await assertSaveReopen(unknownSecondYield: false)
    }

    @MainActor
    func testUnknownComparisonSaveCloseReopenStaysUnresolved() async throws {
        try await assertSaveReopen(unknownSecondYield: true)
    }

    @MainActor
    func testInvalidEditClearsPreviousAnswer() {
        let model = ComparisonModel(draft: makeDraft(unknownSecondYield: false))
        model.compare()
        XCTAssertNotNil(model.result)
        model.draft.needed = "twelve"
        model.compare()
        XCTAssertNotNil(model.error)
        XCTAssertNil(model.result, "A prior answer cannot describe a draft whose current quantity is invalid")
    }

    @MainActor
    func testFailedSaveRetainsDraftAndComputedResult() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ComparisonStore(url: directory.appendingPathComponent("local.sqlite"))
        try await store.close()
        let original = makeDraft(unknownSecondYield: true)
        let model = ComparisonModel(draft: original)
        model.compare()
        let result = model.result

        await model.save(in: store)

        XCTAssertEqual(model.draft, original)
        XCTAssertEqual(model.result, result)
        XCTAssertNotNil(model.error)
        XCTAssertNil(model.savedAt)
        XCTAssertFalse(model.saving)
    }

    @MainActor
    func testUnavailableStoreLeavesEditableDraftIntact() async {
        let original = makeDraft(unknownSecondYield: false)
        let model = ComparisonModel(draft: original)
        await model.save(in: nil)
        XCTAssertEqual(model.draft, original)
        XCTAssertNotNil(model.error)
        XCTAssertNil(model.savedAt)
        XCTAssertFalse(model.saving)
    }

    @MainActor
    func testSavedPayloadRejectsFutureFormatAndDifferentRecordIdentity() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = AppModel(databaseURL: directory.appendingPathComponent("local.sqlite"))
        await app.open()
        let store = try XCTUnwrap(app.store)
        let draft = makeDraft(unknownSecondYield: false)
        let future = SavedPayload(formatVersion: 2, draft: draft)
        let futureRecord = try await store.save(id: draft.id, title: draft.item,
                                               payload: JSONEncoder().encode(future), savedAt: Date())
        XCTAssertThrowsError(try app.decode(futureRecord))
        let mismatch = try await store.save(id: UUID(), title: draft.item,
                                           payload: JSONEncoder().encode(SavedPayload(draft: draft)), savedAt: Date())
        XCTAssertThrowsError(try app.decode(mismatch))
        try await store.close()
    }

    @MainActor
    func testLegacyDraftOnlyV1RemainsReadableWithoutRewritingRecord() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("local.sqlite")
        let store = try ComparisonStore(url: databaseURL)
        let draft = makeDraft(unknownSecondYield: true)
        // This fixture encodes only the two original v1 keys, rather than relying on
        // the current SavedPayload encoder to keep omitting new optional properties.
        struct LegacyPayload: Encodable {
            let formatVersion: Int
            let draft: ComparisonDraft
        }
        let bytes = try JSONEncoder().encode(LegacyPayload(formatVersion: 1, draft: draft))
        let saved = try await store.save(id: draft.id, title: draft.item, payload: bytes,
                                         savedAt: Date(timeIntervalSince1970: 1_700_000_000))
        try await store.close()

        let app = AppModel(databaseURL: databaseURL)
        await app.open()
        XCTAssertTrue(app.ready)
        let record = try XCTUnwrap(app.records.first)
        XCTAssertEqual(try app.decode(record), draft)
        let readPayload = try JSONDecoder().decode(SavedPayload.self, from: record.payload)
        XCTAssertNil(readPayload.calculationVersion)
        XCTAssertNil(readPayload.normalizedRequest)
        XCTAssertNil(readPayload.answer)
        XCTAssertNil(readPayload.roundingPolicy)
        XCTAssertEqual(record, saved)
        let reopenedStore = try XCTUnwrap(app.store)
        let retained = try await reopenedStore.load(id: draft.id)
        XCTAssertEqual(retained, saved)
        try await reopenedStore.close()
    }

    @MainActor
    func testUnsupportedCalculationVersionIsRejectedWithoutMutation() async throws {
        try await assertRejectedSnapshotRetained { payload in
            payload.calculationVersion = "pack-future/unknown-unit-table"
        }
    }

    @MainActor
    func testAnswerFromDifferentPriceIsRejectedWithoutDeletion() async throws {
        try await assertRejectedSnapshotRetained { payload in
            var changed = payload.draft
            changed.aPrice = "9.99"
            payload.answer = try PackComparison.evaluate(ComparisonModel(draft: changed).request())
        }
    }

    @MainActor
    func testSnapshotDraftMismatchIsRejectedWithoutDeletion() async throws {
        try await assertRejectedSnapshotRetained { payload in
            payload.draft.needed = "24"
        }
    }

    @MainActor
    func testNormalizedRequestMismatchIsRejectedWithoutDeletion() async throws {
        try await assertRejectedSnapshotRetained { payload in
            var changed = payload.draft
            changed.aPrice = "9.99"
            payload.normalizedRequest = try ComparisonModel(draft: changed).request()
        }
    }

    @MainActor
    private func assertRejectedSnapshotRetained(_ change: (inout SavedPayload) throws -> Void) async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = AppModel(databaseURL: directory.appendingPathComponent("local.sqlite"))
        await app.open()
        let store = try XCTUnwrap(app.store)
        let draft = makeDraft(unknownSecondYield: false)
        let request = try ComparisonModel(draft: draft).request()
        var payload = SavedPayload(draft: draft,
                                   calculationVersion: SavedPayload.currentCalculationVersion,
                                   normalizedRequest: request,
                                   answer: try PackComparison.evaluate(request),
                                   roundingPolicy: "whole-packs-ceiling; USD-cents-exact; per-pack-ceiling-floor")
        try change(&payload)
        let saved = try await store.save(id: draft.id, title: draft.item,
                                         payload: JSONEncoder().encode(payload),
                                         savedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let before = try await store.list()
        XCTAssertThrowsError(try app.decode(saved))
        await app.refresh()
        XCTAssertEqual(app.records, before)
        let retained = try await store.load(id: draft.id)
        XCTAssertEqual(retained, saved)
        try await store.close()
    }

    @MainActor
    private func assertSaveReopen(unknownSecondYield: Bool) async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("local.sqlite")
        let app = AppModel(databaseURL: databaseURL)
        await app.open()
        XCTAssertTrue(app.ready)
        XCTAssertNil(app.error)
        let store = try XCTUnwrap(app.store)
        let workspace = store.workspaceID
        let draft = makeDraft(unknownSecondYield: unknownSecondYield)
        let fixedTime = Date(timeIntervalSince1970: 1_700_000_000)
        let model = ComparisonModel(draft: draft, clock: { fixedTime })
        model.compare()
        XCTAssertNil(model.error)
        let originalResult = try XCTUnwrap(model.result)
        XCTAssertEqual(originalResult.scope, .itemOnly)
        XCTAssertEqual(originalResult.offerA.packsToBuy, 2)
        XCTAssertEqual(originalResult.offerA.totalCost, Money(minorUnits: 698))
        if unknownSecondYield {
            XCTAssertTrue(originalResult.offerB.issues.contains(.usableQuantityUnknown))
            XCTAssertNil(originalResult.offerB.packsToBuy)
            XCTAssertNil(originalResult.offerB.totalCost)
            XCTAssertNil(originalResult.preferredOfferID)
        } else {
            XCTAssertTrue(originalResult.offerA.isResolved)
            XCTAssertTrue(originalResult.offerB.isResolved)
            XCTAssertEqual(originalResult.preferredOfferID, "b")
        }

        await model.save(in: store)
        XCTAssertNil(model.error)
        XCTAssertEqual(model.savedAt, fixedTime)
        XCTAssertFalse(model.saving)
        XCTAssertEqual(model.draft, draft)
        await app.refresh()
        XCTAssertEqual(app.records.count, 1)
        let record = try XCTUnwrap(app.records.first)
        XCTAssertEqual(record.id, draft.id)
        XCTAssertEqual(record.savedAt, fixedTime)
        XCTAssertEqual(record.revision, 1)
        let payload = try JSONDecoder().decode(SavedPayload.self, from: record.payload)
        XCTAssertEqual(payload.formatVersion, 1)
        XCTAssertEqual(payload.draft, draft)
        XCTAssertEqual(payload.calculationVersion, SavedPayload.currentCalculationVersion)
        XCTAssertEqual(payload.roundingPolicy, "whole-packs-ceiling; USD-cents-exact; per-pack-ceiling-floor")
        XCTAssertEqual(payload.answer, originalResult)
        let normalized = try XCTUnwrap(payload.normalizedRequest)
        XCTAssertEqual(normalized, try model.request())
        XCTAssertEqual(normalized.needed?.amount, try Rational(12))
        XCTAssertEqual(normalized.needed?.originalLiteral, " 12.000 ")
        XCTAssertEqual(normalized.confirmedAtHome?.amount, .zero)
        XCTAssertEqual(normalized.protectedAmount?.amount, try Rational(2))
        XCTAssertEqual(normalized.offerA.usableQuantity?.amount, try Rational(8))
        XCTAssertEqual(normalized.offerA.price?.minorUnits, 349)
        XCTAssertEqual(normalized.offerB.price?.minorUnits, 450)
        XCTAssertEqual(normalized.itemCap?.minorUnits, 3_000)
        if unknownSecondYield { XCTAssertNil(normalized.offerB.usableQuantity) }
        else { XCTAssertEqual(normalized.offerB.usableQuantity?.amount, try Rational(12)) }
        try await store.close()

        let reopened = AppModel(databaseURL: databaseURL)
        await reopened.open()
        XCTAssertTrue(reopened.ready)
        XCTAssertNil(reopened.error)
        XCTAssertEqual(reopened.store?.workspaceID, workspace)
        XCTAssertEqual(reopened.records, [record])
        let restoredDraft = try reopened.decode(XCTUnwrap(reopened.records.first))
        XCTAssertEqual(restoredDraft, draft)
        let restored = ComparisonModel(draft: restoredDraft, clock: { fixedTime.addingTimeInterval(30) })
        restored.compare()
        XCTAssertNil(restored.error)
        XCTAssertEqual(restored.result, originalResult)
        await restored.save(in: reopened.store)
        await reopened.refresh()
        XCTAssertEqual(reopened.records, [record], "An unchanged retry must preserve its original evidence time and revision")
        let reopenedStore = try XCTUnwrap(reopened.store)
        try await reopenedStore.close()
    }

    private func makeDraft(unknownSecondYield: Bool) -> ComparisonDraft {
        var draft = ComparisonDraft()
        draft.item = "Tortillas — family wraps"
        draft.needed = " 12.000 "
        draft.stock = "00.00"
        draft.protected = "2.0"
        draft.cap = "30.00"
        draft.aLabel = "Eight usable wraps"
        draft.aQuantity = "08.000"
        draft.aPrice = "3.49"
        draft.bLabel = "Twelve-wrap option"
        draft.bQuantity = unknownSecondYield ? "" : "12.00"
        draft.bPrice = "04.50"
        return draft
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AppModelTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
