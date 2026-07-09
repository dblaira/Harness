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
    /// 0...1, driven by the synthesizer's own per-word callback -- real
    /// progress through the spoken text, not a timer guess. Resets to 0
    /// when playback ends or is cancelled.
    @Published private(set) var progress: Double = 0

    private let synthesizer = AVSpeechSynthesizer()
    private var utteranceLength = 0

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
        utteranceLength = trimmed.utf16.count
        progress = 0
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

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString characterRange: NSRange, utterance: AVSpeechUtterance) {
        Task { @MainActor in
            guard self.utteranceLength > 0 else { return }
            self.progress = min(1, Double(characterRange.location + characterRange.length) / Double(self.utteranceLength))
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.isSpeaking = false
            self.progress = 0
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.isSpeaking = false
            self.progress = 0
        }
    }
}
#endif
