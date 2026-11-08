import AVFoundation
import UIKit

/// Local installed voices only. Playback never requests microphone or speech-recognition permission.
@MainActor final class LocalCookSpeech: NSObject, CookSpeechPlayback, AVSpeechSynthesizerDelegate {
    var onEnd: ((UUID) -> Void)?
    private let synthesizer = AVSpeechSynthesizer()
    private var ids: [ObjectIdentifier: UUID] = [:]
    private let preparation = CookSpeechPreparation<AVSpeechSynthesisVoice>(
        loadVoices: CookInstalledVoices.load,
        acquire: { CookAudioSession.shared.acquire($0, completion: $1) },
        release: { CookAudioSession.shared.release($0) }
    )

    override init() { super.init(); synthesizer.delegate = self }
    func prepareAudio(for id: UUID, completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        preparation.prepare(for: id, completion: completion)
    }
    func speak(_ text: String, localeIdentifier: String, playbackID: UUID) throws {
        guard preparation.sessionID == playbackID else { throw CaptureFailure.audioUnavailable }
        guard !UIAccessibility.isVoiceOverRunning else { throw CaptureFailure.audioUnavailable }
        guard let voice = preparation.installedVoice(localeIdentifier: localeIdentifier, language: { $0.language })
        else { throw CaptureFailure.onDeviceUnavailable }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        ids[ObjectIdentifier(utterance)] = playbackID
        synthesizer.speak(utterance)
    }
    func pause() -> Bool {
        let paused = synthesizer.pauseSpeaking(at: .immediate)
        if paused { preparation.releaseAudio() }
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
        preparation.invalidate()
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

/// Only installed-voice discovery crosses this queue; synthesizers and utterances stay on MainActor.
private enum CookInstalledVoices {
    static let queue = DispatchQueue(label: "dev.roominthecart.cook-installed-voices", qos: .userInitiated)

    static func load(_ completion: @escaping @MainActor @Sendable ([AVSpeechSynthesisVoice]) -> Void) {
        queue.async {
            let voices = AVSpeechSynthesisVoice.speechVoices()
            DispatchQueue.main.async { completion(voices) }
        }
    }
}

/// A catalog belongs to one playback, including its pauses, and is never a process-wide voice cache.
@MainActor final class CookSpeechPreparation<Voice: Sendable> {
    typealias VoiceCompletion = @MainActor @Sendable ([Voice]) -> Void
    typealias AudioCompletion = @MainActor @Sendable (Bool) -> Void
    private let loadVoices: (@escaping VoiceCompletion) -> Void
    private let acquire: (UUID, @escaping AudioCompletion) -> Void
    private let release: @Sendable (UUID) -> Void
    private var generation: UUID?
    private var preparedFor: UUID?
    private var voices: [Voice] = []
    private(set) var sessionID: UUID?

    init(loadVoices: @escaping (@escaping VoiceCompletion) -> Void,
         acquire: @escaping (UUID, @escaping AudioCompletion) -> Void,
         release: @escaping @Sendable (UUID) -> Void) {
        self.loadVoices = loadVoices; self.acquire = acquire; self.release = release
    }
    deinit { if let sessionID { release(sessionID) } }

    func prepare(for id: UUID, completion: @escaping AudioCompletion) {
        // Invalidation queues the old owner's release before any newer acquire, even for a reused id.
        releaseAudio()
        let token = UUID()
        generation = token
        sessionID = id
        if preparedFor == id {
            acquireAudio(for: id, token: token, completion: completion)
        } else {
            preparedFor = nil; voices = []
            loadVoices { [weak self] voices in
                guard let self, self.generation == token else { return }
                self.voices = voices; self.preparedFor = id
                self.acquireAudio(for: id, token: token, completion: completion)
            }
        }
    }
    private func acquireAudio(for id: UUID, token: UUID, completion: @escaping AudioCompletion) {
        acquire(id) { [weak self] ready in
            // The matching release was already queued on invalidation. Releasing here could release
            // a newer preparation using the same playback id.
            guard let self, self.generation == token else { return }
            completion(ready)
        }
    }
    func installedVoice(localeIdentifier: String, language: (Voice) -> String) -> Voice? {
        let code = Locale(identifier: localeIdentifier).language.languageCode?.identifier
        guard code == "en" || code == "es" else { return nil }
        let locale = code == "es" ? "es-US" : "en-US"
        return voices.first { language($0) == locale }
    }
    func releaseAudio() {
        generation = nil
        if let sessionID { release(sessionID) }
        sessionID = nil
    }
    func invalidate() {
        releaseAudio()
        preparedFor = nil; voices = []
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
