import CoreDomain
import HouseholdClient
import PDFKit
import UIKit
import XCTest
@testable import RoomInTheCart

@MainActor final class ReceiptDocumentTests: XCTestCase {
    func testLocalReceiptPhotoOffersPrintedFieldsWithoutClaimingReceivedUsableOrPaid() async throws {
        let bounds = CGRect(x: 0, y: 0, width: 1100, height: 280)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(bounds: bounds, format: format).image { _ in
            UIColor.white.setFill(); UIRectFill(bounds)
            for (wording,y) in [("Purchase date: 2024-11-17",15),("FROZEN PEAS 2 CT USD 6.50",96),("SERVICE FEE USD 1.20",177)] {
                (wording as NSString).draw(at: .init(x: 22, y: y), withAttributes: [.font: UIFont.systemFont(ofSize: 52), .foregroundColor: UIColor.black])
            }
        }
        let document = try await ReceiptDocumentReader().extract(.init(data: XCTUnwrap(image.pngData()), kind: .image))
        let rows = try XCTUnwrap(document.pages.first?.lines)
        XCTAssertEqual(rows.count, 3)
        let selected = Set(rows.map { ExtractedReceiptDocument.Selection(page: 1, line: $0.id) })
        let target = CaptureTarget(workspaceID: UUID(), containerID: UUID(), objectID: UUID(), revision: 1, kind: .receiptEvidence)
        let source = try document.source(target: target, merchant: "Market", stage: .receipt, selection: selected, at: Date())
        var draft = try ReceiptImportDraft(source: source)
        XCTAssertNotNil(draft.printedDate); XCTAssertFalse(draft.dateConfirmed)
        XCTAssertTrue(draft.selectedLines.isEmpty)
        let index = try XCTUnwrap(draft.lines.firstIndex(where: { $0.name == "FROZEN PEAS" }))
        XCTAssertEqual(draft.lines[index].printed?.quantity, "2")
        XCTAssertEqual(draft.lines[index].printed?.amount, "6.50")
        XCTAssertEqual(draft.lines[index].location, .freezer)
        XCTAssertEqual(draft.lines[index].documentLine?.method, .imageOCR)
        XCTAssertTrue(draft.lines[index].original.contains("USD"))
        XCTAssertTrue(draft.lines[index].paid.isEmpty)
        draft.lines[index].usePrintedQuantity()
        XCTAssertEqual(draft.lines[index].received, "2"); XCTAssertTrue(draft.lines[index].usable.isEmpty)
        XCTAssertEqual(draft.lines.last?.printed?.kind, .adjustment)
    }

    func testSpanishWeightedReceiptKeepsDateAndPaidAmbiguitiesOutOfStock() throws {
        func proposal(_ text: String) -> ReceiptPrintedEvidence {
            .init(.init(originalText: text), knownStorage: ["peras":[.fridge]])
        }
        let row = proposal("PERAS 0,75 kg @ USD 4,00/kg USD 3,00")
        XCTAssertEqual(row.name, "PERAS"); XCTAssertEqual(row.quantity, "0.75"); XCTAssertEqual(row.unit, .kilogram)
        XCTAssertEqual(row.storage, .fridge); XCTAssertEqual(row.amount, "3.00")
        XCTAssertNil(proposal("PERAS 2 por $5.00").amount)
        XCTAssertNil(proposal("YOGURT 1,234 kg USD 5.00").quantity)
        XCTAssertNil(proposal("KEEP REFRIGERATED AFTER OPENING 1 CT USD 1.00").storage)
        XCTAssertEqual(proposal("FAT FREE MILK 1 CT USD 2.00").name, "FAT FREE MILK")
        XCTAssertNil(proposal("PERAS USD 4.00/lb").amount)
        XCTAssertNil(proposal("PERAS 1 kg CAD 5.00").amount)
        XCTAssertNil(proposal("PERAS 2 kg USD 8.00 OFERTA USD 5.00").amount)
        XCTAssertEqual(proposal("DESCUENTO USD 2,00").kind, .adjustment)
        var blurry = ScanReceiptLine(originalText: "PERAS 1 kg USD 3.00"); blurry.uncertainOCR = true
        XCTAssertNil(ReceiptPrintedEvidence(blurry,knownStorage: [:]).quantity)
        func date(_ text: String) -> ReceiptPrintedDate? { .unique(in: [.init(originalText: text)], now: Date()) }
        XCTAssertNotNil(date("Fecha de compra: 17/11/2024"))
        for text in ["Fecha: 03/04/2024","Fecha: 31/02/2024","Best before: 2024-11-17","Fecha: 2099-01-01"] { XCTAssertNil(date(text)) }
        XCTAssertNil(ReceiptPrintedDate.unique(in: [.init(originalText:"2024-11-01"),.init(originalText:"2024-11-02")],now: Date()))
        var ordered = ScanReceiptLine(originalText: "2024-11-17")
        ordered.documentLine = .init(method: .pdfText, stage: .order, page: 1, line: 1)
        XCTAssertNil(ReceiptPrintedDate.unique(in: [ordered], now: Date()))
    }

