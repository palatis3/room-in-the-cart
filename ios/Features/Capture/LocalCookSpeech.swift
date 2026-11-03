import AVFoundation
import UIKit

/// Local installed voices only. Playback never requests microphone or speech-recognition permission.
@MainActor final class LocalCookSpeech: NSObject, CookSpeechPlayback, AVSpeechSynthesizerDelegate {
    var onEnd: ((UUID) -> Void)?
    private let synthesizer = AVSpeechSynthesizer()
    private var ids: [ObjectIdentifier: UUID] = [:]
    private var ownsSession = false

    override init() { super.init(); synthesizer.delegate = self }
    func speak(_ text: String, localeIdentifier: String, playbackID: UUID) throws {
        stop()
        guard !UIAccessibility.isVoiceOverRunning else { throw CaptureFailure.audioUnavailable }
        let language = Locale(identifier: localeIdentifier).language.languageCode?.identifier
        guard language == "en" || language == "es" else { throw CaptureFailure.onDeviceUnavailable }
        let locale = language == "es" ? "es-US" : "en-US"
        let voices = AVSpeechSynthesisVoice.speechVoices()
        guard let voice = voices.first(where: { $0.language == locale }) else { throw CaptureFailure.onDeviceUnavailable }
        try activate()
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
        try activate(); return synthesizer.continueSpeaking()
    }
    func stop() { synthesizer.stopSpeaking(at: .immediate); ids.removeAll(); deactivate() }
    private func activate() throws {
        try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try AVAudioSession.sharedInstance().setActive(true)
        ownsSession = true
    }
    private func deactivate() {
        if ownsSession { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation); ownsSession = false }
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
