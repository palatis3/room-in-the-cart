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
    func testInitialPlaybackCategoryEchoBeforeDuringAndAfterActivationIsHarmless() async {
        for timing in ["none", "before", "during", "after"] {
            let h = AudioOwnerHarness(now: now)
            h.backend.setSnapshot(.init(outputs: [], profile: .capture))
            if timing == "before" { h.speech.delayVoices = true }
            if timing == "after" { h.speech.holdReadiness = true }
            if timing == "during" {
                let center = h.center
                h.backend.onNextActivation { _ in center.post(name: AVAudioSession.routeChangeNotification,
                    object: nil, userInfo: [AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.categoryChange.rawValue]) }
            }
            h.model.playFromBeginning()
            if timing == "before" { h.post(.categoryChange); h.speech.finishVoices() }
            await h.settle()
            if timing == "after" {
                h.post(.categoryChange); h.speech.readiness.removeFirst()(); await h.settle()
            }
            XCTAssertEqual(h.model.state, .speaking, timing)
            XCTAssertEqual(h.speech.spoken.count, 1)
            h.post(.categoryChange) // Also covers a delayed configuration echo after admission.
            await h.settle()
            XCTAssertEqual(h.model.state, .speaking)
            XCTAssertEqual(h.speech.spoken.count, 1)
            h.model.close(); await h.settle()
        }
    }

    func testCategoryOutputOrProfileEffectsRetirePreparingSpeakingAndPausedIntents() async {
        let observations = [CookAudioSnapshot(outputs: [CookAudioOutput(type: "speaker", uid: "other")], profile: .playback),
            CookAudioSnapshot(outputs: AudioOwnerBackend.normalOutputs, profile: .capture),
            CookAudioSnapshot(outputs: [], profile: .playback)]
        for state in [CookReadbackModel.State.preparing, .speaking, .paused] {
            for observation in observations {
                let h = AudioOwnerHarness(now: now)
                h.speech.holdReadiness = state == .preparing
                h.model.playFromBeginning(); await h.settle()
                if state == .paused { h.model.pause(); await h.settle() }
                let spoken = h.speech.spoken.count
                h.backend.setSnapshot(observation)
                h.post(.categoryChange); await h.settle()
                XCTAssertEqual(h.model.state, .stopped)
                if !h.speech.readiness.isEmpty { h.speech.readiness.removeFirst()() }
                XCTAssertEqual(h.speech.spoken.count, spoken)
                XCTAssertEqual(h.speech.resumes, 0)
                h.backend.setSnapshot(.init(outputs: AudioOwnerBackend.normalOutputs, profile: .playback))
                h.post(.categoryChange); await h.settle()
                XCTAssertEqual(h.model.state, .stopped)
                h.model.close(); await h.settle()
            }
        }
    }

    func testCategoryTicketsIndividuallyHoldTheSameExplicitReadiness() async {
        let h = AudioOwnerHarness(now: now); h.speech.holdReadiness = true
        h.model.playFromBeginning(); await h.settle()
        let first = AudioOwnerOperationGate("first category read"), second = AudioOwnerOperationGate("second category read")
        h.backend.onNextSnapshot { first.block() }
        h.backend.onNextSnapshot { second.block() }
        h.post(.categoryChange)
        await fulfillment(of: [first.entered], timeout: 3)
        h.post(.categoryChange)
        h.speech.readiness.removeFirst()()
        XCTAssertEqual(h.model.state, .preparing); XCTAssertTrue(h.speech.spoken.isEmpty)
        first.open()
        await fulfillment(of: [second.entered], timeout: 3)
        await h.mainBarrier()
        XCTAssertEqual(h.model.state, .preparing) // First ticket cannot clear the second receipt.
        XCTAssertTrue(h.speech.spoken.isEmpty)
        second.open(); await h.settle()
        XCTAssertEqual(h.model.state, .speaking); XCTAssertEqual(h.speech.spoken.count, 1)
        h.model.close(); await h.settle()
    }

    func testRouteReceiptBeforeReadinessCannotEnterNativeStartOrResume() async {
        for background in [false, true] {
            for resume in [false, true] {
                let h = AudioOwnerHarness(now: now)
                if resume { h.model.playFromBeginning(); await h.settle(); h.model.pause(); await h.settle() }
                h.speech.holdReadiness = true
                if resume { h.model.resume() } else { h.model.playFromBeginning() }
                await h.settle()
                let ready = h.speech.readiness.removeFirst(), spoken = h.speech.spoken.count
                h.post(.oldDeviceUnavailable, background: background)
                ready() // Deliberately before queued MainActor Stop for the background case.
                XCTAssertEqual(h.model.state, .stopped)
                XCTAssertEqual(h.speech.spoken.count, spoken); XCTAssertEqual(h.speech.resumes, 0)
                h.speech.holdReadiness = false; h.model.playFromBeginning()
                ready() // Stale G/P readiness must not bind to the new explicit start.
                await h.settle()
                XCTAssertEqual(h.model.state, .speaking)
                XCTAssertEqual(h.speech.spoken.count, spoken + 1)
                h.model.close(); await h.settle()
            }
        }
    }

    func testStoppedAndOldGenerationReceiptsDoNotAffectNewExplicitPlayback() async {
        for background in [false, true] {
            let h = AudioOwnerHarness(now: now)
            h.post(.oldDeviceUnavailable, background: background)
            h.model.playFromBeginning(); await h.settle()
            XCTAssertEqual(h.model.state, .speaking)
            let oldID = h.speech.ids.last!
            h.post(.oldDeviceUnavailable, background: background)
            h.model.playFromBeginning(); await h.settle()
            h.speech.onEnd?(oldID)
            XCTAssertEqual(h.model.state, .speaking); XCTAssertEqual(h.speech.spoken.count, 2)
            h.model.close(); await h.settle()
        }
    }

    func testStaleCategoryReconciliationCannotRevokeNewGeneration() async {
        let h = AudioOwnerHarness(now: now)
        h.model.playFromBeginning(); await h.settle()
        let gate = AudioOwnerOperationGate("old category sample")
        h.backend.onNextSnapshot { gate.block() }
        h.post(.categoryChange); await fulfillment(of: [gate.entered], timeout: 3)
        h.model.playFromBeginning()
        gate.open(); await h.settle()
        XCTAssertEqual(h.model.state, .speaking); XCTAssertEqual(h.speech.spoken.count, 2)
        h.model.close(); await h.settle()
    }

    func testDeviceReceiptDuringVoiceLookupOrBlockedActivationRetiresIntent() async {
        let voice = AudioOwnerHarness(now: now); voice.speech.delayVoices = true
        voice.model.playFromBeginning(); voice.post(.oldDeviceUnavailable, background: true)
        voice.speech.finishVoices(); await voice.settle()
        XCTAssertTrue(voice.speech.spoken.isEmpty); XCTAssertFalse(voice.backend.events.contains("activate:playback"))
        voice.model.close(); await voice.settle()

        let h = AudioOwnerHarness(now: now), gate = AudioOwnerOperationGate("activation")
        h.backend.onNextActivation { _ in gate.block() }
        h.model.playFromBeginning(); await fulfillment(of: [gate.entered], timeout: 3)
        h.post(.categoryChange) // A harmless ticket must never clear the following device revocation.
        h.post(.oldDeviceUnavailable, background: true)
        gate.open(); await h.settle()
        XCTAssertEqual(h.model.state, .stopped); XCTAssertTrue(h.speech.spoken.isEmpty)
        XCTAssertEqual(h.backend.events.filter { $0 == "deactivate" }.count, 1)
        h.model.close(); await h.settle()
    }

    func testRouteReceiptAfterAdmissionStopsBeforeSpeakingStateIsPublished() async {
        let h = AudioOwnerHarness(now: now)
        h.speech.nativeEntry = { [weak h] in h?.post(.oldDeviceUnavailable, background: true) }
        h.model.playFromBeginning(); await h.settle()
        XCTAssertEqual(h.speech.spoken.count, 1) // Call was admitted; no false zero-acoustic claim.
        XCTAssertEqual(h.model.state, .stopped)
        XCTAssertTrue(h.backend.events.contains("speech-stop"))
        h.model.close(); await h.settle()
    }

    func testCaptureTakeoverStopsVoiceLoadingSpeakingAndPausedBeforeCategoryMutation() async {
        for state in [CookReadbackModel.State.preparing, .speaking, .paused] {
            let h = AudioOwnerHarness(now: now)
            h.speech.delayVoices = state == .preparing
            h.model.playFromBeginning()
            if state != .preparing { await h.settle() }
            if state == .paused { h.model.pause(); await h.settle() }
            h.backend.clearEvents()
            let request = CookCaptureAudioRequest(audio: h.audio)
            let ready = await withCheckedContinuation { continuation in request.acquire { continuation.resume(returning: $0) } }
            XCTAssertTrue(ready)
            if state == .preparing { h.speech.finishVoices() }
            await h.settle()
            XCTAssertEqual(h.model.state, .stopped)
            let events = h.backend.events
            XCTAssertLessThan(events.firstIndex(of: "speech-stop")!, events.firstIndex(of: "activate:capture")!)
            let count = events.filter { $0 == "activate:playback" }.count
            h.model.playFromBeginning(); await h.settle()
            XCTAssertEqual(h.model.state, .stopped)
            XCTAssertEqual(h.backend.events.filter { $0 == "activate:playback" }.count, count)
            request.cancel(); await h.settle()
            XCTAssertEqual(h.model.state, .stopped) // Releasing capture never resumes cook.
            h.model.close(); await h.settle()
        }
    }

    func testCaptureWaitsForMatchedStopAcknowledgementAndStaleReleaseCannotDeactivateIt() async {
        let center = NotificationCenter(), backend = AudioOwnerBackend()
        let audio = CookAudioSession(backend: backend.backend, notificationCenter: center)
        let generation = UUID(), oldLease = UUID(), stopped = expectation(description: "stop requested")
        var acknowledge: (@Sendable () -> Void)?
        XCTAssertTrue(audio.registerCook(generation, changed: { _ in }, stop: { ack in acknowledge = ack; stopped.fulfill() }))
        let cookReady = await withCheckedContinuation { continuation in
            audio.acquireCook(generation, lease: oldLease) { continuation.resume(returning: $0) }
        }
        XCTAssertTrue(cookReady)
        let capture = CookCaptureAudioRequest(audio: audio), captureReady = expectation(description: "capture ready")
        capture.acquire { XCTAssertTrue($0); captureReady.fulfill() }
        await fulfillment(of: [stopped], timeout: 3)
        await audioWorkerBarrier(audio)
        XCTAssertFalse(backend.events.contains("activate:capture"))
        audio.release(oldLease); audio.retireCook(generation)
        acknowledge?(); acknowledge?()
        await fulfillment(of: [captureReady], timeout: 3)
        let deactivations = backend.events.filter { $0 == "deactivate" }.count
        audio.release(oldLease); await audioWorkerBarrier(audio)
        XCTAssertEqual(backend.events.filter { $0 == "deactivate" }.count, deactivations)
        capture.cancel(); await audioWorkerBarrier(audio)
    }

    func testCancelledCaptureBeforeReservationOrDuringStopWaitNeverConfiguresAudio() async {
        let h = AudioOwnerHarness(now: now); h.model.playFromBeginning(); await h.settle()
        let before = h.speech.stops, preCancelled = CookCaptureAudioRequest(audio: h.audio)
        preCancelled.cancel()
        let rejected = await withCheckedContinuation { continuation in preCancelled.acquire { continuation.resume(returning: $0) } }
        XCTAssertFalse(rejected); XCTAssertEqual(h.speech.stops, before); XCTAssertEqual(h.model.state, .speaking)
        h.model.close(); await h.settle()

        let backend = AudioOwnerBackend(), center = NotificationCenter()
        let audio = CookAudioSession(backend: backend.backend, notificationCenter: center)
        let id = UUID(); var acknowledge: (@Sendable () -> Void)?
        XCTAssertTrue(audio.registerCook(id, changed: { _ in }, stop: { acknowledge = $0 }))
        let capture = CookCaptureAudioRequest(audio: audio), completed = expectation(description: "cancelled acquisition")
        capture.acquire { XCTAssertFalse($0); completed.fulfill() }
        capture.cancel()
        acknowledge?(); acknowledge?(); audio.retireCook(id)
        await fulfillment(of: [completed], timeout: 3)
        XCTAssertFalse(backend.events.contains("activate:capture"))
    }

    func testCaptureCancellationDuringActivationCleansOnlyItsLease() async {
        let h = AudioOwnerHarness(now: now), gate = AudioOwnerOperationGate("capture activation")
        h.backend.onNextActivation { profile in XCTAssertEqual(profile, .capture); gate.block() }
        let capture = CookCaptureAudioRequest(audio: h.audio), completed = expectation(description: "cancelled capture ready")
        capture.acquire { XCTAssertFalse($0); completed.fulfill() }
        await fulfillment(of: [gate.entered], timeout: 3)
        capture.cancel(); gate.open()
        await fulfillment(of: [completed], timeout: 3)
        h.model.playFromBeginning(); await h.settle()
        XCTAssertEqual(h.model.state, .speaking)
        let deactivations = h.backend.events.filter { $0 == "deactivate" }.count
        capture.cancel(); await h.settle()
        XCTAssertEqual(h.backend.events.filter { $0 == "deactivate" }.count, deactivations)
        h.model.close(); await h.settle()
    }

    func testPauseResumeUsesNewLeaseAndPreservesOnlyTheAdmittedOutput() async {
        let h = AudioOwnerHarness(now: now)
        h.model.playFromBeginning(); await h.settle()
        let firstLease = h.speech.leases.last!
        h.model.pause(); await h.settle(); h.post(.categoryChange); await h.settle()
        XCTAssertEqual(h.model.state, .paused)
        h.model.resume(); await h.settle()
        XCTAssertEqual(h.model.state, .speaking); XCTAssertEqual(h.speech.resumes, 1)
        XCTAssertNotEqual(firstLease, h.speech.leases.last)
        h.audio.release(firstLease); await h.settle()
        XCTAssertEqual(h.model.state, .speaking)
        h.model.pause(); await h.settle()
        h.backend.setSnapshot(.init(outputs: [CookAudioOutput(type: "speaker", uid: "new")], profile: .playback))
        h.model.resume(); await h.settle()
        XCTAssertEqual(h.model.state, .stopped); XCTAssertEqual(h.speech.resumes, 1)
        h.model.playFromBeginning(); await h.settle() // Explicit new Play may accept the new baseline.
        XCTAssertEqual(h.model.state, .speaking); XCTAssertEqual(h.speech.spoken.count, 2)
        h.model.close(); await h.settle()
    }

    func testPartialActivationFailureAndQueuedReconciliationCloseCleanUpOnce() async {
        let h = AudioOwnerHarness(now: now)
        h.backend.failNextActivation()
        h.model.playFromBeginning(); await h.settle()
        XCTAssertEqual(h.model.state, .stopped); XCTAssertTrue(h.speech.spoken.isEmpty)
        XCTAssertEqual(h.backend.events.filter { $0 == "deactivate" }.count, 1)
        XCTAssertTrue(h.model.unavailable)
        h.model.playFromBeginning(); await h.settle()
        let gate = AudioOwnerOperationGate("closing category reconciliation")
        h.backend.onNextSnapshot { gate.block() }
        h.post(.categoryChange); await fulfillment(of: [gate.entered], timeout: 3)
        h.model.close(); gate.open(); await h.settle()
        XCTAssertEqual(h.model.state, .stopped)
        XCTAssertEqual(h.backend.events.filter { $0 == "deactivate" }.count, 2)
    }

    func testUnrelatedCookOwnerIsDeniedWithoutChangingFirstLease() async {
        let h = AudioOwnerHarness(now: now)
        h.model.playFromBeginning(); await h.settle()
        let otherSpeech = AudioOwnerSpeech(audio: h.audio, backend: h.backend)
        let other = CookReadbackModel(instruction: instruction(), speech: otherSpeech, clock: { self.now }) { _, _ in true }
        other.playFromBeginning(); await h.settle()
        XCTAssertEqual(other.state, .stopped); XCTAssertTrue(otherSpeech.spoken.isEmpty)
        XCTAssertEqual(h.model.state, .speaking)
        XCTAssertEqual(h.backend.events.filter { $0 == "activate:playback" }.count, 1)
        other.close(); h.model.close(); await h.settle()
    }

    func testOutputFingerprintUsesEveryPortAndIgnoresOrderingOnly() async {
        let h = AudioOwnerHarness(now: now)
        let first = CookAudioOutput(type: "speaker", uid: "first")
        let second = CookAudioOutput(type: "external", uid: "second")
        h.backend.setSnapshot(.init(outputs: [first, second, first], profile: .playback))
        h.model.playFromBeginning(); await h.settle()
        h.backend.setSnapshot(.init(outputs: [first, first, second], profile: .playback))
        h.post(.categoryChange); await h.settle()
        XCTAssertEqual(h.model.state, .speaking)
        h.backend.setSnapshot(.init(outputs: [first, second], profile: .playback))
        h.post(.categoryChange); await h.settle()
        XCTAssertEqual(h.model.state, .stopped) // Multiplicity matters, not just a Set of IDs.
        h.model.close(); await h.settle()
    }

    func testHeldCategoryReadinessStillChecksAuthorityDeadlineAndVoiceOver() async {
        for revocation in ["authority", "deadline", "voiceOver"] {
            let h = AudioOwnerHarness(now: now); h.speech.holdReadiness = true
            h.model.playFromBeginning(); await h.settle()
            let gate = AudioOwnerOperationGate("category with later authorization change")
            h.backend.onNextSnapshot { gate.block() }
            h.post(.categoryChange); await fulfillment(of: [gate.entered], timeout: 3)
            h.speech.readiness.removeFirst()()
            switch revocation {
            case "authority": h.authority.allowed = false
            case "deadline": h.authority.now = h.model.instruction.startBefore
            default: h.model.setVoiceOver(true)
            }
            gate.open(); await h.settle()
            XCTAssertEqual(h.model.state, .stopped); XCTAssertTrue(h.speech.spoken.isEmpty)
            h.model.setVoiceOver(false); h.authority.allowed = true; h.authority.now = now
            h.post(.categoryChange); await h.settle()
            XCTAssertEqual(h.model.state, .stopped); XCTAssertTrue(h.speech.spoken.isEmpty)
            h.model.close(); await h.settle()
        }
    }

    func testNativeProfileClassifierAcceptsDocumentedDuckNormalizationOnly() {
        XCTAssertEqual(CookAudioProfile.observed(category: .playback, mode: .spokenAudio,
            options: [.duckOthers]), .playback)
        XCTAssertEqual(CookAudioProfile.observed(category: .playback, mode: .spokenAudio,
            options: [.duckOthers, .mixWithOthers]), .playback)
        let incompatible: [AVAudioSession.CategoryOptions] = [[], [.mixWithOthers],
            [.duckOthers, .defaultToSpeaker], [.duckOthers, .interruptSpokenAudioAndMixWithOthers]]
        for options in incompatible {
            XCTAssertNil(CookAudioProfile.observed(category: .playback, mode: .spokenAudio, options: options))
        }
        XCTAssertNil(CookAudioProfile.observed(category: .playAndRecord, mode: .spokenAudio, options: [.duckOthers]))
        XCTAssertNil(CookAudioProfile.observed(category: .playback, mode: .measurement, options: [.duckOthers]))
        XCTAssertEqual(CookAudioProfile.observed(category: .record, mode: .measurement, options: []), .capture)
        XCTAssertNil(CookAudioProfile.observed(category: .record, mode: .measurement, options: [.duckOthers]))
    }

    func testCaptureAndPlaybackNativeArgumentsUseSupportedActivationOptions() {
        let capture = CookAudioProfile.capture.configuration
        XCTAssertEqual(capture.category, .record); XCTAssertEqual(capture.mode, .measurement)
        XCTAssertTrue(capture.options.isEmpty); XCTAssertTrue(capture.activationOptions.isEmpty)
        let playback = CookAudioProfile.playback.configuration
        XCTAssertEqual(playback.category, .playback); XCTAssertEqual(playback.mode, .spokenAudio)
        XCTAssertEqual(playback.options, [.duckOthers]); XCTAssertTrue(playback.activationOptions.isEmpty)
    }

    private func audioWorkerBarrier(_ audio: CookAudioSession) async {
        await withCheckedContinuation { continuation in audio.afterPendingOperations { continuation.resume() } }
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

    func testSlowVoiceDiscoveryLeavesInstructionReadableAndOnlyServesAnExplicitRetry() async throws {
        var systemReplies: [CookVoiceDiscovery<String>.Completion] = []
        let discovery = CookVoiceDiscovery<String>(timeout: .milliseconds(20)) { systemReplies.append($0) }
        let expired = expectation(description: "Voice lookup returned the readable fallback")
        let speech = FakeCookSpeech()
        var acquisitions = 0
        speech.preparation = CookSpeechPreparation(loadVoices: { reply in
            discovery.load { voices in
                reply(voices)
                if voices.isEmpty { expired.fulfill() }
            }
        }, acquire: { _, ready in acquisitions += 1; ready(true) }, release: { _ in })
        let original = instruction()
        let model = CookReadbackModel(instruction: original, speech: speech, clock: { self.now }) { _, _ in true }
        defer { model.close() }
        model.playFromBeginning()
        await fulfillment(of: [expired], timeout: 2)
        XCTAssertEqual(model.state, .stopped)
        XCTAssertTrue(model.unavailable)
        XCTAssertEqual(model.instruction.text, original.text)
        XCTAssertTrue(speech.spoken.isEmpty)
        XCTAssertEqual(acquisitions, 0)

        // A second tap joins the outstanding system query without queuing another behind it.
        model.playFromBeginning()
        XCTAssertEqual(systemReplies.count, 1)
        let reply = try XCTUnwrap(systemReplies.popLast())
        reply([original.localeIdentifier])
        XCTAssertEqual(acquisitions, 1)
        XCTAssertEqual(speech.spoken, [original.text])
        XCTAssertEqual(model.state, .speaking)
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

@MainActor private final class AudioOwnerHarness {
    let center = NotificationCenter()
    let backend = AudioOwnerBackend()
    let audio: CookAudioSession
    let speech: AudioOwnerSpeech
    let model: CookReadbackModel
    let authority: AudioOwnerAuthority
    init(now: Date) {
        audio = CookAudioSession(backend: backend.backend, notificationCenter: center)
        speech = AudioOwnerSpeech(audio: audio, backend: backend)
        let instruction = CookReadbackInstruction(authorityBindingID: UUID(), sourceID: UUID(), sourceRevision: 1,
            createdAt: now.addingTimeInterval(-1), startBefore: now.addingTimeInterval(60), text: "Use four wraps; save two.",
            localeIdentifier: "en-US", excludesPrivateBudget: true)
        let authority = AudioOwnerAuthority(now: now); self.authority = authority
        model = CookReadbackModel(instruction: instruction, speech: speech, clock: { authority.now }) { _, _ in authority.allowed }
    }
    func post(_ reason: AVAudioSession.RouteChangeReason, background: Bool = false) {
        let center = center, raw = reason.rawValue
        if background {
            let received = DispatchSemaphore(value: 0)
            DispatchQueue.global(qos: .userInitiated).async {
                center.post(name: AVAudioSession.routeChangeNotification, object: nil,
                    userInfo: [AVAudioSessionRouteChangeReasonKey: raw])
                received.signal()
            }
            // Test-only receipt handshake: the main Stop remains queued until this method returns.
            XCTAssertEqual(received.wait(timeout: .now() + 3), .success)
        } else {
            center.post(name: AVAudioSession.routeChangeNotification, object: nil,
                userInfo: [AVAudioSessionRouteChangeReasonKey: raw])
        }
    }
    func mainBarrier() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
    func settle() async {
        // First worker→main barrier delivers readiness/reconciliation; its MainActor Stop may
        // enqueue release. Second worker→main barrier includes that cleanup. No retries/sleeps.
        await withCheckedContinuation { continuation in audio.afterPendingOperations { continuation.resume() } }
        await mainBarrier()
        await withCheckedContinuation { continuation in audio.afterPendingOperations { continuation.resume() } }
        await mainBarrier()
    }
}

/// Controlled native speech boundary, using the REAL binding/preparation/coordinator implementation.
@MainActor private final class AudioOwnerSpeech: CookSpeechPlayback {
    var onEnd: ((UUID) -> Void)?
    let audio: CookAudioSession
    let backend: AudioOwnerBackend
    lazy var binding = CookSpeechSessionBinding(audio: audio, stop: { [weak self] in self?.stop() })
    lazy var preparation = CookSpeechPreparation<String>(loadVoices: { [weak self] done in
        guard let self else { return }
        if self.delayVoices { self.voices.append(done) } else { done(["en-US"]) }
    }, acquire: { [weak self] lease, done in
        guard let self else { done(false); return }
        self.leases.append(lease)
        self.binding.acquire(lease) { [weak self] ready in
            if self?.holdReadiness == true { self?.readiness.append { done(ready) } }
            else { done(ready) }
        }
    }, release: { [audio] in audio.release($0) }, uniqueLeaseIDs: true)
    var delayVoices = false, holdReadiness = false
    var voices: [CookSpeechPreparation<String>.VoiceCompletion] = []
    var readiness: [@MainActor @Sendable () -> Void] = []
    var spoken: [String] = [], ids: [UUID] = [], leases: [UUID] = []
    var resumes = 0, stops = 0
    var nativeEntry: (@MainActor () -> Void)?
    init(audio: CookAudioSession, backend: AudioOwnerBackend) { self.audio = audio; self.backend = backend }
    func finishVoices() { if !voices.isEmpty { voices.removeFirst()(["en-US"]) } }
    func beginIntent(_ id: UUID, changed: @escaping @MainActor @Sendable (UUID) -> Void) -> Bool {
        binding.begin(id, changed: changed)
    }
    func intentGate(_ id: UUID) -> CookAudioGate { binding.intentGate(id) }
    func admitPlayback(_ id: UUID) -> CookAudioGate { binding.admit(id) }
    func prepareAudio(for id: UUID, completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        preparation.prepare(for: id, completion: completion)
    }
    func speak(_ text: String, localeIdentifier: String, playbackID: UUID) throws {
        XCTAssertTrue(Thread.isMainThread)
        guard preparation.sessionID == playbackID else { throw CaptureFailure.audioUnavailable }
        spoken.append(text); ids.append(playbackID); nativeEntry?()
    }
    func pause() -> Bool { preparation.releaseAudio(); return true }
    func resume() throws -> Bool { resumes += 1; nativeEntry?(); return true }
    func stop() {
        binding.invalidate(); stops += 1; backend.record("speech-stop")
        preparation.invalidate(); binding.retire()
    }
}

/// Lock protects fake observations and scripted hooks; hooks execute OUTSIDE the lock. Production
/// session methods call this backend on their real serial worker, never on the test's main actor.
private final class AudioOwnerBackend: @unchecked Sendable {
    static let normalOutputs = [CookAudioOutput(type: "speaker", uid: "fixture-output")]
    private let lock = NSLock()
    private var observed = CookAudioSnapshot(outputs: normalOutputs, profile: .playback)
    private var log: [String] = []
    private var activationHooks: [@Sendable (CookAudioProfile) -> Void] = []
    private var snapshotHooks: [@Sendable () -> Void] = []
    private var failActivation = false
    var backend: CookAudioBackend {
        CookAudioBackend(activate: { [self] in try activate($0) }, deactivate: { [self] in deactivate() },
                         snapshot: { [self] in snapshot() })
    }
    var events: [String] { lock.lock(); defer { lock.unlock() }; return log }
    func clearEvents() { lock.lock(); log.removeAll(); lock.unlock() }
    func record(_ event: String) { lock.lock(); log.append(event); lock.unlock() }
    func setSnapshot(_ value: CookAudioSnapshot) { lock.lock(); observed = value; lock.unlock() }
    func onNextActivation(_ hook: @escaping @Sendable (CookAudioProfile) -> Void) {
        lock.lock(); activationHooks.append(hook); lock.unlock()
    }
    func onNextSnapshot(_ hook: @escaping @Sendable () -> Void) {
        lock.lock(); snapshotHooks.append(hook); lock.unlock()
    }
    func failNextActivation() { lock.lock(); failActivation = true; lock.unlock() }
    private func activate(_ profile: CookAudioProfile) throws {
        XCTAssertFalse(Thread.isMainThread)
        lock.lock()
        log.append(profile == .playback ? "activate:playback" : "activate:capture")
        observed = CookAudioSnapshot(outputs: observed.outputs.isEmpty && profile == .playback ? Self.normalOutputs : observed.outputs,
                                     profile: profile)
        let hook = activationHooks.isEmpty ? nil : activationHooks.removeFirst()
        let fail = failActivation; failActivation = false
        lock.unlock()
        hook?(profile)
        if fail { throw CaptureFailure.audioUnavailable }
    }
    private func deactivate() { XCTAssertFalse(Thread.isMainThread); record("deactivate") }
    private func snapshot() -> CookAudioSnapshot {
        XCTAssertFalse(Thread.isMainThread)
        lock.lock(); log.append("snapshot")
        let hook = snapshotHooks.isEmpty ? nil : snapshotHooks.removeFirst()
        lock.unlock()
        hook?()
        lock.lock(); defer { lock.unlock() }; return observed
    }
}

private final class AudioOwnerOperationGate: @unchecked Sendable {
    let entered: XCTestExpectation
    private let release = DispatchSemaphore(value: 0)
    init(_ label: String) { entered = XCTestExpectation(description: label) }
    func block() { entered.fulfill(); XCTAssertEqual(release.wait(timeout: .now() + 5), .success) }
    func open() { release.signal() }
}

@MainActor private final class AudioOwnerAuthority {
    var now: Date
    var allowed = true
    init(now: Date) { self.now = now }
}
