import Foundation

public protocol SupportingMemoryRetrieving: Sendable {
    func retrieve(prompt: String, limit: Int) async throws -> [MemoryHit]
}

public struct DirectoryMemoryRetriever: SupportingMemoryRetrieving {
    public let roots: [URL]
    public let allowedExtensions: Set<String>
    public let maxFiles: Int

    public init(
        roots: [URL] = DirectoryMemoryRetriever.defaultRoots(),
        allowedExtensions: Set<String> = ["md", "txt", "ttl"],
        maxFiles: Int = 300
    ) {
        self.roots = roots
        self.allowedExtensions = allowedExtensions
        self.maxFiles = maxFiles
    }

    public func retrieve(prompt: String, limit: Int = 5) async throws -> [MemoryHit] {
        let queryTokens = OntologyAuthorityRetriever.tokens(prompt)
        guard !queryTokens.isEmpty else { return [] }

        var hits: [(MemoryHit, Double)] = []
        let files = Self.files(in: roots, allowedExtensions: allowedExtensions, maxFiles: maxFiles)

        for file in files {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let score = Self.score(queryTokens, text: text)
            guard score > 0 else { continue }
            hits.append((
                MemoryHit(
                    source: file.path,
                    excerpt: Self.excerpt(from: text, matching: queryTokens),
                    score: score,
                    reasonSelected: "supporting-memory token overlap",
                    authorityLevel: .supporting
                ),
                score
            ))
        }

        return hits
            .sorted { lhs, rhs in
                if lhs.1 == rhs.1 { return lhs.0.source < rhs.0.source }
                return lhs.1 > rhs.1
            }
            .prefix(limit)
            .map(\.0)
    }

    public static func defaultRoots() -> [URL] {
        [
            URL(fileURLWithPath: "\(NSHomeDirectory())/Developer/GitHub/obsidian-vault"),
            URL(fileURLWithPath: "\(NSHomeDirectory())/Developer/GitHub/Harness/Docs")
        ]
    }

    private static func score(_ queryTokens: Set<String>, text: String) -> Double {
        let target = OntologyAuthorityRetriever.tokens(text)
        guard !target.isEmpty else { return 0 }
        let overlap = queryTokens.intersection(target).count
        guard overlap > 0 else { return 0 }
        return Double(overlap) / Double(max(queryTokens.count, 1))
    }

    private static func files(in roots: [URL], allowedExtensions: Set<String>, maxFiles: Int) -> [URL] {
        var files: [URL] = []
        for root in roots {
            guard files.count < maxFiles else { break }
            guard FileManager.default.fileExists(atPath: root.path) else { continue }
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }

            for case let file as URL in enumerator {
                guard files.count < maxFiles else { break }
                guard allowedExtensions.contains(file.pathExtension.lowercased()) else { continue }
                files.append(file)
            }
        }
        return files
    }

    private static func excerpt(from text: String, matching tokens: Set<String>) -> String {
        let lines = text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
        let selected = lines.first { line in
            let lineTokens = OntologyAuthorityRetriever.tokens(line)
            return !tokens.intersection(lineTokens).isEmpty
        } ?? lines.first ?? ""
        let trimmed = selected.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 360 else { return trimmed }
        return String(trimmed.prefix(357)) + "..."
    }
}

public protocol CandidateMemoryExtracting: Sendable {
    func candidates(prompt: String, response: String, runId: String, redactor: SecretRedacting) -> [MemoryCandidate]
}

public struct HeuristicCandidateMemoryExtractor: CandidateMemoryExtracting {
    public init() {}

    public func candidates(prompt: String, response: String, runId: String, redactor: SecretRedacting) -> [MemoryCandidate] {
        let lower = prompt.lowercased()
        let triggers = ["remember", "i prefer", "i always", "my rule", "from now on"]
        guard triggers.contains(where: lower.contains) else { return [] }
        let evidence = redactor.redact(prompt)
        return [
            MemoryCandidate(
                runId: runId,
                sourceRunIds: [runId],
                evidenceText: evidence,
                proposedClaim: evidence,
                proposedGraph: nil,
                status: .suggested,
                validationResult: "Not validated. Candidate is not accepted graph authority."
            )
        ]
    }
}

public protocol SecretRedacting: Sendable {
    func redact(_ text: String) -> String
}

public struct SecretRedactor: SecretRedacting {
    public init() {}

    public func redact(_ text: String) -> String {
        var redacted = text
        let patterns = [
            #"sk-ant-[A-Za-z0-9_\-]+"#,
            #"sk-[A-Za-z0-9_\-]{12,}"#,
            #"xox[baprs]-[A-Za-z0-9\-]+"#,
            #"AKIA[0-9A-Z]{16}"#,
            #"(?i)(api[_-]?key|token|secret)\s*[:=]\s*[^\s]+"#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(redacted.startIndex..., in: redacted)
            redacted = regex.stringByReplacingMatches(
                in: redacted,
                options: [],
                range: range,
                withTemplate: "[REDACTED_SECRET]"
            )
        }
        return redacted
    }
}
