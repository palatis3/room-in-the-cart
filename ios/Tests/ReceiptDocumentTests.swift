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

    func testGardenMarketOCRLinksOnlyMatchingPrintedRowsAndLeavesReceiptUnconfirmed() async throws {
        // The audit receipt separates the item and amount into distant printed columns.
        let size = CGSize(width: 760, height: 560)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            UIColor.white.setFill()
            UIRectFill(CGRect(origin: .zero, size: size))
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.monospacedSystemFont(ofSize: 32, weight: .regular), .foregroundColor: UIColor.black
            ]
            for (left, right, y) in [
                ("GARDEN MARKET", "", 48.0), ("2026-11-20", "", 112.0),
                ("BLACK BEANS", "$2.40", 210.0), ("CORN TORTILLAS", "$3.20", 296.0),
                ("TOTAL", "$5.60", 390.0)
            ] {
                (left as NSString).draw(at: CGPoint(x: 36, y: y), withAttributes: attributes)
                (right as NSString).draw(at: CGPoint(x: 595, y: y), withAttributes: attributes)
            }
        }
        let document = try await ReceiptDocumentReader().extract(.init(data: XCTUnwrap(image.pngData()), kind: .image))
        let page = try XCTUnwrap(document.pages.first)
        let items = page.lines.filter { $0.text.contains("BLACK BEANS") || $0.text.contains("CORN TORTILLAS") }
        XCTAssertEqual(items.count, 2)
        let target = CaptureTarget(workspaceID: UUID(), containerID: UUID(), objectID: UUID(), revision: 1, kind: .receiptEvidence)
        let expected = ["BLACK BEANS": "$2.40", "CORN TORTILLAS": "$3.20"]
        for item in items {
            let matchingName = try XCTUnwrap(expected.keys.first(where: { item.text.contains($0) }))
            let amount = try XCTUnwrap(expected[matchingName])
            let itemPosition = ExtractedReceiptDocument.Selection(page: page.id, line: item.id)
            if item.text.contains(amount) {
                // Vision can emit a whole printed row on other supported runtimes.
                XCTAssertNil(document.amountAssociations[itemPosition])
                let source = try document.source(target: target, merchant: "Garden Market", stage: .receipt,
                                                 selection: [itemPosition], at: Date())
                let draft = try ReceiptImportDraft(source: source)
                XCTAssertEqual(draft.lines.first?.printed?.priceWording, amount)
                XCTAssertTrue(draft.selectedLines.isEmpty)
                XCTAssertEqual(draft.lines.first?.paid, "")
                continue
            }
            let matched = try XCTUnwrap(document.amountAssociations[itemPosition], page.lines.map(\.text).joined(separator: " | "))
            XCTAssertEqual(page.lines.first(where: { $0.id == matched.line })?.text, amount)
            let source = try document.source(target: target, merchant: "Garden Market", stage: .receipt,
                                             selection: [itemPosition], linkedAmountItems: [itemPosition], at: Date())
            XCTAssertEqual(Set(source.receiptLines.map(\.originalText)), [matchingName, amount])
            let draft = try ReceiptImportDraft(source: source)
            let line = try XCTUnwrap(draft.lines.first)
            XCTAssertEqual(draft.lines.count, 1)
            XCTAssertEqual(line.name, matchingName)
            XCTAssertEqual(line.original, matchingName + "\n" + amount)
            XCTAssertEqual(line.printed?.priceWording, amount)
            XCTAssertEqual(line.received, "")
            XCTAssertEqual(line.usable, "")
            XCTAssertEqual(line.paid, "")
            XCTAssertFalse(draft.dateConfirmed)
            XCTAssertTrue(draft.selectedLines.isEmpty)

            let undone = try document.source(target: target, merchant: "Garden Market", stage: .receipt,
                                             selection: [itemPosition], at: Date())
            XCTAssertEqual(undone.documentLayoutID, source.documentLayoutID)
            XCTAssertFalse(undone.originalText.contains(amount))
            XCTAssertNil(try ReceiptImportDraft(source: undone).lines.first?.printed?.amount)
        }
        let totalRows = page.lines.filter { $0.text.contains("TOTAL") }
        XCTAssertEqual(totalRows.count, 1)
        XCTAssertNil(document.amountAssociations[.init(page: 1, line: try XCTUnwrap(totalRows.first).id)])
    }

    func testAmountLinksRejectMultiplePricesRatesTotalsAndNonmatchingRows() throws {
        typealias Line = ReceiptDocumentPage.Line
        func box(_ x: Double, _ y: Double) -> CGRect { .init(x: x, y: y, width: 0.18, height: 0.05) }
        let left = box(0.06, 0.6), right = box(0.7, 0.6)
        func document(_ lines: [Line], method: ReceiptAcquisition.DocumentLine.Method = .imageOCR) -> ExtractedReceiptDocument {
            .init(digest: Data(repeating: 1, count: 32), pages: [.init(id: 1, method: method, lines: lines)])
        }
        let beans = Line(id: 1, text: "BLACK BEANS", bounds: left)
        let amount = Line(id: 2, text: "$2.40", bounds: right)
        let first = ExtractedReceiptDocument.Selection(page: 1, line: 1)
        let second = ExtractedReceiptDocument.Selection(page: 1, line: 2)
        XCTAssertEqual(document([beans, amount]).amountAssociations, [first: second])
        let reversed = document([.init(id: 1, text: "$2.40", bounds: right), .init(id: 2, text: "BLACK BEANS", bounds: left)])
        XCTAssertEqual(reversed.amountAssociations, [second: first])
        XCTAssertTrue(document([beans, amount], method: .textFile).amountAssociations.isEmpty)
        XCTAssertTrue(document([beans, amount, .init(id: 3, text: "$5.60", bounds: box(0.45, 0.6))]).amountAssociations.isEmpty)
        XCTAssertTrue(document([beans, amount, .init(id: 3, text: "$2.40", bounds: right)]).amountAssociations.isEmpty)
        XCTAssertTrue(document([beans, .init(id: 2, text: "$2.40", uncertain: true, bounds: right)]).amountAssociations.isEmpty)
        XCTAssertTrue(document([beans, .init(id: 2, text: "$2.40", bounds: box(0.7, 0.49))]).amountAssociations.isEmpty)
        for wording in ["TOTAL", "GRAND TOTAL", "SERVICE FEE", "CARD PAYMENT", "IMPORTE A PAGAR",
                        "PRECIO UNITARIO", "BEANS 2 CT @ $1.20", "BEANS 2 FOR $1.20", "BEANS $1.20"] {
            XCTAssertTrue(document([.init(id: 1, text: wording, bounds: left), amount]).amountAssociations.isEmpty, wording)
        }
        for wording in ["$2.40/kg", "-$2.40", "$2.40 $5.60", "2.40", "MXN $2.40"] {
            XCTAssertTrue(document([beans, .init(id: 2, text: wording, bounds: right)]).amountAssociations.isEmpty, wording)
        }

        let target = CaptureTarget(workspaceID: UUID(), containerID: UUID(), objectID: UUID(), revision: 1, kind: .receiptEvidence)
        XCTAssertThrowsError(try document([beans, amount]).source(target: target, merchant: "Garden Market", stage: .order,
                                                                 selection: [first], linkedAmountItems: [first], at: Date()))
        XCTAssertThrowsError(try document([beans, amount]).source(target: target, merchant: "Garden Market", stage: .receipt,
                                                                 selection: [second], linkedAmountItems: [first], at: Date()))
        let unlinked = try document([beans, amount]).source(target: target, merchant: "Garden Market", stage: .receipt,
                                                           selection: [first, second], at: Date())
        XCTAssertEqual(unlinked.receiptLines.map(\.originalText), ["BLACK BEANS", "$2.40"])
        XCTAssertTrue(try ReceiptImportDraft(source: unlinked).selectedLines.isEmpty)
    }

    func testPricePrintedBelowTheItemRequiresExplicitLinkingAndStaysUnpaid() throws {
        typealias Line = ReceiptDocumentPage.Line
        typealias Selection = ExtractedReceiptDocument.Selection
        let itemBounds = CGRect(x: 0.07, y: 0.66, width: 0.31, height: 0.035)
        let amountBounds = CGRect(x: 0.80, y: 0.61, width: 0.13, height: 0.035)
        let item = Line(id: 4, text: "LENTILS 2 CT", bounds: itemBounds)
        let amount = Line(id: 5, text: "$5.60", bounds: amountBounds)
        let itemPosition = Selection(page: 1, line: 4)
        let amountPosition = Selection(page: 1, line: 5)
        let target = CaptureTarget(workspaceID: UUID(), containerID: UUID(), objectID: UUID(), revision: 1, kind: .receiptEvidence)
        func input(_ lines: [Line]) -> ExtractedReceiptDocument {
            .init(digest: Data(repeating: 1, count: 32), pages: [.init(id: 1, method: .imageOCR, lines: lines)])
        }
        let document = input([item, amount])
        XCTAssertTrue(document.amountAssociations.isEmpty)
        XCTAssertEqual(document.splitAmountAssociations(excluding: document.amountAssociations), [itemPosition: amountPosition])

        let included = try document.source(target: target, merchant: "Bridgeway Grocer", stage: .receipt,
                                           selection: [itemPosition, amountPosition], at: Date())
        let independent = try ReceiptImportDraft(source: included)
        XCTAssertEqual(independent.lines.count, 2)
        XCTAssertNil(independent.lines.first?.printed?.amount)

        let linked = try document.source(target: target, merchant: "Bridgeway Grocer", stage: .receipt,
                                         selection: [itemPosition], linkedAmountItems: [itemPosition], at: Date())
        XCTAssertEqual(linked.documentLayoutID, included.documentLayoutID)
        XCTAssertEqual(linked.receiptLines.map(\.originalText), ["LENTILS 2 CT", "$5.60"])
        XCTAssertEqual(linked.receiptLines.first?.linkedAmountLineID, linked.receiptLines.last?.id)
        let reviewed = try ReceiptImportDraft(source: linked)
        XCTAssertEqual(reviewed.lines.count, 1)
        XCTAssertEqual(reviewed.lines.first?.printed?.priceWording, "$5.60")
        XCTAssertEqual(reviewed.lines.first?.paid, "")
        XCTAssertTrue(reviewed.stockLines.isEmpty)

        let totalLabel = Line(id: 6, text: "TOTAL PAID", bounds: CGRect(x: 0.03, y: 0.61, width: 0.38, height: 0.035))
        for unsafe in [
            input([item, amount, totalLabel]),
            input([.init(id: 4, text: "TOTAL", bounds: itemBounds), amount]),
            input([item, .init(id: 5, text: "$5.60 / kg", bounds: amountBounds)]),
            input([item, .init(id: 5, text: "$5.60", uncertain: true, bounds: amountBounds)])
        ] {
            XCTAssertTrue(unsafe.splitAmountAssociations(excluding: unsafe.amountAssociations).isEmpty)
            XCTAssertThrowsError(try unsafe.source(target: target, merchant: "Bridgeway Grocer", stage: .receipt,
                                                   selection: [itemPosition], linkedAmountItems: [itemPosition], at: Date()))
        }
        XCTAssertThrowsError(try document.source(target: target, merchant: "Bridgeway Grocer", stage: .order,
                                                  selection: [itemPosition], linkedAmountItems: [itemPosition], at: Date()))
        XCTAssertThrowsError(try document.source(target: target, merchant: "Bridgeway Grocer", stage: .receipt,
                                                  selection: [amountPosition], linkedAmountItems: [itemPosition], at: Date()))
    }

    func testReceiptAcceptsPrintedCountWordsInEnglishAndSpanishWithoutAssumingPackageContents() {
        for (wording, expected) in [("1 unit", "1"), ("2 units", "2"), ("1 unidad", "1"), ("2 unidades", "2")] {
            let source = ReceiptPrintedEvidence(.init(originalText: "Tamal " + wording), knownStorage: [:])
            XCTAssertEqual(source.quantity, expected, wording)
            XCTAssertEqual(source.unit, .count, wording)
            let correction = ReceiptPrintedEvidence(.init(originalText: "Tamal", quantityNote: wording), knownStorage: [:])
            XCTAssertEqual(correction.quantity, expected, wording)
            XCTAssertEqual(correction.unit, .count, wording)
        }
        for wording in ["Tamal 2 units per pack $4.82", "Tamal 2 unidades por paquete $4.82", "Tamal 2 units/pack $4.82",
                        "Tamal per pack: 2 units $4.82", "Tamal por paquete: 2 unidades $4.82", "Tamal por cada caja 2 unidades $4.82"] {
            let source = ReceiptPrintedEvidence(.init(originalText: wording), knownStorage: [:])
            XCTAssertNil(source.quantity, wording)
            XCTAssertNil(source.unit, wording)
            XCTAssertEqual(source.amount, "4.82", wording)
        }
        for note in ["2 paquetes", "2 packages", "2 units per pack", "2 unitarios"] {
            let result = ReceiptPrintedEvidence(.init(originalText: "Tamal", quantityNote: note), knownStorage: [:])
            XCTAssertNil(result.quantity, note)
            XCTAssertNil(result.unit, note)
        }
    }

    func testAmbiguousItemAcceptsOnlyExplicitPrintedFieldCorrections() {
        func proposal(_ text: String, quantity: String = "", price: String = "") -> ReceiptPrintedEvidence {
            ReceiptPrintedEvidence(.init(originalText: text, quantityNote: quantity, priceNote: price), knownStorage: [:])
        }
        for (wording, note, product) in [("2x Canned lentils 3.20", "2 units", "Canned lentils"),
                                          ("2 × Lentejas en lata 3,20", "2 unidades", "Lentejas en lata"),
                                          ("Plain yogurt 2.40", "500 g", "Plain yogurt")] {
            XCTAssertNil(proposal(wording).quantity)
            XCTAssertNil(proposal(wording).amount)
            let quantityOnly = proposal(wording, quantity: note)
            XCTAssertEqual(quantityOnly.name, product)
            XCTAssertEqual(quantityOnly.quantity, note.components(separatedBy: " ").first)
            XCTAssertEqual(quantityOnly.unit, note == "500 g" ? .gram : .count)
            XCTAssertNil(quantityOnly.amount)
            XCTAssertNil(proposal(wording, quantity: note, price: "3.20").amount)
            let priceOnly = proposal(wording, price: "USD 3,20")
            XCTAssertEqual(priceOnly.amount, "3.20")
            XCTAssertEqual(priceOnly.priceWording, "USD 3,20")
            XCTAssertNil(priceOnly.quantity)
            XCTAssertFalse(proposal(wording, quantity: note, price: "USD 3.20").uncertain)
        }
        for wording in ["2x Beans NZD $3.20", "2x Beans HKD $3.20", "2x Lentejas CLP $3,20",
                        "2x Beans chf 3.20", "2x Beans 3.20 NZD", "2x Beans (NZD) $3.20",
                        "2x Beans NZD: $3.20", "2x Beans ( NZD ) : $3.20", "2x Beans $3.20 (NZD)", "2x Arroz HK $3,20",
                        "2x Beans NZ $3.20", "2x Frijoles R$3,20", "2x Beans kr 3.20", "2x Arroz S/ 3,20", "2x Arroz CLP $320",
                        "2x Beans ¥3.20", "2x Arroz ₱3,20", "2x Frijoles pesos $3,20"] {
            for correction in ["", "3.20", "USD 3.20"] {
                let result = proposal(wording, price: correction)
                XCTAssertNil(result.amount, wording)
                XCTAssertNil(result.priceWording, wording)
            }
            let renamed = ScanReceiptLine(originalText: wording, reviewedText: "Beans", priceNote: "USD 3.20")
            XCTAssertNil(ReceiptPrintedEvidence(renamed, knownStorage: [:]).amount, wording)
        }
        for (wording, price) in [("2x Beans USD 3.20", "USD 3.20"), ("2x Frijoles US$3,20", "US$3,20"),
                                 ("2x RED PEPPERS $3.20", "$3.20"), ("2x ALL PURPOSE FLOUR $3.20", "$3.20"),
                                 ("ACEITE 0,50 L USD 3,20", "USD 3,20"), ("Arroz 125.00 g $3.20", "$3.20"),
                                 ("EGGS GRADE A $3.20", "$3.20")] {
            XCTAssertEqual(proposal(wording).priceWording, price, wording)
        }
        for letter in ["D", "C", "B", "E"] {
            let name = "Vitamin " + letter
            XCTAssertEqual(proposal(name + " $3.20").name, name)
            XCTAssertEqual(proposal(name + " $3.20").priceWording, "$3.20")
            XCTAssertEqual(proposal("2x " + name + " $3.20").priceWording, "$3.20")
        }
        let measured = proposal("Medicine Vitamin D 2 units USD 3.20")
        XCTAssertEqual(measured.name, "Medicine Vitamin D")
        XCTAssertEqual(measured.quantity, "2")
        XCTAssertEqual(measured.priceWording, "USD 3.20")
        let renamedForeign = ScanReceiptLine(originalText: "2x Beans (NZD) $3.20", reviewedText: "Plain beans",
                                             quantityNote: "2 units", priceNote: "USD 3.20")
        let correctedFields = ReceiptPrintedEvidence(renamedForeign, knownStorage: [:])
        XCTAssertEqual(correctedFields.name, "Plain beans")
        XCTAssertEqual(correctedFields.quantity, "2")
        XCTAssertNil(correctedFields.amount)
        for (wording, unit) in [("Beans 2 kg at $1.60/kg USD 3.20", UnitOfMeasure.kilogram),
                                ("Beans 2 units at $1.60 USD 3.20", .count),
                                ("Beans 2 kg @ $1.60/kg $3.20", .kilogram),
                                ("Beans 2 units @ $1.60 $3.20", .count),
                                ("Frijoles 2 kg a $1,60/kg USD 3,20", .kilogram),
                                ("Frijoles 2 unidades a $1,60 USD 3,20", .count)] {
            let printed = proposal(wording)
            XCTAssertEqual(printed.name, wording.components(separatedBy: " ").first, wording)
            XCTAssertEqual(printed.quantity, "2", wording)
            XCTAssertEqual(printed.unit, unit, wording)
            XCTAssertEqual(printed.amount, "3.20", wording)
            XCTAssertEqual(proposal(wording, price: "USD 3.10").amount, "3.10", wording)
        }
        let rateOnly = "Frijoles 2 kg a $1,60/kg"
        XCTAssertNil(proposal(rateOnly).amount)
        XCTAssertEqual(proposal(rateOnly, price: "USD 3,20").amount, "3.20")
        let marked = proposal("2x Canned lentils $3.20", quantity: "2 units", price: "3,20")
        XCTAssertEqual(marked.priceWording, "$3.20")
        XCTAssertEqual(marked.quantity, "2")
        for note in ["2 cans", "2 latas", "2", "0 units", "-2 units", "2 units per pack"] {
            XCTAssertNil(proposal("2x Canned lentils 3.20", quantity: note).quantity, note)
        }
        for wording in ["Service fee 0.45", "2x TOTAL 3.20", "Fecha: 2024-11-18", "2x Lentejas EUR 3,20",
                        "2x Beans 2 kg 3.20", "2x Beans 4 x 2 3.20", "Beans 3.20 4.20", "2x Beans @ 1.60",
                        "Beans 1.60 USD 3.20", "2x Beans 1.60 USD 3.20", "2x Beans NZ$3.20",
                        "2x Beans at $1.60 USD 3.20", "2x Beans 3.20 at $1.60",
                        "2x Beans -3.20", "2x Beans ? 3.20", "2x Beans per pack 3.20"] {
            let result = proposal(wording, quantity: "2 units", price: "USD 3.20")
            XCTAssertNil(result.quantity, wording)
            XCTAssertNil(result.amount, wording)
        }
        var blurry = ScanReceiptLine(originalText: "2x Canned lentils 3.20", quantityNote: "2 units", priceNote: "USD 3.20")
        blurry.uncertainOCR = true
        let blocked = ReceiptPrintedEvidence(blurry, knownStorage: [:])
        XCTAssertNil(blocked.quantity)
        XCTAssertNil(blocked.amount)
    }

    func testBarePrintedAmountOnlyKeepsTheSameExplicitCurrencyEvidence() throws {
        let wording = "2 paquetes de maíz seco $4.82"
        func proposal(_ source: String, note: String) -> ReceiptPrintedEvidence {
            .init(.init(originalText: source, quantityNote: "2", priceNote: note), knownStorage: [:])
        }
        XCTAssertEqual(proposal(wording, note: "").priceWording, "$4.82")
        XCTAssertEqual(proposal(wording, note: "4.82").priceWording, "$4.82")
        XCTAssertEqual(proposal(wording, note: "4,82").amount, "4.82")
        XCTAssertEqual(proposal(wording, note: "USD 4.28").amount, "4.28")
        XCTAssertNil(proposal(wording, note: "4.28").amount)
        XCTAssertNil(proposal("MAÍZ 2 CT 4.82", note: "4.82").amount)
        XCTAssertNil(proposal("MAÍZ 2 CT MXN 4.82", note: "4.82").amount)
        XCTAssertNil(proposal(wording, note: "4.82").quantity)

        let target = CaptureTarget(workspaceID: UUID(), containerID: UUID(), objectID: UUID(), revision: 1, kind: .receiptEvidence)
        let source = SourceMediaRecord(id: UUID(), target: target, originalText: wording, reviewedLabel: "Mercado Alondra",
                                       imageJPEG: nil, barcode: nil,
                                       receiptLines: [.init(originalText: wording, quantityNote: "2", priceNote: "4.82")],
                                       capturedAt: Date())
        let draft = try ReceiptImportDraft(source: source)
        XCTAssertEqual(draft.lines.first?.original, wording)
        XCTAssertEqual(draft.lines.first?.printed?.amount, "4.82")
        XCTAssertEqual(draft.lines.first?.paid, "")
        XCTAssertTrue(draft.selectedLines.isEmpty)
    }

    func testPrintedPaidTotalRemainsUnknownUntilTheShopperAdoptsIt() throws {
        typealias Selection = ExtractedReceiptDocument.Selection
        let paidLabel = ReceiptDocumentPage.Line(id: 14, text: "TOTAL PAID", bounds: .init(x: 0.08, y: 0.2, width: 0.29, height: 0.04))
        let paidAmount = ReceiptDocumentPage.Line(id: 15, text: "$12.35", bounds: .init(x: 0.8, y: 0.2, width: 0.12, height: 0.04))
        let document = ExtractedReceiptDocument(digest: Data(repeating: 7, count: 32),
                                                pages: [.init(id: 1, method: .imageOCR, lines: [paidLabel, paidAmount])])
        let label = Selection(page: 1, line: 14)
        let amount = Selection(page: 1, line: 15)
        for selection: Set<Selection> in [[], [label], [amount]] {
            XCTAssertNil(document.printedPaidTotal(selected: selection))
        }
        let total = try XCTUnwrap(document.printedPaidTotal(selected: [label, amount]))
        XCTAssertEqual(total.wording, "$12.35")
        XCTAssertEqual(total.amount, "12.35")

        let target = CaptureTarget(workspaceID: UUID(), containerID: UUID(), objectID: UUID(), revision: 1, kind: .receiptEvidence)
        let source = try document.source(target: target, merchant: "Bridgeway Grocer", stage: .receipt,
                                         selection: [label, amount], at: Date())
        XCTAssertEqual(source.receiptLines.map(\.originalText), ["TOTAL PAID", "$12.35"])
        var draft = try ReceiptImportDraft(source: source)
        draft.printedPaidTotal = total
        XCTAssertNil(try ComparisonModel.money(draft.receiptTotal))
        draft.usePrintedPaidTotal()
        XCTAssertTrue(draft.receiptTotal.isEmpty)

        draft.tracksPutaway = true
        draft.usePrintedPaidTotal()
        XCTAssertEqual(draft.receiptTotal, "12.35")
        draft.receiptTotal = "12.34"
        draft.usePrintedPaidTotal()
        XCTAssertEqual(draft.receiptTotal, "12.34")
        XCTAssertEqual(try ComparisonModel.money(draft.receiptTotal), try ComparisonModel.money("12.34"))
        XCTAssertTrue(draft.selectedLines.isEmpty)
        XCTAssertTrue(draft.stockLines.isEmpty)
    }

    func testPrintedPaidTotalRejectsSubtotalConflictsAndUncertainAmounts() throws {
        typealias Line = ReceiptDocumentPage.Line
        typealias Selection = ExtractedReceiptDocument.Selection
        let left = CGRect(x: 0.06, y: 0.2, width: 0.32, height: 0.04)
        let right = CGRect(x: 0.8, y: 0.2, width: 0.13, height: 0.04)
        let paid = Line(id: 2, text: "TOTAL PAGADO:", bounds: left)
        let amount = Line(id: 1, text: "USD 12,35", bounds: right)
        let both: Set<Selection> = [.init(page: 1, line: 1), .init(page: 1, line: 2)]
        func document(_ lines: [Line], method: ReceiptAcquisition.DocumentLine.Method = .pdfOCR,
                      extraPages: [ReceiptDocumentPage] = []) -> ExtractedReceiptDocument {
            .init(digest: Data(repeating: 8, count: 32), pages: [.init(id: 1, method: method, lines: lines)] + extraPages)
        }
        XCTAssertEqual(document([amount, paid]).printedPaidTotal(selected: both)?.amount, "12.35")
        for wording in ["SUBTOTAL", "TOTAL", "AMOUNT DUE", "TAX", "TOTAL PAID USD 12.35"] {
            XCTAssertNil(document([amount, .init(id: 2, text: wording, bounds: left)]).printedPaidTotal(selected: both), wording)
        }
        for wording in ["12.35", "MXN $12.35", "$12.35 CAD", "$12.35 A", "$12.35/kg", "$12.35 $9.55"] {
            XCTAssertNil(document([.init(id: 1, text: wording, bounds: right), paid]).printedPaidTotal(selected: both), wording)
        }
        XCTAssertNil(document([amount, paid], method: .textFile).printedPaidTotal(selected: both))
        XCTAssertNil(document([.init(id: 1, text: "$12.35", uncertain: true, bounds: right), paid]).printedPaidTotal(selected: both))
        XCTAssertNil(document([.init(id: 1, text: "$12.35", bounds: right.offsetBy(dx: 0, dy: -0.07)), paid])
            .printedPaidTotal(selected: both))
        XCTAssertNil(document([amount, paid, .init(id: 3, text: "MXN", bounds: .init(x: 0.6, y: 0.2, width: 0.14, height: 0.04))])
            .printedPaidTotal(selected: both))
        let conflict = ReceiptDocumentPage(id: 2, method: .pdfOCR, lines: [
            .init(id: 1, text: "TOTAL PAID", bounds: left), .init(id: 2, text: "$19.95", bounds: right)
        ])
        XCTAssertNil(document([amount, paid], extraPages: [conflict]).printedPaidTotal(selected: both))
        XCTAssertNil(document([amount, paid], extraPages: [.init(id: 2, method: .pdfOCR, lines: [])]).printedPaidTotal(selected: both))
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

    func testPurchaseDateUsesAppLanguageAndKeepsTheChosenRegion() {
        let usEnglish = Locale(identifier: "en_US@calendar=gregorian")
        let spanish = ReceiptDateDisplay.displayLocale(regionLocale: usEnglish, appLanguage: "es")
        XCTAssertEqual(spanish.language.languageCode?.identifier, "es")
        XCTAssertEqual(spanish.region?.identifier, "US")
        XCTAssertEqual(spanish.calendar.identifier, usEnglish.calendar.identifier)
        let mexico = Locale(identifier: "es_MX")
        XCTAssertEqual(ReceiptDateDisplay.displayLocale(regionLocale: mexico, appLanguage: "es"), mexico)
    }

    func testReceiptDateOnlyAndTimestampUseTheChosenCalendarAndZone() throws {
        let locale = ReceiptDateDisplay.displayLocale(regionLocale: Locale(identifier: "en_US"), appLanguage: "es")
        let zone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let instant = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-20T02:03:00Z"))
        let gregorian = Calendar(identifier: .gregorian)
        let localDay = ReceiptDateDisplay.format(date: .long, time: .omitted, locale: locale, calendar: gregorian, timeZone: zone)
        let utcDay = ReceiptDateDisplay.format(date: .long, time: .omitted, locale: locale, calendar: gregorian, timeZone: .gmt)
        XCTAssertEqual(instant.formatted(localDay), "19 de noviembre de 2026")
        XCTAssertEqual(instant.formatted(utcDay), "20 de noviembre de 2026")
        let timestamp = ReceiptDateDisplay.format(date: .omitted, time: .shortened, locale: locale, calendar: gregorian, timeZone: zone)
        XCTAssertTrue(instant.formatted(timestamp).contains("6:03") || instant.formatted(timestamp).contains("18:03"))

        let buddhist = ReceiptDateDisplay.format(date: .long, time: .omitted, locale: locale,
                                                calendar: Calendar(identifier: .buddhist), timeZone: zone)
        XCTAssertTrue(instant.formatted(buddhist).contains("2569"))
    }

    func testSavedReceiptCivilDayDoesNotConvertToTheViewersTimeZone() throws {
        let locale = Locale(identifier: "es_US")
        let calendar = Calendar(identifier: .gregorian)
        let west = try XCTUnwrap(TimeZone(identifier: "Pacific/Pago_Pago"))
        let east = try XCTUnwrap(TimeZone(identifier: "Pacific/Kiritimati"))
        for zone in [west, .gmt, east] {
            XCTAssertEqual(ReceiptDateDisplay.civilDay("2026-11-19", locale: locale, calendar: calendar, zone: zone),
                           "19 de noviembre de 2026")
        }
        XCTAssertEqual(ReceiptDateDisplay.civilDay("2026-02-30", locale: locale, calendar: calendar, zone: west), "2026-02-30")
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
        XCTAssertEqual(extracted.pages.first?.lines.map(\.text), ["OATS", "FEE"])
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
        XCTAssertEqual(offline.pages[0].lines.map(\.text), ["OATS", "FEE"])
        XCTAssertEqual(offline.pages[1].skipped, .unavailable)
        XCTAssertTrue(offline.pages[1].lines.isEmpty)
    }

    func testReceiptPDFPreservesInlinePriceAndSeparatesPrintedCharges() async throws {
        let bounds = CGRect(x: 0, y: 0, width: 340, height: 400)
        let bytes = UIGraphicsPDFRenderer(bounds: bounds).pdfData { context in
            context.beginPage()
            let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 18)]
            for (wording, y) in [
                ("GARDEN MARKET", 28.0), ("ROLLED OATS USD 2.40", 76.0),
                ("SERVICE FEE USD 1.25", 119.0), ("TAX USD 0.42", 162.0)
            ] {
                (wording as NSString).draw(at: .init(x: 24, y: y), withAttributes: attributes)
            }
        }
        let input = ReceiptDocumentBytes(data: bytes, kind: .pdf)
        let document = try await ReceiptDocumentReader().extract(input)
        XCTAssertEqual(document.digest, Data(SHA256.hash(data: bytes)))
        let page = try XCTUnwrap(document.pages.first)
        let printedRows = ["GARDEN MARKET", "ROLLED OATS USD 2.40", "SERVICE FEE USD 1.25", "TAX USD 0.42"]
        XCTAssertEqual(page.method, .pdfText)
        XCTAssertEqual(page.lines.map(\.text), printedRows)
        XCTAssertEqual(page.lines.map(\.id), [1, 2, 3, 4])
        XCTAssertTrue(document.amountAssociations.isEmpty)
        let originalPage = try XCTUnwrap(PDFDocument(data: bytes)?.page(at: 0))
        let flattened = try XCTUnwrap(originalPage.string).split(whereSeparator: \.isNewline).joined(separator: " ")
        XCTAssertEqual(try ReceiptDocumentReader.pdfPrintedWording(flattened, page: originalPage), printedRows.joined(separator: "\n"))
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
