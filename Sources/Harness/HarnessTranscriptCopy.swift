import Foundation
import OntologyKit
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

enum HarnessTranscriptCopy {
    static func assistantAnswer(from detail: HarnessRunDetail) -> String {
        if let message = detail.messages.last(where: { $0.role == .assistant }) {
            return message.text
        }
        return detail.run.finalAnswer
    }

    static func fullTranscript(from detail: HarnessRunDetail) -> String {
        detail.messages.map { message in
            let label = message.role == .user ? "You" : "Harness"
            return "\(label):\n\(message.text)"
        }
        .joined(separator: "\n\n---\n\n")
    }

    static func statusCopyText(status: String) -> String? {
        let trimmed = status.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let routineStatuses: Set<String> = [
            "Trace saved",
            "Backend failed; trace saved",
            "Checking graph authority",
            "Route planned; approval-gated steps detected",
        ]
        guard !routineStatuses.contains(trimmed) else { return nil }
        return trimmed
    }
}

enum HarnessClipboard {
    static func copy(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #elseif os(iOS)
        UIPasteboard.general.string = text
        #endif
    }
}