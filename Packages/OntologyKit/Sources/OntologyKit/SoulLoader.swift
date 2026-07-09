import Foundation

public struct SoulDocument: Codable, Sendable, Equatable {
    public let path: String
    public let text: String

    public init(path: String, text: String) {
        self.path = path
        self.text = text
    }

    public var wordCount: Int {
        text.split { $0.isWhitespace || $0.isNewline }.count
    }
}

public enum SoulLoader {
    /// High enough that the full vault SOUL.md never truncates — the soul is
    /// slot #1 of the stable prompt tier and must arrive whole.
    public static let maxCharacters = 32_000

    public static func load(
        homeDirectory: URL = URL(fileURLWithPath: NSHomeDirectory()),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> SoulDocument? {
        for candidate in candidateURLs(homeDirectory: homeDirectory, environment: environment) {
            guard let text = try? String(contentsOf: candidate, encoding: .utf8) else { continue }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            return SoulDocument(path: candidate.path, text: trimmedCharacterLimited(trimmed))
        }
        return nil
    }

    public static func candidateURLs(
        homeDirectory: URL,
        environment: [String: String]
    ) -> [URL] {
        var urls: [URL] = []
        if let override = environment["HARNESS_SOUL_PATH"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            urls.append(URL(fileURLWithPath: (override as NSString).expandingTildeInPath))
        }

        urls.append(contentsOf: [
            homeDirectory.appendingPathComponent("Documents/Main/Memory/SOUL.md"),
            homeDirectory.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/Documents/Main/Memory/SOUL.md"),
            homeDirectory.appendingPathComponent("Developer/GitHub/Harness/Docs/SOUL.md"),
            homeDirectory.appendingPathComponent(".hermes/SOUL.md"),
        ])
        return urls
    }

    private static func trimmedCharacterLimited(_ text: String) -> String {
        guard text.count > maxCharacters else { return text }
        let prefix = String(text.prefix(maxCharacters))
        return prefix + "\n\n[SOUL.md truncated to \(maxCharacters) characters for context budget.]"
    }
}

public struct ConversationTurn: Identifiable, Codable, Sendable, Equatable {
    public let id: String
    public let role: MessageRole
    public let text: String

    public init(id: String = UUID().uuidString, role: MessageRole, text: String) {
        self.id = id
        self.role = role
        self.text = text
    }

    public static func cappedHistory(_ turns: [ConversationTurn], maxTurns: Int = 24) -> [ConversationTurn] {
        guard turns.count > maxTurns else { return turns }
        return Array(turns.suffix(maxTurns))
    }
}