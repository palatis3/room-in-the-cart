import Combine
import SwiftUI
import UIKit

@MainActor final class PantryVoiceSession: ObservableObject {
    @Published private(set) var capture: CaptureModel?
    @Published private(set) var unsupportedLanguage = false
    private var authorized: (() -> Bool)?
    private var promptReadiness: AnyCancellable?
    private var releasePrompt: (() -> Void)?

    func start(localeIdentifier: String, authorized: @escaping () -> Bool,
               prompt: PantryVoicePromptAccess? = nil, makeSpeech: @MainActor () -> any CaptureSpeechService = { OnDeviceSpeechCapture() }) {
        guard authorized(), capture?.busy != true else { return }
        cancel()
        let language = Locale(identifier: localeIdentifier).language.languageCode?.identifier
        guard language == "en" || language == "es" else {
            unsupportedLanguage = true
            return
        }
        // A new service per deliberate start isolates delayed permission replies from later runs.
        let model = CaptureModel(localeIdentifier: language == "es" ? "es-US" : "en-US",
                                 speech: makeSpeech(), ocr: OnDeviceTextCapture())
        self.authorized = authorized
        capture = model
        // Bind the permission interruption before the system starts its prompt. Its
        // lifetime follows this capture and the owning screen, independent of visible form rows.
        let promptID = prompt?.begin()
        if let prompt, let promptID { releasePrompt = { prompt.cancel(promptID) } }
        model.startSpeech()
        if let prompt, let promptID {
            promptReadiness = model.$listening.combineLatest(model.$busy)
                .first { listening, busy in listening || !busy }
                .sink { _ in prompt.ready(promptID) }
        }
    }

    func use(_ model: CaptureModel, authorizedNow: () -> Bool, onUse: (String) -> Void) {
        guard capture === model else { return }
        guard authorized?() == true, authorizedNow() else { cancel(); return }
        guard !model.busy, let text = model.candidate?.text,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        cancel()
        onUse(text)
    }

    func cancel() {
        promptReadiness?.cancel()
        promptReadiness = nil
        releasePrompt?()
        releasePrompt = nil
        capture?.close()
        capture = nil
        authorized = nil
        unsupportedLanguage = false
    }
}

struct PantryVoiceInput: View {
    @ObservedObject var voice: PantryVoiceSession
    let authorized: () -> Bool
    let onUse: (String) -> Void
    @Environment(\.locale) private var locale
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.pantryVoicePrompt) private var prompt

    var body: some View {
        Section {
            if authorized() {
                if let model = voice.capture {
                    PantryVoiceControls(model: model, start: start, cancel: voice.cancel, use: {
                        guard scenePhase == .active, UIApplication.shared.applicationState == .active, UIApplication.shared.isProtectedDataAvailable else { return }
                        voice.use(model, authorizedNow: authorized, onUse: onUse)
                    })
                } else {
                    if voice.unsupportedLanguage {
                        Text(pantryText("On-device dictation is unavailable for this language or device. You can type instead."))
                            .accessibilityIdentifier("pantry.voice.status")
                    }
                    Button(pantryText("Start dictation"), action: start)
                        .accessibilityIdentifier("pantry.voice.start")
                }
            }
        }
    }

    private func start() {
        guard scenePhase == .active, UIApplication.shared.applicationState == .active, UIApplication.shared.isProtectedDataAvailable else { return }
        voice.start(localeIdentifier: locale.identifier, authorized: authorized, prompt: prompt)
    }
}

private struct PantryVoiceControls: View {
    @ObservedObject var model: CaptureModel
    let start: () -> Void
    let cancel: () -> Void
    let use: () -> Void

    var body: some View {
        if model.listening {
            Text(pantryText("Listening — tap Stop when finished"))
                .accessibilityIdentifier("pantry.voice.listening")
            Button(pantryText("Stop")) { model.stopSpeech() }
                .accessibilityIdentifier("pantry.voice.stop")
        } else if model.busy {
            Text(pantryText("Preparing microphone…"))
                .accessibilityIdentifier("pantry.voice.status")
        } else if let failure = model.failure {
            switch failure {
            case .permissionDenied:
                Text(pantryText("Microphone or speech access is unavailable. You can type instead."))
                    .accessibilityIdentifier("pantry.voice.status")
            case .notConfigured, .onDeviceUnavailable:
                Text(pantryText("On-device dictation is unavailable for this language or device. You can type instead."))
                    .accessibilityIdentifier("pantry.voice.status")
            default:
                Text(pantryText("Dictation stopped. You can type or try again."))
                    .accessibilityIdentifier("pantry.voice.status")
            }
        } else if model.candidate?.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            Text(pantryText("Dictation stopped. You can type or try again."))
                .accessibilityIdentifier("pantry.voice.status")
        }

        if let text = model.candidate?.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if !model.busy { Text(pantryText("Review what you dictated")) }
            Text(verbatim: text).privacySensitive().accessibilityIdentifier("pantry.voice.transcript")
            if !model.busy {
                Button(pantryText("Use this text"), action: use)
                    .accessibilityIdentifier("pantry.voice.use")
            }
        } else if !model.busy {
            Button(pantryText("Start dictation"), action: start)
                .accessibilityIdentifier("pantry.voice.start")
        }
        Button(pantryText("Cancel"), action: cancel).accessibilityIdentifier("pantry.voice.cancel")
    }
}
