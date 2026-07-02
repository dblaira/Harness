import Foundation

public protocol AuthorityRetrieving: Sendable {
    func retrieve(prompt: String, ontology: Ontology, limit: Int) async throws -> [GraphAuthorityHit]
}

public struct OntologyAuthorityRetriever: AuthorityRetrieving {
    private let sparqlEndpoint: URL
    private let acceptedGraphIRI: String

    public init(
        sparqlEndpoint: URL? = nil,
        acceptedGraphIRI: String = "https://understood.app/graph/accepted"
    ) {
        if let sparqlEndpoint {
            self.sparqlEndpoint = sparqlEndpoint
        } else if let env = ProcessInfo.processInfo.environment["HARNESS_FUSEKI_SPARQL_ENDPOINT"],
                  let url = URL(string: env) {
            self.sparqlEndpoint = url
        } else if let env = ProcessInfo.processInfo.environment["FUSEKI_SPARQL_ENDPOINT"],
                  let url = URL(string: env) {
            self.sparqlEndpoint = url
        } else {
            self.sparqlEndpoint = URL(string: "http://127.0.0.1:3030/understood/sparql")!
        }
        self.acceptedGraphIRI = ProcessInfo.processInfo.environment["ACCEPTED_GRAPH_IRI"] ?? acceptedGraphIRI
    }

    public func retrieve(prompt: String, ontology: Ontology, limit: Int = 6) async throws -> [GraphAuthorityHit] {
        let queryTokens = Self.tokens(prompt)
        guard !queryTokens.isEmpty else { return [] }
        if let liveHits = try? await liveSparqlHits(queryTokens: queryTokens, limit: limit), !liveHits.isEmpty {
            return liveHits
        }

        return bundledFallbackHits(queryTokens: queryTokens, ontology: ontology, limit: limit)
    }

    private func bundledFallbackHits(queryTokens: Set<String>, ontology: Ontology, limit: Int) -> [GraphAuthorityHit] {

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
                    source: "offline bundled TTL fallback: accepted:adam-beliefs.ttl",
                    queryTrace: "SPARQL unavailable; fallback=local bundled TTL; tokens=\(Array(queryTokens).sorted().joined(separator: ",")); resultCount=local",
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
                    source: "offline bundled TTL fallback: accepted:adam-axioms.ttl",
                    queryTrace: "SPARQL unavailable; fallback=local bundled TTL; tokens=\(Array(queryTokens).sorted().joined(separator: ",")); resultCount=local; confidence=\(axiom.confidence)",
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
                    source: "offline bundled TTL fallback: accepted:adam_pattern.ttl",
                    queryTrace: "SPARQL unavailable; fallback=local bundled TTL; tokens=\(Array(queryTokens).sorted().joined(separator: ",")); resultCount=local",
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

    private func liveSparqlHits(queryTokens: Set<String>, limit: Int) async throws -> [GraphAuthorityHit] {
        let regex = Array(queryTokens).sorted().map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
        let query = """
        PREFIX understood: <https://understood.app/ontology#>
        SELECT ?s ?p ?o WHERE {
          GRAPH <\(acceptedGraphIRI)> {
            ?s ?p ?o .
            FILTER(
              (isLiteral(?o) && regex(lcase(str(?o)), "\(regex)")) ||
              regex(lcase(str(?s)), "\(regex)") ||
              regex(lcase(str(?p)), "\(regex)")
            )
          }
        }
        LIMIT \(max(limit * 6, limit))
        """
        var request = URLRequest(url: sparqlEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/sparql-results+json", forHTTPHeaderField: "Accept")
        request.httpBody = "query=\(Self.formEncode(query))".data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        let bindings = try Self.sparqlBindings(from: data)
        let resultCount = bindings.count
        let trace = "SPARQL query:\n\(query)\nResult count: \(resultCount)"
        return bindings
            .compactMap { binding -> GraphAuthorityHit? in
                guard let subject = binding["s"], let predicate = binding["p"], let object = binding["o"] else {
                    return nil
                }
                let score = Self.score(queryTokens, in: "\(subject) \(predicate) \(object)")
                guard score > 0 else { return nil }
                return GraphAuthorityHit(
                    subject: subject,
                    predicate: predicate,
                    object: object,
                    source: "Fuseki /accepted named graph",
                    queryTrace: trace,
                    authorityLevel: .accepted,
                    score: score
                )
            }
            .sorted { lhs, rhs in
                if lhs.score == rhs.score { return lhs.subject < rhs.subject }
                return lhs.score > rhs.score
            }
            .prefix(limit)
            .map { $0 }
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

    private static func formEncode(_ text: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?")
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
    }

    private static func sparqlBindings(from data: Data) throws -> [[String: String]] {
        guard
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let results = object["results"] as? [String: Any],
            let bindings = results["bindings"] as? [[String: Any]]
        else {
            return []
        }
        return bindings.map { row in
            var out: [String: String] = [:]
            for key in ["s", "p", "o"] {
                if let value = row[key] as? [String: Any],
                   let text = value["value"] as? String {
                    out[key] = text
                }
            }
            return out
        }
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
        system += "\nRules: answer plainly first; cite the accepted rule if one shaped the answer; include `Adam Pattern Step: 1-8` or `Adam Pattern Step: none`; never present candidate or supporting memory as accepted graph authority."

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
