import Foundation

/// Signals attached to a chat send so agents understand importance and intent.
struct ComposerIntent: Equatable, Sendable {
    var pattern = "None"
    var priority = "None"
    var effort = "-"
    var energy = "-"
    var lift = "None"
    var isFlagged = false
    var dueEnabled = false
    var dueDate = Date()
    var nudgeEnabled = false
    var nudgeTime = Date()

    var hasActiveSignals: Bool {
        pattern != "None"
            || priority != "None"
            || effort != "-"
            || energy != "-"
            || lift != "None"
            || isFlagged
            || dueEnabled
            || nudgeEnabled
    }

    func promptBlock() -> String? {
        var lines: [String] = []
        if priority != "None" { lines.append("Priority: \(priority)") }
        if effort != "-" { lines.append("Effort: \(effort)") }
        if energy != "-" { lines.append("Energy: \(energy)") }
        if pattern != "None" { lines.append("Pattern: \(pattern)") }
        if lift != "None" { lines.append("Lift: \(lift)") }
        if isFlagged { lines.append("Flagged: yes") }
        if dueEnabled { lines.append("Due: \(Self.shortDate(dueDate))") }
        if nudgeEnabled { lines.append("Nudge: \(Self.shortTime(nudgeTime))") }
        guard !lines.isEmpty else { return nil }
        return """
        DELEGATION CONTEXT
        \(lines.joined(separator: "\n"))
        """
    }

    static func composedPrompt(
        userText: String,
        attachments: [ComposerAttachment],
        intent: ComposerIntent
    ) -> String {
        let base = ComposerAttachment.composedPrompt(userText: userText, attachments: attachments)
        guard let context = intent.promptBlock() else { return base }
        guard !base.isEmpty else { return context }
        return context + "\n\n---\n" + base
    }

    private static let shortDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    private static let shortTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    private static func shortDate(_ date: Date) -> String {
        shortDateFormatter.string(from: date)
    }

    private static func shortTime(_ date: Date) -> String {
        shortTimeFormatter.string(from: date)
    }
}