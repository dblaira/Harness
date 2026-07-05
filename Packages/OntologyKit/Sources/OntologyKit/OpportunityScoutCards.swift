import Foundation

public struct OpportunityCardEnvelope: Codable, Sendable, Equatable {
    public var source: String
    public var type: String
    public var title: String?
    public var description: String?
    public var tags: [String]
    public var resource: String?
    public var timestamp: String?
    public var declaredTrustLevel: String?
    public var authorityLevel: AuthorityLevel
    public var trustNote: String?

    public init(
        source: String,
        type: String,
        title: String? = nil,
        description: String? = nil,
        tags: [String] = [],
        resource: String? = nil,
        timestamp: String? = nil,
        declaredTrustLevel: String? = nil,
        authorityLevel: AuthorityLevel = .supporting,
        trustNote: String? = nil
    ) {
        self.source = source
        self.type = type
        self.title = title
        self.description = description
        self.tags = tags
        self.resource = resource
        self.timestamp = timestamp
        self.declaredTrustLevel = declaredTrustLevel
        self.authorityLevel = authorityLevel
        self.trustNote = trustNote
    }
}

public enum OpportunityApp: String, Codable, Sendable, Equatable, CaseIterable {
    case newsCalm = "News Calm"
    case notoriousRecall = "Notorious Recall"
    case understood = "Understood"
    case savy = "SAVY"
}

public enum OpportunityEffort: String, Codable, Sendable, Equatable, CaseIterable {
    case fits = "in"
    case above = "above"
    case below = "below"
}

public struct OpportunityCard: Codable, Sendable, Equatable {
    public var envelope: OpportunityCardEnvelope
    public var oppID: String
    public var fit: Double?
    public var rulesHit: [String]
    public var app: OpportunityApp?
    public var rawApp: String?
    public var windowDays: Int?
    public var effort: OpportunityEffort?
    public var rawEffort: String?
    public var dollarOrder: String?
    public var attention: Int
    public var timesSeen: Int
    public var sources: Int
    public var scoutID: String?
    public var body: String

    public init(
        envelope: OpportunityCardEnvelope,
        oppID: String = "",
        fit: Double? = nil,
        rulesHit: [String] = [],
        app: OpportunityApp? = nil,
        rawApp: String? = nil,
        windowDays: Int? = nil,
        effort: OpportunityEffort? = nil,
        rawEffort: String? = nil,
        dollarOrder: String? = nil,
        attention: Int = 0,
        timesSeen: Int = 1,
        sources: Int = 0,
        scoutID: String? = nil,
        body: String = ""
    ) {
        self.envelope = envelope
        self.oppID = oppID
        self.fit = fit
        self.rulesHit = rulesHit
        self.app = app
        self.rawApp = rawApp
        self.windowDays = windowDays
        self.effort = effort
        self.rawEffort = rawEffort
        self.dollarOrder = dollarOrder
        self.attention = attention
        self.timesSeen = timesSeen
        self.sources = sources
        self.scoutID = scoutID
        self.body = body
    }

    public var priority: Double {
        guard let fit else { return 0 }
        guard let windowDays else { return fit * 50 }
        return fit * 100 / Double(windowDays + 1)
    }
}

public struct OpportunitySourceCard: Codable, Sendable, Equatable {
    public var envelope: OpportunityCardEnvelope
    public var retrievedBy: String
    public var contentHash: String
    public var linkedOpportunities: [String]
    public var body: String

    public init(
        envelope: OpportunityCardEnvelope,
        retrievedBy: String = "",
        contentHash: String = "",
        linkedOpportunities: [String] = [],
        body: String = ""
    ) {
        self.envelope = envelope
        self.retrievedBy = retrievedBy
        self.contentHash = contentHash
        self.linkedOpportunities = linkedOpportunities
        self.body = body
    }
}

public enum ParsedOpportunityCard: Sendable, Equatable {
    case opportunity(OpportunityCard)
    case sourceCard(OpportunitySourceCard)
    case unsupported(OpportunityCardEnvelope)

