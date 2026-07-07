import Foundation

/// Metadata block prepended to chat sends so agents understand priority and intent.
public enum DelegationContext {
    public static let header = "DELEGATION CONTEXT"
    public static let messageSeparator = "\n\n---\n"

    public static let systemInstruction = """
    DELEGATION CONTEXT RULE: When the user's message includes a DELEGATION CONTEXT block, treat every field in it as authoritative metadata about their intent, priority, effort budget, energy level, success pattern, lift category, flag urgency, due date, and nudge time. Weight your answer accordingly — higher priority and flagged items deserve tighter focus and clearer next steps.
    """

    public static func containsContext(in prompt: String) -> Bool {
        prompt.contains(header)
    }

    public static func parsePrompt(_ prompt: String) -> (contextLines: [String], message: String) {
        guard prompt.hasPrefix(header) else {
            return ([], prompt)
        }
        let chunks = prompt.components(separatedBy: messageSeparator)
        guard chunks.count >= 2 else {
            return ([], prompt)
        }
        let contextBody = chunks[0]
            .replacingOccurrences(of: header, with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = contextBody
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let message = chunks.dropFirst().joined(separator: messageSeparator)
        return (lines, message)
    }
}