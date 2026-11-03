import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import CoreImage
import CoreDomain
@testable import RoomInTheCart

final class ScanParsingTests: XCTestCase {
    func testGTINCheckDigitDoesNotConferProductIdentity() {
        XCTAssertTrue(CapturedBarcode(symbology: "EAN13", value: "4006381333931").validGTIN)
        XCTAssertTrue(CapturedBarcode(symbology: "UPC", value: "036000291452").validGTIN)
        XCTAssertFalse(CapturedBarcode(symbology: "EAN13", value: "4006381333932").validGTIN)
        XCTAssertFalse(CapturedBarcode(symbology: "QR", value: "https://example.com").validGTIN)
        XCTAssertFalse(CapturedBarcode(symbology: "EAN13", value: "４００６３８１３３３９３１").validGTIN)
    }
    func testReceiptLinesKeepPrintedTextAndUnknownAmounts() throws {
        let rows = try ScanLimits.receiptLines("2 x rice  $5.?0\nTOTAL 18.00\nTARJETA")
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows[0].originalText, "2 x rice  $5.?0")
        XCTAssertTrue(rows.allSatisfy { $0.quantityNote.isEmpty && $0.priceNote.isEmpty })
        XCTAssertEqual(rows[2].reviewedText, "TARJETA")
    }
    func testImageNormalizationStripsLocationAndRejectsUnsupportedBytes() throws {
        let data = try image()
        let normalized = try ScanImageNormalizer.normalize(data)
        try ScanImageNormalizer.validateReference(normalized)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(normalized as CFData, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertNil(properties[kCGImagePropertyGPSDictionary])
        XCTAssertLessThanOrEqual(normalized.count, ScanLimits.maximumReferenceBytes)
        XCTAssertThrowsError(try ScanImageNormalizer.normalize(Data("<svg/>".utf8)))
        XCTAssertThrowsError(try ScanImageNormalizer.normalize(Data(repeating: 0, count: CaptureLimits.imageBytes + 1)))
    }
    func testSelectedFileReadRejectsOversizeAndSymlink() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("photo.jpg"), link = root.appendingPathComponent("link.jpg")
        let data = try image(); try data.write(to: file)
        XCTAssertEqual(try SelectedPhotoTransfer.boundedData(file), data)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        XCTAssertThrowsError(try SelectedPhotoTransfer.boundedData(link))
        try Data(repeating: 0, count: CaptureLimits.imageBytes + 1).write(to: file)
        XCTAssertThrowsError(try SelectedPhotoTransfer.boundedData(file))
    }
    func testRealVisionFindsCodeWithoutInventingAProduct() async throws {
        let filter = try XCTUnwrap(CIFilter(name: "CIQRCodeGenerator"))
        filter.setValue(Data("4006381333931".utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        let input = try XCTUnwrap(filter.outputImage).transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        let cg = try XCTUnwrap(CIContext().createCGImage(input, from: input.extent))
        let data = NSMutableData(); let output = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(output, cg, nil); XCTAssertTrue(CGImageDestinationFinalize(output))
        let scanned = try await OnDeviceScanService().scan(data as Data)
        XCTAssertTrue(scanned.barcodes.contains { $0.value == "4006381333931" })
        XCTAssertEqual(scanned.originalImageData, data as Data)
        XCTAssertFalse(scanned.referenceJPEG.isEmpty)
    }
}

@MainActor final class ScanMediaStoreTests: XCTestCase {
    func testExactReplayAndCurrentNamespaceAndTargetBinding() async throws {
        let root = location(); defer { try? FileManager.default.removeItem(at: root) }
        let store = CaptureMediaStore(directory: root), record = try record()
        let reference = try await store.save(record, authorize: { true })
        let replay = try await store.save(record, authorize: { true }); XCTAssertEqual(replay, reference)
        let value = try await store.read(reference, target: record.target, authorize: { true })
        XCTAssertEqual(value, record)
        let foreign = CaptureTarget(workspaceID: UUID(), containerID: record.target.containerID, objectID: record.target.objectID, revision: 0, kind: .packageReference)
        await fails { _ = try await store.read(reference, target: foreign, authorize: { true }) }
        let other = CaptureTarget(workspaceID: record.target.workspaceID, containerID: record.target.containerID, objectID: UUID(), revision: 0, kind: .packageReference)
        await fails { _ = try await store.read(reference, target: other, authorize: { true }) }
        await fails { _ = try await store.read(reference, target: record.target, authorize: { false }) }
        let changed = SourceMediaRecord(id: record.id, target: record.target, originalText: record.originalText, reviewedLabel: "Changed", imageJPEG: record.imageJPEG, barcode: nil, receiptLines: [], capturedAt: record.capturedAt)
        await fails { _ = try await store.save(changed, authorize: { true }) }
    }
    func testErasureAndRemovalRejectLateCallbacksAfterRestart() async throws {
        let root = location(); defer { try? FileManager.default.removeItem(at: root) }
        let store = CaptureMediaStore(directory: root), record = try record()
        let ref = try await store.save(record, authorize: { true })
        try await store.remove(ref, target: record.target, authorize: { true })
        await fails { _ = try await CaptureMediaStore(directory: root).save(record, authorize: { true }) }
        let next = try self.record(target: record.target)
        _ = try await store.save(next, authorize: { true })
        try await store.eraseWorkspace(record.target.workspaceID)
        let reopened = CaptureMediaStore(directory: root)
        await fails { _ = try await reopened.save(next, authorize: { true }) }
        await fails { _ = try await reopened.read(next.reference, target: next.target, authorize: { true }) }
    }
    func testPickupRecordErasurePreservesOtherJourneys() async throws {
        let root = location(); defer { try? FileManager.default.removeItem(at: root) }
        let store = CaptureMediaStore(directory: root), workspace = UUID()
        let one = try record(target: .init(workspaceID: workspace, containerID: UUID(), objectID: UUID(), revision: 0, kind: .receiptEvidence))
        let two = try record(target: .init(workspaceID: workspace, containerID: UUID(), objectID: UUID(), revision: 0, kind: .receiptEvidence))
        _ = try await store.save(one, authorize: { true }); _ = try await store.save(two, authorize: { true })
        try await store.erasePickupRecord(workspaceID: workspace, recordID: one.target.containerID)
        await fails { _ = try await store.save(one, authorize: { true }) }
        let remaining = try await store.read(two.reference, target: two.target, authorize: { true }); XCTAssertEqual(remaining, two)
    }
    func testScopeInvalidationDuringSaveLeavesNoNewEvidence() async throws {
        let root = location(); defer { try? FileManager.default.removeItem(at: root) }
        let store = CaptureMediaStore(directory: root), record = try record()
        let probe = AuthorizationProbe()
        await fails { _ = try await store.save(record, authorize: { probe.next() }) }
        let values = try await store.list(target: record.target, authorize: { true })
        XCTAssertTrue(values.isEmpty)
    }
    func testPersistedImageCountBoundAndNoAutomaticEviction() async throws {
        let root = location(); defer { try? FileManager.default.removeItem(at: root) }
        let store = CaptureMediaStore(directory: root), first = try record()
        for _ in 0..<ScanLimits.maximumWorkspaceRecords { _ = try await store.save(try record(target: first.target), authorize: { true }) }
        await fails { _ = try await store.save(try self.record(target: first.target), authorize: { true }) }
        let values = try await store.list(target: first.target, authorize: { true })
        XCTAssertEqual(values.count, ScanLimits.maximumWorkspaceRecords)
    }
    func testSymlinkEvidenceFileCannotEscapeStore() async throws {
        let root = location(), outside = location(); defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
        let store = CaptureMediaStore(directory: root), record = try record()
        let reference = try await store.save(record, authorize: { true })
        let folder = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey]).first { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true })
        let file = folder.appendingPathComponent(record.id.uuidString.lowercased() + ".json")
        let bytes = try Data(contentsOf: file); try bytes.write(to: outside); try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: outside)
        await fails { _ = try await store.read(reference, target: record.target, authorize: { true }) }
        XCTAssertEqual(try Data(contentsOf: outside), bytes)
    }
    func testDEBUGStoreIsolation() {
        let base = location()
        let normal = CaptureMediaStore.defaultDirectory(applicationSupport: base, arguments: [])
        let ui = CaptureMediaStore.defaultDirectory(applicationSupport: base, arguments: ["--ui-testing", "--reset-test-workspace"])
        #if DEBUG
        XCTAssertNotEqual(normal, ui); XCTAssertTrue(ui.path.contains("/UITestWorkspace/"))
        #else
        XCTAssertEqual(normal, ui)
        #endif
    }
    private func location() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    private func record(target: CaptureTarget? = nil) throws -> SourceMediaRecord {
        .init(id: UUID(), target: target ?? .init(workspaceID: UUID(), containerID: UUID(), objectID: UUID(), revision: 1, kind: .packageReference), originalText: "2 tortillas", reviewedLabel: "Tortillas", imageJPEG: try ScanImageNormalizer.normalize(image()), barcode: nil, receiptLines: [], capturedAt: Date(timeIntervalSince1970: 123))
    }
    private func fails(_ work: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        do { try await work(); XCTFail("Expected rejection", file: file, line: line) } catch {}
    }
}
@MainActor private final class AuthorizationProbe { private var count = 0; func next() -> Bool { count += 1; return count == 1 } }
private func image() throws -> Data {
    let context = try XCTUnwrap(CGContext(data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 128, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
    context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
    let data = NSMutableData(); let output = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(output, try XCTUnwrap(context.makeImage()), [kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 12.3, kCGImagePropertyGPSLongitude: 45.6]] as CFDictionary)
    XCTAssertTrue(CGImageDestinationFinalize(output)); return data as Data
}

final class RecipeCaptureAdapterTests: XCTestCase {
    func testBilingualHeadingsSeparateIngredientsAndInstructions() throws {
        let draft = try RecipeOCRParser.draft("Tacos\nRinde: 4\nIngredientes\n2 paquetes de 6 tortillas\nPreparación\nCaliente las tortillas\n")
        XCTAssertEqual(draft.title, "Tacos"); XCTAssertEqual(draft.servings, "4")
        XCTAssertEqual(draft.ingredientText, "2 paquetes de 6 tortillas")
        XCTAssertEqual(draft.notes, "Caliente las tortillas"); XCTAssertFalse(draft.confirmed)
        let unstructured = try RecipeOCRParser.draft("Dinner\n2 apples\nBake for 20 minutes")
        XCTAssertTrue(unstructured.servings.isEmpty); XCTAssertTrue(unstructured.ingredientText.isEmpty)
        XCTAssertTrue(unstructured.unclassifiedText.contains("Bake"))
    }
    func testReviewedRecipeKeepsOriginalSeparateAndDoesNotChooseAMeal() throws {
        let original = "Tacos\nServes 4\nIngredients\n2 packs of 6 wraps\nInstructions\nWarm wraps"
        var draft = try RecipeOCRParser.draft(original)
        draft.title = "Family tacos"; draft.notes = "Our own method"; draft.sourceURL = "https://example.com/old-recipe"; draft.confirmed = true
        var row = try XCTUnwrap(StructuredCaptureParser.lines(draft.ingredientText, destination: "Recipe").first)
        row.confirmed = true
        let line = try XCTUnwrap(row.reviewed(expectedDestination: "Recipe"))
        let target = CaptureTarget(workspaceID: UUID(), containerID: UUID(), objectID: UUID(), revision: 0, kind: .recipeSource)
        let captured = UUID()
        let template = try draft.template(captureID: captured, target: target, originalText: original, kind: .photoOCR, hasImage: true, reviewedIngredients: [line])
        XCTAssertEqual(template.id, target.objectID); XCTAssertEqual(template.title, "Family tacos")
        XCTAssertEqual(template.notes, "Our own method"); XCTAssertEqual(template.sourceEvidence?.originalText, original)
        XCTAssertEqual(template.sourceEvidence?.localMediaID(in: .activeNativeWorkspace(target.workspaceID)), captured)
        XCTAssertNil(template.sourceEvidence?.localMediaID(in: .importedOrRecovered))
        XCTAssertEqual(template.ingredients.first?.quantity?.amount.description, "12")
        let workspace = LedgerWorkspace()
        XCTAssertTrue(workspace.shops.isEmpty); XCTAssertTrue(workspace.mealTemplates.isEmpty)
    }
    func testUnknownServingsAndUnreviewedRowsRequireCorrection() throws {
        var draft = RecipeCaptureDraft(); draft.title = "Rice"; draft.confirmed = true
        let target = CaptureTarget(workspaceID: UUID(), containerID: UUID(), objectID: UUID(), revision: 0, kind: .recipeSource)
        let row = CaptureImportLine(originalText: "rice", name: "rice", unresolvedFields: [.negation])
        XCTAssertThrowsError(try draft.template(captureID: UUID(), target: target, originalText: "Rice", kind: .typed, hasImage: false, reviewedIngredients: [row]))
        draft.servings = "4"; draft.sourceURL = "file:///private/recipe"; draft.confirmed = true
        XCTAssertThrowsError(try draft.template(captureID: UUID(), target: target, originalText: "Rice", kind: .typed, hasImage: false, reviewedIngredients: [row]))
        draft.sourceURL = ""; draft.confirmed = true
        XCTAssertThrowsError(try draft.template(captureID: UUID(), target: target, originalText: "Rice", kind: .typed, hasImage: false, reviewedIngredients: [row]))
    }
}

@MainActor final class ScanModelTests: XCTestCase {
    func testTypedFallbackAndExactlyOneReviewedCallback() throws {
        let model = ScanModel(text: "Package notes")
        let target = CaptureTarget(workspaceID: UUID(), containerID: UUID(), objectID: UUID(), revision: 0, kind: .packageReference)
        model.confirmed = true
        let record = try model.reviewed(target: target, label: "Rice", barcode: nil)
        XCTAssertEqual(record.originalText, "Package notes"); XCTAssertNil(record.imageJPEG)
        XCTAssertThrowsError(try model.reviewed(target: target, label: "Rice", barcode: nil))
    }
    func testPasteKeepsOriginalAfterUserCorrection() throws {
        let model = ScanModel(); model.paste(["rize"]); model.text = "rice"; model.confirmed = true
        let target = CaptureTarget(workspaceID: UUID(), containerID: UUID(), objectID: UUID(), revision: 0, kind: .packageReference)
        let record = try model.reviewed(target: target, label: "Rice", barcode: nil)
        XCTAssertEqual(record.originalText, "rize"); XCTAssertEqual(model.source, .paste)
    }
    func testRevokingPhotoConsentRejectsLateResultAndKeepsTyping() async throws {
        let service = HeldScan(), model = ScanModel(text: "Keep typed", service: service)
        model.stage(try image())
        let deadline = Date().addingTimeInterval(2)
        while !(await service.waiting), Date() < deadline { await Task.yield() }
        let waiting = await service.waiting; XCTAssertTrue(waiting)
        model.revokePhotoConsent()
        await service.complete(ScannedSource(originalText: "Late photo", uncertainLines: [], originalImageData: Data(), referenceJPEG: Data(), barcodes: []))
        for _ in 0..<20 { await Task.yield() }
        XCTAssertFalse(model.closed); XCTAssertFalse(model.busy)
        XCTAssertNil(model.candidate); XCTAssertNil(model.accepted); XCTAssertEqual(model.text, "Keep typed")
        model.confirmed = true
        let target = CaptureTarget(workspaceID: UUID(), containerID: UUID(), objectID: UUID(), revision: 0, kind: .packageReference)
        XCTAssertNil(try model.reviewed(target: target, label: "Rice", barcode: nil).imageJPEG)
    }
    func testLatePhotoCompletionCannotRestoreClosedSource() async throws {
        let service = HeldScan(), model = ScanModel(text: "Keep typed", service: service)
        model.stage(try image())
        let deadline = Date().addingTimeInterval(2)
        while !(await service.waiting), Date() < deadline { await Task.yield() }
        let waiting = await service.waiting; XCTAssertTrue(waiting)
        model.close()
        await service.complete(ScannedSource(originalText: "Late photo", uncertainLines: [], originalImageData: Data(), referenceJPEG: Data(), barcodes: []))
        for _ in 0..<20 { await Task.yield() }
        XCTAssertTrue(model.closed); XCTAssertNil(model.candidate); XCTAssertNil(model.accepted); XCTAssertTrue(model.text.isEmpty)
    }
}
private actor HeldScan: LocalScanService {
    private var continuation: CheckedContinuation<ScannedSource, Error>?
    var waiting: Bool { continuation != nil }
    func scan(_ data: Data) async throws -> ScannedSource { try await withCheckedThrowingContinuation { continuation = $0 } }
    func complete(_ source: ScannedSource) { continuation?.resume(returning: source); continuation = nil }
}