    public var opportunity: OpportunityCard? {
        guard case let .opportunity(card) = self else { return nil }
        return card
    }

    public var sourceCard: OpportunitySourceCard? {
        guard case let .sourceCard(card) = self else { return nil }
        return card
    }
}

public struct OpportunityCardValidation: Sendable, Equatable {
    public let passed: Bool
    public let reason: String

    public init(passed: Bool, reason: String) {
        self.passed = passed
        self.reason = reason
    }
}

public enum OpportunityCardParseError: Error, LocalizedError, Equatable {
    case missingFrontmatter
    case missingType

    public var errorDescription: String? {
        switch self {
        case .missingFrontmatter:
            return "Card frontmatter must start and end with ---."
        case .missingType:
            return "Card frontmatter must include type."
        }
    }
}

public struct OpportunityCardParser: Sendable {
    public init() {}

    public func parse(markdown: String, source: String) throws -> ParsedOpportunityCard {
        let parsed = try MarkdownFrontmatterParser.parse(markdown)
        guard let type = Self.firstValue(in: parsed.frontmatter, keys: ["type"]),
              !type.isEmpty else {
            throw OpportunityCardParseError.missingType
        }
        let envelope = Self.envelope(
            source: source,
            type: type,
            frontmatter: parsed.frontmatter
        )

        switch type {
        case "opportunity", "delegation":
            return .opportunity(Self.opportunity(envelope: envelope, frontmatter: parsed.frontmatter, body: parsed.body))
        case "source_card":
            return .sourceCard(Self.sourceCard(envelope: envelope, frontmatter: parsed.frontmatter, body: parsed.body))
        default:
            return .unsupported(envelope)
        }
    }

    private static func envelope(
        source: String,
        type: String,
        frontmatter: [String: String]
    ) -> OpportunityCardEnvelope {
        let declaredTrustLevel = firstValue(
            in: frontmatter,
            keys: ["trust_level", "trust-level", "trustLevel"]
        )
        let normalizedDeclaredTrust = declaredTrustLevel.map(normalizeTrustLevel)
        let trustNote = normalizedDeclaredTrust == nil || normalizedDeclaredTrust == .supporting
            ? nil
            : "Self-declared trust_level \(declaredTrustLevel ?? "") ignored; connector ceiling is supporting."

        return OpportunityCardEnvelope(
            source: source,
            type: type,
            title: firstValue(in: frontmatter, keys: ["title", "name"]),
            description: firstValue(in: frontmatter, keys: ["description", "summary"]),
            tags: parseList(firstValue(in: frontmatter, keys: ["tags", "tag"])),
            resource: firstValue(in: frontmatter, keys: ["resource", "source", "url"]),
            timestamp: firstValue(in: frontmatter, keys: ["timestamp", "created", "created_at", "date"]),
            declaredTrustLevel: declaredTrustLevel,
            authorityLevel: .supporting,
            trustNote: trustNote
        )
    }

