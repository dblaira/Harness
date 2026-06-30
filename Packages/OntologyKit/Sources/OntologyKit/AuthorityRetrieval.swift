import Foundation

public protocol AuthorityRetrieving: Sendable {
    func retrieve(prompt: String, ontology: Ontology, limit: Int) async throws -> [GraphAuthorityHit]
}

public struct OntologyAuthorityRetriever: AuthorityRetrieving {
    public init() {}

    public func retrieve(prompt: String, ontology: Ontology, limit: Int = 6) async throws -> [GraphAuthorityHit] {
        let queryTokens = Self.tokens(prompt)
        guard !queryTokens.isEmpty else { return [] }

        var scored: [(GraphAuthorityHit, Double)] = []

        for connection in ontology.connections {
            let text = "\(connection.id) \(connection.label) \(connection.connectionType) \(connection.lifeDomains.joined(separator: " "))"
            let score = Self.score(queryTokens, in: text)
            guard score > 0 else { continue }
            scored.append((
                GraphAuthorityHit(
                    subject: "understood:connection/\(connection.id)",
                    predicate: "understood:label",
                    object: connection.label,
                    source: "accepted:adam-beliefs.ttl",
                    queryTrace: "local-authority-query kind=Connection tokens=\(Array(queryTokens).sorted().joined(separator: ","))",
                    authorityLevel: .accepted,
                    score: score
                ),
                score
            ))
        }

        for axiom in ontology.axioms {
            let text = "\(axiom.id) \(axiom.antecedent) \(axiom.consequent) \(axiom.relationshipType)"
            let score = Self.score(queryTokens, in: text)
            guard score > 0 else { continue }
            scored.append((
                GraphAuthorityHit(
                    subject: "understood:axiom/\(axiom.id)",
                    predicate: "understood:consequentLabel",
                    object: "\(axiom.antecedent) -> \(axiom.consequent)",
                    source: "accepted:adam-axioms.ttl",
                    queryTrace: "local-authority-query kind=Axiom tokens=\(Array(queryTokens).sorted().joined(separator: ",")) confidence=\(axiom.confidence)",
                    authorityLevel: .accepted,
                    score: score
                ),
                score
            ))
        }

        for step in ontology.pattern {
            let text = "\(step.id) \(step.title) \(step.description) \(step.zone.rawValue)"
            let score = Self.score(queryTokens, in: text)
            guard score > 0 else { continue }
            scored.append((
                GraphAuthorityHit(
                    subject: "understood:adam-pattern/step-\(step.id)",
                    predicate: "understood:description",
                    object: "\(step.title): \(step.description)",
                    source: "accepted:adam_pattern.ttl",
                    queryTrace: "local-authority-query kind=PatternStep tokens=\(Array(queryTokens).sorted().joined(separator: ","))",
                    authorityLevel: .accepted,
                    score: score
                ),
                score
            ))
        }

        return scored
            .sorted { lhs, rhs in
                if lhs.1 == rhs.1 { return lhs.0.subject < rhs.0.subject }
                return lhs.1 > rhs.1
            }
            .prefix(limit)
            .map(\.0)
    }

    static func tokens(_ text: String) -> Set<String> {
        let stop: Set<String> = [
            "about", "after", "again", "before", "being", "could", "first",
            "from", "have", "into", "should", "that", "their", "there",
            "these", "thing", "this", "with", "what", "when", "where", "which",
            "your", "youre", "would", "because"
        ]
        let raw = text
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
        return Set(raw.filter { $0.count > 2 && !stop.contains($0) })
    }

    static func score(_ queryTokens: Set<String>, in text: String) -> Double {
        let target = tokens(text)
        guard !target.isEmpty else { return 0 }
        let overlap = queryTokens.intersection(target).count
        guard overlap > 0 else { return 0 }
        return Double(overlap) / Double(max(queryTokens.count, 1))
    }
}

public enum PromptPacketBuilder {
    public static func makePacket(
        prompt: String,
        ontology: Ontology,
        authorityHits: [GraphAuthorityHit],
        memoryHits: [MemoryHit]
    ) -> ModelPacket {
        var system = ClaudeClient.systemPrompt(from: ontology)
        system += "\n\nACCEPTED GRAPH AUTHORITY RETRIEVED FIRST:\n"
        if authorityHits.isEmpty {
            system += "  none\n"
        } else {
            for hit in authorityHits {
                system += "  - \(hit.subject) \(hit.predicate) \(hit.object) [\(hit.source)]\n"
            }
        }
        system += "\nSUPPORTING MEMORY, NOT AUTHORITY:\n"
        if memoryHits.isEmpty {
            system += "  none\n"
        } else {
            for hit in memoryHits {
                system += "  - \(hit.source): \(hit.excerpt)\n"
            }
        }
        system += "\nRules: answer plainly first; cite the accepted rule if one shaped the answer; never present candidate or supporting memory as accepted graph authority."

        let hashInput = prompt + "\n" + system
        return ModelPacket(
            userPrompt: prompt,
            system: system,
            authorityHits: authorityHits,
            memoryHits: memoryHits,
            promptPacketHash: StableHash.hex(hashInput)
        )
    }
}

enum StableHash {
    static func hex(_ text: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }
}
