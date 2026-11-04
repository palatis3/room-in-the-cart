import XCTest
@testable import RoomInTheCart

@MainActor final class CookReadbackTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func instruction(revision: Int64 = 3, text: String = "Tuesday · Revision 3\nUse four wraps. Save two wraps for lunch.", budgetExcluded: Bool = true) -> CookReadbackInstruction {
        .init(authorityBindingID: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!,
            sourceID: UUID(uuidString: "22222222-2222-4222-8222-222222222222")!, sourceRevision: revision,
            createdAt: now.addingTimeInterval(-30), startBefore: now.addingTimeInterval(30),
            text: text, localeIdentifier: "es-US", excludesPrivateBudget: budgetExcluded)
    }
    func testPlaybackUsesExactAuthorizedDatedProjection() {
        let value = instruction(); let speech = FakeCookSpeech()
        let model = CookReadbackModel(instruction: value, speech: speech, clock: { self.now }) { requested, _ in requested == value }
        model.playFromBeginning()
        XCTAssertEqual(speech.spoken, [value.text]); XCTAssertEqual(speech.locales, ["es-US"])
        XCTAssertEqual(model.state, .speaking)
        model.close()
    }
    func testDeniedSourceAndPrivateBudgetCannotPlay() {
        for value in [instruction(), instruction(budgetExcluded: false)] {
            let speech = FakeCookSpeech()
            let model = CookReadbackModel(instruction: value, speech: speech, clock: { self.now }) { _, _ in false }
            model.playFromBeginning()
            XCTAssertTrue(speech.spoken.isEmpty); XCTAssertFalse(model.canRead)
            model.close()
        }
        let speech = FakeCookSpeech()
        let model = CookReadbackModel(instruction: instruction(budgetExcluded: false), speech: speech, clock: { self.now }) { _, _ in true }
        model.playFromBeginning(); XCTAssertTrue(speech.spoken.isEmpty); model.close()
    }
    func testVoiceOverIsExclusiveAndDoesNotAutoResume() {
        let speech = FakeCookSpeech()
        let model = CookReadbackModel(instruction: instruction(), speech: speech, clock: { self.now }) { _, _ in true }
        model.setVoiceOver(true); model.playFromBeginning()
        XCTAssertTrue(speech.spoken.isEmpty)
        model.setVoiceOver(false); XCTAssertEqual(model.state, .stopped)
        model.playFromBeginning(); XCTAssertEqual(speech.spoken.count, 1)
        model.setVoiceOver(true); XCTAssertEqual(model.state, .stopped)
        model.setVoiceOver(false); XCTAssertEqual(speech.spoken.count, 1)
        model.close()
    }
    func testSourceRevisionChangeStopsAndOldFinishCannotStopNewPlayback() {
        let speech = FakeCookSpeech()
        let model = CookReadbackModel(instruction: instruction(), speech: speech, clock: { self.now }) { _, _ in true }
        model.playFromBeginning(); let oldID = speech.ids.last!
        let fresh = instruction(revision: 4, text: "Tuesday · Revision 4\nSave all four wraps for lunch.")
        model.update(fresh); XCTAssertEqual(model.state, .stopped)
        model.playFromBeginning()
        speech.onEnd?(oldID)
        XCTAssertEqual(model.state, .speaking); XCTAssertEqual(speech.spoken.last, fresh.text)
        speech.onEnd?(speech.ids.last!)
        XCTAssertEqual(model.state, .stopped)
        model.close()
    }
    func testResumeRechecksAuthorityAndRequiresExplicitAction() {
        var allowed = true
        let speech = FakeCookSpeech()
        let model = CookReadbackModel(instruction: instruction(), speech: speech, clock: { self.now }) { _, _ in allowed }
        model.playFromBeginning(); model.pause(); XCTAssertEqual(model.state, .paused)
        allowed = false; model.resume()
        XCTAssertEqual(model.state, .stopped); XCTAssertEqual(speech.resumes, 0)
        allowed = true; model.checkCurrent()
        XCTAssertEqual(model.state, .stopped); XCTAssertEqual(speech.spoken.count, 1)
        model.close()
    }
    func testExpiredAuthorityStopsCurrentPlayback() {
        var instant = now
        let deadline = now.addingTimeInterval(5)
        let speech = FakeCookSpeech()
        let model = CookReadbackModel(instruction: instruction(), speech: speech, clock: { instant }) { _, at in at < deadline }
        model.playFromBeginning(); XCTAssertEqual(model.state, .speaking)
        instant = deadline; model.checkCurrent()
        XCTAssertEqual(model.state, .stopped); XCTAssertFalse(model.canRead)
        model.close()
    }
    func testRouteCloseCannotBeReactivated() {
        let speech = FakeCookSpeech()
        let model = CookReadbackModel(instruction: instruction(), speech: speech, clock: { self.now }) { _, _ in true }
        model.playFromBeginning(); model.close()
        model.playFromBeginning(); model.resume(); model.update(instruction(revision: 4))
        XCTAssertEqual(model.state, .stopped); XCTAssertEqual(speech.spoken.count, 1)
    }
    func testUnavailableLocalVoiceKeepsVisibleTextWithoutFallback() {
        let speech = FakeCookSpeech(); speech.failure = .onDeviceUnavailable
        let value = instruction()
        let model = CookReadbackModel(instruction: value, speech: speech, clock: { self.now }) { _, _ in true }
        model.playFromBeginning()
        XCTAssertTrue(model.unavailable); XCTAssertTrue(model.canRead)
        XCTAssertEqual(model.instruction.text, value.text); XCTAssertEqual(model.state, .stopped)
        model.close()
    }
}
@MainActor final class FakeCookSpeech: CookSpeechPlayback {
    var onEnd: ((UUID) -> Void)?
    var spoken: [String] = []; var locales: [String] = []; var ids: [UUID] = []
    var resumes = 0; var stops = 0; var failure: CaptureFailure?
    func speak(_ text: String, localeIdentifier: String, playbackID: UUID) throws {
        if let failure { throw failure }
        spoken.append(text); locales.append(localeIdentifier); ids.append(playbackID)
    }
    func pause() -> Bool { true }
    func resume() throws -> Bool { resumes += 1; return true }
    func stop() { stops += 1 }
}
