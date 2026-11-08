import XCTest
import AVFoundation
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
    var onStopRequired: (() -> Void)?
    var spoken: [String] = []; var locales: [String] = []; var ids: [UUID] = []
    var resumes = 0; var stops = 0; var failure: CaptureFailure?
    var delayed = false
    var preparation: CookSpeechPreparation<String>?
    var activations: [@MainActor @Sendable (Bool) -> Void] = []
    func prepareAudio(for id: UUID, completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        if let preparation { preparation.prepare(for: id, completion: completion) }
        else if delayed { activations.append(completion) } else { completion(true) }
    }
    func speak(_ text: String, localeIdentifier: String, playbackID: UUID, startBefore: Date,
               completion: @escaping @MainActor @Sendable (Result<Void, CaptureFailure>) -> Void) {
        if let failure { completion(.failure(failure)); return }
        if let preparation, preparation.installedVoice(localeIdentifier: localeIdentifier, language: { $0 }) == nil {
            completion(.failure(.onDeviceUnavailable)); return
        }
        spoken.append(text); locales.append(localeIdentifier); ids.append(playbackID); completion(.success(()))
    }
    func pause(completion: @escaping @MainActor @Sendable (Bool) -> Void) { completion(true) }
    func resume(completion: @escaping @MainActor @Sendable (Result<Bool, CaptureFailure>) -> Void) { resumes += 1; completion(.success(true)) }
    func stop(completion: @escaping @MainActor @Sendable (Bool) -> Void) { stops += 1; preparation?.invalidate(); completion(true) }
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

