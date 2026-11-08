// Scratch XCTest source; compile with SpeechControlPrototype.swift in an isolated test target.
// Deliberately held results model native-call blocking; no native speech or timing claims.
import XCTest
import Foundation
@testable import SpeechControlPrototype

@MainActor final class SpeechControlPrototypeTests: XCTestCase {
    private func make(_ owner: ControlledPrototypeOwner, allowed: @escaping () -> Bool = { true }) -> PrototypeSpeechCoordinator {
        PrototypeSpeechCoordinator(transport: owner, allowedToStart: allowed, allowedToContinue: allowed)
    }
    private func start(_ model: PrototypeSpeechCoordinator, _ owner: ControlledPrototypeOwner) {
        XCTAssertTrue(model.play("Exact confirmed instruction"))
        XCTAssertEqual(model.state, .preparing)
        owner.completeAudio(); XCTAssertEqual(owner.enterNext()?.action, .start("Exact confirmed instruction"))
        owner.returnCurrent(true); XCTAssertEqual(model.state, .speaking)
    }
    func testHeldPauseRevocationReturnsThenStopBarrierBeforeReplacementStart() {
        let owner = ControlledPrototypeOwner(); var allowed = true
        let model = make(owner, allowed: { allowed }); start(model, owner)
        let oldGeneration = model.generation!
        model.pause(); let pause = owner.enterNext()!
        XCTAssertEqual(pause.action, .pause); XCTAssertEqual(model.state, .pausing)
        // Native Pause has entered but has not returned. MainActor handles revocation now.
        allowed = false; model.checkAuthority()
        XCTAssertEqual(model.state, .stopping); XCTAssertTrue(owner.mailbox.revoked)
        XCTAssertNil(model.audioLease); XCTAssertFalse(model.canStart)
        model.resume(); XCTAssertEqual(owner.mailbox.pending.map(\.action), [.stop])
        XCTAssertNil(owner.enterNext(), "Stop cannot preempt the held native Pause")
        allowed = true
        XCTAssertFalse(model.play("Replacement must wait"))
        owner.returnCurrent(true) // Late Pause success cannot overwrite stopping or release a new lease.
        XCTAssertEqual(model.state, .stopping); XCTAssertFalse(model.canStart)
        XCTAssertEqual(owner.enterNext()?.action, .stop)
        XCTAssertEqual(model.state, .stopping)
        XCTAssertFalse(model.play("Still waiting for native Stop"))
        owner.returnCurrent(true)
        XCTAssertEqual(model.state, .stopped); XCTAssertTrue(model.canStart)
        XCTAssertTrue(model.play("Replacement after acknowledgment"))
        XCTAssertNotEqual(model.generation, oldGeneration)
        XCTAssertEqual(owner.nativeEntries.map(\.action), [.start("Exact confirmed instruction"), .pause, .stop])
    }
    func testRevokeDiscardsAlreadyQueuedResumeWhilePauseIsInFlight() {
        var mailbox = PrototypeSpeechMailbox(); let generation = UUID()
        XCTAssertTrue(mailbox.open(generation))
        let pause = PrototypeSpeechCommand(generation: generation, sequence: 1, action: .pause)
        let resume = PrototypeSpeechCommand(generation: generation, sequence: 2, action: .resume)
        let stop = PrototypeSpeechCommand(generation: generation, sequence: 3, action: .stop)
        XCTAssertTrue(mailbox.enqueue(pause)); XCTAssertEqual(mailbox.admitNext(), pause)
        XCTAssertTrue(mailbox.enqueue(resume))
        mailbox.revokeAndStop(stop)
        XCTAssertFalse(mailbox.enqueue(resume)); XCTAssertEqual(mailbox.pending, [stop])
        XCTAssertNil(mailbox.admitNext())
        mailbox.returned(.init(command: pause, succeeded: true))
        XCTAssertEqual(mailbox.admitNext(), stop)
    }
    func testBackgroundVoiceOverRouteCloseEachPreserveStopBarrierDuringHeldPause() {
        for trigger in ["background", "voiceOver", "routeChange", "close"] {
            let owner = ControlledPrototypeOwner(); var permitted = true
            let model = make(owner, allowed: { permitted }); start(model, owner)
            model.pause(); _ = owner.enterNext()
            permitted = false // Production VoiceOver/lifecycle/authority gate, separate from ack.
            if trigger == "close" { model.close() } else { model.stop() }
            XCTAssertEqual(model.state, .stopping, trigger)
            owner.returnCurrent(true); XCTAssertEqual(model.state, .stopping, trigger)
            XCTAssertEqual(owner.enterNext()?.action, .stop)
            owner.returnCurrent(true); XCTAssertEqual(model.state, .stopped, trigger)
            XCTAssertFalse(model.play("Cannot restart while the gate is invalid"), trigger)
        }
    }
    func testFailedStopNeverClaimsStoppedOrAllowsReplacementAndDoesNotRetry() {
        let owner = ControlledPrototypeOwner(); let model = make(owner); start(model, owner)
        model.stop(); XCTAssertEqual(owner.enterNext()?.action, .stop); owner.returnCurrent(false)
        XCTAssertEqual(model.state, .stopping); XCTAssertTrue(model.unavailable)
        XCTAssertFalse(model.play("Unsafe replacement")); XCTAssertNil(owner.enterNext())
    }
    func testLatePauseAndOldStopResultsCannotAffectNewGenerationOrLease() {
        let owner = ControlledPrototypeOwner(); let model = make(owner); start(model, owner)
        model.pause(); let pause = owner.enterNext()!
        model.stop(); owner.returnCurrent(true); let stop = owner.enterNext()!; owner.returnCurrent(true)
        XCTAssertTrue(model.play("New current projection")); let newLease = model.audioLease!
        owner.onResult?(.init(command: pause, succeeded: true))
        owner.onResult?(.init(command: stop, succeeded: true))
        XCTAssertEqual(model.state, .preparing); XCTAssertEqual(model.audioLease, newLease)
        XCTAssertFalse(owner.releasedLeases.contains(newLease))
    }
    func testPendingAudioCompletionAfterRevocationCannotStartOrReleaseNewLease() {
        let owner = ControlledPrototypeOwner(); let model = make(owner)
        XCTAssertTrue(model.play("Old")); let oldLease = model.audioLease!
        model.stop(); XCTAssertEqual(owner.enterNext()?.action, .stop); owner.returnCurrent(true)
        XCTAssertTrue(model.play("New")); let newLease = model.audioLease!
        owner.completeAudio() // Stale old completion: only old lease can be disposed.
        XCTAssertEqual(model.state, .preparing); XCTAssertEqual(model.audioLease, newLease)
        XCTAssertTrue(owner.releasedLeases.contains(oldLease)); XCTAssertFalse(owner.releasedLeases.contains(newLease))
        XCTAssertNil(owner.enterNext())
        owner.completeAudio(); XCTAssertEqual(owner.enterNext()?.action, .start("New"))
    }
    func testSuccessfulPauseAndResumeUseSameGenerationNewLeaseAndRealResumeCommand() {
        let owner = ControlledPrototypeOwner(); let model = make(owner); start(model, owner)
        let generation = model.generation!, firstLease = model.audioLease!
        model.pause(); XCTAssertEqual(owner.enterNext()?.action, .pause); owner.returnCurrent(true)
        XCTAssertEqual(model.state, .paused); XCTAssertTrue(owner.releasedLeases.contains(firstLease))
        model.resume(); let secondLease = model.audioLease!
        XCTAssertNotEqual(firstLease, secondLease); XCTAssertEqual(model.generation, generation)
        owner.completeAudio(); XCTAssertEqual(owner.enterNext()?.action, .resume)
        owner.returnCurrent(true); XCTAssertEqual(model.state, .speaking)
    }
    func testFailedPauseStopsInsteadOfPretendingPaused() {
        let owner = ControlledPrototypeOwner(); let model = make(owner); start(model, owner)
        model.pause(); _ = owner.enterNext(); owner.returnCurrent(false)
        XCTAssertEqual(model.state, .stopping); XCTAssertEqual(owner.enterNext()?.action, .stop)
    }
    func testDuplicatePreparationCompletionCannotRepeatStartOrReleaseCurrentLease() {
        let owner = ControlledPrototypeOwner(); let model = make(owner)
        XCTAssertTrue(model.play("One exact instruction"))
        let lease = model.audioLease!, completion = owner.audioCompletions[0]
        owner.completeAudio(); completion(true)
        XCTAssertEqual(owner.mailbox.pending.count, 1)
        XCTAssertFalse(owner.releasedLeases.contains(lease))
        XCTAssertEqual(owner.enterNext()?.action, .start("One exact instruction"))
        owner.returnCurrent(true)
        completion(true) // Duplicate arriving after native ack must not release active audio.
        XCTAssertEqual(model.state, .speaking); XCTAssertNil(owner.enterNext())
        XCTAssertFalse(owner.releasedLeases.contains(lease))
    }
    func testDuplicatePreparationCompletionCannotRepeatResumeOrReleaseItsLease() {
        let owner = ControlledPrototypeOwner(); let model = make(owner); start(model, owner)
        model.pause(); _ = owner.enterNext(); owner.returnCurrent(true)
        model.resume(); let lease = model.audioLease!, completion = owner.audioCompletions[0]
        owner.completeAudio(); completion(true)
        XCTAssertEqual(owner.mailbox.pending.map(\.action), [.resume])
        XCTAssertFalse(owner.releasedLeases.contains(lease))
        _ = owner.enterNext(); owner.returnCurrent(true); completion(true)
        XCTAssertEqual(model.state, .speaking); XCTAssertNil(owner.enterNext())
        XCTAssertFalse(owner.releasedLeases.contains(lease))
    }
    func testMailboxRejectsDuplicateOlderAndStaleRevocationCommands() {
        var mailbox = PrototypeSpeechMailbox(); let id = UUID()
        XCTAssertTrue(mailbox.open(id))
        let newer = PrototypeSpeechCommand(generation: id, sequence: 2, action: .pause)
        let older = PrototypeSpeechCommand(generation: id, sequence: 1, action: .resume)
        XCTAssertTrue(mailbox.enqueue(newer)); XCTAssertFalse(mailbox.enqueue(newer))
        XCTAssertFalse(mailbox.enqueue(older)); XCTAssertEqual(mailbox.pending, [newer])
        let stop = PrototypeSpeechCommand(generation: id, sequence: 3, action: .stop)
        XCTAssertTrue(mailbox.revokeAndStop(stop))
        XCTAssertFalse(mailbox.revokeAndStop(stop))
        XCTAssertFalse(mailbox.revokeAndStop(.init(generation: id, sequence: 1, action: .stop)))
        XCTAssertEqual(mailbox.pending, [stop]); XCTAssertEqual(mailbox.lastAcceptedSequence, 3)
    }
    func testLateStartAcknowledgmentAfterRevocationCannotRestoreSpeaking() {
        let owner = ControlledPrototypeOwner(); let model = make(owner)
        XCTAssertTrue(model.play("Current")); owner.completeAudio(); _ = owner.enterNext()
        model.stop(); owner.returnCurrent(true)
        XCTAssertEqual(model.state, .stopping); XCTAssertEqual(owner.enterNext()?.action, .stop)
    }
}