    private static func opportunity(
        envelope: OpportunityCardEnvelope,
        frontmatter: [String: String],
        body: String
    ) -> OpportunityCard {
        let rawApp = firstValue(in: frontmatter, keys: ["app"])
        let rawEffort = firstValue(in: frontmatter, keys: ["effort"])
        return OpportunityCard(
            envelope: envelope,
            oppID: firstValue(in: frontmatter, keys: ["opp_id", "opp-id", "oppID"]) ?? "",
            fit: parseDouble(firstValue(in: frontmatter, keys: ["fit"])),
            rulesHit: parseList(firstValue(in: frontmatter, keys: ["rules_hit", "rules-hit", "rulesHit"])),
            app: rawApp.flatMap(parseApp),
            rawApp: rawApp,
            windowDays: parseInt(firstValue(in: frontmatter, keys: ["window_days", "window-days", "windowDays"])),
            effort: rawEffort.flatMap(parseEffort),
            rawEffort: rawEffort,
            dollarOrder: firstValue(in: frontmatter, keys: ["dollar_order", "$ order", "order", "dollarOrder"]),
            attention: parseInt(firstValue(in: frontmatter, keys: ["attention"])) ?? 0,
            timesSeen: parseInt(firstValue(in: frontmatter, keys: ["times_seen", "times-seen", "timesSeen"])) ?? 1,
            sources: parseInt(firstValue(in: frontmatter, keys: ["sources"])) ?? 0,
            scoutID: firstValue(in: frontmatter, keys: ["scout_id", "scout-id", "scoutID", "scout"]),
            body: body.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private static func sourceCard(
        envelope: OpportunityCardEnvelope,
        frontmatter: [String: String],
        body: String
    ) -> OpportunitySourceCard {
        OpportunitySourceCard(
            envelope: envelope,
            retrievedBy: firstValue(in: frontmatter, keys: ["retrieved_by", "retrieved-by", "retrievedBy"]) ?? "",
            contentHash: firstValue(in: frontmatter, keys: ["content_hash", "content-hash", "contentHash"]) ?? "",
            linkedOpportunities: parseList(firstValue(
                in: frontmatter,
                keys: ["linked_opportunities", "linked-opportunities", "linkedOpportunities"]
            )),
            body: body.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    static func firstValue(in frontmatter: [String: String], keys: [String]) -> String? {
        keys.compactMap { frontmatter[$0] }.first
    }

    static func parseList(_ raw: String?) -> [String] {
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

    private static func parseApp(_ raw: String) -> OpportunityApp? {
        let normalized = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
        switch normalized {
        case "news calm", "boring news":
            return .newsCalm
        case "notorious recall":
            return .notoriousRecall
        case "understood":
            return .understood
        case "savy", "savvy":
            return .savy
        default:
            return OpportunityApp.allCases.first { $0.rawValue.lowercased() == normalized }
        }
    }

    private static func parseEffort(_ raw: String) -> OpportunityEffort? {
        OpportunityEffort.allCases.first { $0.rawValue.lowercased() == raw.lowercased() }
    }

    private static func parseDouble(_ raw: String?) -> Double? {
        guard let raw else { return nil }
        return Double(raw.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func parseInt(_ raw: String?) -> Int? {
        guard let raw else { return nil }
        if let integer = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return integer
        }
        guard let double = Double(raw.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }
        return Int(double)
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
}

public struct OpportunityCardValidator: Sendable {
    public init() {}

    public func validate(_ opportunity: OpportunityCard) -> OpportunityCardValidation {
        var reasons: [String] = []
        if opportunity.envelope.resource?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            reasons.append("resource must be present.")
        }
        if opportunity.rulesHit.isEmpty {
            reasons.append("rules_hit must include at least one accepted rule ID.")
        }
        if opportunity.fit == nil || opportunity.fit! < 0 || opportunity.fit! > 1 {
            reasons.append("fit must be between 0 and 1.")
        }
        if opportunity.app == nil {
            reasons.append("app must be News Calm, Notorious Recall, Understood, or SAVY.")
        }
        if opportunity.sources < 1 {
            reasons.append("sources must be at least 1.")
        }
        guard reasons.isEmpty else {
            return OpportunityCardValidation(passed: false, reason: reasons.joined(separator: " "))
        }
        return OpportunityCardValidation(passed: true, reason: "Delegation file passed typed validation.")
    }

    public func validate(_ sourceCard: OpportunitySourceCard) -> OpportunityCardValidation {
        var reasons: [String] = []
        if sourceCard.envelope.resource?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            reasons.append("resource must be present.")
        }
        if sourceCard.retrievedBy.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            reasons.append("retrieved_by must be present.")
        }
        if sourceCard.contentHash.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            reasons.append("content_hash must be present.")
        }
        guard reasons.isEmpty else {
            return OpportunityCardValidation(passed: false, reason: reasons.joined(separator: " "))
        }
        return OpportunityCardValidation(passed: true, reason: "Source file passed typed validation.")
    }
}

public struct OpportunityBoardRow: Identifiable, Codable, Sendable, Equatable {
    public var id: String { card.oppID.isEmpty ? canonicalResource : card.oppID }
    public var canonicalResource: String
    public var card: OpportunityCard
    public var history: [OpportunityCard]

    public init(canonicalResource: String, card: OpportunityCard, history: [OpportunityCard]) {
        self.canonicalResource = canonicalResource
        self.card = card
        self.history = history
    }
}

public enum OpportunityBoardViewMode: String, Codable, Sendable, Equatable, Hashable, CaseIterable, Identifiable {
    case all = "all"
    case byApp = "by_app"

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .all:
            return "All"
        case .byApp:
            return "By App"
        }
    }
}

public struct OpportunityBoardAppGroup: Identifiable, Codable, Sendable, Equatable {
    public var id: OpportunityApp { app }
    public var app: OpportunityApp
    public var rows: [OpportunityBoardRow]

