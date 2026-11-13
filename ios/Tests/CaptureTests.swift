import XCTest
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers
@testable import RoomInTheCart

@MainActor final class CaptureTests: XCTestCase {
    private func make(_ speech: FakeSpeech? = nil, _ ocr: any CaptureOCRService = FakeOCR()) -> CaptureModel {
        CaptureModel(initialText: "12 wraps", localeIdentifier: "es-US", speech: speech ?? FakeSpeech(), ocr: ocr)
    }
    private func settle(_ condition: () -> Bool) async {
        for _ in 0..<2000 { if condition() { return }; await Task.yield() }
        XCTFail("Capture operation did not settle")
    }
    func testTypedReviewRequiresConfirmationAndDeliversExactlyOnce() {
        let model = make()
        XCTAssertNil(model.reviewed())
        model.confirmed = true
        let value = model.reviewed()
        XCTAssertEqual(value?.text, "12 wraps")
        XCTAssertEqual(value?.source, .typed)
        XCTAssertEqual(value?.localeIdentifier, "es-US")
        XCTAssertNil(model.reviewed())
    }
    func testEditingInvalidatesConfirmation() {
        let model = make(); model.confirmed = true; model.text = "6 wraps"
        XCTAssertFalse(model.confirmed); XCTAssertNil(model.reviewed())
    }
    func testPasteIsCandidateUntilExplicitlyAccepted() {
        let model = make()
        model.stagePaste(["2 kg rice", "sin leche"])
        XCTAssertEqual(model.text, "12 wraps")
        model.confirmed = true; XCTAssertNil(model.reviewed())
        model.acceptCandidate()
        XCTAssertEqual(model.text, "2 kg rice\nsin leche")
        XCTAssertFalse(model.confirmed)
        XCTAssertTrue(model.containsExclusion)
        model.confirmed = true
        XCTAssertEqual(model.reviewed()?.source, .paste)
    }
    func testDiscardCapturePreservesTypedDraft() {
        let model = make(); model.stagePaste(["cereal"]); model.discardCandidate()
        XCTAssertEqual(model.text, "12 wraps"); XCTAssertNil(model.candidate)
    }
    func testPermissionDeniedPreservesTypedFallback() async {
        let speech = FakeSpeech(); speech.failure = .permissionDenied
        let model = make(speech); model.startSpeech()
        await settle { model.failure == .permissionDenied && !model.busy }
        XCTAssertEqual(model.text, "12 wraps"); XCTAssertFalse(model.listening)
        model.confirmed = true
        XCTAssertEqual(model.reviewed()?.source, .typed)
    }
    func testUnavailableOnDeviceLanguageNeverStartsOnlineFallback() async {
        let speech = FakeSpeech(); speech.failure = .onDeviceUnavailable
        let model = make(speech); model.startSpeech()
        await settle { model.failure == .onDeviceUnavailable }
        XCTAssertEqual(speech.begins, 1)
        XCTAssertFalse(speech.active)
        XCTAssertEqual(model.text, "12 wraps")
    }
    func testDictationUsesTheInterfaceLanguageForRecognitionAndReview() async {
        let speech = FakeSpeech()
        let model = CaptureModel(initialText: "Arroz", speech: speech, ocr: FakeOCR())
        model.startSpeech()
        await settle { model.listening }
        let expected = CaptureCorrectionScope.appLanguage()
        XCTAssertEqual(speech.locale, expected)
        model.stopSpeech()
        model.confirmed = true
        XCTAssertEqual(model.reviewed()?.localeIdentifier, expected)
    }
    func testRepeatedSpeechCallbackDoesNotAppendOrApply() async {
        let speech = FakeSpeech(); let model = make(speech); model.startSpeech()
        await settle { model.listening }
        let update = SpeechCaptureUpdate(text: "2 packs of wraps", isFinal: false, uncertain: true)
        speech.yield(update); speech.yield(update)
        await settle { model.candidate?.text == update.text }
        XCTAssertEqual(model.text, "12 wraps")
        model.stopSpeech(); model.acceptCandidate()
        model.text = "2 packs of 8 wraps"; model.confirmed = true
        let result = model.reviewed()
        XCTAssertEqual(result?.originalText, "2 packs of wraps")
        XCTAssertEqual(result?.text, "2 packs of 8 wraps")
        XCTAssertEqual(result?.source, .speech)
        XCTAssertNil(model.reviewed())
        XCTAssertFalse(speech.active)
    }
    func testClosingBeforeSpeechStartsDoesNotRequestPermission() async {
        let speech = FakeSpeech()
        let unexpected = expectation(description: "Speech authorization after leaving capture")
        unexpected.isInverted = true
        speech.onBegin = { unexpected.fulfill() }
        let model = make(speech)
        model.startSpeech()
        model.close()
        await fulfillment(of: [unexpected], timeout: 0.25)
        XCTAssertEqual(speech.begins, 0)
        XCTAssertFalse(model.listening)
        XCTAssertNil(model.candidate)
    }
    func testLateSpeechPermissionAfterCloseCannotRestoreDraft() async {
        let speech = FakeSpeech(); speech.pausePermission = true
        let model = make(speech); model.startSpeech()
        await settle { speech.permission != nil }
        model.close(); speech.permission?.resume()
        await settle { speech.begins == 1 && speech.stops >= 2 }
        XCTAssertTrue(model.closed); XCTAssertEqual(model.text, "")
        XCTAssertFalse(speech.active); XCTAssertNil(model.candidate); XCTAssertNil(model.reviewed())
    }
    func testLateOCRAfterCloseCannotRestoreImageOrText() async {
        let ocr = GatedOCR(); let model = make(FakeSpeech(), ocr)
        model.stageImage(Data([1, 2, 3]))
        for _ in 0..<2000 { if await ocr.waiting { break }; await Task.yield() }
        model.close()
        await ocr.complete()
        await Task.yield()
        XCTAssertTrue(model.closed); XCTAssertEqual(model.text, "")
        XCTAssertNil(model.candidate); XCTAssertNil(model.acceptedEvidence)
    }
    func testImageEvidencePreservedWhileCorrectingRecognizedText() async {
        let model = make(); model.stageImage(Data([1]))
        await settle { model.candidate != nil && !model.busy }
        XCTAssertEqual(model.text, "12 wraps")
        model.acceptCandidate(); model.text = "2 kg rice"; model.confirmed = true
        let result = model.reviewed()
        XCTAssertEqual(result?.originalText, "2 kq rice")
        XCTAssertEqual(result?.sourceImageData, Data([1]))
        XCTAssertEqual(result?.source, .photoOCR)
    }
    func testOversizedDraftAndImageFailWithoutReplacingExistingDraft() {
        let model = make()
        model.stagePaste([String(repeating: "x", count: CaptureLimits.textCharacters + 1)])
        XCTAssertEqual(model.failure, .inputTooLarge); XCTAssertEqual(model.text, "12 wraps")
        model.stageImage(Data(count: CaptureLimits.imageBytes + 1))
        XCTAssertEqual(model.failure, .inputTooLarge); XCTAssertFalse(model.busy)
        model.text = Array(repeating: "rice", count: CaptureLimits.lines + 1).joined(separator: "\n")
        model.confirmed = true; XCTAssertFalse(model.canContinue)
    }
    func testExclusionWordsUseWholeTokensAndBothLanguages() {
        XCTAssertTrue(CaptureLimits.containsExclusion("rice without milk"))
        XCTAssertTrue(CaptureLimits.containsExclusion("arroz sin leche"))
        XCTAssertFalse(CaptureLimits.containsExclusion("cinnamon single packs"))
    }
    func testThreeNearbyOCRRowsHaveDeterministicOrderAcrossPermutations() {
        // Every adjacent pair is within 0.015, but the endpoints are not.
        // A pairwise y tolerance followed by x creates a comparison cycle here.
        let rows = [CaptureTextPosition(midY: 0.900, minX: 0.9),
                    CaptureTextPosition(midY: 0.890, minX: 0.5),
                    CaptureTextPosition(midY: 0.880, minX: 0.1)]
        for permutation in [[0,1,2],[0,2,1],[1,0,2],[1,2,0],[2,0,1],[2,1,0]] {
            let positions = permutation.map { rows[$0] }
            XCTAssertEqual(CaptureReadingOrder.indices(positions).map { permutation[$0] }, [0,1,2])
        }
        let sameRow = [CaptureTextPosition(midY: 0.5, minX: 0.8),
                       CaptureTextPosition(midY: 0.5, minX: 0.1),
                       CaptureTextPosition(midY: 0.5, minX: 0.1)]
        XCTAssertEqual(CaptureReadingOrder.indices(sameRow), [1,2,0])
    }
    func testActualVisionOCRReadsLocalSyntheticImage() async throws {
        let context = CGContext(data: nil, width: 700, height: 180, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 700, height: 180))
        for (text, y) in [("12 wraps", 110), ("2 kg rice", 40)] {
            let font = CTFontCreateWithName("Helvetica" as CFString, 42, nil)
            let value = NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)])
            context.textPosition = CGPoint(x: 25, y: y)
            CTLineDraw(CTLineCreateWithAttributedString(value), context)
        }
        let image = context.makeImage()!
        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil); XCTAssertTrue(CGImageDestinationFinalize(destination))
        let evidence = try await OnDeviceTextCapture().recognize(output as Data)
        XCTAssertTrue(evidence.text.contains("12 wraps")); XCTAssertTrue(evidence.text.contains("2 kg rice"))
        XCTAssertEqual(evidence.source, .photoOCR)
        XCTAssertNotNil(evidence.previewImageData)
    }
}

