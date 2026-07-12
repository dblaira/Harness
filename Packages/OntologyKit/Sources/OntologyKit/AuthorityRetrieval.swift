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
        let queryTokens = Self.retrievalTokens(prompt)
        guard !queryTokens.isEmpty else { return [] }
        let liveHits = (try? await liveSparqlHits(queryTokens: queryTokens, limit: limit)) ?? []
        let bundledHits = bundledFallbackHits(
            queryTokens: queryTokens,
            ontology: ontology,
            limit: max(limit * 6, limit)
        )
        return Self.mergedRankedHits(
            liveHits: liveHits,
            bundledHits: bundledHits,
            queryTokens: queryTokens,
            limit: limit
        )
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
        let query = Self.liveQuery(
            queryTokens: queryTokens,
            acceptedGraphIRI: acceptedGraphIRI,
            limit: limit
        )
        let request = Self.liveRequest(query: query, endpoint: sparqlEndpoint)

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
            .map { $0 }
    }

    static func liveRequest(query: String, endpoint: URL) -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 2
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/sparql-results+json", forHTTPHeaderField: "Accept")
        request.httpBody = "query=\(Self.formEncode(query))".data(using: .utf8)
        return request
    }

    static func tokens(_ text: String) -> Set<String> {
        let stop: Set<String> = [
            "and", "the", "you",
            "about", "after", "again", "before", "being", "could", "first",
            "from", "have", "into", "should", "that", "their", "there",
            "these", "thing", "this", "with", "what", "when", "where", "which",
            "your", "youre", "would", "because"
        ]
        let raw = text
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
        return Set(
            raw
                .filter { $0.count > 2 && !stop.contains($0) }
                .map(Self.normalizedToken)
        )
    }

    /// Delegation fields are operating metadata, not the subject of the
    /// user's question. Searching them made generic words such as authority,
    /// source, and action outrank the actual request.
    static func retrievalTokens(_ prompt: String) -> Set<String> {
        tokens(DelegationContext.parsePrompt(prompt).message)
    }

    /// Rank matches inside Fuseki before applying the result cap. The old
    /// query limited an unordered match stream and only ranked those first
    /// rows in Swift, so a newly appended and more relevant accepted claim
    /// could never reach the model.
    static func liveQuery(
        queryTokens: Set<String>,
        acceptedGraphIRI: String,
        limit: Int
    ) -> String {
        let normalizedQueryTokens = normalizedTokens(queryTokens).sorted()
        let scoreTerms = normalizedQueryTokens.map { token in
            let literal = token
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            return "IF(CONTAINS(?searchText, \"\(literal)\"), 1, 0)"
        }
        let subjectScoreTerms = normalizedQueryTokens.map { token in
            let literal = token
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            return "IF(CONTAINS(?subjectText, \"\(literal)\"), 1, 0)"
        }
        let scoreExpression = scoreTerms.isEmpty ? "0" : scoreTerms.joined(separator: " + ")
        let subjectScoreExpression = subjectScoreTerms.isEmpty ? "0" : subjectScoreTerms.joined(separator: " + ")
        return """
        PREFIX understood: <https://understood.app/ontology#>
        SELECT ?s ?p ?o WHERE {
          GRAPH <\(acceptedGraphIRI)> {
            ?s ?p ?o .
            BIND(lcase(concat(str(?s), " ", str(?p), " ", str(?o))) AS ?searchText)
            BIND(lcase(str(?s)) AS ?subjectText)
            BIND(lcase(str(?p)) AS ?predicateText)
            BIND((\(scoreExpression)) AS ?matchScore)
            BIND((\(subjectScoreExpression)) AS ?subjectMatchScore)
            BIND(IF(CONTAINS(?predicateText, "label") || CONTAINS(?predicateText, "consequent"), 1, 0) AS ?predicatePriority)
            BIND((?predicatePriority + ?subjectMatchScore) AS ?structuralPriority)
            FILTER(?matchScore > 0)
          }
        }
        ORDER BY DESC(?structuralPriority) DESC(?subjectMatchScore) DESC(?predicatePriority) DESC(?matchScore) STR(?s) STR(?p) STR(?o)
        LIMIT \(max(limit * 6, limit))
        """
    }

    static func score(_ queryTokens: Set<String>, in text: String) -> Double {
        let queryTokens = normalizedTokens(queryTokens)
        let target = tokens(text)
        guard !target.isEmpty else { return 0 }
        let overlap = queryTokens.intersection(target).count
        guard overlap > 0 else { return 0 }
        return Double(overlap) / Double(max(queryTokens.count, 1))
    }

    static func mergedRankedHits(
        liveHits: [GraphAuthorityHit],
        bundledHits: [GraphAuthorityHit],
        queryTokens: Set<String>,
        limit: Int
    ) -> [GraphAuthorityHit] {
        var seen: Set<String> = []
        return (liveHits + bundledHits)
            .filter { $0.authorityLevel == .accepted }
            .filter { seen.insert(mergeKey(for: $0)).inserted }
            .sorted { lhs, rhs in
                isHigherPriority(lhs, than: rhs, queryTokens: queryTokens)
            }
            .prefix(limit)
            .map { $0 }
    }

    private static func isHigherPriority(
        _ lhs: GraphAuthorityHit,
        than rhs: GraphAuthorityHit,
        queryTokens: Set<String>
    ) -> Bool {
        let lhsSubjectScore = score(queryTokens, in: lhs.subject)
        let rhsSubjectScore = score(queryTokens, in: rhs.subject)
        let lhsSubjectSpecificity = subjectMatchSpecificity(lhs.subject, queryTokens: queryTokens)
        let rhsSubjectSpecificity = subjectMatchSpecificity(rhs.subject, queryTokens: queryTokens)
        let lhsPredicatePriority = preferredPredicate(lhs.predicate) ? 1 : 0
        let rhsPredicatePriority = preferredPredicate(rhs.predicate) ? 1 : 0
        let lhsStructuralPriority = lhsPredicatePriority + (lhsSubjectScore > 0 ? 1 : 0)
        let rhsStructuralPriority = rhsPredicatePriority + (rhsSubjectScore > 0 ? 1 : 0)

        if lhsStructuralPriority != rhsStructuralPriority {
            return lhsStructuralPriority > rhsStructuralPriority
        }
        if lhsSubjectScore != rhsSubjectScore { return lhsSubjectScore > rhsSubjectScore }
        if lhsSubjectSpecificity != rhsSubjectSpecificity {
            return lhsSubjectSpecificity > rhsSubjectSpecificity
        }
        if lhsPredicatePriority != rhsPredicatePriority { return lhsPredicatePriority > rhsPredicatePriority }
        if lhs.score != rhs.score { return lhs.score > rhs.score }
        if lhs.object != rhs.object { return lhs.object < rhs.object }
        return lhs.subject < rhs.subject
    }

    private static func preferredPredicate(_ predicate: String) -> Bool {
        let normalized = predicate.lowercased()
        return normalized.contains("label") || normalized.contains("consequent")
    }

    private static func subjectMatchSpecificity(
        _ subject: String,
        queryTokens: Set<String>
    ) -> Double {
        let subjectTokens = tokens(subjectIdentifier(subject))
        guard !subjectTokens.isEmpty else { return 0 }
        let overlap = normalizedTokens(queryTokens).intersection(subjectTokens).count
        return Double(overlap) / Double(subjectTokens.count)
    }

    private static func subjectIdentifier(_ subject: String) -> String {
        subject.split(separator: "/").last.map(String.init) ?? subject
    }

    private static func mergeKey(for hit: GraphAuthorityHit) -> String {
        let subject = subjectIdentifier(hit.subject)
        let predicate = hit.predicate.split(whereSeparator: { $0 == "/" || $0 == "#" }).last.map(String.init)
            ?? hit.predicate
        return "\(subject.lowercased())|\(predicate.lowercased())|\(hit.object.lowercased())"
    }

    private static func normalizedTokens(_ tokens: Set<String>) -> Set<String> {
        Set(tokens.map(normalizedToken))
    }

    private static func normalizedToken(_ token: String) -> String {
        switch token.lowercased() {
        case "captured", "captures", "capturing":
            return "capture"
        default:
            return token.lowercased()
        }
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

/// Capture consolidation must still see Adam's current accepted shelf when
/// Fuseki is offline. The ordinary retriever's bundled fallback is useful for
/// shipping defaults, but it can lag the canonical accepted graph on this Mac.
public struct CanonicalAcceptedGraphAuthorityRetriever: AuthorityRetrieving {
    private let base: any AuthorityRetrieving
    private let acceptedGraphURL: URL

    public init(
        base: any AuthorityRetrieving = OntologyAuthorityRetriever(),
        acceptedGraphURL: URL = ReviewQueueStore.defaultOntologyRoot()
            .appendingPathComponent("accepted/accepted-graph.ttl")
    ) {
        self.base = base
        self.acceptedGraphURL = acceptedGraphURL
    }

    public func retrieve(
        prompt: String,
        ontology: Ontology,
        limit: Int = 6
    ) async throws -> [GraphAuthorityHit] {
        let baseHits = (try? await base.retrieve(
            prompt: prompt,
            ontology: ontology,
            limit: limit
        )) ?? []
        let queryTokens = OntologyAuthorityRetriever.retrievalTokens(prompt)
        let canonicalHits = localAcceptedGraphHits(queryTokens: queryTokens)
        return Self.mergeAcceptedShelfHits(
            baseHits: baseHits,
            canonicalHits: canonicalHits,
            limit: limit
        )
    }

    static func mergeAcceptedShelfHits(
        baseHits: [GraphAuthorityHit],
        canonicalHits: [GraphAuthorityHit],
        limit: Int
    ) -> [GraphAuthorityHit] {
        guard limit > 0 else { return [] }
        var seen: Set<String> = []
        let sourcePreferred = (baseHits + canonicalHits)
            .filter { $0.authorityLevel == .accepted }
            .sorted { lhs, rhs in
                let lhsRank = Self.sourceRank(lhs.source)
                let rhsRank = Self.sourceRank(rhs.source)
                if lhsRank != rhsRank { return lhsRank < rhsRank }
                if lhs.score == rhs.score {
                    return lhs.subject < rhs.subject
                }
                return lhs.score > rhs.score
            }
            .filter { seen.insert("\($0.subject)|\($0.predicate)|\($0.object)").inserted }
        let ranked = sourcePreferred.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            let lhsRank = Self.sourceRank(lhs.source)
            let rhsRank = Self.sourceRank(rhs.source)
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            return lhs.subject < rhs.subject
        }
        var selected = Array(ranked.prefix(limit))
        if !selected.contains(where: Self.isLiveFusekiHit),
           let liveHit = ranked.first(where: Self.isLiveFusekiHit) {
            if selected.count == limit {
                selected.removeLast()
            }
            selected.append(liveHit)
        }
        return selected
    }

    private static func sourceRank(_ source: String) -> Int {
        if source == "Fuseki /accepted named graph" { return 0 }
        if source.hasPrefix("canonical local accepted graph") { return 1 }
        return 2
    }

    private static func isLiveFusekiHit(_ hit: GraphAuthorityHit) -> Bool {
        hit.source == "Fuseki /accepted named graph"
    }

    private func localAcceptedGraphHits(queryTokens: Set<String>) -> [GraphAuthorityHit] {
        guard !queryTokens.isEmpty,
              let turtle = try? String(contentsOf: acceptedGraphURL, encoding: .utf8),
              let blockRegex = try? NSRegularExpression(
                pattern: #"<([^>]+)>\s+a\s+understood:Connection\s*;([\s\S]*?)\n\s*\."#
              ),
              let labelRegex = try? NSRegularExpression(
                pattern: #"understood:label\s+"((?:\\.|[^"\\])*)""#
              ) else { return [] }

        let turtleRange = NSRange(turtle.startIndex..., in: turtle)
        return blockRegex.matches(in: turtle, range: turtleRange).compactMap { match in
            guard match.numberOfRanges > 2,
                  let subjectRange = Range(match.range(at: 1), in: turtle),
                  let bodyRange = Range(match.range(at: 2), in: turtle) else { return nil }
            let subject = String(turtle[subjectRange])
            let body = String(turtle[bodyRange])
            let bodyRangeNS = NSRange(body.startIndex..., in: body)
            guard let labelMatch = labelRegex.firstMatch(in: body, range: bodyRangeNS),
                  labelMatch.numberOfRanges > 1,
                  let labelRange = Range(labelMatch.range(at: 1), in: body) else { return nil }
            let label = Self.unescapeTurtleLiteral(String(body[labelRange]))
            let score = OntologyAuthorityRetriever.score(
                queryTokens,
                in: "\(subject) \(label) \(body)"
            )
            guard score > 0 else { return nil }
            return GraphAuthorityHit(
                subject: subject,
                predicate: "understood:label",
                object: label,
                source: "canonical local accepted graph: \(acceptedGraphURL.path)",
                queryTrace: "Fuseki unavailable or incomplete; searched canonical accepted graph at \(acceptedGraphURL.path)",
                authorityLevel: .accepted,
                score: score
            )
        }
    }

    private static func unescapeTurtleLiteral(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }
}

