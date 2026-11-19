import CoreDomain
import CryptoKit
import DeviceSurfaces
import UniformTypeIdentifiers
import HouseholdClient
import PDFKit
import UIKit
import XCTest
@testable import RoomInTheCart

@MainActor final class ReceiptDocumentTests: XCTestCase {
    func testOriginalSharedTextReopensAsReceiptWithItsExactFileDigestAndEncoding() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("shared.sqlite"), now = Date()
        let scope = SharedReceiptScope(origin: UUID(), persona: UUID())
        let wording = "2 tortillas\r\nCafé 🍚"
        let little = try XCTUnwrap(wording.data(using: .utf16LittleEndian))
        let big = try XCTUnwrap(wording.data(using: .utf16BigEndian))
        let samples: [(Data, UTType?)] = [
            (Data(wording.utf8), .utf8PlainText), (Data([0xef, 0xbb, 0xbf]) + Data(wording.utf8), .plainText),
            (Data([0xff, 0xfe]) + little, nil), (Data([0xfe, 0xff]) + big, nil),
            (little, .utf16PlainText), (big, .utf16ExternalPlainText)
        ]
        for (bytes, type) in samples {
            // Untyped marked files use the same descriptor as receipts staged before encoding hints.
            XCTAssertEqual(try SelectedTextInbox.decodePlainText(bytes, type: type ?? .plainText), wording)
            let writer = try SharedCaptureInbox(url: url), id = UUID()
            _ = try await writer.stageReceipt(bytes, kind: .text, id: id, now: now, type: type)
            let inbox = try SharedCaptureInbox(url: url)
            let pending = try await inbox.pendingReceiptFiles(scope: scope, now: now)
            let item = try XCTUnwrap(pending.first(where: { $0.id == id }))
            let original = try await inbox.openReceipt(item, scope: scope, now: now)
            XCTAssertEqual(original, bytes)
            let result = try await ReceiptDocumentReader().extract(.shared(original, descriptor: item.descriptor))
            XCTAssertEqual(result.digest, Data(SHA256.hash(data: bytes)))
            XCTAssertEqual(result.pages.first?.lines.map(\.text), ["2 tortillas", "Café 🍚"])
            try await inbox.finishReceipt(item, scope: scope, committed: false, now: now)
        }

