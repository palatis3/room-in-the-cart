import Foundation
import AVFoundation
import Speech

/// In-memory buffers go only to Apple's explicitly on-device recognizer. No file, HTTP or analytics path exists.
@MainActor final class OnDeviceSpeechCapture: CaptureSpeechService {
    private let bundle: Bundle
    private var recognizer: SFSpeechRecognizer?
    private var engine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognition: SFSpeechRecognitionTask?
    private var continuation: AsyncThrowingStream<SpeechCaptureUpdate, Error>.Continuation?
    private var runID = UUID()
    private var hasTap = false
    private let audio: CookAudioSession
    private var audioLease: CookCaptureAudioRequest?

    init(bundle: Bundle = .main, audio: CookAudioSession = .shared) { self.bundle = bundle; self.audio = audio }

    func begin(localeIdentifier: String) async throws -> AsyncThrowingStream<SpeechCaptureUpdate, Error> {
        stop(); let run = runID
        for key in ["NSSpeechRecognitionUsageDescription", "NSMicrophoneUsageDescription"] {
            guard let description = bundle.object(forInfoDictionaryKey: key) as? String,
                  !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CaptureFailure.notConfigured }
        }
        let language = Locale(identifier: localeIdentifier).language.languageCode?.identifier
        guard language == "en" || language == "es" else { throw CaptureFailure.onDeviceUnavailable }
        let locale = language == "es" ? "es-US" : "en-US"
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: locale)),
              recognizer.supportsOnDeviceRecognition else { throw CaptureFailure.onDeviceUnavailable }
        let authorized = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
        }
        guard runID == run, !Task.isCancelled else { throw CancellationError() }
        guard authorized else { throw CaptureFailure.permissionDenied }
        let microphone = await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) }
        }
        guard runID == run, !Task.isCancelled else { throw CancellationError() }
        guard microphone else { throw CaptureFailure.permissionDenied }
        guard recognizer.supportsOnDeviceRecognition, recognizer.isAvailable else { throw CaptureFailure.onDeviceUnavailable }
        do {
            let lease = CookCaptureAudioRequest(audio: audio); audioLease = lease
            let acquired = await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    lease.acquire { continuation.resume(returning: $0) }
                }
            } onCancel: { lease.cancel() }
            guard runID == run, audioLease === lease, !Task.isCancelled else {
                lease.cancel(); throw CancellationError()
            }
            guard acquired else { throw CaptureFailure.audioUnavailable }
            let engine = AVAudioEngine()
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.requiresOnDeviceRecognition = true
            request.shouldReportPartialResults = true
            request.taskHint = .dictation
            let format = engine.inputNode.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else { throw CaptureFailure.audioUnavailable }
            self.recognizer = recognizer; self.engine = engine; self.request = request
            let stream = AsyncThrowingStream<SpeechCaptureUpdate, Error> { continuation in
                self.continuation = continuation
                continuation.onTermination = { [weak self] _ in
                    Task { @MainActor [weak self] in if self?.runID == run { self?.stop() } }
                }
            }
            recognition = recognizer.recognitionTask(with: request) { [weak self] result, error in
                let update = result.map { SpeechCaptureUpdate(text: $0.bestTranscription.formattedString,
                    isFinal: $0.isFinal, uncertain: $0.bestTranscription.segments.contains { $0.confidence < 0.7 }) }
                let failed = error != nil
                Task { @MainActor [weak self] in
                    guard let self, self.runID == run else { return }
                    if let update { self.continuation?.yield(update) }
                    if update?.isFinal == true { self.continuation?.finish() }
                    else if failed { self.continuation?.finish(throwing: CaptureFailure.recognitionFailed) }
                }
            }
            engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in request.append(buffer) }
            hasTap = true
            engine.prepare(); try engine.start()
            return stream
        } catch {
            if runID == run { stop() } // A late cancelled begin must not stop a newer capture run.
            if error is CancellationError { throw CancellationError() }
            throw error as? CaptureFailure ?? .audioUnavailable
        }
    }

    func stop() {
        runID = UUID()
        engine?.stop()
        if hasTap { engine?.inputNode.removeTap(onBus: 0); hasTap = false }
        request?.endAudio(); recognition?.cancel()
        continuation?.finish(); continuation = nil
        recognition = nil; request = nil; engine = nil; recognizer = nil
        if let audioLease { audioLease.cancel(); self.audioLease = nil }
    }
}
