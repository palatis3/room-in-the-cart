import XCTest
import CoreDomain
import LocalStore
import RecordArchive
import HouseholdClient
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
        let model = RecordsToolsModel(registry: registry, snapshot: {
            try await RecordsSnapshotProjection.project(store.listing(), origin: origin) { saved in
                let payload = try RecordsNativeCodec.comparison(saved.payload)
                guard payload.draft.id == saved.id else { throw ArchiveError.invalidIdentity }
                let bytes = try RecordsNativeCodec.canonical(payload)
                return ArchiveRecord(id: saved.id.uuidString, origin: origin, revision: ArchiveCodec.digest(bytes), kind: .comparison,
                    title: payload.draft.item, savedAtMilliseconds: 100, helperLines: [HelperLine(label: payload.draft.item)], nativePayload: bytes)
            }
        }, validateNativePayload: { try RecordsNativeCodec.validate($0) }, openRecovered: { _ in })
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

extension RecordsListingTests {
    @MainActor func testRetiredLiveHistoryWithdrawsItsPreviewAndKeepsCurrentPickupAndIndependentCopy() async throws {
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("shared/fixtures/shared-records")
        let current = try SharedRecordArchiveAdapter.make(SharedRecordWire.snapshot(from: Data(contentsOf: fixtures.appendingPathComponent("partial-v2.json"))))
        let page = try SharedRecordHistoryWire.snapshot(from: Data(contentsOf: fixtures.appendingPathComponent("history-v1.json")))
        let history = try SharedHistoryArchiveAdapter.make(page)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let registry = try RecoveryRegistry(url: directory.appendingPathComponent("registry.json"))
        let saved = try ArchiveCodec.make(records: [history], kind: .personalRecovery, origin: "recovery", revision: "1")
        _ = try await registry.apply(registry.review(saved))
        var retired = false
        var holdValidation = false
        let validating = expectation(description: "Earlier export has read live history")
        var resume: CheckedContinuation<Void, Never>?
        weak var active: RecordsToolsModel?
        func makeModel() -> RecordsToolsModel {
            return RecordsToolsModel(registry: registry, snapshot: {
                var batch = try await RecordsSnapshotProjection.liveSharedRecords(
                    householdID: page.record.origin.householdId.string, shopID: page.record.origin.shopId.uuid,
                    authorized: { true }, accessDenied: { XCTFail("The shopper still has access") },
                    historyRetired: { active?.liveHistoryRetired($0) }, current: { current }, history: {
                        guard !retired else { throw ClientError.service(status: 404, code: "shared_history_retired", correlationID: nil, retryAfter: nil) }
                        return history
                    })
                let local = try await registry.refreshList().map(\.record)
                batch.records = try RecordsSnapshotProjection.mergeForExport(batch.records + local)
                return batch
            }, validateNativePayload: { record in
                try RecordsNativeCodec.validate(record)
                if holdValidation {
                    holdValidation = false
                    await withCheckedContinuation { resume = $0; validating.fulfill() }
                }
            }, openRecovered: { _ in })
        }
        let model = makeModel()
        active = model
        await model.refresh()
        model.selectAll()
        await model.prepareExport(.ownerText)
        XCTAssertNotNil(model.preparedDocument)
        retired = true
        await model.refresh()
        XCTAssertNil(model.preparedDocument)
        XCTAssertEqual(model.selectedIDs, [RecordsToolsModel.selectionID(current)])
        XCTAssertEqual(model.sourceListing.liveSharedRecordIDs, model.selectedIDs)
        XCTAssertEqual(model.unavailableRecords.map(\.reason), [.retiredHistory])
        XCTAssertTrue(model.currentRecords.contains(history), "The independent recovered copy remains available")
        await model.prepareExport(.ownerText)
        let currentFile = try XCTUnwrap(model.preparedDocument?.data)
        await model.refresh()
        XCTAssertEqual(model.preparedDocument?.data, currentFile)
        model.selectedIDs = [RecordsToolsModel.selectionID(history)]
        await model.prepareExport(.ownerText)
        XCTAssertNotNil(model.preparedDocument, "The user can select the independent recovered history")

        // A previously started read may complete after the retirement response.
        // A fresh model simulates a second visit before either request has completed.
        retired = false
        let competing = makeModel()
        active = competing
        await competing.refresh()
        competing.selectAll()
        holdValidation = true
        let export = Task { await competing.prepareExport(.ownerText) }
        await fulfillment(of: [validating], timeout: 2)
        retired = true
        await competing.refresh()
        resume?.resume()
        await export.value
        XCTAssertNil(competing.preparedDocument)
        XCTAssertEqual(competing.error, .staleReview)
        XCTAssertEqual(competing.sourceListing.liveSharedRecordIDs, [RecordsToolsModel.selectionID(current)])
    }
}
