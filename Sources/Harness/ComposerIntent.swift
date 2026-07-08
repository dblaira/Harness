import Foundation
import OntologyKit

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
    var startDeferEnabled = false
    var startDeferDate = Date()
    var repeatRule = "Never"
    var nudgeEnabled = false
    var nudgeTime = Date()
    var endEnabled = false
    var endTime = Date()
    var tags: [String] = []

    var hasActiveSignals: Bool {
        pattern != "None"
            || priority != "None"
            || effort != "-"
            || energy != "-"
            || lift != "None"
            || isFlagged
            || dueEnabled
            || startDeferEnabled
            || repeatRule != "Never"
            || nudgeEnabled
            || endEnabled
            || !tags.isEmpty
    }

    func promptBlock() -> String? {
        let lines = contextLines()
        guard !lines.isEmpty else { return nil }
        return """
        \(DelegationContext.header)
        \(lines.joined(separator: "\n"))
        """
    }

    private func contextLines() -> [String] {
        var lines: [String] = []
        if priority != "None" { lines.append("Priority: \(priority)") }
        if effort != "-" { lines.append("Effort: \(effort)") }
        if energy != "-" { lines.append("Energy: \(energy)") }
        if pattern != "None" { lines.append("Pattern: \(pattern)") }
        if lift != "None" { lines.append("Lift: \(lift)") }
        if isFlagged { lines.append("Flagged: yes") }
        if dueEnabled { lines.append("Due: \(Self.shortDate(dueDate))") }
        if startDeferEnabled { lines.append("Start / defer: \(Self.shortDate(startDeferDate))") }
        if repeatRule != "Never" { lines.append("Repeat: \(repeatRule)") }
        if nudgeEnabled { lines.append("Nudge: \(Self.shortTime(nudgeTime))") }
        if endEnabled { lines.append("End: \(Self.shortTime(endTime))") }
        if !tags.isEmpty { lines.append("Tags: \(tags.joined(separator: ", "))") }
        return lines
    }

    /// WO-J: conn-004 "Delegation is three sentences" -- Intent is
    /// `userText` itself (the message body); PreferredApproach and
    /// DoneCondition join the DELEGATION CONTEXT block verbatim,
    /// alongside the existing signal lines. Matches AgentPolicy's
    /// "preserve Intent, PreferredApproach, and DoneCondition"
    /// directive (delegation-three-parts).
    static func composedPrompt(
        userText: String,
        attachments: [ComposerAttachment],
        intent: ComposerIntent,
        preferredApproach: String = "",
        doneCondition: String = ""
    ) -> String {
        let base = ComposerAttachment.composedPrompt(userText: userText, attachments: attachments)
        let lines = Self.delegationLines(preferredApproach: preferredApproach, doneCondition: doneCondition)
            + intent.contextLines()
        guard !lines.isEmpty else { return base }
        let context = """
        \(DelegationContext.header)
        \(lines.joined(separator: "\n"))
        """
        guard !base.isEmpty else { return context }
        return context + DelegationContext.messageSeparator + base
    }

    private static func delegationLines(preferredApproach: String, doneCondition: String) -> [String] {
        var lines: [String] = []
        let trimmedApproach = preferredApproach.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDone = doneCondition.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedApproach.isEmpty { lines.append("PreferredApproach: \(trimmedApproach)") }
        if !trimmedDone.isEmpty { lines.append("DoneCondition: \(trimmedDone)") }
        return lines
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

// MARK: - One-shot routine creation (Due / Nudge)

/// The Schedule signals are not just prompt annotations any more: a send
/// with a Due date or a Nudge time also registers a oneshot routine, so the
/// agent actually comes back to the work when the moment arrives.
extension ComposerIntent {
    /// The oneshot routine drafts this intent implies for a given send.
    /// Due schedules at the due date; a Nudge already in the past rolls
    /// forward to the next day at the same wall-clock time.
    func scheduledRoutineDrafts(userText: String, now: Date = Date()) -> [RoutineDraft] {
        ComposerRoutineDrafts.drafts(
            userText: userText,
            dueDate: dueEnabled ? dueDate : nil,
            nudgeTime: nudgeEnabled ? nudgeTime : nil,
            now: now
        )
    }

    /// Send-time hook: registers the implied oneshot routines with the
    /// running scheduler and returns a copy with the schedule signals
    /// consumed, so re-sending in the same session cannot double-register.
    /// Call this once per send, with the same prompt handed to the run —
    /// e.g. `composerIntent = composerIntent.registeringScheduledRoutines(userText: prompt)`.
    func registeringScheduledRoutines(
        userText: String,
        scheduler: RoutineScheduler? = RoutineScheduler.shared,
        now: Date = Date()
    ) -> ComposerIntent {
        guard dueEnabled || nudgeEnabled else { return self }
        guard let scheduler else { return self }
        for draft in scheduledRoutineDrafts(userText: userText, now: now) {
            scheduler.add(draft, now: now)
        }
        var consumed = self
        consumed.dueEnabled = false
        consumed.nudgeEnabled = false
        return consumed
    }
}