// Append to existing CookReadbackTests.swift in the scratch overlay.
@MainActor final class CookReadbackAsyncIntegrationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func instruction() -> CookReadbackInstruction {
        .init(authorityBindingID: UUID(), sourceID: UUID(), sourceRevision: 1,
              createdAt: now.addingTimeInterval(-1), startBefore: now.addingTimeInterval(30),
              text: "Exact confirmed cooking instruction.", localeIdentifier: "en-US", excludesPrivateBudget: true)
    }
    func testExplicitRepeatWaitsForStopAcknowledgment() {
        let speech = ControlledAsyncCookSpeech()
        let model = CookReadbackModel(instruction: instruction(), speech: speech, clock: { self.now }) { _, _ in true }
        model.playFromBeginning(); let oldID = speech.ids[0]
        model.playFromBeginning()
        XCTAssertEqual(model.state, .stopping); XCTAssertEqual(speech.ids.count, 1)
        XCTAssertFalse(model.canStart)
        speech.completeStop(true)
        XCTAssertEqual(model.state, .speaking); XCTAssertEqual(speech.ids.count, 2)
        XCTAssertNotEqual(oldID, speech.ids[1])
        model.close(); speech.completeStop(true)
    }
    func testInvalidationCancelsExplicitRepeatWhileStopIsHeld() {
        for reason in ["stop", "source", "voiceOver", "close"] {
            let speech = ControlledAsyncCookSpeech()
            let model = CookReadbackModel(instruction: instruction(), speech: speech, clock: { self.now }) { _, _ in true }
            model.playFromBeginning(); model.playFromBeginning()
            switch reason {
            case "source": model.update(instruction())
            case "voiceOver": model.setVoiceOver(true)
            case "close": model.close()
            default: model.stop()
            }
            speech.completeStop(true)
            XCTAssertEqual(model.state, .stopped, reason); XCTAssertEqual(speech.ids.count, 1, reason)
            model.close()
        }
    }
    func testRepeatRechecksStartDeadlineAfterStopAcknowledgment() {
        let speech = ControlledAsyncCookSpeech(); var instant = now
        let model = CookReadbackModel(instruction: instruction(), speech: speech, clock: { instant }) { _, _ in true }
        model.playFromBeginning(); model.playFromBeginning()
        instant = now.addingTimeInterval(31); speech.completeStop(true)
        XCTAssertEqual(model.state, .stopped); XCTAssertEqual(speech.ids.count, 1)
        XCTAssertFalse(model.canStart); model.close()
    }
    func testHeldPauseThenStopCannotRestorePausedAndRequiresStopAcknowledgment() {
        let speech = ControlledAsyncCookSpeech()
        let model = CookReadbackModel(instruction: instruction(), speech: speech, clock: { self.now }) { _, _ in true }
        model.playFromBeginning(); model.pause(); XCTAssertEqual(model.state, .pausing)
        model.stop(); speech.completePause(true)
        XCTAssertEqual(model.state, .stopping); XCTAssertFalse(model.canStart)
        speech.completeStop(true); XCTAssertEqual(model.state, .stopped); model.close()
    }
    func testRevocationAndFailedStopRemainExplicitlyRetryable() {
        let speech = ControlledAsyncCookSpeech(); var authorized = true
        let model = CookReadbackModel(instruction: instruction(), speech: speech, clock: { self.now }) { _, _ in authorized }
        model.playFromBeginning(); authorized = false; model.checkCurrent(); model.stop()
        XCTAssertEqual(speech.pendingStopCount, 1); XCTAssertFalse(model.canRead)
        speech.completeStop(false)
        XCTAssertEqual(model.state, .stopping); XCTAssertFalse(model.canStart); XCTAssertFalse(model.canRead)
        model.stop(); XCTAssertEqual(speech.pendingStopCount, 1)
        XCTAssertFalse(model.canStart); speech.completeStop(true)
        XCTAssertEqual(model.state, .stopped); XCTAssertEqual(speech.ids.count, 1); model.close()
    }
    func testIdlePreparationCancellationDoesNotRequireNativeStopSuccess() {
        var nativeStopCalls = 0
        let accepted = CookSpeechStopPolicy.stop(hasAdmittedUtterance: false, isSpeaking: false, isPaused: false) {
            nativeStopCalls += 1; return false
        }
        XCTAssertTrue(accepted); XCTAssertEqual(nativeStopCalls, 0)
    }
    func testFalseStopOfAdmittedSpeechIsNotSuccessEvenIfSampledIdle() {
        for paused in [false, true] {
            var nativeStopCalls = 0
            let accepted = CookSpeechStopPolicy.stop(hasAdmittedUtterance: true, isSpeaking: false, isPaused: paused) {
                nativeStopCalls += 1; return false
            }
            XCTAssertFalse(accepted); XCTAssertEqual(nativeStopCalls, 1)
        }
    }
    func testMatchedTerminalAndNowIdleCanAcknowledgeWithoutRepeatingNativeStop() {
        var nativeStopCalls = 0
        let accepted = CookSpeechStopPolicy.stop(hasAdmittedUtterance: true, matchedTerminal: true, isSpeaking: false, isPaused: false) {
            nativeStopCalls += 1; return false
        }
        XCTAssertTrue(accepted); XCTAssertEqual(nativeStopCalls, 0)
    }
    func testHeadphoneRemovalNotificationCancelsRepeatWithoutAutomaticRestart() async {
        let center = NotificationCenter(), speech = ControlledAsyncCookSpeech()
        let model = CookReadbackModel(instruction: instruction(), speech: speech, clock: { self.now }) { _, _ in true }
        let invalidated = expectation(description: "Route notification reached model")
        let observation = CookSpeechRouteObservation(center: center, previousOutputs: { _ in ["headphones"] }, currentOutputs: { ["speaker"] }) {
            model.stop(); invalidated.fulfill()
        }
        model.playFromBeginning(); model.playFromBeginning()
        center.post(name: AVAudioSession.routeChangeNotification, object: nil,
                    userInfo: [AVAudioSessionRouteChangeReasonKey: NSNumber(value: AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue)])
        await fulfillment(of: [invalidated], timeout: 2)
        speech.completeStop(true)
        XCTAssertEqual(model.state, .stopped); XCTAssertEqual(speech.ids.count, 1)
        withExtendedLifetime(observation) {}; model.close()
    }
    func testInterruptionEndedShouldResumeNotificationNeverRestarts() async {
        let center = NotificationCenter(), speech = ControlledAsyncCookSpeech()
        let model = CookReadbackModel(instruction: instruction(), speech: speech, clock: { self.now }) { _, _ in true }
        let invalidated = expectation(description: "Interruption notification reached model")
        let observation = CookSpeechInterruptionObservation(center: center) { model.stop(); invalidated.fulfill() }
        model.playFromBeginning(); model.playFromBeginning()
        center.post(name: AVAudioSession.interruptionNotification, object: nil, userInfo: [
            AVAudioSessionInterruptionTypeKey: NSNumber(value: AVAudioSession.InterruptionType.ended.rawValue),
            AVAudioSessionInterruptionOptionKey: NSNumber(value: AVAudioSession.InterruptionOptions.shouldResume.rawValue)
        ])
        await fulfillment(of: [invalidated], timeout: 2)
        speech.completeStop(true)
        XCTAssertEqual(model.state, .stopped); XCTAssertEqual(speech.ids.count, 1); XCTAssertEqual(speech.resumes, 0)
        withExtendedLifetime(observation) {}; model.close()
    }
    func testOwnCategoryNotificationWithSameOutputDoesNotCancelPlayback() async {
        let center = NotificationCenter()
        let stopped = expectation(description: "No stop for verified unchanged output"); stopped.isInverted = true
        let observation = CookSpeechRouteObservation(center: center, previousOutputs: { _ in ["headphones"] }, currentOutputs: { ["headphones"] }) { stopped.fulfill() }
        center.post(name: AVAudioSession.routeChangeNotification, object: nil,
                    userInfo: [AVAudioSessionRouteChangeReasonKey: NSNumber(value: AVAudioSession.RouteChangeReason.categoryChange.rawValue)])
        await fulfillment(of: [stopped], timeout: 0.2)
        withExtendedLifetime(observation) {}
        XCTAssertTrue(CookSpeechRoutePolicy.shouldStop(reason: AVAudioSession.RouteChangeReason.categoryChange.rawValue,
                                                       previous: ["headphones"], current: ["speaker"]))
    }
}

