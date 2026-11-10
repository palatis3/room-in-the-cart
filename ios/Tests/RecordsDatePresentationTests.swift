import XCTest
import RecordArchive
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
}