        let long = String(repeating: "A", count: SelectedTextInbox.maximumEntryBytes + 1)
        let bytes = try XCTUnwrap(long.data(using: .utf16LittleEndian))
        let file = folder.appendingPathComponent("receipt.txt")
        try bytes.write(to: file)
        XCTAssertThrowsError(try SelectedTextInbox.decodePlainText(bytes, type: .utf16PlainText))
        let picked = try ReceiptDocumentBytes.read(file, kind: .text, type: .utf16PlainText)
        let document = try await ReceiptDocumentReader().extract(picked)
        XCTAssertEqual(document.pages.first?.lines.first?.text, long)
        XCTAssertEqual(document.digest, Data(SHA256.hash(data: bytes)))
    }

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

    func testSourceInspectorReturnsOnlyAnAvailableImagePage() async throws {
        let text = ReceiptDocumentBytes(data: Data("YOGURT $1.50".utf8), kind: .text)
        let typedImage = await ReceiptDocumentReader.originalPage(text, pageNumber: 1)
        XCTAssertNil(typedImage)

        let pdf = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 200, height: 240)).pdfData { context in
            context.beginPage()
            ("YOGURT $1.50" as NSString).draw(at: CGPoint(x: 12, y: 18), withAttributes: [.font: UIFont.systemFont(ofSize: 18)])
        }
        let input = ReceiptDocumentBytes(data: pdf, kind: .pdf)
        let firstPage = await ReceiptDocumentReader.originalPage(input, pageNumber: 1)
        let bytes = try XCTUnwrap(firstPage)
        XCTAssertNotNil(UIImage(data: bytes))
        let missingPage = await ReceiptDocumentReader.originalPage(input, pageNumber: 2)
        XCTAssertNil(missingPage)
    }

    func testSpanishWeightedReceiptKeepsDateAndPaidAmbiguitiesOutOfStock() throws {
        func proposal(_ text: String) -> ReceiptPrintedEvidence {
            .init(.init(originalText: text), knownStorage: ["peras":[.fridge]])
        }
        let row = proposal("PERAS 0,75 kg @ USD 4,00/kg USD 3,00")
        XCTAssertEqual(row.name, "PERAS"); XCTAssertEqual(row.quantity, "0.75"); XCTAssertEqual(row.unit, .kilogram)
        XCTAssertEqual(row.storage, .fridge); XCTAssertEqual(row.amount, "3.00")
        for text in ["PERAS 2 kg a USD 2,50", "PERAS 2 kg @ USD 2,50", "PERAS 2 kg at 2.50"] {
            let rateOnly = proposal(text)
            XCTAssertNil(rateOnly.amount, text)
            XCTAssertNil(rateOnly.priceWording, text)
            XCTAssertEqual(rateOnly.quantity, "2", text)
            XCTAssertEqual(rateOnly.name, "PERAS", text)
        }
        XCTAssertEqual(proposal("PERAS 2 kg a USD 2,50 USD 5,00").amount, "5.00")
        XCTAssertEqual(proposal("EGGS GRADE A $4.00").name, "EGGS GRADE A")
        XCTAssertEqual(proposal("EGGS GRADE A $4.00").amount, "4.00")
        for unit in ["onzas líquidas", "oz liq.", "fluid ounces", "fl. oz."] {
            let oil = proposal("ACEITE 8 \(unit) USD 4,00")
            XCTAssertEqual(oil.unit, .fluidOunce, unit)
            XCTAssertEqual(oil.quantity, "8", unit)
            XCTAssertEqual(oil.name, "ACEITE", unit)
            XCTAssertEqual(oil.amount, "4.00", unit)
        }
        XCTAssertEqual(proposal("QUESO 8 onzas USD 4,00").unit, .ounce)
        let returned = proposal("PERAS -2 CT USD 6.50")
        XCTAssertNil(returned.quantity); XCTAssertNil(returned.amount); XCTAssertTrue(returned.uncertain)
        XCTAssertNil(proposal("PERAS 2 CT (6.50)").quantity)
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
        XCTAssertNotNil(first.documentLayoutID)
        XCTAssertEqual(first.documentLayoutID, second.documentLayoutID)
        // The same bytes can yield different OCR coordinates on another reading.
        let shifted = try await ReceiptDocumentReader(recognize: { _ in "HEADER\nSCANNED BEANS" }).extract(input)
        let shiftedRow = try shifted.source(target: target, merchant: "Market", stage: .finalInvoice,
            selection: [.init(page: 2, line: 2)], at: Date())
        XCTAssertEqual(shiftedRow.documentDigest, single.documentDigest)
        XCTAssertNotEqual(shiftedRow.documentLayoutID, single.documentLayoutID)
        XCTAssertFalse(shiftedRow.originalText.contains("HEADER"))
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

extension ReceiptDocumentTests {
    func testReceiptSectionsKeepDistinctYogurtsAcrossRetakesAndPartialImports() throws {
        func photo(_ lines: [String], _ key: String) -> ExtractedReceiptDocument {
            .init(digest: Data(SHA256.hash(data: Data(key.utf8))), pages: [
                .init(id: 1, method: .imageOCR, lines: lines.enumerated().map { .init(id: $0.offset + 1, text: $0.element) })
            ])
        }
        let target = CaptureTarget(workspaceID: UUID(), containerID: UUID(), objectID: UUID(), revision: 0, kind: .receiptEvidence)
        let first = photo(["LECHE", "YOGUR", "YOGUR"], "first")
        var draft = ReceiptSectionDraft()
        try draft.put(first, bytes: 400, preview: nil, at: 0)
        XCTAssertEqual(try draft.review().document.digest, first.digest)
        try draft.put(photo(["YOGUR", "YOGUR", "HUEVOS"], "second"), bytes: 500, preview: nil, at: 1)
        XCTAssertEqual(draft.likelyOverlaps(at: 1), [1, 2])
        XCTAssertThrowsError(try draft.review())
        draft.resolve(at: 1, omitting: 1)
        let partial = try draft.review()
        XCTAssertEqual(partial.omitted, [.init(page: 2, line: 1)])
        let eggs = try partial.document.source(target: target, merchant: "Tienda", stage: .receipt, selection: [.init(page: 2, line: 3)], at: Date())
        draft.resolve(at: 1, omitting: 0)
        let keep = try draft.review()
        XCTAssertTrue(keep.omitted.isEmpty)
        let yogurt = try keep.document.source(target: target, merchant: "Tienda", stage: .receipt, selection: [.init(page: 2, line: 2)], at: Date())
        XCTAssertEqual(yogurt.id, eggs.id)
        XCTAssertEqual(yogurt.documentLayoutID, eggs.documentLayoutID)
        XCTAssertNotEqual(yogurt.receiptLines[0].id, eggs.receiptLines[0].id)
        XCTAssertThrowsError(try draft.put(photo([], "bad"), bytes: 50, preview: nil, at: 1))
        XCTAssertEqual(try draft.review().document.digest, partial.document.digest)
        try draft.put(photo(["YOGUR", "HUEVOS"], "retake"), bytes: 500, preview: nil, at: 1)
        XCTAssertThrowsError(try draft.review())
        draft.resolve(at: 1, omitting: 1)
        XCTAssertNotEqual(try draft.review().document.digest, partial.document.digest)
        try draft.put(photo(["PAN"], "new first"), bytes: 500, preview: nil, at: 0)
        XCTAssertTrue(try draft.review().omitted.isEmpty)
        XCTAssertEqual(try draft.review().document.pages[1].lines.map(\.text), ["YOGUR", "HUEVOS"])
        var bounded = ReceiptSectionDraft()
        func part(_ index: Int) -> ExtractedReceiptDocument { photo(["YOGUR"], String(index)) }
        for index in 0..<3 { try bounded.put(part(index), bytes: 10_000_000, preview: nil, at: index) }
        XCTAssertThrowsError(try bounded.put(part(0), bytes: 1, preview: nil, at: 1)) { XCTAssertEqual($0 as? ReceiptDocumentFailure, .duplicateSection) }
        XCTAssertThrowsError(try bounded.put(part(3), bytes: 1, preview: nil, at: 3)) { XCTAssertEqual($0 as? ReceiptDocumentFailure, .size) }
        XCTAssertEqual(bounded.sections.count, 3)
        for index in 0..<6 { try bounded.put(part(index), bytes: 10, preview: nil, at: index) }
        XCTAssertThrowsError(try bounded.put(part(6), bytes: 10, preview: nil, at: 6))
    }

    func testPrivateTripDifferencesPreserveRepeatsUnknownPricesAndSplitAllocations() throws {
        func unit(_ amount: String, _ unit: UnitOfMeasure = .count) throws -> Quantity { try XCTUnwrap(ComparisonModel.quantity(amount, unit)) }
        let a = UUID(), b = UUID()
        let first = BasketLine(id: a, name: "Yogurt", quantity: try unit("2"), expectedCost: .exact(.init(minorUnits: 400)))
        let other = BasketLine(id: b, name: "Yogurt", quantity: try unit("1"), expectedCost: .exact(.init(minorUnits: 200)))
        var links: [UUID: ReceiptTripLink] = [:]
        XCTAssertEqual(ReceiptTripLink.compare(first, with: links), .noEvidence)
        func add(_ total: Quantity, _ portions: [UUID: Quantity], cents: Int64?) throws {
            let id = UUID()
            links[id] = try XCTUnwrap(.init(receiptLineID: id, printed: total, portions: portions, printedTotal: cents.map { Money(minorUnits: $0) }))
        }
        try add(unit("1"), [a: unit("1")], cents: 200)
        XCTAssertEqual(ReceiptTripLink.compare(first, with: links), .quantity)
        try add(unit("1"), [a: unit("1")], cents: 200)
        XCTAssertEqual(ReceiptTripLink.compare(first, with: links), .matched)
        XCTAssertEqual(ReceiptTripLink.compare(other, with: links), .noEvidence)
        links = [:]
        try add(unit("3"), [a: unit("2"), b: unit("1")], cents: 600)
        XCTAssertEqual(ReceiptTripLink.compare(first, with: links), .priceUnknown)
        XCTAssertEqual(ReceiptTripLink.compare(other, with: links), .priceUnknown)
        XCTAssertNil(ReceiptTripLink(receiptLineID: UUID(), printed: try unit("2"), portions: [a: try unit("2"), b: try unit("1")], printedTotal: nil))
        links = [:]
        try add(unit("2"), [a: unit("2")], cents: 450)
        XCTAssertEqual(ReceiptTripLink.compare(first, with: links), .price)
        links = [:]
        try add(unit("2", .ounce), [a: unit("2", .ounce)], cents: 400)
        XCTAssertEqual(ReceiptTripLink.compare(first, with: links), .incompatible)
    }
}

extension ReceiptDocumentTests {
    func testSharedReceiptTripUsesAmendedPacksAndNeverLinksBySimilarWording() throws {
        let shop = UUID(), line = UUID(), amendment = UUID()
        let original: [String: Any] = ["lineId": line.uuidString, "originalItem": "Tortillas", "packs": 3, "unitPriceMinor": 200, "feeEligible": true]
        let changed: [String: Any] = ["lineId": line.uuidString, "originalItem": "Tortillas", "packs": 2, "unitPriceMinor": 225, "feeEligible": true]
        let quote: [String: Any] = ["currency": "USD", "scope": "wholeCheckout", "complete": true, "capMinor": NSNull(),
            "capScope": "wholeCheckout", "fee": ["kind": "fixed", "amountMinor": 0], "taxesMinor": 0, "depositsMinor": 0,
            "discountsMinor": 0, "observedAt": "2026-01-01T08:00:00Z", "expiresAt": "2026-01-01T12:00:00Z"]
        let raw: [String: Any] = ["shopId": shop.uuidString, "shopRevision": 4, "authorityEpoch": 1, "placedRevision": 3,
            "asOf": "2026-01-03T12:00:00Z",
            "original": ["lines": [original], "quote": quote, "snapshotCreatedAt": "2026-01-01T10:00:00Z"] as [String: Any],
            "current": ["lines": [changed], "amendmentId": amendment.uuidString] as [String: Any],
            "amendments": [["amendmentId": amendment.uuidString, "predecessorId": NSNull(), "retailerReference": "Shop revision",
                            "confirmedAt": "2026-01-02T10:00:00Z", "recordedAt": "2026-01-02T10:01:00Z",
                            "actorId": UUID().uuidString, "lines": [changed]] as [String: Any]]]
        let page = try JSONDecoder().decode(SharedConfirmedOrder.self, from: JSONSerialization.data(withJSONObject: raw))
        let trip = try ReceiptTripPlan(shared: page, household: "Casa")
        XCTAssertTrue(trip.countsPacks)
        XCTAssertEqual(trip.id, shop)
        XCTAssertEqual(trip.lines[0].quantity.amount, try Rational(2))
        XCTAssertEqual(trip.lines[0].expectedCost, .exact(Money(minorUnits: 450)))
        let wording = ReceiptImportDraft.Line(id: UUID(), ordinal: 0, original: "TORTILLAS 2 EA $4.50", name: "Tortillas")
        XCTAssertNil(trip.suggestedLine(for: wording, purchases: []))
        var plannedOnly = wording
        plannedOnly.documentLine = .init(method: .pdfText, stage: .order, page: 1, line: 1)
        XCTAssertFalse(plannedOnly.canComparePurchase)
        plannedOnly.documentLine = .init(method: .pdfText, stage: .finalInvoice, page: 1, line: 1)
        XCTAssertTrue(plannedOnly.canComparePurchase)
        XCTAssertThrowsError(try page.validate(shopID: UUID()))
    }
}
