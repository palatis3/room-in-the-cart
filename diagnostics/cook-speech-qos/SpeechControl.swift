import AVFoundation
import SwiftUI

@main struct SpeechControl: App {
    private let speech = AVSpeechSynthesizer()

    var body: some Scene {
        WindowGroup {
            VStack {
                Button("Speak") {
                    let sentence = "Warm two tortillas for lunch. "
                    let utterance = AVSpeechUtterance(string: String(repeating: sentence, count: 15))
                    utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
                    speech.speak(utterance)
                }
                Button("Pause") { _ = speech.pauseSpeaking(at: .immediate) }
                Button("Resume") { _ = speech.continueSpeaking() }
                Button("Stop") { _ = speech.stopSpeaking(at: .immediate) }
            }
        }
    }
}