    public init(app: OpportunityApp, rows: [OpportunityBoardRow]) {
        self.app = app
        self.rows = rows
    }
}

public struct OpportunityBoardProjection: Codable, Sendable, Equatable {
    public var rows: [OpportunityBoardRow]

    public init(rows: [OpportunityBoardRow]) {
        self.rows = Self.sortedByPriority(rows)
    }

    public func rows(for mode: OpportunityBoardViewMode) -> [OpportunityBoardRow] {
        switch mode {
        case .all:
            return rows
        case .byApp:
            return groupsByApp().flatMap(\.rows)
        }
    }

    public func groupsByApp() -> [OpportunityBoardAppGroup] {
        OpportunityApp.allCases.compactMap { app in
            let appRows = Self.sortedByPriority(rows.filter { $0.card.app == app })
            guard !appRows.isEmpty else { return nil }
            return OpportunityBoardAppGroup(app: app, rows: appRows)
        }
    }

    private static func sortedByPriority(_ rows: [OpportunityBoardRow]) -> [OpportunityBoardRow] {
        rows.sorted { lhs, rhs in
            if lhs.card.priority == rhs.card.priority {
                return lhs.id < rhs.id
            }
            return lhs.card.priority > rhs.card.priority
        }
    }

    private static func sortedByWindow(_ rows: [OpportunityBoardRow]) -> [OpportunityBoardRow] {
        rows.sorted { lhs, rhs in
            switch (lhs.card.windowDays, rhs.card.windowDays) {
            case let (lhsWindow?, rhsWindow?) where lhsWindow != rhsWindow:
                return lhsWindow < rhsWindow
            case (nil, _?):
                return false
            case (_?, nil):
                return true
            default:
                if lhs.card.priority == rhs.card.priority {
                    return lhs.id < rhs.id
                }
                return lhs.card.priority > rhs.card.priority
            }
        }
    }
}

public enum OpportunityBoardAction: String, Codable, Sendable, Equatable, Hashable, CaseIterable {
    case pass
    case hold
    case bookmark
    case pursue

    public var label: String {
        switch self {
        case .pass:
            return "Pass"
        case .hold:
            return "Hold"
        case .bookmark:
            return "Bookmark"
        case .pursue:
            return "Pursue"
        }
    }
}

public struct OpportunityBoardActionRecord: Identifiable, Codable, Sendable, Equatable {
    public var id: String
    public var batchID: String
    public var opportunityID: String
    public var canonicalResource: String
    public var action: OpportunityBoardAction
    public var createdAt: Date

    public init(
        id: String = UUID().uuidString,
        batchID: String,
        opportunityID: String,
        canonicalResource: String,
        action: OpportunityBoardAction,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.batchID = batchID
        self.opportunityID = opportunityID
        self.canonicalResource = canonicalResource
        self.action = action
        self.createdAt = createdAt
    }
}

public struct OpportunityBoardDeduper: Sendable {
    public init() {}

