import Foundation
import Combine

/// Runtime presentation only. The authority binding is not Codable or restored from a saved note.
struct CookReadbackInstruction: Equatable, Sendable {
    let authorityBindingID: UUID
    let sourceID: UUID
    let sourceRevision: Int64
    let createdAt: Date
    let text: String
    let localeIdentifier: String
    let excludesPrivateBudget: Bool
}

@MainActor protocol CookSpeechPlayback: AnyObject {
    var onEnd: ((UUID) -> Void)? { get set }
    func speak(_ text: String, localeIdentifier: String, playbackID: UUID) throws
    func pause() -> Bool
    func resume() throws -> Bool
    func stop()
}

@MainActor final class CookReadbackModel: ObservableObject {
    enum State: Equatable { case stopped, speaking, paused }
    @Published private(set) var state = State.stopped
    @Published private(set) var voiceOverActive = false
    @Published private(set) var unavailable = false
    @Published private(set) var instruction: CookReadbackInstruction
    private let speech: any CookSpeechPlayback
    private let authorize: (CookReadbackInstruction, Date) -> Bool
    private let clock: () -> Date
    private var playbackID: UUID?
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
    var canRead: Bool {
        !closed && instruction.excludesPrivateBudget && instruction.sourceRevision >= 0 &&
        instruction.createdAt <= clock() && !instruction.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        (try? CaptureLimits.validate(instruction.text)) != nil && authorize(instruction, clock())
    }
    var canPlay: Bool { canRead && !voiceOverActive }

    func update(_ instruction: CookReadbackInstruction) {
        guard !closed else { return }
        if self.instruction != instruction { stop(); self.instruction = instruction; unavailable = false }
    }
    func setVoiceOver(_ active: Bool) {
        voiceOverActive = active
        if active { stop() } // VoiceOver is exclusive. Turning it off never resumes playback automatically.
    }
    func playFromBeginning() {
        guard canPlay else { stop(); return }
        stop(); unavailable = false
        let id = UUID(); playbackID = id
        do {
            try speech.speak(instruction.text, localeIdentifier: instruction.localeIdentifier, playbackID: id)
            state = .speaking
            watch(id)
        } catch { stop(); unavailable = true }
    }
    func pause() {
        guard state == .speaking else { return }
        if speech.pause() { state = .paused }
        else { stop() }
    }
    func resume() {
        guard state == .paused, canPlay else { stop(); return }
        do {
            if try speech.resume() { state = .speaking }
            else { stop(); unavailable = true }
        } catch { stop(); unavailable = true }
    }
    /// Parent may call synchronously on an authority/source change; the watchdog also checks during playback.
    func checkCurrent() { if !canPlay { stop() } }
    func stop() {
        playbackID = nil; watchdog?.cancel(); watchdog = nil
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
