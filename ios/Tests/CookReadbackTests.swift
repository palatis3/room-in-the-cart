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
    func testActivationCompletionRechecksAuthorityAndCannotRestartCancelledPlayback() {
        let speech = FakeCookSpeech()
        speech.delayed = true
        var allowed = true
        let model = CookReadbackModel(instruction: instruction(), speech: speech, clock: { self.now }) { _, _ in allowed }
        model.playFromBeginning()
        XCTAssertEqual(model.state, .preparing)
        allowed = false
        speech.activations.removeFirst()(true)
        XCTAssertTrue(speech.spoken.isEmpty)
        XCTAssertEqual(model.state, .stopped)

        allowed = true
        model.playFromBeginning()
        model.stop() // The view stops synchronously when it backgrounds or disappears.
        model.update(instruction(revision: 4, text: "Updated cook note"))
        model.playFromBeginning()
        speech.activations.removeFirst()(true)
        XCTAssertTrue(speech.spoken.isEmpty)
        XCTAssertEqual(model.state, .preparing)
        speech.activations.removeFirst()(true)
        XCTAssertEqual(speech.spoken, ["Updated cook note"])
        model.pause()
        model.resume()
        model.setVoiceOver(true)
        speech.activations.removeFirst()(true)
        XCTAssertEqual(speech.resumes, 0)
        XCTAssertEqual(model.state, .stopped)
        model.close()
    }

    func testCancelledVoiceLookupCannotAcquireAudioOrRestoreCatalog() {
        let control = ControlledCookPreparation()
        control.preparation.prepare(for: UUID()) { _ in XCTFail("Cancelled preparation completed") }
        control.preparation.invalidate()
        control.lookups.removeFirst()(["es-US"])
        XCTAssertTrue(control.activations.isEmpty)
        XCTAssertNil(control.preparation.sessionID)
        XCTAssertNil(control.preparation.installedVoice(localeIdentifier: "es-US", language: { $0 }))
    }

    func testSupersededVoiceLookupCannotReplaceNewPlaybackCatalog() {
        let control = ControlledCookPreparation()
        let oldID = UUID(), newID = UUID()
        control.preparation.prepare(for: oldID) { _ in XCTFail("Superseded preparation completed") }
        var ready = false
        control.preparation.prepare(for: newID) { ready = $0 }
        control.lookups.removeFirst()(["en-US"])
        XCTAssertTrue(control.activations.isEmpty)
        control.lookups.removeFirst()(["es-US"])
        XCTAssertEqual(control.activations.count, 1)
        control.activations.removeFirst()(true)
        XCTAssertTrue(ready)
        XCTAssertEqual(control.preparation.sessionID, newID)
        XCTAssertNil(control.preparation.installedVoice(localeIdentifier: "en-US", language: { $0 }))
        XCTAssertEqual(control.preparation.installedVoice(localeIdentifier: "es-US", language: { $0 }), "es-US")
        control.preparation.invalidate()
    }

    func testLateAudioCompletionCannotReleaseNewPreparationWithSamePlaybackID() {
        let control = ControlledCookPreparation()
        let id = UUID()
        control.preparation.prepare(for: id) { _ in XCTFail("Superseded activation completed") }
        control.lookups.removeFirst()(["es-US"])
        var ready = false
        control.preparation.prepare(for: id) { ready = $0 }
        XCTAssertTrue(control.lookups.isEmpty) // Same playback retains its installed catalog.
        XCTAssertEqual(control.audioLog.events, ["acquire:\(id)", "release:\(id)", "acquire:\(id)"])
        control.activations.removeFirst()(true)
        XCTAssertFalse(ready)
        XCTAssertEqual(control.audioLog.events.count, 3) // Stale callback must not release the newer owner.
        control.activations.removeFirst()(true)
        XCTAssertTrue(ready)
        XCTAssertEqual(control.preparation.sessionID, id)
        control.preparation.invalidate()
    }

    func testPendingVoicePreparationHonorsStopVoiceOverAndAuthorityRevocation() {
        for revocation in ["stop", "voiceOver", "authority"] {
            let control = ControlledCookPreparation()
            let speech = FakeCookSpeech(); speech.preparation = control.preparation
            var allowed = true
            let model = CookReadbackModel(instruction: instruction(), speech: speech, clock: { self.now }) { _, _ in allowed }
            model.playFromBeginning()
            XCTAssertEqual(model.state, .preparing)
            switch revocation {
            case "stop": model.stop()
            case "voiceOver": model.setVoiceOver(true)
            default: allowed = false
            }
            control.lookups.removeFirst()(["es-US"])
            if revocation == "authority" {
                // Exercise the model's final authority check even before its watchdog has run.
                XCTAssertEqual(control.activations.count, 1)
                control.activations.removeFirst()(true)
            } else {
                XCTAssertTrue(control.activations.isEmpty)
            }
            XCTAssertTrue(speech.spoken.isEmpty)
            XCTAssertEqual(model.state, .stopped)
            XCTAssertNil(control.preparation.sessionID)
            model.close()
        }
    }

    func testPreparedVoiceSelectionHasNoFallbackAndRefreshesAfterStop() {
        let control = ControlledCookPreparation()
        let id = UUID()
        control.preparation.prepare(for: id) { XCTAssertTrue($0) }
        control.lookups.removeFirst()(["en-GB", "en-US:first", "en-US:second", "es-ES"])
        control.activations.removeFirst()(true)
        let language: (String) -> String = { String($0.split(separator: ":")[0]) }
        XCTAssertEqual(control.preparation.installedVoice(localeIdentifier: "en-GB", language: language), "en-US:first")
        XCTAssertNil(control.preparation.installedVoice(localeIdentifier: "es-US", language: language))
        XCTAssertNil(control.preparation.installedVoice(localeIdentifier: "fr-FR", language: language))
        control.preparation.releaseAudio()
        control.preparation.prepare(for: id) { XCTAssertTrue($0) }
        XCTAssertTrue(control.lookups.isEmpty) // Resume does not enumerate again.
        control.activations.removeFirst()(true)
        control.preparation.invalidate()
        control.preparation.prepare(for: UUID()) { XCTAssertTrue($0) }
        XCTAssertEqual(control.lookups.count, 1)
        control.lookups.removeFirst()(["es-US"])
        control.activations.removeFirst()(true)
        XCTAssertNil(control.preparation.installedVoice(localeIdentifier: "en-US", language: language))
        XCTAssertEqual(control.preparation.installedVoice(localeIdentifier: "es-US", language: language), "es-US")
        control.preparation.invalidate()
    }

    func testMissingPreparedVoicePreservesVisibleTextWithoutFallback() {
        let control = ControlledCookPreparation()
        let speech = FakeCookSpeech(); speech.preparation = control.preparation
        let value = instruction()
        let model = CookReadbackModel(instruction: value, speech: speech, clock: { self.now }) { _, _ in true }
        model.playFromBeginning()
        control.lookups.removeFirst()(["en-US", "es-ES"])
        control.activations.removeFirst()(true)
        XCTAssertTrue(model.unavailable)
        XCTAssertEqual(model.instruction.text, value.text)
        XCTAssertTrue(speech.spoken.isEmpty)
        XCTAssertEqual(model.state, .stopped)
        model.close()
    }

    func testSessionOperationsRunOffMainAndStaleReleasePreservesTheNewOwner() async {
        let activations = expectation(description: "Three successful session activations")
        activations.expectedFulfillmentCount = 3
        let releases = expectation(description: "Three matching session releases")
        releases.expectedFulfillmentCount = 3
        let session = CookAudioSession(activate: {
            XCTAssertFalse(Thread.isMainThread)
            activations.fulfill()
        }, deactivate: {
            XCTAssertFalse(Thread.isMainThread)
            releases.fulfill()
        })
        let first = UUID(), second = UUID(), competing = UUID()
        func acquire(_ id: UUID) async -> Bool {
            await withCheckedContinuation { continuation in
                session.acquire(id) { continuation.resume(returning: $0) }
            }
        }
        let firstReady = expectation(description: "First activation returned")
        session.acquire(first) { ready in
            XCTAssertTrue(ready)
            firstReady.fulfill()
        }
        // Stop the first playback before its main-actor callback can run.
        session.release(first)
        let next = await acquire(second)
        XCTAssertTrue(next)
        session.release(first)
        let unauthorized = await acquire(competing)
        XCTAssertFalse(unauthorized)
        session.release(second)
        let afterRelease = await acquire(competing)
        XCTAssertTrue(afterRelease)
        session.release(competing)
        await fulfillment(of: [firstReady, activations, releases], timeout: 5)
    }
}
@MainActor final class FakeCookSpeech: CookSpeechPlayback {
    var onEnd: ((UUID) -> Void)?
    var spoken: [String] = []; var locales: [String] = []; var ids: [UUID] = []
    var resumes = 0; var stops = 0; var failure: CaptureFailure?
    var delayed = false
    var preparation: CookSpeechPreparation<String>?
    var activations: [@MainActor @Sendable (Bool) -> Void] = []
    func prepareAudio(for id: UUID, completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        if let preparation { preparation.prepare(for: id, completion: completion) }
        else if delayed { activations.append(completion) } else { completion(true) }
    }
    func speak(_ text: String, localeIdentifier: String, playbackID: UUID) throws {
        if let failure { throw failure }
        if let preparation, preparation.installedVoice(localeIdentifier: localeIdentifier, language: { $0 }) == nil {
            throw CaptureFailure.onDeviceUnavailable
        }
        spoken.append(text); locales.append(localeIdentifier); ids.append(playbackID)
    }
    func pause() -> Bool { true }
    func resume() throws -> Bool { resumes += 1; return true }
    func stop() { stops += 1; preparation?.invalidate() }
}

@MainActor private final class ControlledCookPreparation {
    var lookups: [CookSpeechPreparation<String>.VoiceCompletion] = []
    var activations: [CookSpeechPreparation<String>.AudioCompletion] = []
    let audioLog = CookPreparationAudioLog()
    lazy var preparation = CookSpeechPreparation<String>(loadVoices: { [weak self] in
        self?.lookups.append($0)
    }, acquire: { [weak self] id, completion in
        self?.audioLog.append("acquire:\(id)")
        self?.activations.append(completion)
    }, release: { [audioLog] id in
        audioLog.append("release:\(id)")
    })
}

/// Release is Sendable because production deinitialization also releases a pending audio owner.
private final class CookPreparationAudioLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    var events: [String] { lock.lock(); defer { lock.unlock() }; return storage }
    func append(_ event: String) { lock.lock(); defer { lock.unlock() }; storage.append(event) }
}
