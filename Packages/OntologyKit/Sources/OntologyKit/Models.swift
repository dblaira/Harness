import Foundation

/// A confirmed personal connection/belief from adam-beliefs.ttl (conn-001…conn-019).
public struct Connection: Identifiable, Hashable, Sendable {
    public let id: String          // e.g. "conn-019"
    public let label: String       // the human-readable belief
    public let connectionType: String  // process_anchor | validated_principle | pattern_interrupt | identity_anchor | connection
    public let lifeDomains: [String]
}

/// A confirmed causal axiom from adam-axioms.ttl (antecedent → consequent).
public struct Axiom: Identifiable, Hashable, Sendable {
    public let id: String          // axiomId, e.g. "system-over-task"
    public let antecedent: String
    public let consequent: String
    public let relationshipType: String
    public let confidence: Double
    public let evidenceCount: Int
    public let status: String
}

/// One step of the 8-step Adam Pattern from adam_pattern.ttl.
public struct PatternStep: Identifiable, Hashable, Sendable {
    public let id: Int             // 1…8
    public let title: String
    public let description: String
    public let zone: Zone
    public enum Zone: String, Sendable { case observational, execution }
}

/// The deterministic constraint layer that governs every app in the suite.
/// Loaded from the bundled .ttl files — the same files Adam edits in his graph.
public struct Ontology: Sendable {
    public let connections: [Connection]
    public let axioms: [Axiom]
    public let pattern: [PatternStep]

    /// Lightweight startup value so UI can draw before bundled graph parsing finishes.
    public static let empty = Ontology(connections: [], axioms: [], pattern: OntologyLoader.adamPattern)

    /// Pattern-interrupt questions Adam wants surfaced during decisions.
    public var patternInterrupts: [Connection] {
        connections.filter { $0.connectionType == "pattern_interrupt" }
    }

    /// Find the closest confirmed connection to a free-text phrase (soft-match,
    /// not exact-match — covers Adam's "judgment strong, vocabulary gap" rule).
    public func match(_ text: String) -> Connection? {
        let q = text.lowercased()
        let words = Set(q.split(whereSeparator: { !$0.isLetter }).map(String.init).filter { $0.count > 3 })
        return connections
            .map { conn -> (Connection, Int) in
                let lw = Set(conn.label.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init))
                return (conn, words.intersection(lw).count)
            }
            .filter { $0.1 > 0 }
            .max { $0.1 < $1.1 }?.0
    }
}