@MainActor private final class FakeSpeech: CaptureSpeechService {
    var failure: CaptureFailure?
    var locale: String?
    var onBegin: (() -> Void)?
    var begins = 0; var stops = 0; var active = false
    var pausePermission = false
    var permission: CheckedContinuation<Void, Never>?
    private var stream: AsyncThrowingStream<SpeechCaptureUpdate, Error>.Continuation?
    func begin(localeIdentifier: String) async throws -> AsyncThrowingStream<SpeechCaptureUpdate, Error> {
        begins += 1
        locale = localeIdentifier
        onBegin?()
        if pausePermission { await withCheckedContinuation { permission = $0 } }
        if let failure { throw failure }
        active = true
        return AsyncThrowingStream { stream = $0 }
    }
    func yield(_ update: SpeechCaptureUpdate) { stream?.yield(update) }
    func stop() { stops += 1; active = false; stream?.finish(); stream = nil }
}
private struct FakeOCR: CaptureOCRService {
    func recognize(_ data: Data) async throws -> CaptureEvidence {
        .init(text: "2 kq rice", source: .photoOCR, uncertainLines: ["2 kq rice"], sourceImageData: data, previewImageData: data)
    }
}
private actor GatedOCR: CaptureOCRService {
    private var continuation: CheckedContinuation<CaptureEvidence, Never>?
    var waiting: Bool { continuation != nil }
    func recognize(_ data: Data) async throws -> CaptureEvidence { await withCheckedContinuation { continuation = $0 } }
    func complete() { continuation?.resume(returning: .init(text: "milk", source: .photoOCR, uncertainLines: [], sourceImageData: Data([1]), previewImageData: Data([1]))) }
}
