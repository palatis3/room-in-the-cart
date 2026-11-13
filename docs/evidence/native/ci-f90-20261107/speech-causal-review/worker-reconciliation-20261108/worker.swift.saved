import SwiftUI
import AVFoundation
final class Voice: @unchecked Sendable {
    let queue = DispatchQueue(label: "speech.control", qos: .default)
    private lazy var synth = AVSpeechSynthesizer()
    func action(_ name: String) {
        queue.async {
            switch name {
            case "Speak":
                let utterance = AVSpeechUtterance(string: String(repeating: "Warm two tortillas for lunch. ", count: 15))
                utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
                self.synth.speak(utterance)
            case "Pause": _ = self.synth.pauseSpeaking(at: .immediate)
            case "Resume": _ = self.synth.continueSpeaking()
            default: _ = self.synth.stopSpeaking(at: .immediate)
            }
        }
    }
}
@main struct SpeechControl: App {
    let voice = Voice()
    var body: some Scene {
        WindowGroup {
            VStack {
                ForEach(["Speak", "Pause", "Resume", "Stop"], id: \.self) { name in
                    Button(name) { voice.action(name) }
                }
            }
        }
    }
}
