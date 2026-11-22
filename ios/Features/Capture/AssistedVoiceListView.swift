import AVFoundation
import HouseholdClient
import SwiftUI

@MainActor struct AssistedVoiceListView: View {
    let language: String
    let authorized: () -> Bool
    let stage: (String) -> Void
    @StateObject private var audio = VoiceListRecording()
    @EnvironmentObject private var access: WorkspaceAccess
    @EnvironmentObject private var household: HouseholdModel
    @Environment(\.scenePhase) private var scene
    @Environment(\.dismiss) private var dismiss
    @State private var basis: CapturePrivateIdentity?
    @State private var originalScope: ReceiptAssistanceScope?
    @State private var checked = false
    @State private var available = false
    @State private var sending = false
    @State private var failed = false
    @State private var request: VoiceTranscriptionRequest?
    @State private var attempts = 0
    @State private var transcript: String?
    @State private var operation: Task<Void,Never>?
    @State private var generation = UUID()

    private var identity: CapturePrivateIdentity? {
        guard authorized(), !household.guardianChildOnly, household.projection?.grantId == nil else { return nil }
        return CapturePrivateIdentity.current(access: access, household: household)
    }
    private var current: Bool { scene == .active && originalScope != nil && originalScope == scope && basis == identity }
    private var scope: ReceiptAssistanceScope? {
        guard let basis, let subject = basis.subject, let householdID = basis.householdID, let memberID = basis.memberID else { return nil }
        return .init(subject: subject, householdID: householdID, memberID: memberID, shopID: household.projection?.shopId)
    }

    var body: some View {
        NavigationStack {
            WorkingForm {
                if !checked { ProgressView() }
                else if !available || !current {
                    Text(captureText("Online transcription is unavailable. Return to your list to dictate on this iPhone or type."))
                } else {
                    Section {
                        Text(captureText("Record up to 30 seconds on this iPhone. You can listen, replace or discard the recording before sharing it."))
                        if audio.recording {
                            Button(captureText("Stop this recording")) { audio.stop() }
                        } else if audio.preparing { ProgressView() }
                        else if audio.clip == nil, transcript == nil {
                            Button(captureText("Record a new list on this iPhone")) {
                                operation = Task { await audio.start() }
                            }
                        }
                        if audio.failed || (failed && audio.clip == nil) { recordingError }
                    }
                    if let clip = audio.clip {
                        Section {
                            LabeledContent(captureText("Recording length"), value: Duration.seconds(clip.duration).formatted(.time(pattern: .minuteSecond)))
                                .monospacedDigit()
                            Button(captureText("Listen to this recording")) { audio.play() }.disabled(sending)
                            Button(captureText("Discard recording")) { clear() }.disabled(sending)
                        }
                        Section {
                            Text(captureText("OpenAI will receive this entire recording and the selected language through Room in the Cart."))
                                .font(.headline)
                            LabeledContent(captureText("Transcription language"), value: language == "es" ? captureText("Spanish") : captureText("English"))
                            Button(captureText("Send this recording to OpenAI for transcription")) { send(clip) }
                                .disabled(sending || attempts >= 2 || transcript != nil)
                            if sending { ProgressView() }
                            if failed { recordingError }
                        }
                    }
                    if let transcript {
                        Section(captureText("Review the online transcript")) {
                            Text(verbatim: transcript).textSelection(.enabled)
                            Button(captureText("Use this transcript in list review")) {
                                guard current else { return }
                                stage(transcript); clear(); dismiss()
                            }
                            .buttonStyle(PrimaryAction())
                        }
                    }
                }
            }
            .navigationTitle(captureText("Optional online transcription"))
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(captureText("Cancel")) { clear(); dismiss() } } }
            .privacySensitive()
        }
        .task {
            basis = identity
            originalScope = scope
            guard ["en","es"].contains(language), current, let scope, let service = household.service else { checked = true; return }
            let allowed = try? await service.voiceTranscriptionAvailable(scope: scope)
            if !Task.isCancelled, current, self.scope == scope { available = allowed == true }
            checked = true
        }
        .task(id: audio.clip != nil) {
            guard audio.clip != nil else { return }
            try? await Task.sleep(for: .seconds(300))
            if !Task.isCancelled, audio.clip != nil { clear() }
        }
        .onChange(of: identity) { _, next in if basis != nil && next != basis { clear(); dismiss() } }
        .onChange(of: scope) { _, newScope in if originalScope != nil && newScope != originalScope { clear(); dismiss() } }
        .onChange(of: scene) { _, next in if next == .background { clear(); dismiss() } }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)) { _ in
            if audio.recording || audio.preparing { clear(); failed = true }
        }
        .onDisappear { clear() }
    }
    private var recordingError: some View {
        Text(captureText("This recording could not be used. You can record again, dictate on this iPhone or type."))
            .foregroundStyle(Theme.error)
    }

    private func clear() {
        generation = UUID(); operation?.cancel(); operation = nil; audio.clear()
        request = nil; attempts = 0; sending = false; failed = false; transcript = nil
    }
    private func send(_ clip: VoiceListClip) {
        guard current, available, !sending, attempts < 2, transcript == nil, let scope, let service = household.service,
              let input = try? request ?? VoiceTranscriptionRequest(consentingTo: clip, language: language) else { return }
        request = input; attempts += 1; sending = true; failed = false
        audio.stopPlayback()
        let active = generation
        operation = Task {
            defer { if generation == active { sending = false; operation = nil } }
            do {
                let result = try await service.transcribeVoiceList(input, scope: scope)
                guard !Task.isCancelled, current, self.scope == scope, active == generation, request == input else { return }
                transcript = result.text
                request = nil
                audio.clear()
            } catch { if !Task.isCancelled && current && active == generation { failed = true } }
        }
    }
}
