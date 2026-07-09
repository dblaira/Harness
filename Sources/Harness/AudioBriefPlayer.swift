#if os(macOS)
import Foundation
import AVFoundation

/// WO-P: audio over EXISTING text briefs -- this speaks whatever text
/// is already displayed (a run's final answer), it never generates new
/// wording of its own. Injected via .environmentObject at the same
/// seam as RoutineScheduler (HarnessApp.swift), so any screen can play
/// a brief the same way any screen can see scheduler state.
@MainActor
final class AudioBriefPlayer: NSObject, ObservableObject {
    @Published private(set) var isSpeaking = false

    private let synthesizer = AVSpeechSynthesizer()

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        let utterance = AVSpeechUtterance(string: trimmed)
        if let languageCode = AVSpeechSynthesisVoice.currentLanguageCode() as String?,
           let voice = AVSpeechSynthesisVoice(language: languageCode) {
            utterance.voice = voice
        }
        synthesizer.speak(utterance)
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
    }
}

extension AudioBriefPlayer: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        Task { @MainActor in self.isSpeaking = true }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.isSpeaking = false }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.isSpeaking = false }
    }
}
#endif
