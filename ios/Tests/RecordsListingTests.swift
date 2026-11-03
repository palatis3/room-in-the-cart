import XCTest
import CoreDomain
import LocalStore
import RecordArchive
@testable import RoomInTheCart

final class RecordsListingTests: XCTestCase {
    @MainActor func testUnreadableNativeSiblingsAreReportedAndExcludedFromHealthyExportWithoutChangingBytes() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ComparisonStore(url: directory.appendingPathComponent("comparisons.sqlite"))
        var draft = ComparisonDraft(); draft.item = "Readable rice"; draft.needed = "2"
        draft.aQuantity = "1"; draft.aPrice = "2"; draft.bQuantity = "2"; draft.bPrice = "3"
        let valid = try JSONEncoder().encode(SavedPayload(draft: draft))
        let malformedID = UUID(), futureID = UUID()
        let malformed = Data("{broken".utf8)
        var futureDraft = draft; futureDraft.id = futureID
        let future = try JSONEncoder().encode(SavedPayload(formatVersion: 99, draft: futureDraft))
        try await store.save(id: draft.id, title: draft.item, payload: valid, savedAt: Date())
        try await store.save(id: malformedID, title: "Unreadable saved draft", payload: malformed, savedAt: Date())
        try await store.save(id: futureID, title: "Future native format", payload: future, savedAt: Date())
        let original = try await store.list()
        let registry = try RecoveryRegistry(url: directory.appendingPathComponent("registry.json"))
        let origin = "comparisons/" + store.workspaceID.uuidString
        var unavailable: [RecordsUnavailableRecord] = []
        let model = RecordsToolsModel(registry: registry, snapshot: {
            let batch = RecordsSnapshotProjection.project(try await store.listing(), origin: origin) { saved in
                let payload = try RecordsNativeCodec.comparison(saved.payload)
                guard payload.draft.id == saved.id else { throw ArchiveError.invalidIdentity }
                let bytes = try RecordsNativeCodec.canonical(payload)
                return ArchiveRecord(id: saved.id.uuidString, origin: origin, revision: ArchiveCodec.digest(bytes), kind: .comparison,
                    title: payload.draft.item, savedAtMilliseconds: 100, helperLines: [HelperLine(label: payload.draft.item)], nativePayload: bytes)
            }
            unavailable = batch.unavailable
            return batch.records
        }, validateNativePayload: { try RecordsNativeCodec.validate($0) }, openRecovered: { _ in }, unavailableRecords: { unavailable })
        await model.refresh()
        XCTAssertEqual(model.currentRecords.map(\.id), [draft.id.uuidString])
        XCTAssertEqual(Set(model.unavailableRecords.map(\.recordID)), [malformedID.uuidString, futureID.uuidString])
        XCTAssertTrue(model.unavailableRecords.allSatisfy { $0.reason == .invalidNative })
        model.selectAll()
        await model.prepareExport(.helperJSON)
        let data = try XCTUnwrap(model.preparedDocument?.data)
        let exported = try ArchiveCodec.decode(data)
        XCTAssertEqual(exported.payload.records.map(\.id), [draft.id.uuidString])
        XCTAssertEqual(model.unavailableRecords.count, 2, "Omitted records stay visible after preparing a successful file")
        let after = try await store.list()
        XCTAssertEqual(after, original, "Projection failures never rewrite or delete the original saved bytes")
        try await store.close()
        await model.prepareExport(.helperJSON)
        XCTAssertNil(model.preparedDocument, "A database-level failure cannot become a successful partial export")
        XCTAssertNotNil(model.error)
    }
}