@MainActor private final class ControlledAsyncCookSpeech: CookSpeechPlayback {
    var onEnd: ((UUID) -> Void)?
    var onStopRequired: (() -> Void)?
    var ids: [UUID] = []
    var resumes = 0
    private var pauses: [@MainActor @Sendable (Bool) -> Void] = []
    private var stops: [@MainActor @Sendable (Bool) -> Void] = []
    func prepareAudio(for id: UUID, completion: @escaping @MainActor @Sendable (Bool) -> Void) { completion(true) }
    func speak(_ text: String, localeIdentifier: String, playbackID: UUID, startBefore: Date,
               completion: @escaping @MainActor @Sendable (Result<Void, CaptureFailure>) -> Void) { ids.append(playbackID); completion(.success(())) }
    func pause(completion: @escaping @MainActor @Sendable (Bool) -> Void) { pauses.append(completion) }
    func resume(completion: @escaping @MainActor @Sendable (Result<Bool, CaptureFailure>) -> Void) { resumes += 1; completion(.success(true)) }
    func stop(completion: @escaping @MainActor @Sendable (Bool) -> Void) { stops.append(completion) }
    func completePause(_ ok: Bool) { pauses.removeFirst()(ok) }
    var pendingStopCount: Int { stops.count }
    func completeStop(_ ok: Bool) { stops.removeFirst()(ok) }
}

// Real Thread + CFRunLoopSource + production mailbox/core. Only the confined
// engine factory is replaced. No AVSpeechSynthesizer or AVAudioSession is used.
import Darwin
import CoreFoundation

private struct OwnerThreadRecord: Sendable {
    let name: String
    let thread: UInt64
    let isMain: Bool
}

/// All cross-thread test controls are locked values/closures, never an engine.
private final class OwnerEngineControl: @unchecked Sendable {
    private let condition = NSCondition()
    private var records: [OwnerThreadRecord] = []
    private var callbacks: [String: @Sendable () -> Void] = [:]
    private var heldPause = false
    private var heldStop = false
    private var armedGetter = false
    private var heldGetter = false
    private var speaking = false
    private var paused = false
    private var stopResults: [Bool] = []
    private var terminals: [CookNativeTerminal: @Sendable (CookNativeTerminal) -> Void] = [:]
    private var current: CookNativeTerminal?
    func record(_ name: String) {
        var thread: UInt64 = 0; pthread_threadid_np(nil, &thread)
        condition.lock()
        records.append(.init(name: name, thread: thread, isMain: Thread.isMainThread))
        let callback = callbacks.removeValue(forKey: name)
        condition.unlock(); callback?()
    }
    func observe(_ name: String, _ callback: @escaping @Sendable () -> Void) {
        condition.lock(); callbacks[name] = callback; condition.unlock()
    }
    func snapshot() -> [OwnerThreadRecord] { condition.lock(); defer { condition.unlock() }; return records }
    func setHoldPause() { condition.lock(); heldPause = true; condition.unlock() }
    func releasePause() { condition.lock(); heldPause = false; condition.broadcast(); condition.unlock() }
    func setHoldStop() { condition.lock(); heldStop = true; condition.unlock() }
    func releaseStop() { condition.lock(); heldStop = false; condition.broadcast(); condition.unlock() }
    func armNestedGetter() { condition.lock(); armedGetter = true; heldGetter = true; condition.unlock() }
    func releaseGetter() { condition.lock(); heldGetter = false; condition.broadcast(); condition.unlock() }
    func spinNestedGetterIfArmed() {
        condition.lock(); let armed = armedGetter; armedGetter = false; condition.unlock()
        guard armed else { return }
        record("getter.enter")
        condition.lock(); while heldGetter { condition.wait() }; condition.unlock()
        // MainActor has queued and signaled the real source before releasing this
        // condition. Assert handledSource so the test cannot pass on timing alone.
        let result = CFRunLoopRunInMode(.defaultMode, 0.05, true)
        record(result == .handledSource ? "getter.nestedSourceHandled" : "getter.noSourceHandled")
        record("getter.return")
    }
    func setStopResults(_ values: [Bool]) { condition.lock(); stopResults = values; condition.unlock() }
    func flags() -> (Bool, Bool) { condition.lock(); defer { condition.unlock() }; return (speaking, paused) }
    func setIdle() { condition.lock(); speaking = false; paused = false; condition.unlock() }
    func admitted(_ value: CookNativeTerminal, sink: @escaping @Sendable (CookNativeTerminal) -> Void) {
        condition.lock(); current = value; terminals[value] = sink; speaking = true; paused = false; condition.unlock()
    }
    func currentIdentity() -> CookNativeTerminal? { condition.lock(); defer { condition.unlock() }; return current }
    func emit(_ value: CookNativeTerminal, through captured: CookNativeTerminal? = nil) {
        condition.lock(); let sink = terminals[captured ?? value]; condition.unlock(); sink?(value)
    }
    func pause() -> Bool {
        record("pause.enter")
        condition.lock()
        while heldPause { condition.wait() } // The owner alone waits; main never waits on this condition.
        paused = true; condition.unlock(); record("pause.return"); return true
    }
    func resume() -> Bool { condition.lock(); paused = false; condition.unlock(); record("resume"); return true }
    func stop() -> Bool {
        record("stop.enter")
        condition.lock()
        while heldStop { condition.wait() }
        let result = stopResults.isEmpty ? true : stopResults.removeFirst()
        if result { speaking = false; paused = false }
        condition.unlock(); record(result ? "stop.true" : "stop.false"); return result
    }
}

