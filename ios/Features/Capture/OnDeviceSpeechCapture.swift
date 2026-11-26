import Foundation
import AVFoundation
import Speech
import SwiftUI

struct GrocerySpeechPermissionScope: Equatable {
    let adult: CapturePrivateIdentity
    let workspace: UUID
    let shop: UUID?
    let generation: UUID
}

private struct GrocerySpeechPermissionKey: EnvironmentKey {
    static let defaultValue: PantryNotificationPresenter? = nil
}

extension EnvironmentValues {
    var grocerySpeechPermission: PantryNotificationPresenter? {
        get { self[GrocerySpeechPermissionKey.self] }
        set { self[GrocerySpeechPermissionKey.self] = newValue }
    }
}

/// In-memory buffers go only to Apple's explicitly on-device recognizer. No file, HTTP or analytics path exists.
@MainActor final class OnDeviceSpeechCapture: CaptureSpeechService {
    private let bundle: Bundle
    private let punctuatesList: Bool
    private let willRequestPermission: @MainActor () -> Bool
    private var recognizer: SFSpeechRecognizer?
    private var engine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognition: SFSpeechRecognitionTask?
    private var continuation: AsyncThrowingStream<SpeechCaptureUpdate, Error>.Continuation?
    private var interruptionObserver: NSObjectProtocol?
    private var runID = UUID()
    private var hasTap = false
    private let audio: CookAudioSession
    private var audioLease: CookCaptureAudioRequest?

    init(bundle: Bundle = .main, audio: CookAudioSession = .shared, punctuatesList: Bool = false,
         willRequestPermission: @escaping @MainActor () -> Bool = { true }) {
        self.willRequestPermission = willRequestPermission
        self.bundle = bundle
        self.audio = audio
        self.punctuatesList = punctuatesList
    }

    private static func configured(_ bundle: Bundle) -> Bool {
        ["NSSpeechRecognitionUsageDescription", "NSMicrophoneUsageDescription"].allSatisfy {
            guard let value = bundle.object(forInfoDictionaryKey: $0) as? String else { return false }
            return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private static func localRecognizer(_ language: String?) -> SFSpeechRecognizer? {
        guard language == "en" || language == "es" else { return nil }
        let locales = language == "es" ? ["es-MX", "es-US"] : ["en-US"]
        return locales.compactMap { SFSpeechRecognizer(locale: Locale(identifier: $0)) }
            .first { $0.supportsOnDeviceRecognition && $0.isAvailable }
    }

    /// Ask while the private Shop is still mounted, before presenting the nested list editor.
    /// The root permission window resumes only in the same unlocked adult workspace.
    static func prepareGroceryPermissions(_ present: PantryNotificationPresenter) async throws {
        let language = Locale(identifier: CaptureCorrectionScope.appLanguage()).language.languageCode?.identifier
        guard configured(.main), localRecognizer(language) != nil else { return }
        if SFSpeechRecognizer.authorizationStatus() == .notDetermined {
            let granted = try await present {
                await withCheckedContinuation { reply in SFSpeechRecognizer.requestAuthorization { reply.resume(returning: $0 == .authorized) } }
            }
            guard granted else { return }
        }
        if SFSpeechRecognizer.authorizationStatus() == .authorized, AVAudioApplication.shared.recordPermission == .undetermined {
            _ = try await present {
                await withCheckedContinuation { reply in AVAudioApplication.requestRecordPermission { reply.resume(returning: $0) } }
            }
        }
    }

    func begin(localeIdentifier: String) async throws -> AsyncThrowingStream<SpeechCaptureUpdate, Error> {
        stop(); let run = runID
        guard Self.configured(bundle) else { throw CaptureFailure.notConfigured }
        let language = Locale(identifier: localeIdentifier).language.languageCode?.identifier
        guard let recognizer = Self.localRecognizer(language) else { throw CaptureFailure.onDeviceUnavailable }
        if SFSpeechRecognizer.authorizationStatus() == .notDetermined && !willRequestPermission() {
            throw CaptureFailure.permissionDenied
        }
        let authorized = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
        }
        guard runID == run, !Task.isCancelled else { throw CancellationError() }
        guard authorized else { throw CaptureFailure.permissionDenied }
        if AVAudioApplication.shared.recordPermission == .undetermined && !willRequestPermission() {
            throw CaptureFailure.permissionDenied
        }
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
            if punctuatesList { request.addsPunctuation = true }
            let format = engine.inputNode.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else { throw CaptureFailure.audioUnavailable }
            self.recognizer = recognizer; self.engine = engine; self.request = request
            let stream = AsyncThrowingStream<SpeechCaptureUpdate, Error> { continuation in
                self.continuation = continuation
                continuation.onTermination = { [weak self] _ in
                    Task { @MainActor [weak self] in if self?.runID == run { self?.stop() } }
                }
            }
            interruptionObserver = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification,
                object: nil, queue: .main) { [weak self] note in
                guard let type = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                      type == AVAudioSession.InterruptionType.began.rawValue else { return }
                Task { @MainActor [weak self] in
                    guard let self, self.runID == run else { return }
                    self.continuation?.finish(throwing: CaptureFailure.audioUnavailable)
                    self.stop()
                }
            }
            recognition = recognizer.recognitionTask(with: request) { [weak self] result, error in
                let update = result.map { result in
                    let transcript = result.bestTranscription
                    let uncertain = transcript.segments.filter { $0.confidence < 0.7 }
                    let repairs = uncertain.prefix(64).compactMap { segment in
                        SpeechWordRepair(text: transcript.formattedString, range: segment.substringRange,
                            word: segment.substring, alternatives: segment.alternativeSubstrings)
                    }
                    return SpeechCaptureUpdate(text: transcript.formattedString, isFinal: result.isFinal,
                        uncertain: !uncertain.isEmpty, repairs: repairs)
                }
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
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
            self.interruptionObserver = nil
        }
        engine?.stop()
        if hasTap { engine?.inputNode.removeTap(onBus: 0); hasTap = false }
        request?.endAudio(); recognition?.cancel()
        continuation?.finish(); continuation = nil
        recognition = nil; request = nil; engine = nil; recognizer = nil
        if let audioLease { audioLease.cancel(); self.audioLease = nil }
    }
}
