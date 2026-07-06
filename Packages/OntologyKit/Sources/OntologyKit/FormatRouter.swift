import Foundation

/// Cognitive Fit routing (Vessey/Galletta; Samuel et al.):
/// match display component to query task type — not aesthetic preference.
/// Swift port of understood-app `lib/ai/format-intent-router.ts`, extended
/// with the fifth modality (graphic imagery) from the approved
/// format-selection matrix and Adam's volume-discipline law.
public enum PresentationFormatIntent: String, Codable, Sendable, Equatable {
    case overview
    case crossReference = "cross_reference"
    case systemFlow = "system_flow"
    case pureConceptual = "pure_conceptual"
    case macroTrend = "macro_trend"
}

public enum PrimaryDisplayComponent: String, Codable, Sendable, Equatable {
    case table
    case matrix
    case tree
    case editorial
    case graphic
}

public struct FormatRoute: Codable, Sendable, Equatable {
    public let intent: PresentationFormatIntent
    public let primary: PrimaryDisplayComponent
    public let researchNote: String
    public let promptBlock: String

    public init(intent: PresentationFormatIntent, primary: PrimaryDisplayComponent, researchNote: String, promptBlock: String) {
        self.intent = intent
        self.primary = primary
        self.researchNote = researchNote
        self.promptBlock = promptBlock
    }
}

public enum FormatRouter {
    static let crossRef = try! NSRegularExpression(
        pattern: "\\b(compare|contrast|versus|vs\\.?|intersect|correlation|matrix|cross.?ref|overlap|both .+ and)\\b",
        options: [.caseInsensitive]
    )
    static let systemFlow = try! NSRegularExpression(
        pattern: "\\b(how (does|do|it|this)|architecture|flow|pipeline|depend|connects?|wiring|stack|pathway|taxonomy|hierarchy|decision tree|system)\\b",
        options: [.caseInsensitive]
    )
    static let conceptual = try! NSRegularExpression(
        pattern: "\\b(why|meaning|should i|strategic|so what|interpret|recommend|worth it|big picture)\\b",
        options: [.caseInsensitive]
    )
    static let overview = try! NSRegularExpression(
        pattern: "\\b(what|who|when|where|which|list|find|show|recent|about|search|entries)\\b",
        options: [.caseInsensitive]
    )
    static let macroTrend = try! NSRegularExpression(
        pattern: "\\b(trend|over time|trajectory|distribution|cluster|anomal|proportion|ratio of|spike|drop)\\b",
        options: [.caseInsensitive]
    )

    static func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    public static func route(query: String) -> FormatRoute {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)

        if matches(crossRef, q) {
            return FormatRoute(
                intent: .crossReference,
                primary: .matrix,
                researchNote: "Multi-axis intersection — matrix (Samuel et al., 2022)",
                promptBlock: "FORMAT ROUTE: cross_reference → use a matrix (row labels × column labels × cells). No prose dump."
            )
        }
        if matches(systemFlow, q) {
            return FormatRoute(
                intent: .systemFlow,
                primary: .tree,
                researchNote: "Hierarchical/procedural logic — node tree (Mayer & Moreno, 2003)",
                promptBlock: "FORMAT ROUTE: system_flow → use a node tree (root + children, spatial indentation). No prose dump."
            )
        }
        if matches(macroTrend, q), !matches(overview, q) {
            return FormatRoute(
                intent: .macroTrend,
                primary: .graphic,
                researchNote: "Macro-trend / pattern recognition — graphic imagery (format-selection matrix, row 5)",
                promptBlock: "FORMAT ROUTE: macro_trend → use graphic/spatial representation (chart, sparkline, bars). Exact digits secondary."
            )
        }
        if matches(conceptual, q), !matches(overview, q) {
            return FormatRoute(
                intent: .pureConceptual,
                primary: .editorial,
                researchNote: "Interpretation — max 2-sentence lead, then structure if data exists",
                promptBlock: "FORMAT ROUTE: pure_conceptual → lead = punchline (max 2 sentences). Small table only if data supports it. No essay."
            )
        }
        return FormatRoute(
            intent: .overview,
            primary: .table,
            researchNote: "Categorical lookup — table (Slutsky/King)",
            promptBlock: "FORMAT ROUTE: overview → use a table (2–4 columns, ≤8 rows). No prose dump."
        )
    }

    // MARK: - Structure detection (for evals)

    public static func containsMarkdownTable(_ answer: String) -> Bool {
        let lines = answer.components(separatedBy: "\n")
        for (index, line) in lines.enumerated() where index + 1 < lines.count {
            let next = lines[index + 1]
            if line.contains("|"), next.contains("|"), next.contains("-") { return true }
        }
        return false
    }

    public static func containsTreeStructure(_ answer: String) -> Bool {
        let lines = answer.components(separatedBy: "\n")
        let indentedBullets = lines.filter { line in
            let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
            let indent = line.count - trimmed.count
            return indent >= 2 && (trimmed.hasPrefix("-") || trimmed.hasPrefix("*") || trimmed.hasPrefix("└") || trimmed.hasPrefix("├"))
        }
        return indentedBullets.count >= 2 || answer.contains("└") || answer.contains("├") || answer.contains("->") && lines.filter({ $0.contains("->") }).count >= 2
    }

    public static func hasAnyStructure(_ answer: String) -> Bool {
        containsMarkdownTable(answer)
            || containsTreeStructure(answer)
            || answer.components(separatedBy: "\n").filter({ $0.trimmingCharacters(in: .whitespaces).hasPrefix("-") || $0.trimmingCharacters(in: .whitespaces).hasPrefix("|") }).count >= 3
    }

    /// Adam's volume-discipline law: "Way too much explanation when a simple
    /// done is the best choice." Long unstructured prose is a waterfall.
    public static func volumeDiscipline(answer: String) -> (passed: Bool, detail: String) {
        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        let characterCount = trimmed.count
        if characterCount <= 700 {
            return (true, "Answer is \(characterCount) characters — within the short-answer band.")
        }
        if hasAnyStructure(trimmed) {
            return (true, "Answer is \(characterCount) characters with structural components carrying the load.")
        }
        return (false, "Waterfall: \(characterCount) characters of unstructured prose. Restructure (table/matrix/tree) or cut.")
    }

    /// Does the answer's dominant modality match the routed format?
    public static func formatFit(answer: String, route: FormatRoute) -> (passed: Bool, detail: String) {
        switch route.primary {
        case .table, .matrix:
            let has = containsMarkdownTable(answer)
            return (has, has
                ? "\(route.intent.rawValue) routed to \(route.primary.rawValue); tabular structure present."
                : "\(route.intent.rawValue) routed to \(route.primary.rawValue); no tabular structure found.")
        case .tree:
            let has = containsTreeStructure(answer)
            return (has, has
                ? "system_flow routed to tree; hierarchical structure present."
                : "system_flow routed to tree; no hierarchical structure found.")
        case .graphic:
            let has = hasAnyStructure(answer)
            return (has, has
                ? "macro_trend routed to graphic; structured representation present."
                : "macro_trend routed to graphic; unstructured prose only.")
        case .editorial:
            let sentences = answer
                .components(separatedBy: "\n\n").first?
                .components(separatedBy: CharacterSet(charactersIn: ".!?"))
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? []
            let passed = sentences.count <= 3
            return (passed, passed
                ? "pure_conceptual: lead paragraph is \(sentences.count) sentence(s)."
                : "pure_conceptual: lead paragraph runs \(sentences.count) sentences — punchline first, then structure.")
        }
    }
}
