import XCTest
import HouseholdClient
import RecordArchive
@testable import RoomInTheCart

final class SharedRecordArchiveTests: XCTestCase {
    private func record() throws -> ArchiveRecord {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let bytes = try Data(contentsOf: root.appendingPathComponent("shared/fixtures/shared-records/partial-v2.json"))
        return try SharedRecordArchiveAdapter.make(SharedRecordWire.snapshot(from: bytes))
    }
    private func registry() throws -> RecoveryRegistry {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return try RecoveryRegistry(url: directory.appendingPathComponent("records.json"))
    }
    @MainActor func testEncryptedIndependentRoundtripReimportsOnceAndPreservesPartialFacts() async throws {
        let record = try record(), registry = try registry()
        try RecordsNativeCodec.validate(record)
        let envelope = try ArchiveCodec.make(records: [record], kind: .personalRecovery, origin: "selected-local-records", revision: "test")
        let key = EncryptedArchive.generateKey(), bytes = try EncryptedArchive.seal(envelope, key: key)
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("Unknown lunch wraps"))
        let reopened = try EncryptedArchive.open(bytes, key: key)
        let firstReview = try await registry.review(reopened)
        let first = try await registry.apply(firstReview)
        let secondReview = try await registry.review(reopened)
        let second = try await registry.apply(secondReview)
        XCTAssertEqual(first.insertedCount, 1); XCTAssertEqual(second.insertedCount, 0)
        XCTAssertEqual(first.records.map(\.id), second.records.map(\.id))
        let recovered = try SharedRecordArchiveAdapter.validate(XCTUnwrap(first.records.first).record)
        XCTAssertEqual(recovered.food.coverage?.status, .partial); XCTAssertNil(recovered.food.unbound.first?.transferred?.quantity)
        XCTAssertTrue(recovered.food.coverage?.allocatableUnboundFactIds.isEmpty == true)
    }
    @MainActor func testHelperProjectionCannotAccidentallySharePrivateSnapshot() throws {
        XCTAssertThrowsError(try ArchiveCodec.make(records: [record()], kind: .helperShop, origin: "helper", revision: "1"))
    }
    @MainActor func testRepeatedHelperExportFailuresRevealFreshOutcomesWithoutPublishingOrWritingPrivateData() async throws {
        let source = try record()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let manifest = directory.appendingPathComponent("records.json")
        let registry = try RecoveryRegistry(url: manifest)
        let existing = try ArchiveCodec.make(records: [source], kind: .personalRecovery, origin: source.origin, revision: source.revision)
        let existingReview = try await registry.review(existing)
        let saved = try await registry.apply(existingReview)
        let originalBytes = try Data(contentsOf: manifest)
        var reads = 0, validations = 0
        var refreshFails = false
        let model = RecordsToolsModel(registry: registry, snapshot: {
            reads += 1
            if refreshFails { throw ArchiveError.unavailable }
            return [source]
        }, validateNativePayload: {
            validations += 1
            try RecordsNativeCodec.validate($0)
        }, openRecovered: { _ in XCTFail("Export must not open recovered work") },
           deleteSource: { _ in XCTFail("Export must not delete or write the source") })
        await model.refresh(); model.selectAll()
        XCTAssertNil(model.actionOutcomeID)
        // A failed helper action must also clear a previously prepared private file.
        await model.prepareExport(.ownerText)
        XCTAssertNotNil(model.preparedDocument); XCTAssertTrue(model.preparedIsPrivate)
        var previousOutcome: UUID?
        for choice in [RecordsToolsModel.ExportChoice.helperText, .helperJSON] {
            await model.prepareExport(choice)
            XCTAssertEqual(model.error, .unsupportedProjection)
            let outcome = try XCTUnwrap(model.actionOutcomeID)
            XCTAssertNotEqual(outcome, previousOutcome, "Each repeated failure must reveal the result again")
            previousOutcome = outcome
            XCTAssertNil(model.preparedDocument, "No private document may remain available to save or share")
            XCTAssertNil(model.status); XCTAssertFalse(model.busy)
            XCTAssertEqual(model.currentRecords, [source])
            XCTAssertEqual(model.selectedIDs, [RecordsToolsModel.selectionID(source)])
            XCTAssertEqual(model.recoveredRecords, saved.records)
            let persisted = try await registry.refreshList()
            XCTAssertEqual(persisted, saved.records)
            XCTAssertEqual(try Data(contentsOf: manifest), originalBytes, "Failed export must not write the recovery registry")
        }
        XCTAssertEqual(reads, 4); XCTAssertEqual(validations, 3)
        // A background refresh failure still does not move the user's focus.
        refreshFails = true
        await model.refresh()
        XCTAssertEqual(model.error, .unavailable); XCTAssertNil(model.actionOutcomeID)
        XCTAssertNil(model.preparedDocument)
        XCTAssertEqual(try Data(contentsOf: manifest), originalBytes)
    }
    @MainActor func testUnknownAuthorityAndForgedArchiveIdentityRejectBeforeRecovery() throws {
        var record = try record(), object = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(record.nativePayload)) as? [String: Any])
        object["authorityEpoch"] = 8; record.nativePayload = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        XCTAssertThrowsError(try RecordsNativeCodec.validate(record))
        record = try self.record(); record.origin = "shared-shop/forged"; XCTAssertThrowsError(try SharedRecordArchiveAdapter.validate(record))
    }
    @MainActor func testConflictingSameRevisionIsQuarantinedAndKnownErasureBlocksOldCopies() async throws {
        let record = try record(), registry = try registry()
        let original = try ArchiveCodec.make(records: [record], kind: .personalRecovery, origin: record.origin, revision: record.revision)
        let originalReview = try await registry.review(original)
        _ = try await registry.apply(originalReview)
        var changed = record; changed.title += " changed"
        let conflict = try ArchiveCodec.make(records: [changed], kind: .personalRecovery, origin: record.origin, revision: record.revision)
        let review = try await registry.review(conflict)
        XCTAssertEqual(review.rows.first?.disposition, .quarantined); XCTAssertFalse(review.canApply)
        try await registry.registerErasedSources([.init(origin: record.origin, recordID: record.id)])
        let erased = try await registry.review(original)
        XCTAssertEqual(erased.rows.first?.disposition, .erased)
        let remaining = await registry.list()
        XCTAssertTrue(remaining.isEmpty)
    }
    @MainActor func testReadableOwnerCopyKeepsOriginalWordingAndUnknownsInBothLanguages() throws {
        let value = try record()
        let english = try SharedRecordArchiveAdapter.readable(value, locale: Locale(identifier: "en_US"))
        let spanish = try SharedRecordArchiveAdapter.readable(value, locale: Locale(identifier: "es_US"))
        XCTAssertTrue(english.contains("Unknown lunch wraps")); XCTAssertTrue(english.contains("Unbound; not available as free supply"))
        XCTAssertTrue(spanish.contains("Unknown lunch wraps")); XCTAssertTrue(spanish.contains("Sin determinar"))
        XCTAssertTrue(spanish.contains("Exact family restriction"))
        XCTAssertFalse(english.contains("authorityEpoch")); XCTAssertFalse(spanish.contains("previewId"))
    }

}