public enum PromptPacketBuilder {
    public static func makePacket(
        prompt: String,
        ontology: Ontology,
        authorityHits: [GraphAuthorityHit],
        memoryHits: [MemoryHit],
        soul: SoulDocument? = SoulLoader.load(),
        conversationHistory: [ConversationTurn] = [],
        images: [ModelImageAttachment] = [],
        sessionId: String = PromptAssembler.defaultSessionId,
        assembler: PromptAssembler = .shared
    ) -> ModelPacket {
        // Hermes-style tiered prompt: identity-first STABLE tier, ontology as
        // CONTEXT (not cage), Adam's response-rule skill files verbatim, then
        // the VOLATILE memory snapshot — byte-stable per session.
        var system = assembler.assemble(
            sessionId: sessionId,
            ontology: ontology,
            soul: soul
        ).joined

        // Everything below is per-query and stays OUT of the stable tiers so
        // the cached prompt prefix survives across turns.
        if DelegationContext.containsContext(in: prompt) {
            system += "\n\n" + DelegationContext.systemInstruction + "\n"
        }
        let cappedHistory = ConversationTurn.cappedHistory(conversationHistory)
        if !cappedHistory.isEmpty {
            system += "\n\nCHAT CONTINUITY: Prior turns in this thread are in the message history. Stay consistent with what you already said.\n"
        }
        let policyDirectives = AgentPolicyCompiler.compile(
            prompt: prompt,
            ontology: ontology,
            authorityHits: authorityHits
        )

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
        system += "\nRDF POLICY DIRECTIVES:\n"
        if policyDirectives.isEmpty {
            system += "  none\n"
        } else {
            for directive in policyDirectives {
                system += "  - \(directive.promptLine)\n"
            }
            system += "When a directive shapes the answer, include its required marker exactly.\n"
        }

        var hashInput = prompt + "\n" + system
        for turn in cappedHistory {
            hashInput += "\n\(turn.role.rawValue):\(turn.text)"
        }
        for image in images {
            hashInput += "\n\(image.title):\(image.mimeType):\(image.base64Data.count)"
        }
        return ModelPacket(
            userPrompt: prompt,
            system: system,
            authorityHits: authorityHits,
            memoryHits: memoryHits,
            policyDirectives: policyDirectives,
            images: images,
            conversationHistory: cappedHistory,
            soulPath: soul?.path,
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
