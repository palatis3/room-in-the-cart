import XCTest
import RecordArchive
import HouseholdClient
@testable import RoomInTheCart

final class RecordsDatePresentationTests: XCTestCase {
    func testUnknownSourceIsNotFormattedAsEpochInEitherLanguage() {
        XCTAssertEqual(RecordsDatePresentation.sourceSavedAt(0, locale: .init(identifier: "en_US")), "Source saved date not supplied")
        XCTAssertEqual(RecordsDatePresentation.sourceSavedAt(0, locale: .init(identifier: "es_US")), "Fecha de guardado de origen no indicada")
        for locale in [Locale(identifier: "en_US"), Locale(identifier: "es_US")] {
            XCTAssertFalse(RecordsDatePresentation.sourceSavedAt(0, locale: locale).contains("1970"))
            XCTAssertFalse(RecordsDatePresentation.exportedAt(0, locale: locale).contains("1970"))
            XCTAssertFalse(RecordsDatePresentation.recoveredAt(0, locale: locale).contains("1970"))
        }
    }
    func testRealExportTimeDoesNotBecomeUnknownSourceSaveTime() throws {
        let record = ArchiveRecord(id: "example", origin: "source", revision: "1", kind: .recipe, title: "Meal", savedAtMilliseconds: 0)
        let date = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-10T12:00:00Z"))
        let file = try ArchiveCodec.make(records: [record], kind: .personalRecovery, origin: "source", revision: "1", exportedAt: date)
        XCTAssertEqual(file.lastSavedAtMilliseconds, 0)
        XCTAssertEqual(file.payload.records[0].savedAtMilliseconds, 0)
        let export = RecordsDatePresentation.exportedAt(file.exportedAtMilliseconds, locale: .init(identifier: "en_US"))
        XCTAssertTrue(export.hasPrefix("File exported at: ")); XCTAssertTrue(export.contains("2026"))
        XCTAssertEqual(RecordsDatePresentation.sourceSavedAt(file.payload.records[0].savedAtMilliseconds, locale: .init(identifier: "en_US")), "Source saved date not supplied")
    }
    func testMixedArchiveKeepsEachUnknownVisibleInsteadOfAssigningAggregateDate() throws {
        let records = [ArchiveRecord(id: "unknown", origin: "source", revision: "1", kind: .recipe, title: "First", savedAtMilliseconds: 0),
                       ArchiveRecord(id: "known", origin: "source", revision: "1", kind: .recipe, title: "Second", savedAtMilliseconds: 1_799_884_800_000)]
        let file = try ArchiveCodec.make(records: records, kind: .personalRecovery, origin: "source", revision: "1")
        XCTAssertEqual(file.lastSavedAtMilliseconds, 1_799_884_800_000)
        let unknown = try XCTUnwrap(file.payload.records.first { $0.id == "unknown" })
        XCTAssertEqual(RecordsDatePresentation.sourceSavedAt(unknown.savedAtMilliseconds, locale: .init(identifier: "es_US")), "Fecha de guardado de origen no indicada")
    }
    func testRecoveryTimeUsesIndependentLabel() {
        let time: Int64 = 1_799_884_800_000
        XCTAssertTrue(RecordsDatePresentation.recoveredAt(time, locale: .init(identifier: "en_US")).hasPrefix("Copy recovered at: "))
        XCTAssertTrue(RecordsDatePresentation.recoveredAt(time, locale: .init(identifier: "es_US")).hasPrefix("Copia recuperada: "))
        XCTAssertTrue(RecordsDatePresentation.sourceSavedAt(time, locale: .init(identifier: "en_US")).hasPrefix("Source saved at: "))
    }
    func testLocalSaveHouseholdReadAndSelectedEncryptedBackupHaveDistinctBilingualLabels() {
        let time: Int64 = 1_799_884_800_000
        for (localeID, local, household, current, earlier) in [
            ("en_US", "Saved on this device: ", "Last read from household: ", "selected data from this version", "selected data from an earlier version"),
            ("es_US", "Guardado en este dispositivo: ", "Última consulta al hogar: ", "datos seleccionados de esta versión", "datos seleccionados de una versión anterior")
        ] {
            let locale = Locale(identifier: localeID)
            XCTAssertTrue(RecordsDatePresentation.localSavedAt(time, locale: locale).hasPrefix(local))
            XCTAssertTrue(RecordsDatePresentation.householdFetchedAt(time, locale: locale).hasPrefix(household))
            XCTAssertTrue(RecordsDatePresentation.encryptedBackupSavedAt(time, currentRevision: true, locale: locale).contains(current))
            XCTAssertTrue(RecordsDatePresentation.encryptedBackupSavedAt(time, currentRevision: false, locale: locale).contains(earlier))
            XCTAssertFalse(RecordsDatePresentation.localSavedAt(0, locale: locale).contains("1970"))
        }
    }