@MainActor private final class ControlledPrototypeOwner: PrototypeSpeechTransport {
    var onResult: (@MainActor (PrototypeSpeechResult) -> Void)?
    var mailbox = PrototypeSpeechMailbox()
    var nativeEntries: [PrototypeSpeechCommand] = []
    var releasedLeases: [UUID] = []
    var audioCompletions: [@MainActor (Bool) -> Void] = []
    func openGeneration(_ id: UUID) -> Bool { mailbox.open(id) }
    func prepareAudio(lease: UUID, completion: @escaping @MainActor (Bool) -> Void) { audioCompletions.append(completion) }
    func releaseAudio(lease: UUID) { releasedLeases.append(lease) }
    func enqueue(_ command: PrototypeSpeechCommand) { precondition(mailbox.enqueue(command)) }
    func revokeAndStop(_ command: PrototypeSpeechCommand) { precondition(mailbox.revokeAndStop(command)) }
    func completeAudio(_ success: Bool = true) { audioCompletions.removeFirst()(success) }
    func enterNext() -> PrototypeSpeechCommand? {
        guard let command = mailbox.admitNext() else { return nil }
        nativeEntries.append(command); return command
    }
    func returnCurrent(_ succeeded: Bool) {
        let result = PrototypeSpeechResult(command: mailbox.inFlight!, succeeded: succeeded)
        mailbox.returned(result); onResult?(result)
    }
}
