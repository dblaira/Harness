import Foundation

/// Whole-file memory snapshot, Hermes-style: Adam's memory files are read in
/// place as shared truth (never copied, never paraphrased) and frozen once per
/// session so the system prompt stays byte-stable for prompt caching.
public struct MemorySnapshot: Codable, Sendable, Equatable {
    public struct Entry: Codable, Sendable, Equatable {
        public let path: String
        public let text: String

        public init(path: String, text: String) {
            self.path = path
            self.text = text
        }
    }

    public let entries: [Entry]

    public init(entries: [Entry]) {
        self.entries = entries
    }

    public var isEmpty: Bool { entries.isEmpty }

    /// Vault hub notes read whole alongside Hermes MEMORY.md.
    public static let vaultHubNoteNames: [String] = [
        "Response Rules.md",
        "Harness Vocabulary.md",
        "One Agent Relationship.md",
        "Memory Hub.md",
    ]

    /// Files read whole: ~/.hermes/memories/MEMORY.md first, then the vault
    /// Main/Memory hub notes. The first vault root that exists wins so the
    /// iCloud and local clones never double-inject.
    public static func candidateURLs(
        homeDirectory: URL,
        fileManager: FileManager = .default
    ) -> [URL] {
        var urls: [URL] = [
            homeDirectory.appendingPathComponent(".hermes/memories/MEMORY.md")
        ]
        let vaultRoots = [
            homeDirectory.appendingPathComponent("Documents/Main/Memory", isDirectory: true),
            homeDirectory.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/Documents/Main/Memory", isDirectory: true),
        ]
        if let vaultRoot = vaultRoots.first(where: { fileManager.fileExists(atPath: $0.path) }) {
            urls.append(contentsOf: vaultHubNoteNames.map { vaultRoot.appendingPathComponent($0) })
        }
        return urls
    }

    /// Reads every candidate file whole. Missing or empty files are skipped
    /// gracefully — a machine without the vault still gets a valid snapshot.
    public static func capture(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> MemorySnapshot {
        let entries = candidateURLs(homeDirectory: homeDirectory, fileManager: fileManager)
            .compactMap { url -> Entry? in
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return nil }
                return Entry(path: url.path, text: trimmed)
            }
        return MemorySnapshot(entries: entries)
    }

    /// Rendered block for the VOLATILE prompt tier. File contents are verbatim.
    public var promptBlock: String {
        guard !entries.isEmpty else { return "" }
        var block = "MEMORY SNAPSHOT (whole files, frozen at session start; supporting memory, never accepted graph authority):\n"
        for entry in entries {
            block += "\n--- \(entry.path) ---\n\(entry.text)\n"
        }
        return block
    }
}