private final class ThreadRecordedEngine: CookNativeEngine {
    private let control: OwnerEngineControl
    init(_ control: OwnerEngineControl) { self.control = control; control.record("create") }
    var isSpeaking: Bool { control.record("isSpeaking"); control.spinNestedGetterIfArmed(); return control.flags().0 }
    var isPaused: Bool { control.record("isPaused"); return control.flags().1 }
    func start(text: String, voice: AVSpeechSynthesisVoice?, startBefore: Date, generation: UUID, utterance: UUID,
               terminal: @escaping @Sendable (CookNativeTerminal) -> Void) -> Bool {
        control.record("start")
        guard Date() < startBefore else { return false }
        control.admitted(.init(generation: generation, utterance: utterance), sink: terminal); return true
    }
    func pause() -> Bool { control.pause() }
    func resume() -> Bool { control.resume() }
    func stop() -> Bool { control.stop() }
    func clearUtterance() { control.record("clear") }
    deinit { control.record("destroy") }
}

@MainActor private final class OwnerEventLog {
    private(set) var values: [CookNativeEvent] = []
    private var waiting: [(XCTestExpectation, (CookNativeEvent) -> Bool)] = []
    func receive(_ event: CookNativeEvent) {
        values.append(event)
        var remaining: [(XCTestExpectation, (CookNativeEvent) -> Bool)] = []
        for (expectation, match) in waiting {
            if match(event) { expectation.fulfill() } else { remaining.append((expectation, match)) }
        }
        waiting = remaining
    }
    func result(_ ticket: CookNativeTicket, _ succeeded: Bool) -> XCTestExpectation {
        expectation("Result \(ticket.kind) \(ticket.sequence)") {
            if case .result(let received, let value) = $0 { return received == ticket && value == succeeded }; return false
        }
    }
    func expectation(_ description: String, match: @escaping (CookNativeEvent) -> Bool) -> XCTestExpectation {
        let expectation = XCTestExpectation(description: description)
        if values.contains(where: match) { expectation.fulfill() } else { waiting.append((expectation, match)) }
        return expectation
    }
}

@MainActor private final class OwnerResultGate {
    var holdStop = false
    var held: [@MainActor @Sendable () -> Void] = []
    var didHold: (() -> Void)?
    func deliver(_ event: CookNativeEvent, _ delivery: @escaping @MainActor @Sendable () -> Void) {
        if holdStop, case .result(let ticket, _) = event, ticket.kind == .stop {
            held.append(delivery); didHold?()
        } else { delivery() }
    }
    func release() { holdStop = false; let values = held; held.removeAll(); values.forEach { $0() } }
}

