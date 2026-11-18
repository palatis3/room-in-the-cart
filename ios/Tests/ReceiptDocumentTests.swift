import CoreDomain
import HouseholdClient
import PDFKit
import UIKit
import XCTest
@testable import RoomInTheCart

@MainActor final class ReceiptDocumentTests: XCTestCase {
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
