import Foundation

public protocol SupportingMemoryRetrieving: Sendable {
    func retrieve(prompt: String, limit: Int) async throws -> [MemoryHit]
}

public struct DirectoryMemoryRetriever: SupportingMemoryRetrieving {
    public let sources: [LocalMemorySource]
    public let roots: [URL]
    public let allowedExtensions: Set<String>
    public let maxFiles: Int
    public let excludedPathComponents: Set<String>
    public let preferredPathComponents: Set<String>

    public init() {
        self.init(sources: LocalMemorySourceRegistry.defaultSources())
    }

    public init(
        roots: [URL],
        allowedExtensions: Set<String> = DirectoryMemoryRetriever.defaultAllowedExtensions(),
        maxFiles: Int = 300,
        excludedPathComponents: Set<String> = DirectoryMemoryRetriever.defaultExcludedPathComponents(),
        preferredPathComponents: Set<String> = DirectoryMemoryRetriever.defaultPreferredPathComponents()
    ) {
        self.sources = roots.map {
            LocalMemorySource(
                title: $0.lastPathComponent.isEmpty ? $0.path : $0.lastPathComponent,
                kind: .custom,
                root: $0,
                weight: 1,
                allowedExtensions: allowedExtensions
            )
        }
        self.roots = roots
        self.allowedExtensions = allowedExtensions
        self.maxFiles = maxFiles
        self.excludedPathComponents = excludedPathComponents
        self.preferredPathComponents = preferredPathComponents
    }

    public init(
        sources: [LocalMemorySource],
        allowedExtensions: Set<String> = DirectoryMemoryRetriever.defaultAllowedExtensions(),
        maxFiles: Int = 1_500,
        excludedPathComponents: Set<String> = DirectoryMemoryRetriever.defaultExcludedPathComponents(),
        preferredPathComponents: Set<String> = DirectoryMemoryRetriever.defaultPreferredPathComponents()
    ) {
        self.sources = sources
        self.roots = sources.map(\.root)
        self.allowedExtensions = allowedExtensions
        self.maxFiles = maxFiles
        self.excludedPathComponents = excludedPathComponents
        self.preferredPathComponents = preferredPathComponents
    }

    public func retrieve(prompt: String, limit: Int = 5) async throws -> [MemoryHit] {
        let queryTokens = OntologyAuthorityRetriever.tokens(prompt)
        guard !queryTokens.isEmpty else { return [] }

        var hits: [(MemoryHit, Double)] = []
        let files = Self.files(
            in: sources,
            allowedExtensions: allowedExtensions,
            excludedPathComponents: excludedPathComponents,
            maxFiles: maxFiles
        )

        for (file, source) in files {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let classification = Self.classify(file: file, source: source, preferredPathComponents: preferredPathComponents)
            let score = Self.score(queryTokens, text: text, classification: classification)
            guard score > 0 else { continue }
            hits.append((
                MemoryHit(
                    source: file.path,
                    excerpt: Self.excerpt(from: text, matching: queryTokens),
                    score: score,
                    reasonSelected: "supporting-memory \(classification.reason) token overlap",
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
        LocalMemorySourceRegistry.defaultSources().map(\.root)
    }

    public static func defaultAllowedExtensions() -> Set<String> {
        LocalMemorySourceRegistry.codeAndTextExtensions()
    }

    public static func defaultExcludedPathComponents() -> Set<String> {
        [
            ".build",
            ".cache",
            ".git",
            ".local-artifacts",
            "build",
            "DerivedData",
            "Harness.xcodeproj",
            "ibooks",
            "node_modules"
        ]
    }

    public static func defaultPreferredPathComponents() -> Set<String> {
        [
            "Docs",
            "Harness",
            "Main",
            "Packages",
            "Sources",
            "Tests",
            "Understood",
            "obsidian-vault"
        ]
    }

    private static func score(_ queryTokens: Set<String>, text: String, classification: MemorySourceClassification) -> Double {
        let target = OntologyAuthorityRetriever.tokens(text)
        guard !target.isEmpty else { return 0 }
        let overlap = queryTokens.intersection(target).count
        guard overlap > 0 else { return 0 }
        let base = Double(overlap) / Double(max(queryTokens.count, 1))
        let density = Double(overlap) / Double(max(target.count, 1))
        return (base * classification.weight) + min(density, 0.2)
    }

    private static func files(
        in sources: [LocalMemorySource],
        allowedExtensions: Set<String>,
        excludedPathComponents: Set<String>,
        maxFiles: Int
    ) -> [(URL, LocalMemorySource)] {
        var files: [(URL, LocalMemorySource)] = []
        for source in sources {
            guard files.count < maxFiles else { break }
            let root = source.root
            let sourceExtensions = source.allowedExtensions ?? allowedExtensions
            guard FileManager.default.fileExists(atPath: root.path) else { continue }
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }

            for case let file as URL in enumerator {
                guard files.count < maxFiles else { break }
                if shouldSkip(file: file, excludedPathComponents: excludedPathComponents) {
                    enumerator.skipDescendants()
                    continue
                }
                guard sourceExtensions.contains(file.pathExtension.lowercased()) else { continue }
                files.append((file, source))
            }
        }
        return files
    }

    private static func shouldSkip(file: URL, excludedPathComponents: Set<String>) -> Bool {
        file.pathComponents.contains { component in
            component.hasPrefix(".") || excludedPathComponents.contains(component)
        }
    }

    private static func classify(
        file: URL,
        source: LocalMemorySource,
        preferredPathComponents: Set<String>
    ) -> MemorySourceClassification {
        if source.kind != .custom {
            return MemorySourceClassification(
                reason: "local-source \(source.kind.rawValue)",
                weight: source.weight
            )
        }

        let components = Set(file.pathComponents)
        if !components.intersection(preferredPathComponents).isEmpty {
            return MemorySourceClassification(reason: "project-context", weight: 1.25)
        }
        return MemorySourceClassification(reason: "local-note", weight: 0.72)
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

private struct MemorySourceClassification: Sendable {
    let reason: String
    let weight: Double
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