    @MainActor func testOnlyCompletedAuthorizedHouseholdReadsCarryFetchDates() async throws {
        let shop = UUID()
        let current = ArchiveRecord(id: shop.uuidString.lowercased(), origin: "shared-shop/family", revision: "current",
                                    kind: .sharedShop, title: "Current", savedAtMilliseconds: 0)
        let history = ArchiveRecord(id: current.id + "/history", origin: "shared-history/family", revision: "history",
                                    kind: .sharedHistory, title: "History", savedAtMilliseconds: 0)
        let currentID = RecordsToolsModel.selectionID(current), historyID = RecordsToolsModel.selectionID(history)
        let start = ArchiveCodec.milliseconds(Date())
        let complete = try await RecordsSnapshotProjection.liveSharedRecords(householdID: "family", shopID: shop,
            authorized: { true }, current: { current }, history: { history })
        let finish = ArchiveCodec.milliseconds(Date())
        XCTAssertEqual(Set(complete.householdFetchedAtMilliseconds.keys), [currentID, historyID])
        for time in complete.householdFetchedAtMilliseconds.values {
            XCTAssertGreaterThanOrEqual(time, start)
            XCTAssertLessThanOrEqual(time, finish)
        }
        XCTAssertEqual(complete.records.map(\.savedAtMilliseconds), [0, 0])
        let partial = try await RecordsSnapshotProjection.liveSharedRecords(householdID: "family", shopID: shop,
            authorized: { true }, current: { throw ClientError.transport }, history: { history })
        XCTAssertEqual(Set(partial.householdFetchedAtMilliseconds.keys), [historyID])
        let denied = try await RecordsSnapshotProjection.liveSharedRecords(householdID: "family", shopID: shop,
            authorized: { true }, current: { current }, history: { throw ClientError.accessEnded })
        XCTAssertTrue(denied.householdFetchedAtMilliseconds.isEmpty)
        XCTAssertTrue(RecordsSnapshotBatch(records: [current, history]).householdFetchedAtMilliseconds.isEmpty)
    }

    @MainActor func testRecoveredProvenanceUsesEmittedRevisionAndIndependentOwner() throws {
        let live = ArchiveRecord(id: "record", origin: "source", revision: "first", kind: .comparison,
                                 title: "Original", savedAtMilliseconds: 0, nativePayload: Data([1]))
        var edited = live
        edited.id = "child"; edited.revision = "edit"; edited.nativePayload = Data([2])
        var helper = edited
        helper.nativePayload = nil
        var helperOnly = helper
        helperOnly.id = "summary"
        var records = [live]
        let copies = RecordsSnapshotProjection.appendRecovered([
            ("redacted", [helper, helperOnly]), ("one", [live, edited]), ("two", [edited])
        ], to: &records)
        XCTAssertNil(copies[RecordsToolsModel.selectionID(live)])
        XCTAssertEqual(copies[RecordsToolsModel.selectionID(edited)], ["one", "two"])
        XCTAssertEqual(copies[RecordsToolsModel.selectionID(helperOnly)], ["redacted"])
        XCTAssertEqual(try RecordsSnapshotProjection.mergeForExport(records), [live, edited, helperOnly])
    }

}
