import AVFoundation
import UIKit

/// Local installed voices only. Playback never requests microphone or speech-recognition permission.
@MainActor final class LocalCookSpeech: NSObject, CookSpeechPlayback, AVSpeechSynthesizerDelegate {
    var onEnd: ((UUID) -> Void)?
    private let synthesizer = AVSpeechSynthesizer()
    private var ids: [ObjectIdentifier: UUID] = [:]
    private var sessionID: UUID?

    override init() { super.init(); synthesizer.delegate = self }
    deinit {
        if let sessionID { CookAudioSession.shared.release(sessionID) }
    }
    func prepareAudio(for id: UUID, completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        sessionID = id
        CookAudioSession.shared.acquire(id, completion: completion)
    }
    func speak(_ text: String, localeIdentifier: String, playbackID: UUID) throws {
        guard sessionID == playbackID else { throw CaptureFailure.audioUnavailable }
        guard !UIAccessibility.isVoiceOverRunning else { throw CaptureFailure.audioUnavailable }
        let language = Locale(identifier: localeIdentifier).language.languageCode?.identifier
        guard language == "en" || language == "es" else { throw CaptureFailure.onDeviceUnavailable }
        let locale = language == "es" ? "es-US" : "en-US"
        let voices = AVSpeechSynthesisVoice.speechVoices()
        guard let voice = voices.first(where: { $0.language == locale }) else { throw CaptureFailure.onDeviceUnavailable }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        ids[ObjectIdentifier(utterance)] = playbackID
        synthesizer.speak(utterance)
    }
    func pause() -> Bool {
        let paused = synthesizer.pauseSpeaking(at: .immediate)
        if paused { deactivate() }
        return paused
    }
    func resume() throws -> Bool {
        guard !UIAccessibility.isVoiceOverRunning else { throw CaptureFailure.audioUnavailable }
        return synthesizer.continueSpeaking()
    }
    func stop() {
        if !ids.isEmpty { synthesizer.stopSpeaking(at: .immediate) }
        ids.removeAll()
        deactivate()
    }
    private func deactivate() {
        if let sessionID { CookAudioSession.shared.release(sessionID) }
        sessionID = nil
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let key = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in
            guard let self, let id = self.ids.removeValue(forKey: key) else { return }
            self.deactivate(); self.onEnd?(id)
        }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let key = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in
            guard let self, let id = self.ids.removeValue(forKey: key) else { return }
            self.deactivate(); self.onEnd?(id)
        }
    }
}

/// The audio session is process-wide. Serialize acquisition and release across cook views, and keep
/// the blocking AVAudioSession calls off the main thread on every supported iOS version.
final class CookAudioSession: @unchecked Sendable {
    static let shared = CookAudioSession(activate: {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try session.setActive(true)
    }, deactivate: {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    })

    private let queue = DispatchQueue(label: "dev.roominthecart.cook-audio-session", qos: .userInitiated)
    private let activate: @Sendable () throws -> Void
    private let deactivate: @Sendable () -> Void
    private var owner: UUID? // Accessed only on queue.

    init(activate: @escaping @Sendable () throws -> Void, deactivate: @escaping @Sendable () -> Void) {
        self.activate = activate
        self.deactivate = deactivate
    }

    func acquire(_ id: UUID, completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        queue.async {
            if self.owner == nil {
                do {
                    try self.activate()
                    self.owner = id
                } catch {
                    DispatchQueue.main.async { completion(false) }
                    return
                }
            }
            let acquired = self.owner == id
            DispatchQueue.main.async { completion(acquired) }
        }
    }

    func release(_ id: UUID) {
        queue.async {
            guard self.owner == id else { return }
            self.deactivate()
            self.owner = nil
        }
    }
}
