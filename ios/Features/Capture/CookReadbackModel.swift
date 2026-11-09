import Foundation
import Combine

/// Runtime presentation only. The authority binding is not Codable or restored from a saved note.
struct CookReadbackInstruction: Equatable, Sendable {
    let authorityBindingID: UUID
    let sourceID: UUID
    let sourceRevision: Int64
    let createdAt: Date
    let startBefore: Date
    let text: String
    let localeIdentifier: String
    let excludesPrivateBudget: Bool
}

@MainActor protocol CookSpeechPlayback: AnyObject {
    var onEnd: ((UUID) -> Void)? { get set }
    func prepareAudio(for id: UUID, completion: @escaping @MainActor @Sendable (Bool) -> Void)
    func speak(_ text: String, localeIdentifier: String, playbackID: UUID) throws
    func pause() -> Bool
    func resume() throws -> Bool
    func stop()
    func beginIntent(_ id: UUID, changed: @escaping @MainActor @Sendable (UUID) -> Void) -> Bool
    func intentGate(_ id: UUID) -> CookAudioGate
    func admitPlayback(_ id: UUID) -> CookAudioGate
}
// Non-session fakes retain their existing contract; production LocalCookSpeech supplies all gates.
extension CookSpeechPlayback {
    func beginIntent(_ id: UUID, changed: @escaping @MainActor @Sendable (UUID) -> Void) -> Bool { true }
    func intentGate(_ id: UUID) -> CookAudioGate { .ready }
    func admitPlayback(_ id: UUID) -> CookAudioGate { .ready }
}

@MainActor final class CookReadbackModel: ObservableObject {
    enum State: Equatable { case stopped, preparing, speaking, paused }
    @Published private(set) var state = State.stopped
    @Published private(set) var voiceOverActive = false
    @Published private(set) var unavailable = false
    @Published private(set) var instruction: CookReadbackInstruction
    private let speech: any CookSpeechPlayback
    private let authorize: (CookReadbackInstruction, Date) -> Bool
    private let clock: () -> Date
    private var playbackID: UUID?
    private var preparationID: UUID?
    private var readiness: (generation: UUID, attempt: UUID, resuming: Bool, ready: Bool)?
    private var watchdog: Task<Void, Never>?
    private var closed = false

    init(instruction: CookReadbackInstruction, speech: any CookSpeechPlayback, clock: @escaping () -> Date = Date.init,
         authorize: @escaping (CookReadbackInstruction, Date) -> Bool) {
        self.instruction = instruction; self.speech = speech; self.clock = clock; self.authorize = authorize
        speech.onEnd = { [weak self] id in
            guard let self, self.playbackID == id else { return }
            self.stop()
        }
    }
    var canRead: Bool { canRead(at: clock()) }
    var canStart: Bool {
        let now = clock()
        return now < instruction.startBefore && !voiceOverActive && canRead(at: now)
    }
    var canResume: Bool { state == .paused && canContinue && playbackID.map { speech.intentGate($0) == .ready } == true }
    private var canContinue: Bool { !voiceOverActive && canRead }

    private func canRead(at now: Date) -> Bool {
        !closed && instruction.excludesPrivateBudget && instruction.sourceRevision >= 0 &&
        instruction.createdAt <= now && !instruction.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        (try? CaptureLimits.validate(instruction.text)) != nil && authorize(instruction, now)
    }

    func update(_ instruction: CookReadbackInstruction) {
        guard !closed else { return }
        if self.instruction != instruction { stop(); self.instruction = instruction; unavailable = false }
    }
    func setVoiceOver(_ active: Bool) {
        voiceOverActive = active
        if active { stop() } // VoiceOver is exclusive. Turning it off never resumes playback automatically.
    }
    func playFromBeginning() {
        guard canStart else { checkCurrent(); return }
        stop(); unavailable = false
        let id = UUID(); playbackID = id
        guard speech.beginIntent(id, changed: { [weak self] id in self?.audioIntentChanged(id) }) else {
            stop(); unavailable = true; return
        }
        watch(id)
        prepareAudio(for: id, resuming: false)
    }
    private func prepareAudio(for id: UUID, resuming: Bool) {
        let attempt = UUID(); preparationID = attempt; readiness = nil
        state = .preparing
        speech.prepareAudio(for: id) { [weak self] ready in
            guard let self, self.playbackID == id, self.preparationID == attempt, self.state == .preparing else { return }
            self.readiness = (id, attempt, resuming, ready)
            self.admitPreparedPlayback()
        }
    }
    private func audioIntentChanged(_ id: UUID) {
        guard playbackID == id else { return }
        if speech.intentGate(id) == .invalid { stop() }
        else { admitPreparedPlayback() }
    }
    private func admitPreparedPlayback() {
        guard let candidate = readiness, playbackID == candidate.generation,
              preparationID == candidate.attempt, state == .preparing else { return }
        guard candidate.resuming ? canContinue : canStart else { stop(); return }
        let intent = speech.intentGate(candidate.generation)
        guard intent != .invalid else { stop(); return }
        guard candidate.ready else { stop(); unavailable = true; return }
        if intent == .pending { return } // Retain only this explicit request until every ticket resolves.
        switch speech.admitPlayback(candidate.generation) { // Atomic receipt/admission boundary.
        case .invalid: stop(); return
        case .pending: return
        case .ready: break
        }
        readiness = nil
        do {
            if candidate.resuming {
                guard try speech.resume() else { throw CaptureFailure.audioUnavailable }
            } else {
                try speech.speak(instruction.text, localeIdentifier: instruction.localeIdentifier,
                                 playbackID: candidate.generation)
            }
            // A reentrant/foreign-thread event after admission requests Stop for this generation;
            // never publish speaking after a revoked call returns. No lock spans the native call.
            guard playbackID == candidate.generation, preparationID == candidate.attempt else { return }
            guard speech.intentGate(candidate.generation) != .invalid else { stop(); return }
            state = .speaking
        } catch {
            guard playbackID == candidate.generation else { return }
            stop(); unavailable = true
        }
    }
    func pause() {
        guard state == .speaking else { return }
        guard canContinue, let playbackID, speech.intentGate(playbackID) != .invalid else { stop(); return }
        if speech.pause() {
            guard self.playbackID == playbackID, speech.intentGate(playbackID) != .invalid else { stop(); return }
            state = .paused
        } else { stop() }
    }
    func resume() {
        guard state == .paused else { return }
        guard canResume, let playbackID else { stop(); return }
        prepareAudio(for: playbackID, resuming: true)
    }
    /// Parent may call synchronously on an authority/source change; the watchdog also checks during playback.
    func checkCurrent() { if !canContinue { stop() } }
    func stop() {
        playbackID = nil; preparationID = nil; readiness = nil
        watchdog?.cancel(); watchdog = nil
        speech.stop(); state = .stopped
    }
    func close() { stop(); closed = true; speech.onEnd = nil }
    private func watch(_ id: UUID) {
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled, let self, self.playbackID == id else { return }
                self.checkCurrent()
            }
        }
    }
}