    private func pdf(pages: Int, scannedLast: Bool = false) -> Data {
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 500)
        let image = UIGraphicsImageRenderer(bounds: bounds).image { _ in
            UIColor.white.setFill(); UIRectFill(bounds)
            ("SCANNED BEANS" as NSString).draw(at: CGPoint(x: 40, y: 90), withAttributes: [.font: UIFont.systemFont(ofSize: 32)])
        }
        return UIGraphicsPDFRenderer(bounds: bounds).pdfData { context in
            for page in 1...pages {
                context.beginPage()
                if scannedLast && page == pages { image.draw(in: bounds) }
                else {
                    ("OATS" as NSString).draw(at: CGPoint(x: 40, y: 40), withAttributes: [.font: UIFont.systemFont(ofSize: 24)])
                    ("FEE" as NSString).draw(at: CGPoint(x: 40, y: 90), withAttributes: [.font: UIFont.systemFont(ofSize: 24)])
                }
            }
        }
    }
    func testMixedPDFKeepsVerbatimPageCoordinatesAcrossIndependentPartialSelections() async throws {
        let input = ReceiptDocumentBytes(data: pdf(pages: 2, scannedLast: true), kind: .pdf)
        let extracted = try await ReceiptDocumentReader().extract(input)
        XCTAssertEqual(extracted.pages.map(\.method), [.pdfText, .pdfOCR])
        XCTAssertEqual(extracted.pages.first?.lines.first?.text, "OATS")
        let scanned = try XCTUnwrap(extracted.pages.last?.lines.first?.text)
        XCTAssertTrue(scanned.uppercased().contains("BEANS"))
        let target = CaptureTarget(workspaceID: UUID(), containerID: UUID(), objectID: UUID(), revision: 1, kind: .receiptEvidence)
        let single = try extracted.source(target: target, merchant: "Market", stage: .finalInvoice, selection: [.init(page: 2, line: 1)], at: Date())
        let combined = try extracted.source(target: target, merchant: "Market", stage: .finalInvoice,
            selection: [.init(page: 1, line: 1), .init(page: 2, line: 1)], at: Date())
        let first = try ReceiptImportDraft(source: single), second = try ReceiptImportDraft(source: combined)
        XCTAssertEqual(first.imageDigest, extracted.digest)
        XCTAssertEqual(first.receiptID, second.receiptID)
        XCTAssertEqual(first.lines.first?.ordinal, 200)
        XCTAssertEqual(first.lines.first, second.lines.last)
        XCTAssertEqual(first.lines.first?.documentLine?.stage, .finalInvoice)
        XCTAssertEqual(first.lines.first?.original, scanned)
        XCTAssertEqual(first.lines.first?.treatment, .skip)
        XCTAssertFalse(first.dateConfirmed)
        let offline = try await ReceiptDocumentReader(recognize: { _ in throw CaptureFailure.onDeviceUnavailable }).extract(input)
        XCTAssertEqual(offline.pages[0].lines.first?.text, "OATS")
        XCTAssertEqual(offline.pages[1].skipped, .unavailable)
        XCTAssertTrue(offline.pages[1].lines.isEmpty)
    }

    func testSelectedReceiptCropEncodesOnlyTheReviewedPixelsAndLocallyReadsThem() async throws {
        let bounds = CGRect(x: 0, y: 0, width: 640, height: 360)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let photo = UIGraphicsImageRenderer(bounds: bounds, format: format).image { _ in
            UIColor.white.setFill(); UIRectFill(bounds)
            for (label,y) in [("PRIVATE TOP", 15), ("OATS 2 KG", 144), ("PRIVATE BOTTOM", 278)] {
                (label as NSString).draw(at: CGPoint(x: 15, y: y), withAttributes: [.font: UIFont.systemFont(ofSize: 45), .foregroundColor: UIColor.black])
            }
        }
        let image = try XCTUnwrap(photo.cgImage)
        let crop = try ReceiptLineCrop.selected(from: image, rectangle: .init(x: 0, y: 0.35, width: 0.8, height: 0.25))
        XCTAssertEqual(crop.pixels.count, crop.width * crop.height)
        XCTAssertLessThan(crop.pixels.count, image.width * image.height)
        let png = try XCTUnwrap(UIImage(cgImage: XCTUnwrap(crop.previewImage)).pngData())
        let local = try await OnDeviceTextCapture().recognize(png)
        XCTAssertTrue(local.text.uppercased().contains("OATS"))
        XCTAssertFalse(local.text.uppercased().contains("PRIVATE"))
        let input = try ReceiptLineAssistanceRequest(consentingTo: "", page: 1, line: 2, crop: crop)
        let encoded = try input.wireData()
        let decoded = try JSONDecoder().decode(ReceiptLineAssistanceRequest.self, from: encoded)
        XCTAssertEqual(decoded.crop, crop)
        XCTAssertTrue(decoded.text.isEmpty)
        let white = try ReceiptLineCrop(width: 768, height: 240, pixels: Data(repeating: 255, count: 768 * 240))
        let maximum = try ReceiptLineAssistanceRequest(consentingTo: String(repeating: "A", count: 500), page: 20, line: 200, crop: white)
        XCTAssertLessThan(try maximum.wireData().count, 251_000)
        XCTAssertThrowsError(try ReceiptLineCrop.selected(from: image, rectangle: .init(x: 0, y: 0, width: 1, height: 1)))
    }

    func testFileLimitsAndLockedOrUnreadableInputsHaveRecoverableOutcomes() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("BEANS\r\n\r\n   \nFEE".utf8).write(to: url)
        let input = try await ReceiptDocumentBytes.picked(url)
        let document = try await ReceiptDocumentReader().extract(input)
        XCTAssertEqual(document.pages.first?.lines.map(\.text), ["BEANS", "FEE"])
        XCTAssertEqual(document.pages.first?.lines.map(\.id), [1, 4])
        let reader = ReceiptDocumentReader()
        for (item, failure) in [
            (ReceiptDocumentBytes(data: Data(repeating: 65, count: 10_000_001), kind: .text), ReceiptDocumentFailure.size),
            (.init(data: Data(repeating: 65, count: 100_001), kind: .text), .characters),
            (.init(data: Data(Array(repeating: "x", count: 201).joined(separator: "\n").utf8), kind: .text), .lineLimit),
            (.init(data: pdf(pages: 21), kind: .pdf), .pages),
            (.init(data: Data("wrong".utf8), kind: .image), .unsupported)] {
            do { _ = try await reader.extract(item); XCTFail("Expected a recoverable refusal") }
            catch { XCTAssertEqual(error as? ReceiptDocumentFailure, failure) }
        }
        let original = try XCTUnwrap(PDFDocument(data: pdf(pages: 1)))
        let locked = try XCTUnwrap(original.dataRepresentation(options: [PDFDocumentWriteOption.userPasswordOption: "read-secret", PDFDocumentWriteOption.ownerPasswordOption: "owner-secret"]))
        do { _ = try await reader.extract(.init(data: locked, kind: .pdf)); XCTFail("Locked source must not be consumed") }
        catch { XCTAssertEqual(error as? ReceiptDocumentFailure, .locked) }
        let task = Task { try await reader.extract(.init(data: pdf(pages: 10), kind: .pdf)) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled review must not publish") } catch is CancellationError {}
    }
}
