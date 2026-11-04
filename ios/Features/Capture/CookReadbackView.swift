import SwiftUI
import AVFoundation

/// The parent supplies the current cook projection and checks that its authority is still valid.
@MainActor struct CookReadbackView: View {
    let instruction: CookReadbackInstruction
    @StateObject private var model: CookReadbackModel
    @Environment(\.scenePhase) private var scenePhase

    init(instruction: CookReadbackInstruction, authorize: @escaping (CookReadbackInstruction, Date) -> Bool) {
        self.instruction = instruction
        _model = StateObject(wrappedValue: CookReadbackModel(instruction: instruction, speech: LocalCookSpeech(), authorize: authorize))
    }
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            VStack(alignment: .leading, spacing: 12) {
                if model.canRead {
                    Text(captureText("Current dated cook instruction")).font(.headline)
                    Text(model.instruction.createdAt.formatted(date: .abbreviated, time: .shortened))
                    Text(model.instruction.text).textSelection(.enabled)
                    if model.voiceOverActive {
                        Text(captureText("VoiceOver can read this instruction. Separate playback is stopped."))
                    }
                    if model.state == .speaking {
                        Button(captureText("Pause readback")) { model.pause() }
                    } else if model.state == .paused {
                        Button(captureText("Resume readback")) { model.resume() }.disabled(!model.canResume)
                    }
                    Button(captureText("Read from beginning")) { model.playFromBeginning() }
                        .disabled(!model.canStart).accessibilityIdentifier("capture.readback.play")
                    Button(captureText("Stop readback")) { model.stop() }.disabled(model.state == .stopped)
                    if model.state == .stopped && !model.voiceOverActive && !model.canStart {
                        Text(captureText("Prepare the instruction again to start a new readback."))
                    }
                    if model.unavailable { Text(captureText("A local voice is unavailable. The complete instruction remains readable.")) }
                } else {
                    Text(captureText("Prepare the current instruction without private budget details before playback."))
                }
            }
        }
        .onAppear { model.setVoiceOver(UIAccessibility.isVoiceOverRunning) }
        .onChange(of: instruction) { _, value in model.update(value) }
        .onChange(of: scenePhase) { _, phase in if phase != .active { model.stop() } }
        .onReceive(NotificationCenter.default.publisher(for: UIAccessibility.voiceOverStatusDidChangeNotification)) { _ in
            model.setVoiceOver(UIAccessibility.isVoiceOverRunning)
        }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)) { _ in model.stop() }
        .onDisappear { model.stop() }
    }
}
