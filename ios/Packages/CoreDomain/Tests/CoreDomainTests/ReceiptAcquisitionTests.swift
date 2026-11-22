import XCTest
@testable import CoreDomain

final class ReceiptAcquisitionTests: XCTestCase {
    func testExactEvidenceAndConfirmedTransactionIdentifyALineIndependentlyOfFoodAndPrice() {
        let draft = UUID(), photo = Data(repeating: 0x47, count: 32)
        let manual = ReceiptAcquisition.receiptID(merchant: "Market", transactionReference: nil, imageDigest: nil, draftID: draft)
        XCTAssertEqual(manual, draft)
        let image = ReceiptAcquisition.receiptID(merchant: "Market", transactionReference: nil, imageDigest: photo, draftID: draft)
        XCTAssertEqual(image, ReceiptAcquisition.receiptID(merchant: "Mercado", transactionReference: nil, imageDigest: photo, draftID: UUID()))
        let first = ReceiptAcquisition.receiptID(merchant: "Market", transactionReference: "007", imageDigest: photo, draftID: draft)
        let rescan = ReceiptAcquisition.receiptID(merchant: " MARKET ", transactionReference: "007", imageDigest: nil, draftID: UUID())
        XCTAssertEqual(first, rescan)
        XCTAssertNotEqual(first, ReceiptAcquisition.receiptID(merchant: "Market", transactionReference: "008", imageDigest: photo, draftID: draft))
        XCTAssertNotEqual(ReceiptAcquisition.lineID(receiptID: first, ordinal: 0), ReceiptAcquisition.lineID(receiptID: first, ordinal: 1))
    }

    func testPurchaseDaySurvivesReopenAndCorrectionAcrossTimeZonesWithoutDatingLegacyReceipts() throws {
        let day = try MealDay(year: 2026, month: 11, day: 20, timeZoneIdentifier: "America/New_York")
        var eastern = Calendar(identifier: .gregorian)
        eastern.timeZone = try XCTUnwrap(TimeZone(identifier: day.timeZoneIdentifier))
        let midnight = eastern.startOfDay(for: try XCTUnwrap(day.date))
        let quantity = Quantity(amount: .one, unit: .count, originalLiteral: "1")
        let receipt = ReceiptAcquisition(receiptID: UUID(), ordinal: 0, lotID: UUID(), foodID: UUID(), merchant: "Market",
            purchaseDate: midnight, transactionReference: nil, imageDigest: nil, originalLine: "Beans", name: "Beans",
            received: quantity, usable: quantity, paidLineTotal: nil, stock: .added(location: .cupboard), purchaseDay: day)
        let data = try JSONEncoder().encode(receipt)
        let reopened = try JSONDecoder().decode(ReceiptAcquisition.self, from: data)
        try reopened.validate()
        XCTAssertEqual(try MealDay(date: midnight, timeZoneIdentifier: "America/Los_Angeles").iso8601, "2026-11-19")
        let correction = try reopened.correctingPaidTotal(Money(decimal: "2.10"))
        XCTAssertEqual(correction.purchaseDay?.iso8601, "2026-11-20")
        guard case .paidReceipt(let evidence) = try PrivatePriceEvidence(receipt: correction).source else { return XCTFail() }
        XCTAssertEqual(evidence.purchaseDay, day)

        var oldJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        oldJSON.removeValue(forKey: "purchaseDay")
        let old = try JSONDecoder().decode(ReceiptAcquisition.self, from: JSONSerialization.data(withJSONObject: oldJSON))
        try old.validate()
        var western = Calendar(identifier: .gregorian)
        western.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let samePrintedDay = try XCTUnwrap(western.date(from: DateComponents(year: 2026, month: 11, day: 20)))
        let westernDay = try MealDay(date: samePrintedDay, timeZoneIdentifier: western.timeZone.identifier)
        XCTAssertTrue(reopened.matchesPurchaseDate(samePrintedDay, day: westernDay))
        XCTAssertFalse(reopened.matchesPurchaseDate(midnight, day: try MealDay(date: midnight, timeZoneIdentifier: western.timeZone.identifier)))
        XCTAssertEqual(old.purchaseDate, midnight)
        XCTAssertTrue(old.matchesPurchaseDate(midnight, day: nil))
        XCTAssertFalse(old.matchesPurchaseDate(samePrintedDay, day: westernDay))
        XCTAssertNil(try old.correctingPaidTotal(Money(decimal: "2.10")).purchaseDay)
    }

