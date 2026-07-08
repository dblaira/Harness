#if os(macOS)
import Foundation
import SwiftUI
import Speech
import AVFoundation

/// WO-K: voice is additive, never a blocker. Typing keeps working
/// exactly as before; this only gives a second way to fill the same
/// three composer fields. The transcript is appended raw, character
/// for character -- no cleanup, no paraphrase.
enum ComposerVoiceField: Hashable {
    case intent
    case preferredApproach
    case doneCondition
}

@MainActor
final class VoiceDictationController: ObservableObject {
    @Published private(set) var activeField: ComposerVoiceField?
    @Published var lastError: String?

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var baseText = ""
    private var liveTranscript = ""
    private var onAppend: ((String) -> Void)?

    func isListening(for field: ComposerVoiceField) -> Bool {
        activeField == field
    }

    /// Tapping the mic on the field already listening stops it.
    /// Tapping a different field's mic stops the first and starts the
    /// new one -- only one AVAudioEngine tap can own the microphone.
    func toggle(field: ComposerVoiceField, currentText: String, onAppend: @escaping (String) -> Void) {
        if activeField == field {
            stop()
            return
        }
        if activeField != nil {
            stop()
        }
        start(field: field, currentText: currentText, onAppend: onAppend)
    }

    private func start(field: ComposerVoiceField, currentText: String, onAppend: @escaping (String) -> Void) {
        guard let recognizer, recognizer.isAvailable else {
            lastError = "Speech recognition unavailable."
            return
        }
        self.onAppend = onAppend
        self.baseText = currentText
        self.liveTranscript = ""

        SFSpeechRecognizer.requestAuthorization { [weak self] authStatus in
            DispatchQueue.main.async {
                guard let self else { return }
                guard authStatus == .authorized else {
                    self.lastError = "Speech recognition not authorized."
                    return
                }
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    DispatchQueue.main.async {
                        guard granted else {
                            self.lastError = "Microphone access not authorized."
                            return
                        }
                        self.beginCapture(field: field, recognizer: recognizer)
                    }
                }
            }
        }
    }

    private func beginCapture(field: ComposerVoiceField, recognizer: SFSpeechRecognizer) {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        self.request = request

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            lastError = "Microphone start failed: \(error.localizedDescription)"
            request.endAudio()
            self.request = nil
            return
        }

        activeField = field
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            Task { @MainActor in
                if let result {
                    // The raw transcript, untouched -- SFSpeechRecognizer's
                    // own hypothesis for the utterance so far, verbatim.
                    self.liveTranscript = result.bestTranscription.formattedString
                    self.onAppend?(self.composedText)
                }
                if error != nil || (result?.isFinal ?? false) {
                    self.stop()
                }
            }
        }
    }

    private var composedText: String {
        let trimmedBase = baseText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedBase.isEmpty { return liveTranscript }
        if liveTranscript.isEmpty { return baseText }
        return baseText + " " + liveTranscript
    }

    func stop() {
        guard activeField != nil else { return }
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
        onAppend = nil
        activeField = nil
    }
}

struct VoiceDictationButton: View {
    @ObservedObject var controller: VoiceDictationController
    let field: ComposerVoiceField
    let currentText: () -> String
    let onAppend: (String) -> Void

    var body: some View {
        Button {
            controller.toggle(field: field, currentText: currentText(), onAppend: onAppend)
        } label: {
            Image(systemName: controller.isListening(for: field) ? "mic.fill" : "mic")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(controller.isListening(for: field) ? Theme.savyCrimson : Theme.macInk.opacity(0.4))
        }
        .buttonStyle(.plain)
        .help(controller.isListening(for: field) ? "Stop dictation" : "Dictate this field")
    }
}
#endif