    public func deduplicate(_ cards: [OpportunityCard]) -> [OpportunityBoardRow] {
        var rows: [OpportunityBoardRow] = []
        var indexesByResource: [String: Int] = [:]

        for originalCard in cards {
            var card = originalCard
            let canonicalResource = Self.canonicalResource(card.envelope.resource)
            card.envelope.resource = canonicalResource
            guard !canonicalResource.isEmpty else { continue }

            if let index = indexesByResource[canonicalResource] {
                rows[index].history.append(card)
                rows[index].card.attention += card.attention
                rows[index].card.timesSeen += 1
                rows[index].card.sources = max(rows[index].card.sources, card.sources)
                rows[index].card.rulesHit = Self.union(rows[index].card.rulesHit, card.rulesHit)
                rows[index].card.envelope.timestamp = Self.newest(
                    rows[index].card.envelope.timestamp,
                    card.envelope.timestamp
                )
            } else {
                let row = OpportunityBoardRow(canonicalResource: canonicalResource, card: card, history: [card])
                indexesByResource[canonicalResource] = rows.count
                rows.append(row)
            }
        }

        return rows.sorted { lhs, rhs in
            if lhs.card.priority == rhs.card.priority {
                return lhs.canonicalResource < rhs.canonicalResource
            }
            return lhs.card.priority > rhs.card.priority
        }
    }

    public static func canonicalResource(_ raw: String?) -> String {
        guard let raw else { return "" }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        guard var components = URLComponents(string: trimmed) else {
            return trimmed.lowercased()
        }
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        components.query = nil
        components.fragment = nil
        var result = components.string ?? trimmed.lowercased()
        if result.hasSuffix("/") {
            result.removeLast()
        }
        return result
    }

    private static func union(_ lhs: [String], _ rhs: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for item in lhs + rhs where !seen.contains(item) {
            result.append(item)
            seen.insert(item)
        }
        return result
    }

    private static func newest(_ lhs: String?, _ rhs: String?) -> String? {
        guard let lhs, !lhs.isEmpty else { return rhs }
        guard let rhs, !rhs.isEmpty else { return lhs }
        return max(lhs, rhs)
    }
}

private struct MarkdownFrontmatterParser {
    let frontmatter: [String: String]
    let body: String

    static func parse(_ markdown: String) throws -> MarkdownFrontmatterParser {
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.first?.trimmingCharacters(in: .whitespacesAndNewlines) == "---" else {
            throw OpportunityCardParseError.missingFrontmatter
        }

        var frontmatter: [String: String] = [:]
        var bodyStartIndex: Int?
        for (offset, line) in lines.dropFirst().enumerated() {
            let lineIndex = offset + 1
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed == "---" {
                bodyStartIndex = lineIndex + 1
                break
            }
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            guard let separator = trimmed.firstIndex(of: ":") else { continue }
            let key = String(trimmed[..<separator])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let value = stripInlineComment(String(trimmed[trimmed.index(after: separator)...]))
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            guard !key.isEmpty, !value.isEmpty else { continue }
            frontmatter[key] = value
        }

        guard let bodyStartIndex else {
            throw OpportunityCardParseError.missingFrontmatter
        }

        let body = lines.dropFirst(bodyStartIndex).joined(separator: "\n")
        return MarkdownFrontmatterParser(frontmatter: frontmatter, body: body)
    }

    private static func stripInlineComment(_ value: String) -> String {
        var bracketDepth = 0
        var quote: Character?
        var previous: Character?

        for index in value.indices {
            let character = value[index]
            if let activeQuote = quote {
                if character == activeQuote {
                    quote = nil
                }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == "[" {
                bracketDepth += 1
            } else if character == "]" {
                bracketDepth = max(0, bracketDepth - 1)
            } else if character == "#",
                      bracketDepth == 0,
                      previous?.isWhitespace == true {
                return String(value[..<index])
            }
            previous = character
        }

        return value
    }
}