    func testAdditionalPrintedDocumentRetainsItsOwnOrdinalAcrossArchivalAndPriceCorrection() throws {
        let receipt = UUID(), firstDocument = UUID(), secondDocument = UUID()
        let quantity = Quantity(amount: try Rational(1), unit: .count, originalLiteral: "1")
        let row = ReceiptAcquisition(receiptID: receipt, ordinal: 0, lotID: UUID(), foodID: UUID(), merchant: "Market",
            purchaseDate: Date(timeIntervalSince1970: 1_790_000_000), transactionReference: nil, imageDigest: Data(repeating: 1, count: 32),
            originalLine: "Beans", name: "Beans", received: quantity, usable: quantity, paidLineTotal: nil, stock: .added(location: .cupboard),
            documentLine: .init(method: .pdfText, stage: .finalInvoice, page: 1, line: 1), lineDocumentID: firstDocument)
        try row.validate()
        XCTAssertNotEqual(row.lineID, ReceiptAcquisition.lineID(receiptID: receipt, ordinal: 0))
        XCTAssertNotEqual(row.lineID, ReceiptAcquisition.lineID(receiptID: receipt, ordinal: 0, document: secondDocument))
        let decoded = try JSONDecoder().decode(ReceiptAcquisition.self, from: JSONEncoder().encode(row))
        XCTAssertEqual(decoded, row)
        let corrected = try decoded.correctingPaidTotal(Money(decimal: "1.25"))
        XCTAssertEqual(corrected.lineID, row.lineID)
        XCTAssertEqual(corrected.lineDocumentID, firstDocument)
        XCTAssertEqual(corrected.supersedesID, row.id)
    }

    func testWeightedFoodWithUnknownPricePreservesSourceAndImmutableCorrection() throws {
        let received = Quantity(amount: try Rational(3, 2), unit: .kilogram, originalLiteral: "1.5")
        let usable = Quantity(amount: try Rational(5, 4), unit: .kilogram, originalLiteral: "1.25")
        let first = ReceiptAcquisition(receiptID: UUID(), ordinal: 3, lotID: UUID(), foodID: UUID(), merchant: "Mercado",
            purchaseDate: Date(timeIntervalSince1970: 1_790_000_000), transactionReference: nil, imageDigest: nil,
            originalLine: "PLAT. KG", name: "Plátanos", received: received, usable: usable, paidLineTotal: nil, stock: .added(location: .cupboard))
        try first.validate()
        let correction = try first.correctingPaidTotal(Money(decimal: "3.15"))
        XCTAssertEqual(correction.supersedesID, first.id)
        XCTAssertEqual(correction.revision, 2)
        XCTAssertEqual(correction.received, received)
        XCTAssertEqual(correction.usable, usable)
        XCTAssertEqual(correction.originalLine, first.originalLine)
        XCTAssertEqual(correction.lotID, first.lotID)
        XCTAssertNil(first.paidLineTotal)
        XCTAssertThrowsError(try correction.correctingPaidTotal(correction.paidLineTotal))
        let invalid = ReceiptAcquisition(receiptID: first.receiptID, ordinal: 3, lotID: first.lotID, foodID: first.foodID, merchant: first.merchant,
            purchaseDate: first.purchaseDate, transactionReference: nil, imageDigest: nil, originalLine: first.originalLine,
            name: first.name, received: usable, usable: received, paidLineTotal: nil, stock: first.stock)
        XCTAssertThrowsError(try invalid.validate())
    }
}
