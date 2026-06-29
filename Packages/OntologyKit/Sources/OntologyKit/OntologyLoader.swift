import Foundation

/// Parses the bundled Turtle (.ttl) files into typed Ontology models.
/// Lightweight, regex-based — enough for the well-formed personal graph files,
/// not a general RDF parser. Source of truth stays the .ttl; this just loads it.
public enum OntologyLoader {

    public static func load() -> Ontology {
        Ontology(
            connections: loadConnections(),
            axioms: loadAxioms(),
            pattern: adamPattern
        )
    }

    private static func ttl(_ name: String) -> String {
        guard let url = Bundle.module.url(forResource: name, withExtension: "ttl"),
              let s = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return s
    }

    // MARK: - Connections (adam-beliefs.ttl)

    static func loadConnections() -> [Connection] {
        let text = ttl("adam-beliefs")
        var out: [Connection] = []
        // Split into per-connection blocks ending in " ."
        let blocks = text.components(separatedBy: " .\n")
        for block in blocks {
            guard block.contains("understood:Connection") else { continue }
            guard let id = firstMatch(#"connection/(conn-\d+)"#, in: block) else { continue }
            let label = firstMatch(#"understood:label\s+"([^"]+)""#, in: block) ?? ""
            let type = firstMatch(#"understood:connectionType\s+"([^"]+)""#, in: block) ?? "connection"
            let domains = allMatches(#"domain/(\w+)"#, in: block)
            out.append(Connection(id: id, label: label, connectionType: type, lifeDomains: domains))
        }
        return out.sorted { $0.id < $1.id }
    }

    // MARK: - Axioms (adam-axioms.ttl)

    static func loadAxioms() -> [Axiom] {
        let text = ttl("adam-axioms")
        var out: [Axiom] = []
        let blocks = text.components(separatedBy: "a understood:Axiom")
        for block in blocks {
            guard let id = firstMatch(#"axiomId\s+"([^"]+)""#, in: block) else { continue }
            let ante = firstMatch(#"antecedentLabel\s+"([^"]+)""#, in: block) ?? ""
            let cons = firstMatch(#"consequentLabel\s+"([^"]+)""#, in: block) ?? ""
            let rel = firstMatch(#"relationshipType\s+"([^"]+)""#, in: block) ?? ""
            let conf = Double(firstMatch(#"confidence\s+"([0-9.]+)""#, in: block) ?? "0") ?? 0
            let ev = Int(firstMatch(#"evidenceCount\s+(\d+)"#, in: block) ?? "0") ?? 0
            let status = firstMatch(#"status\s+"([^"]+)""#, in: block) ?? ""
            out.append(Axiom(id: id, antecedent: ante, consequent: cons,
                             relationshipType: rel, confidence: conf,
                             evidenceCount: ev, status: status))
        }
        return out
    }

    // MARK: - Adam Pattern (static; mirrors adam_pattern.ttl)

    static let adamPattern: [PatternStep] = [
        .init(id: 1, title: "Context",            description: "Accept reality",                          zone: .observational),
        .init(id: 2, title: "Circle",             description: "Watch before moving",                     zone: .observational),
        .init(id: 3, title: "Close the Gap",      description: "Get expertise for the specific gap",      zone: .observational),
        .init(id: 4, title: "Choose Success",     description: "Set precise measurable targets",          zone: .observational),
        .init(id: 5, title: "Code the Pattern",   description: "Build a simple repeatable system",        zone: .execution),
        .init(id: 6, title: "Create Kill Switch", description: "Define the kill switch",                  zone: .execution),
        .init(id: 7, title: "Clear Sign of Success", description: "Look for the immediate signal",        zone: .execution),
        .init(id: 8, title: "Compound",           description: "Don't overwork the problem. Let it compound", zone: .execution),
    ]

    // MARK: - regex helpers

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let r = NSRange(text.startIndex..., in: text)
        guard let m = re.firstMatch(in: text, range: r), m.numberOfRanges > 1,
              let range = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    private static func allMatches(_ pattern: String, in text: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let r = NSRange(text.startIndex..., in: text)
        return re.matches(in: text, range: r).compactMap { m in
            guard m.numberOfRanges > 1, let range = Range(m.range(at: 1), in: text) else { return nil }
            return String(text[range])
        }
    }
}
