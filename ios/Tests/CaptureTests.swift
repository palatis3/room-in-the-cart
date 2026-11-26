import XCTest
import AVFoundation
import HouseholdClient
import CoreDomain
import CryptoKit
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
    func testReviewedPriceImageWordingPreservesOriginalAndLeavesCheckoutAmountsForTheShopper() throws {
        let digest = Data(repeating: 1, count: 32)
        let original = try PriceImageLine(digest: digest, ordinal: 1, wording: "2 por $? socios", uncertain: true)
        let reading = try ReviewedImageWording(text: "2 por $5 socios", method: .assistedImage, cropDigest: Data(repeating: 2, count: 32))
        let reviewed = try PriceImageLine(digest: digest, ordinal: 1, wording: original.wording, uncertain: true, reviewedReading: reading)
        XCTAssertEqual(original.shelfID, reviewed.shelfID)
        XCTAssertNil(ReviewedShelfImage.propose(reviewed.effectiveWording).currencyCode)
        let unknownTotal = try ReviewedCheckoutImage(charges: [.init(field: .total, amount: nil, inclusion: .unknown, line: reviewed)])
        let saved = try JSONDecoder().decode(ReviewedCheckoutImage.self, from: JSONEncoder().encode(unknownTotal))
        XCTAssertEqual(saved.charges.first?.line.wording, original.wording)
        XCTAssertEqual(saved.charges.first?.line.reviewedReading, reading)
        let repeated = try PriceImageLine(digest: digest, ordinal: 4, wording: "Total?", uncertain: true, reviewedReading: reading)
        XCTAssertThrowsError(try ReviewedCheckoutImage(charges: saved.charges + [.init(field: .subtotal, amount: nil, inclusion: .unknown, line: repeated)]))
        XCTAssertNil(saved.displayedTotal)
        XCTAssertEqual(saved.charges.first?.inclusion, .unknown)

        let cropOnly = try PriceImageLine(digest: digest, ordinal: 1, wording: "", uncertain: true, reviewedReading: reading)
        let other = try ReviewedImageWording(text: "Fee", method: .deviceOCR, cropDigest: Data(repeating: 3, count: 32))
        XCTAssertNotEqual(cropOnly.shelfID, try PriceImageLine(digest: digest, ordinal: 1, wording: "", uncertain: true, reviewedReading: other).shelfID)
        let legacy = try JSONSerialization.data(withJSONObject: ["digest": digest.base64EncodedString(), "ordinal": 1, "wording": original.wording, "uncertain": true])
        XCTAssertEqual(try JSONDecoder().decode(PriceImageLine.self, from: legacy), original)
    }

    func testConsentedVoiceClipIsPreviewedThenAddedThroughOrdinaryListReview() async throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 9_600))
        buffer.frameLength = 9_600
        let floats = try XCTUnwrap(buffer.floatChannelData?[0])
        for i in 0..<Int(buffer.frameLength) { floats[i] = Float(sin(Double(i) * 0.05) * 0.3) }
        let recorded = try VoiceListSampleBuffer(input: format)
        recorded.append(buffer)
        let clip = try recorded.clip()
        XCTAssertGreaterThan(clip.duration, 0.15)
        XCTAssertLessThanOrEqual(clip.duration, 0.20)
        XCTAssertEqual(try AVAudioPlayer(data: clip.playbackWAV).duration, clip.duration, accuracy: 0.001)
        XCTAssertEqual(clip.playbackWAV.dropFirst(44), clip.pcm)
        let input = try VoiceTranscriptionRequest(consentingTo: clip, language: "es")
        let raw = "leche y pan"
        let server = S24FixtureServer()
        defer { server.close() }
        let transport = HTTPTransport(session: server.makeSession())
        let auth = AdultAuth(configuration: try .init(projectURL: server.baseURL, publishableKey: "sb_publishable_fixture_only"),
                             vault: S24FixtureVault(), transport: transport)
        let client = HouseholdService(configuration: try .init(baseURL: server.baseURL), auth: auth, deviceVault: S24FixtureVault(), transport: transport)
        _ = try await auth.verifyEmailCode(email: "person@example.invalid", code: "123456")
        _ = try await client.enroll(householdID: S24FixtureServer.household)
        server.intercept = { call in
            guard call.request.url?.path.hasSuffix("/capture-assistance/transcription") == true else { return false }
            do {
                let value: [String:Any]
                if call.request.httpMethod == "GET" {
                    XCTAssertNil(call.request.httpBody)
                    value = ["version":1,"available":true]
                } else {
                    var bytes = call.request.httpBody ?? Data()
                    if bytes.isEmpty, let stream = call.request.httpBodyStream {
                        stream.open(); defer { stream.close() }
                        var buffer = [UInt8](repeating: 0, count: 4096)
                        while stream.hasBytesAvailable {
                            let count = stream.read(&buffer, maxLength: buffer.count)
                            guard count > 0 else { break }
                            bytes.append(buffer, count: count)
                        }
                    }
                    let sent = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String:Any])
                    XCTAssertEqual(sent["pcm"] as? String, clip.pcm.base64EncodedString())
                    XCTAssertEqual(sent["consent"] as? Bool, true)
                    XCTAssertEqual(sent["language"] as? String, "es")
                    value = ["version":1,"requestID":input.requestID.uuidString,"language":"es","text":raw]
                }
                let response = try XCTUnwrap(HTTPURLResponse(url: XCTUnwrap(call.request.url), statusCode: 200, httpVersion: nil, headerFields: nil))
                call.client?.urlProtocol(call, didReceive: response, cacheStoragePolicy: .notAllowed)
                call.client?.urlProtocol(call, didLoad: try JSONSerialization.data(withJSONObject: value))
                call.client?.urlProtocolDidFinishLoading(call)
            } catch { call.client?.urlProtocol(call, didFailWithError: error) }
            return true
        }
        let scope = ReceiptAssistanceScope(subject: "fixture-adult", householdID: S24FixtureServer.household,
            memberID: S24FixtureServer.member, shopID: S24FixtureServer.shop)
        let available = try await client.voiceTranscriptionAvailable(scope: scope)
        XCTAssertTrue(available)
        let transcript = try await client.transcribeVoiceList(input, scope: scope)
        let model = make()
        model.stageOnlineTranscript(transcript.text)
        XCTAssertEqual(model.text, "12 wraps")
        XCTAssertNil(model.reviewed())
        model.acceptCandidate()
        XCTAssertTrue(model.naturalListMode)
        model.text = "leche y pan integral"
        model.confirmed = true
        let lines = try model.fields(forList: true, destination: "This pickup").lines.map { line in
            var row = line; row.confirmed = true
            return try XCTUnwrap(row.reviewed(expectedDestination: "This pickup"))
        }
        let capture = try XCTUnwrap(model.reviewed(lines: lines))
        var shop = ShoppingLedger()
        let preview = try CaptureLedgerImport.stage(capture, in: shop)
        XCTAssertTrue(shop.contributions.isEmpty)
        try shop.commitImport(preview.preview)
        XCTAssertEqual(shop.importBatches.first?.preview.source, .assistedVoice)
        XCTAssertEqual(shop.importBatches.first?.preview.originalText, raw)
        XCTAssertEqual(shop.contributions.count, 2)
        XCTAssertTrue(try CaptureLedgerImport.stage(capture, in: shop).alreadyApplied)
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
    func testAcceptedSpeechOffersNaturalListOnlyToShopperAndCanUseOneLineInstead() async throws {
        let speech = FakeSpeech()
        let model = make(speech)
        model.startSpeech()
        await settle { model.listening }
        let words = "Two milks, bread and cereal for next week"
        speech.yield(.init(text: words, isFinal: true, uncertain: false))
        await settle { !model.busy && model.candidate != nil }
        XCTAssertFalse(model.naturalListMode)
        model.acceptCandidate()
        XCTAssertTrue(model.naturalListMode)
        let proposal = try model.fields(forList: true, destination: "Friday")
        XCTAssertEqual(proposal.lines.map(\.name), ["milks", "bread", "cereal"])
        XCTAssertEqual(proposal.timing, "for next week")
        XCTAssertEqual(try model.fields(forList: false, destination: "Family").lines.count, 1)
        model.naturalListMode = false
        XCTAssertEqual(try model.fields(forList: true, destination: "Friday").lines.count, 1)
        XCTAssertEqual(model.acceptedEvidence?.text, words)
    }

    func testInterruptedSpeechRetainsBothPartialCandidateAndTypedFallback() async throws {
        let speech = FakeSpeech()
        let model = make(speech)
        model.startSpeech()
        await settle { model.listening }
        speech.yield(.init(text: "pan y leche", isFinal: false, uncertain: true))
        await settle { model.candidate != nil }
        speech.interrupt()
        await settle { model.failure == .audioUnavailable && !model.busy }
        XCTAssertEqual(model.text, "12 wraps")
        XCTAssertFalse(speech.active)
        model.acceptCandidate()
        XCTAssertEqual(try model.fields(forList: true, destination: "Compra").lines.map(\.name), ["pan", "leche"])
        XCTAssertNil(model.reviewed())
    }

    func testExplicitPasteChoosesOneRealPickupBeforeStagingAndExactReplay() throws {
        let current = ShoppingLedger(title: "Weekend")
        let next = ShoppingLedger(title: "Weekend")
        let pickups = [current, next].map(CapturePickup.init)
        var workspace = LedgerWorkspace(shops: [current, next], selectedShopID: current.id)
        let model = make()
        let words = "2,5 litros de leche y pan para la próxima compra"
        XCTAssertFalse(model.naturalListMode)
        model.naturalListMode = true
        model.stagePaste([words])
        model.acceptCandidate()
        XCTAssertTrue(model.naturalListMode)
        let proposal = try model.fields(forList: true, destination: current.title)
        XCTAssertEqual(proposal.lines.count, 2)
        XCTAssertEqual(proposal.lines[0].unit, .liter)
        var batch = NaturalCaptureBatch(timing: proposal.timing, lines: proposal.lines, currentPickup: pickups[0])
        XCTAssertNil(batch.pickup)
        XCTAssertThrowsError(try batch.reviewed(proposal.lines, availablePickups: pickups))
        batch.pickup = pickups[1]
        XCTAssertThrowsError(try batch.reviewed(proposal.lines, availablePickups: [pickups[0]]))
        let rows = try batch.reviewed(proposal.lines, availablePickups: pickups)
        XCTAssertFalse(model.confirmed)
        XCTAssertNil(model.reviewed())
        var capture = try XCTUnwrap(model.reviewed(lines: rows, fieldDrafts: proposal.lines, naturalBatch: batch))
        let staged = try CaptureLedgerImport.stage(capture, in: workspace, currentShopID: current.id)
        XCTAssertEqual(staged.preview.shopID, next.id)
        XCTAssertEqual(staged.preview.originalText, words)
        XCTAssertEqual(staged.preview.source, .paste)
        XCTAssertEqual(staged.preview.lines.map(\.id), proposal.lines.map(\.id))
        XCTAssertEqual(staged.preview.lines.map(\.proposedLineID), proposal.lines.map(\.proposedLineID))
        XCTAssertTrue(workspace.shops.allSatisfy { $0.lines.isEmpty })
        XCTAssertThrowsError(try CaptureLedgerImport.stage(capture, in: workspace, currentShopID: next.id))
        try workspace.shops[1].commitImport(staged.preview)
        let replay = try CaptureLedgerImport.stage(capture, in: workspace, currentShopID: current.id)
        XCTAssertTrue(replay.alreadyApplied)
        XCTAssertEqual(replay.preview, staged.preview)
        batch.pickup = pickups[0]
        capture.naturalBatch = batch
        XCTAssertThrowsError(try CaptureLedgerImport.stage(capture, in: workspace, currentShopID: current.id))
        XCTAssertTrue(workspace.shops[0].lines.isEmpty)
        XCTAssertEqual(workspace.shops[1].lines.count, 2)
    }

    func testMixedTimingKeepsEditableWordsAndGroupedGuestWordingRequiresAnOverride() throws {
        let model = make()
        model.naturalListMode = true
        model.text = "milk for this week, bread for next week"
        XCTAssertThrowsError(try model.fields(forList: true, destination: "Today")) {
            XCTAssertEqual($0 as? StructuredCaptureFailure, .timingReviewRequired)
        }
        XCTAssertEqual(model.text, "milk for this week, bread for next week")
        model.text = "tea; two more guests"
        XCTAssertThrowsError(try model.fields(forList: true, destination: "Today")) {
            XCTAssertEqual($0 as? StructuredCaptureFailure, .guestReviewRequired)
        }
        XCTAssertEqual(try model.fields(forList: true, destination: "Today", explicitlyTreatAsItems: true).lines.count, 2)
    }

    func testUnknownDestinationAndAmbiguousProductNeedReviewOnce() throws {
        let current = ShoppingLedger(title: "Friday")
        let pickup = CapturePickup(current)
        let proposal = try StructuredCaptureParser.naturalList("mango and sticky rice; eggs to Mars", destination: current.title)
        var drafts = proposal.lines
        XCTAssertTrue(drafts[0].needsNaturalClarification)
        var batch = NaturalCaptureBatch(timing: proposal.timing, lines: drafts, currentPickup: pickup)
        XCTAssertNil(batch.pickup)
        batch.pickup = pickup
        XCTAssertThrowsError(try batch.reviewed(drafts, availablePickups: [pickup]))
        drafts[0].name = "mango sticky rice"
        drafts[0].confirmed = true
        let rows = try batch.reviewed(drafts, availablePickups: [pickup])
        XCTAssertEqual(rows.map(\.name), ["mango sticky rice", "eggs"])
        XCTAssertEqual(rows.map(\.destination), ["Friday", "Friday"])
        var changed = current
        changed.title = "Monday"
        let renamedPickup = CapturePickup(changed)
        XCTAssertThrowsError(try batch.reviewed(drafts, availablePickups: [renamedPickup]))
        batch.refreshPickups([renamedPickup])
        XCTAssertNil(batch.pickup)
        batch.pickup = renamedPickup
        let refreshed = try batch.reviewed(drafts, availablePickups: [renamedPickup])
        XCTAssertEqual(refreshed.map(\.id), rows.map(\.id))
        XCTAssertEqual(refreshed.map(\.name), rows.map(\.name))
        XCTAssertEqual(refreshed.map(\.destination), ["Monday", "Monday"])
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
    func testRepairReplacesOnlySelectedOccurrenceAndKeepsOriginalEvidence() async throws {
        let speech = FakeSpeech(), original = "🥑 pan, pan y dos peras"
        let model = make(speech)
        let secondPan = try XCTUnwrap(SpeechWordRepair(text: original, range: (original as NSString).range(of: "pan", options: .backwards),
            word: "pan", alternatives: ["pan", "panqué", "panqué", "flan", "extra"]))
        let peras = try XCTUnwrap(SpeechWordRepair(text: original, range: (original as NSString).range(of: "peras"),
            word: "peras", alternatives: ["perras"]))
        XCTAssertNil(SpeechWordRepair(text: original, range: NSRange(location: 1, length: 4), word: "pan", alternatives: ["flan"]))
        XCTAssertEqual(secondPan.alternatives, ["panqué", "flan"])
        model.startSpeech()
        await settle { model.listening }
        speech.yield(.init(text: original, isFinal: true, uncertain: true, repairs: [secondPan, peras]))
        await settle { !model.busy && model.candidate?.text == original }
        XCTAssertEqual(model.text, "12 wraps")
        model.acceptCandidate()
        model.resolveWord(secondPan, as: "panqué")
        XCTAssertEqual(model.text, "🥑 pan, panqué y dos peras")
        model.resolveWord(peras, as: "perras") // Stale pre-edit range.
        XCTAssertEqual(model.text, "🥑 pan, panqué y dos peras")
        let shifted = try XCTUnwrap(model.wordRepairs.first)
        model.resolveWord(shifted, as: "manzanas")
        XCTAssertEqual(model.text, "🥑 pan, panqué y dos manzanas")
        XCTAssertTrue(model.wordRepairs.isEmpty)
        model.confirmed = true
        let result = try XCTUnwrap(model.reviewed())
        XCTAssertEqual(result.originalText, original)
        XCTAssertEqual(result.text, "🥑 pan, panqué y dos manzanas")
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
    func testPriceImageOCRPreservesMembershipWordingAndNeverInfersCheckoutTotalFromSubtotal() async throws {
        let image = try imageOfPriceText([("Members only 2 for $5 USD 500 g", 110), ("Subtotal $18", 40)])
        let evidence = try await OnDeviceTextCapture().recognize(image)
        let text = evidence.text.split(separator: "\n").map(String.init)
        let label = try XCTUnwrap(text.first(where: { $0.localizedCaseInsensitiveContains("members") }))
        let proposal = ReviewedShelfImage.propose(label)
        XCTAssertEqual(proposal.packages, 2)
        XCTAssertEqual(proposal.amountMinor, 500)
        XCTAssertEqual(proposal.conditions, label)
        XCTAssertEqual(proposal.packageSize?.amount, try Rational(500))
        XCTAssertEqual(proposal.packageSize?.unit, .gram)
        let i = try XCTUnwrap(text.firstIndex(where: { $0.localizedCaseInsensitiveContains("subtotal") }))
        let line = try PriceImageLine(digest: Data(SHA256.hash(data: image)), ordinal: i, wording: text[i],
            uncertain: evidence.uncertainLines.contains(text[i]))
        let offers = ReviewedCheckoutImage.proposals(from: [line])
        let subtotal = try XCTUnwrap(offers[.subtotal])
        XCTAssertEqual(subtotal.amount?.minorUnits, 1800)
        let checkout = try ReviewedCheckoutImage(charges: [subtotal])
        XCTAssertNil(checkout.displayedTotal)
        XCTAssertEqual(checkout.charges.first?.line.wording, text[i])
    }

    private func imageOfPriceText(_ rows: [(String, CGFloat)]) throws -> Data {
        let context = CGContext(data: nil, width: 1000, height: 180, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 1000, height: 180))
        for (text, y) in rows {
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
        return output as Data
    }
    func testActualVisionOCRReadsLocalSyntheticImage() async throws {
        let image = try imageOfPriceText([("12 wraps", 110), ("2 kg rice", 40)])
        let evidence = try await OnDeviceTextCapture().recognize(image)
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
    func interrupt() { stream?.finish(throwing: CaptureFailure.audioUnavailable) }
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