@MainActor final class CookSpeechOwnerLifecycleTests: XCTestCase {
    private func makeOwner(_ control: OwnerEngineControl) -> ThreadCookSpeechOwner {
        let owner = ThreadCookSpeechOwner(engineFactory: { ThreadRecordedEngine(control) })
        addTeardownBlock {
            control.releasePause(); control.releaseStop(); control.releaseGetter()
            await MainActor.run { owner.shutdown { _ in } }
        }
        return owner
    }
    private func start(_ owner: ThreadCookSpeechOwner, _ id: UUID, _ events: OwnerEventLog) async throws {
        XCTAssertTrue(owner.reserve(id, events: { events.receive($0) }))
        let ticket = try XCTUnwrap(owner.start(id, text: "Synthetic owner test", voice: nil, startBefore: Date().addingTimeInterval(30)))
        await fulfillment(of: [events.result(ticket, true)], timeout: 3)
    }
    private func finish(_ owner: ThreadCookSpeechOwner, _ control: OwnerEngineControl) async {
        control.releasePause(); control.releaseStop(); control.releaseGetter()
        let finished = expectation(description: "Owner shutdown completed")
        owner.shutdown { result in XCTAssertTrue(result); finished.fulfill() }
        await fulfillment(of: [finished], timeout: 3)
        let records = control.snapshot()
        XCTAssertEqual(records.filter { $0.name == "create" }.count, 1)
        XCTAssertEqual(records.filter { $0.name == "destroy" }.count, 1)
        XCTAssertEqual(Set(records.map(\.thread)).count, 1)
        XCTAssertFalse(records.contains { $0.isMain })
        XCTAssertNotEqual(records.first?.thread, 0)
    }
    func testOwnerDeinitRequestsAsynchronousDestructionOnItsOriginalThread() async {
        let control = OwnerEngineControl()
        let created = expectation(description: "Engine created"), destroyed = expectation(description: "Engine destroyed after owner deinit")
        control.observe("create") { created.fulfill() }; control.observe("destroy") { destroyed.fulfill() }
        var owner: ThreadCookSpeechOwner? = ThreadCookSpeechOwner(engineFactory: { ThreadRecordedEngine(control) })
        await fulfillment(of: [created], timeout: 3); XCTAssertNotNil(owner)
        owner = nil // Only value shutdown admission occurs here; no main-thread join.
        XCTAssertTrue(Thread.isMainThread)
        await fulfillment(of: [destroyed], timeout: 3)
        let records = control.snapshot()
        XCTAssertEqual(Set(records.map(\.thread)).count, 1)
        XCTAssertFalse(records.contains { $0.isMain })
        XCTAssertEqual(records.filter { $0.name == "destroy" }.count, 1)
    }
    func testEngineCreationCallsAndDestructionUseOneNonMainThread() async throws {
        let control = OwnerEngineControl(), events = OwnerEventLog(), id = UUID()
        let owner = makeOwner(control); defer { control.releasePause() }
        try await start(owner, id, events)
        let pause = try XCTUnwrap(owner.pause(id)); await fulfillment(of: [events.result(pause, true)], timeout: 3)
        let resume = try XCTUnwrap(owner.resume(id)); await fulfillment(of: [events.result(resume, true)], timeout: 3)
        let stop = try XCTUnwrap(owner.stop(id)); await fulfillment(of: [events.result(stop, true)], timeout: 3)
        await finish(owner, control)
        let names = control.snapshot().map(\.name)
        XCTAssertTrue(names.contains("start")); XCTAssertTrue(names.contains("pause.return")); XCTAssertTrue(names.contains("resume"))
        XCTAssertTrue(names.contains("stop.true")); XCTAssertEqual(names.last, "destroy")
    }
    func testBlockedPauseAllowsMainRevocationAndStopPrecedesQueuedResume() async throws {
        let control = OwnerEngineControl(), events = OwnerEventLog(), id = UUID()
        let owner = makeOwner(control); defer { control.releasePause() }
        try await start(owner, id, events)
        let entered = expectation(description: "Owner entered held Pause")
        control.observe("pause.enter") { entered.fulfill() }; control.setHoldPause()
        let pause = try XCTUnwrap(owner.pause(id)); await fulfillment(of: [entered], timeout: 3)
        // Running this code on MainActor while Pause remains held is the responsiveness proof.
        XCTAssertTrue(Thread.isMainThread)
        _ = try XCTUnwrap(owner.resume(id))
        let stop = try XCTUnwrap(owner.stop(id))
        XCTAssertNil(owner.resume(id)); XCTAssertFalse(owner.reserve(UUID(), events: { _ in }))
        XCTAssertFalse(control.snapshot().contains { $0.name == "pause.return" })
        control.releasePause()
        await fulfillment(of: [events.result(pause, true), events.result(stop, true)], timeout: 3)
        let names = control.snapshot().map(\.name)
        XCTAssertFalse(names.contains("resume"))
        XCTAssertLessThan(try XCTUnwrap(names.firstIndex(of: "pause.return")), try XCTUnwrap(names.firstIndex(of: "stop.true")))
        await finish(owner, control)
    }
    func testNestedGetterCannotAdmitCommandsAndConsumedWakeIsResignaled() async throws {
        // Getter inside initial Start: the nested wake is consumed, then queued
        // Pause must execute after getter return (proves deferred wake liveness).
        do {
            let control = OwnerEngineControl(), events = OwnerEventLog(), id = UUID()
            let owner = makeOwner(control); defer { control.releaseGetter() }
            XCTAssertTrue(owner.reserve(id, events: { events.receive($0) }))
            let entered = expectation(description: "Start idle getter held")
            control.observe("getter.enter") { entered.fulfill() }; control.armNestedGetter()
            let start = try XCTUnwrap(owner.start(id, text: "Synthetic nested start", voice: nil, startBefore: Date().addingTimeInterval(30)))
            await fulfillment(of: [entered], timeout: 3)
            let pause = try XCTUnwrap(owner.pause(id)); control.releaseGetter()
            await fulfillment(of: [events.result(start, true), events.result(pause, true)], timeout: 3)
            let names = control.snapshot().map(\.name)
            XCTAssertTrue(names.contains("getter.nestedSourceHandled"))
            XCTAssertLessThan(try XCTUnwrap(names.firstIndex(of: "getter.return")), try XCTUnwrap(names.firstIndex(of: "pause.enter")))
            await finish(owner, control)
        }
        // Getter inside terminal observation: stale Pause must not be admitted in
        // the nested loop, and matched idle retires it without resurrection.
        do {
            let control = OwnerEngineControl(), events = OwnerEventLog(), id = UUID()
            let owner = makeOwner(control); defer { control.releaseGetter() }; try await start(owner, id, events)
            let identity = try XCTUnwrap(control.currentIdentity())
            let entered = expectation(description: "Terminal idle getter held")
            control.observe("getter.enter") { entered.fulfill() }; control.armNestedGetter(); control.setIdle()
            let ended = events.expectation("Matched idle completes after nested getter") {
                if case .ended(let received) = $0 { return received == id }; return false
            }
            control.emit(identity); await fulfillment(of: [entered], timeout: 3)
            _ = try XCTUnwrap(owner.pause(id)); control.releaseGetter()
            await fulfillment(of: [ended], timeout: 3)
            let names = control.snapshot().map(\.name)
            XCTAssertTrue(names.contains("getter.nestedSourceHandled")); XCTAssertFalse(names.contains("pause.enter"))
            XCTAssertTrue(owner.reserve(UUID(), events: { _ in })); await finish(owner, control)
        }
    }
    func testFalseActiveStopKeepsReservationUntilExplicitSuccessfulRetry() async throws {
        let control = OwnerEngineControl(), events = OwnerEventLog(), id = UUID()
        let owner = makeOwner(control); try await start(owner, id, events)
        control.setStopResults([false, true])
        let rejected = try XCTUnwrap(owner.stop(id)); await fulfillment(of: [events.result(rejected, false)], timeout: 3)
        XCTAssertFalse(owner.reserve(UUID(), events: { _ in })); XCTAssertNil(owner.resume(id))
        let accepted = try XCTUnwrap(owner.stop(id)); await fulfillment(of: [events.result(accepted, true)], timeout: 3)
        let next = UUID(); XCTAssertTrue(owner.reserve(next, events: { _ in }))
        await finish(owner, control)
    }
    func testPrestartCancellationAcknowledgesIdleWithoutCallingNativeStop() async throws {
        let control = OwnerEngineControl(), events = OwnerEventLog(), id = UUID()
        let testedOwner = makeOwner(control)
        XCTAssertTrue(testedOwner.reserve(id, events: { events.receive($0) }))
        let stop = try XCTUnwrap(testedOwner.stop(id)); await fulfillment(of: [events.result(stop, true)], timeout: 3)
        XCTAssertFalse(control.snapshot().contains { $0.name.hasPrefix("stop.") })
        await finish(testedOwner, control)
    }
    func testLateGenerationAndWrongUtteranceTerminalsCannotRetireCurrentSpeech() async throws {
        let control = OwnerEngineControl(), events = OwnerEventLog(), first = UUID()
        let owner = makeOwner(control); try await start(owner, first, events)
        let old = try XCTUnwrap(control.currentIdentity())
        let stop = try XCTUnwrap(owner.stop(first)); await fulfillment(of: [events.result(stop, true)], timeout: 3)
        let currentID = UUID(); try await start(owner, currentID, events)
        let current = try XCTUnwrap(control.currentIdentity())
        control.emit(old)
        control.emit(.init(generation: currentID, utterance: UUID()), through: current)
        // A following owner command fences processing of the previously queued terminal values.
        let pause = try XCTUnwrap(owner.pause(currentID)); await fulfillment(of: [events.result(pause, true)], timeout: 3)
        XCTAssertFalse(events.values.contains { if case .ended(let id) = $0 { return id == currentID }; return false })
        XCTAssertFalse(owner.reserve(UUID(), events: { _ in }))
        control.setIdle(); let ended = events.expectation("Matching natural end") {
            if case .ended(let id) = $0 { return id == currentID }; return false
        }
        control.emit(.init(generation: currentID, utterance: UUID()), through: current)
        control.emit(.init(generation: currentID, utterance: UUID()), through: current)
        control.emit(.init(generation: currentID, utterance: UUID()), through: current)
        control.emit(current); await fulfillment(of: [ended], timeout: 3)
        await finish(owner, control)
    }
    func testRepeatedShutdownDuringBlockedPauseSharesFinalAcknowledgment() async throws {
        let control = OwnerEngineControl(), events = OwnerEventLog(), id = UUID()
        let owner = makeOwner(control); defer { control.releasePause() }; try await start(owner, id, events)
        let entered = expectation(description: "Pause held before shutdown")
        control.observe("pause.enter") { entered.fulfill() }; control.setHoldPause()
        _ = try XCTUnwrap(owner.pause(id)); await fulfillment(of: [entered], timeout: 3)
        let first = expectation(description: "First shutdown"), second = expectation(description: "Second shutdown")
        var completed = 0
        owner.shutdown { result in XCTAssertTrue(result); completed += 1; first.fulfill() }
        owner.shutdown { result in XCTAssertTrue(result); completed += 1; second.fulfill() }
        XCTAssertEqual(completed, 0); XCTAssertFalse(owner.reserve(UUID(), events: { _ in }))
        control.releasePause(); await fulfillment(of: [first, second], timeout: 3)
        XCTAssertEqual(completed, 2); await finish(owner, control)
        XCTAssertEqual(control.snapshot().filter { $0.name == "stop.true" }.count, 1)
    }
    func testShutdownQueuedDuringInFlightOrdinaryStopIsNotDiscarded() async throws {
        let control = OwnerEngineControl(), events = OwnerEventLog(), id = UUID()
        let owner = makeOwner(control); defer { control.releaseStop() }; try await start(owner, id, events)
        let entered = expectation(description: "Ordinary native Stop held")
        control.observe("stop.enter") { entered.fulfill() }; control.setHoldStop()
        let stop = try XCTUnwrap(owner.stop(id)); await fulfillment(of: [entered], timeout: 3)
        let closed = expectation(description: "Queued shutdown survives Stop return")
        owner.shutdown { result in XCTAssertTrue(result); closed.fulfill() }
        control.releaseStop()
        await fulfillment(of: [events.result(stop, true), closed], timeout: 3)
        XCTAssertEqual(control.snapshot().filter { $0.name == "stop.true" }.count, 1)
        await finish(owner, control)
    }
    func testFailedShutdownCompletesAfterLateMatchedIdleWithoutRetryingNativeStop() async throws {
        let control = OwnerEngineControl(), events = OwnerEventLog(), id = UUID()
        let owner = makeOwner(control); try await start(owner, id, events)
        let identity = try XCTUnwrap(control.currentIdentity()); control.setStopResults([false])
        let rejected = events.expectation("Native shutdown Stop rejected") {
            if case .result(let ticket, let result) = $0 { return ticket.kind == .shutdown && !result }; return false
        }
        let first = expectation(description: "Deferred first close"), second = expectation(description: "Deferred repeated close")
        var completed = 0
        owner.shutdown { result in XCTAssertTrue(result); completed += 1; first.fulfill() }
        await fulfillment(of: [rejected], timeout: 3)
        owner.shutdown { result in XCTAssertTrue(result); completed += 1; second.fulfill() }
        XCTAssertEqual(completed, 0); XCTAssertFalse(owner.reserve(UUID(), events: { _ in }))
        control.setIdle(); control.emit(identity)
        await fulfillment(of: [first, second], timeout: 3); XCTAssertEqual(completed, 2)
        XCTAssertEqual(control.snapshot().filter { $0.name == "stop.true" || $0.name == "stop.false" }.count, 1)
        await finish(owner, control)
    }
    func testLifetimeDeinitDuringBlockedPauseStopsBeforeAnotherViewCanReserve() async throws {
        let control = OwnerEngineControl(), events = OwnerEventLog(), id = UUID()
        let owner = makeOwner(control); defer { control.releasePause() }; try await start(owner, id, events)
        var lifetime: CookSpeechLifetime? = owner.lifetime(for: id)
        XCTAssertNotNil(lifetime)
        let entered = expectation(description: "Pause held for lifetime close")
        control.observe("pause.enter") { entered.fulfill() }; control.setHoldPause()
        _ = try XCTUnwrap(owner.pause(id)); await fulfillment(of: [entered], timeout: 3)
        let stopped = events.expectation("Lifetime Stop acknowledgment") {
            if case .result(let ticket, let result) = $0 { return ticket.kind == .stop && ticket.generation == id && result }; return false
        }
        lifetime = nil; XCTAssertFalse(owner.reserve(UUID(), events: { _ in }))
        control.releasePause(); await fulfillment(of: [stopped], timeout: 3)
        XCTAssertTrue(owner.reserve(UUID(), events: { _ in })); await finish(owner, control)
    }
    func testRealNotificationsInvalidateRepeatBetweenNativeRetirementAndStopDelivery() async throws {
        for notification in [AVAudioSession.routeChangeNotification, AVAudioSession.interruptionNotification] {
            let control = OwnerEngineControl(), events = OwnerEventLog(), gate = OwnerResultGate(), center = NotificationCenter()
            let owner = ThreadCookSpeechOwner(engineFactory: { ThreadRecordedEngine(control) }, observeAudioNotifications: true,
                notificationCenter: center, deliverEvent: { gate.deliver($0, $1) })
            let id = UUID(), invalidated = expectation(description: "Logical repeat invalidated after native retirement")
            var repeatPending = true
            XCTAssertTrue(owner.reserve(id, events: { event in
                events.receive(event)
                if case .externalStop(let received) = event, received == id {
                    repeatPending = false; invalidated.fulfill()
                }
            }))
            let start = try XCTUnwrap(owner.start(id, text: "Synthetic route case", voice: nil, startBefore: Date().addingTimeInterval(30)))
            await fulfillment(of: [events.result(start, true)], timeout: 3)
            let held = expectation(description: "Stop result held after native retirement")
            gate.holdStop = true; gate.didHold = { held.fulfill() }
            let stop = try XCTUnwrap(owner.stop(id)); await fulfillment(of: [held], timeout: 3)
            XCTAssertEqual(gate.held.count, 1)
            // The same real NotificationCenter observer used by the service handles
            // each notification; no direct model guard or observer method is called.
            if notification == AVAudioSession.routeChangeNotification {
                center.post(name: notification, object: nil, userInfo: [
                    AVAudioSessionRouteChangeReasonKey: NSNumber(value: AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue)
                ])
            } else {
                center.post(name: notification, object: nil, userInfo: [
                    AVAudioSessionInterruptionTypeKey: NSNumber(value: AVAudioSession.InterruptionType.ended.rawValue),
                    AVAudioSessionInterruptionOptionKey: NSNumber(value: AVAudioSession.InterruptionOptions.shouldResume.rawValue)
                ])
            }
            await fulfillment(of: [invalidated], timeout: 3)
            XCTAssertFalse(repeatPending); gate.release()
            await fulfillment(of: [events.result(stop, true)], timeout: 3)
            XCTAssertFalse(repeatPending)
            XCTAssertEqual(control.snapshot().filter { $0.name == "start" }.count, 1)
            await finish(owner, control)
        }
    }
    func testFacadeDeinitBeforeSpeakReleasesNativeReservationWithoutNativeStop() async {
        let control = OwnerEngineControl()
        let testedOwner = makeOwner(control)
        let prepared = expectation(description: "Synthetic preparation complete")
        let released = expectation(description: "Facade preparation released its audio lease")
        var facade: LocalCookSpeech? = LocalCookSpeech(owner: testedOwner,
            preparation: CookSpeechPreparation<AVSpeechSynthesisVoice>(loadVoices: { $0([]) },
                acquire: { _, completion in completion(true) }, release: { _ in released.fulfill() }))
        facade?.prepareAudio(for: UUID()) { value in XCTAssertTrue(value); prepared.fulfill() }
        await fulfillment(of: [prepared], timeout: 3)
        XCTAssertFalse(testedOwner.reserve(UUID(), events: { _ in }))
        let cleared = expectation(description: "Facade deinit queued owner clear")
        control.observe("clear") { cleared.fulfill() }; facade = nil
        await fulfillment(of: [cleared, released], timeout: 3)
        // Shutdown is the transport fence for the deinit Stop's mailbox retirement.
        await finish(testedOwner, control)
        XCTAssertFalse(control.snapshot().contains { $0.name.hasPrefix("stop.") })
    }
}
