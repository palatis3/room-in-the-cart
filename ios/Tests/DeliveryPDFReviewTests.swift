import CoreDomain
import LocalStore
import UIKit
import XCTest
@testable import RoomInTheCart

@MainActor final class DeliveryPDFReviewTests: XCTestCase {
    private func document(_ lines: [String]) -> ExtractedReceiptDocument {
        .init(digest: Data(repeating: 4, count: 32), pages: [.init(id: 1, method: .pdfText,
            lines: lines.enumerated().map { .init(id: $0.offset + 1, text: $0.element) })])
    }

    func testMixedOrderRemainsLineSpecificAndUsesOriginalPutawayCoordinates() throws {
        let file = document(["Order #ABC-123", "Milk $3.00", "Eggs 12 count $4.00", "Hot hamburger $8.00",
                             "Frozen beef patties 4 count $5.00", "Burger $6.00", "Delivery fee $3.00",
                             "Tip $2.00", "Tax $1.00", "Promotion -$1.50", "Total $30.50"])
        let target = CaptureTarget(workspaceID: UUID(), containerID: UUID(), objectID: UUID(), revision: 1, kind: .receiptEvidence)
        var review = DeliveryPDFReview(document: file, origin: target.workspaceID)
        review.merchant = "Supermarket"
        let purchase = review.record(at: .now)
        XCTAssertEqual(purchase.order, "ABC-123")
        XCTAssertEqual(purchase.finalCents, 3050)
        XCTAssertEqual(purchase.lines.map(\.disposition), [.fridge, .fridge, .readyToEat, .freezer, .unresolved, .fee, .tip, .tax, .discount])
        XCTAssertEqual(purchase.lines.last?.cents, -150)
        XCTAssertNil(purchase.purchaseDate)
        XCTAssertNil(purchase.deliveryDate)
        XCTAssertThrowsError(try purchase.putaway(target: target, selected: [6]))
        XCTAssertThrowsError(try purchase.putaway(target: target, selected: [5]))
        let handoff = try purchase.putaway(target: target, selected: [1, 2, 4])
        let expected = try file.source(target: target, merchant: "Supermarket", stage: .finalInvoice,
            selection: [.init(page: 1, line: 2), .init(page: 1, line: 3), .init(page: 1, line: 5)], at: .now)
        XCTAssertEqual(handoff.documentLayoutID, expected.documentLayoutID)
        XCTAssertEqual(handoff.receiptLines.map(\.id), expected.receiptLines.map(\.id))
        XCTAssertEqual(handoff.receiptLines.map(\.originalText), ["Milk $3.00", "Eggs 12 count $4.00", "Frozen beef patties 4 count $5.00"])
    }

    func testSelectedPDFWithTypedTextLayerProvidesOneFinalDiningCharge() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("delivery.pdf")
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 350, height: 500))
        try renderer.writePDF(to: file) { context in
            context.beginPage()
            for (index, line) in ["Chipotle", "Order #ABC-123", "Burrito bowl $9.00", "Tip $1.00", "Total USD 10.00"].enumerated() {
                (line as NSString).draw(at: CGPoint(x: 20, y: 20 + index * 40), withAttributes: [.font: UIFont.systemFont(ofSize: 15)])
            }
        }
        let input = try await ReceiptDocumentBytes.picked(file)
        let document = try await ReceiptDocumentReader().extract(input)
        let receipt = DeliveryPDFReview(document: document, origin: UUID()).record(at: .now)
        XCTAssertEqual(receipt.merchant, "Chipotle")
        XCTAssertEqual(receipt.order, "ABC-123")
        XCTAssertEqual(receipt.finalCents, 1000)
        XCTAssertEqual(receipt.lines.map(\.disposition), [.dining, .tip])
    }

    func testDiningSpanishAndTotalOnly() {
        let meal = DeliveryPDFReview(document: document(["Chipotle", "Pedido #12345", "Burrito bowl $9.00", "Propina $1.00", "Total $10.00"]), origin: UUID())
        XCTAssertEqual(meal.merchant, "Chipotle")
        XCTAssertEqual(meal.rows.filter(\.included).map(\.evidence.disposition), [.dining, .tip])
        let total = DeliveryPDFReview(document: document(["Uber Eats", "Pedido #12345", "Total pagado $10,00"]), origin: UUID())
        XCTAssertEqual(total.total, "10.00")
        XCTAssertTrue(total.rows.filter(\.included).isEmpty)
        XCTAssertNil(DeliveryPDFReview.usdSuffix("Total CAD $10.00"))
        XCTAssertEqual(DeliveryPDFReview.suggest("Hamburguesa caliente $2,00", restaurant: false), .readyToEat)
        XCTAssertEqual(DeliveryPDFReview.suggest("Hamburguesa $2,00", restaurant: false), .unresolved)
    }
}
