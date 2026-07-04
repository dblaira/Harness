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
            let classification = Self.classify(
                file: file,
                text: text,
                source: source,
                preferredPathComponents: preferredPathComponents
            )
            let sourceCard = Self.sourceCard(file: file, text: text, source: source)
            let score = Self.score(queryTokens, text: text, classification: classification)
            guard score > 0 else { continue }
            var reasonParts = ["supporting-memory", classification.reason]
            if let sourceCard {
                reasonParts.append("frontmatter type \(sourceCard.type)")
                if let declaredTrustLevel = sourceCard.declaredTrustLevel,
                   sourceCard.trustNote != nil {
                    reasonParts.append("self-declared trust_level \(declaredTrustLevel) ignored")
                }
            }
            reasonParts.append("token overlap")
            hits.append((
                MemoryHit(
                    source: file.path,
                    excerpt: Self.excerpt(from: text, matching: queryTokens),
                    score: score,
                    reasonSelected: reasonParts.joined(separator: " "),
                    authorityLevel: .supporting,
                    sourceCard: sourceCard
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
        text: String,
        source: LocalMemorySource,
        preferredPathComponents: Set<String>
    ) -> MemorySourceClassification {
        if source.kind == .notebookLM {
            return notebookLMClassification(text: text, source: source)
        }

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

    private static func notebookLMClassification(text: String, source: LocalMemorySource) -> MemorySourceClassification {
        let prefix = text.prefix(2_000).lowercased()
        if containsSourceClass("personal-data", in: prefix) || containsSourceClass("my-data", in: prefix) {
            return MemorySourceClassification(
                reason: "local-source notebooklm personal-data-label supporting-only",
                weight: source.weight * 1.18
            )
        }
        if containsSourceClass("direct-thought", in: prefix) || containsSourceClass("direct-thoughts", in: prefix) {
            return MemorySourceClassification(
                reason: "local-source notebooklm direct-thought-label supporting-only",
                weight: source.weight * 1.18
            )
        }
        return MemorySourceClassification(
            reason: "local-source notebooklm web-synthesis supporting-only",
            weight: source.weight * 0.92
        )
    }

    private static func containsSourceClass(_ value: String, in text: String) -> Bool {
        let labels = [
            "source-class: \(value)",
            "source_class: \(value)",
            "harness-source-class: \(value)",
            "notebooklm-source-class: \(value)"
        ]
        return labels.contains { text.contains($0) }
    }

    private static func sourceCard(file: URL, text: String, source: LocalMemorySource) -> SourceCard? {
        let frontmatter = parseFrontmatter(text)
        guard let type = frontmatter["type"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !type.isEmpty else {
            return nil
        }

        let declaredTrustLevel = firstValue(
            in: frontmatter,
            keys: ["trust_level", "trust-level", "trustLevel"]
        )
        let normalizedDeclaredTrust = declaredTrustLevel.map(normalizeTrustLevel)
        let trustNote = normalizedDeclaredTrust == nil || normalizedDeclaredTrust == .supporting
            ? nil
            : "Self-declared trust_level \(declaredTrustLevel ?? "") ignored; connector ceiling is supporting."

        return SourceCard(
            source: file.path,
            connectorTitle: source.title,
            connectorKind: source.kind.rawValue,
            type: type,
            title: firstValue(in: frontmatter, keys: ["title", "name"]),
            description: firstValue(in: frontmatter, keys: ["description", "summary"]),
            tags: parseTags(firstValue(in: frontmatter, keys: ["tags", "tag"])),
            resource: firstValue(in: frontmatter, keys: ["resource", "source", "url"]),
            timestamp: firstValue(in: frontmatter, keys: ["timestamp", "created", "created_at", "date"]),
            declaredTrustLevel: declaredTrustLevel,
            authorityLevel: .supporting,
            trustNote: trustNote
        )
    }

    private static func parseFrontmatter(_ text: String) -> [String: String] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.first?.trimmingCharacters(in: .whitespacesAndNewlines) == "---" else {
            return [:]
        }

        var result: [String: String] = [:]
        for line in lines.dropFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed == "---" { break }
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            guard let separator = trimmed.firstIndex(of: ":") else { continue }
            let key = String(trimmed[..<separator])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let value = String(trimmed[trimmed.index(after: separator)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            guard !key.isEmpty, !value.isEmpty else { continue }
            result[key] = value
        }
        return result
    }

    private static func firstValue(in frontmatter: [String: String], keys: [String]) -> String? {
        keys.compactMap { frontmatter[$0] }.first
    }

    private static func parseTags(_ raw: String?) -> [String] {
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return []
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let listText = trimmed.hasPrefix("[") && trimmed.hasSuffix("]")
            ? String(trimmed.dropFirst().dropLast())
            : trimmed
        return listText
            .split(separator: ",")
            .map {
                String($0)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            }
            .filter { !$0.isEmpty }
    }

    private static func normalizeTrustLevel(_ raw: String) -> AuthorityLevel? {
        let normalized = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
        switch normalized {
        case "accepted", "authority", "accepted_authority", "graph_authority":
            return .accepted
        case "candidate", "candidate_memory":
            return .candidate
        case "supporting", "supporting_memory", "supporting_only":
            return .supporting
        default:
            return nil
        }
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
