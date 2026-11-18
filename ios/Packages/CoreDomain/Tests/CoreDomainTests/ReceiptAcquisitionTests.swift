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
