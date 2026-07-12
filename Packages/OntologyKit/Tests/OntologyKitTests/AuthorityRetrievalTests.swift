import Foundation
import Testing
@testable import OntologyKit

private struct StaticAuthorityRetriever: AuthorityRetrieving {
    let hits: [GraphAuthorityHit]

    func retrieve(prompt: String, ontology: Ontology, limit: Int) async throws -> [GraphAuthorityHit] {
        Array(hits.prefix(limit))
    }
}

@Test func acceptedGraphQueryRanksMatchesBeforeApplyingItsLimit() throws {
    let query = OntologyAuthorityRetriever.liveQuery(
        queryTokens: ["adam", "just", "says"],
        acceptedGraphIRI: "https://understood.app/graph/accepted",
        limit: 6
    )

    let order = try #require(query.range(of: "ORDER BY DESC(?structuralPriority)"))
    let limit = try #require(query.range(of: "LIMIT 36"))
    #expect(order.lowerBound < limit.lowerBound)
    #expect(query.contains("IF(CONTAINS(?searchText, \"adam\"), 1, 0)"))
    #expect(query.contains("IF(CONTAINS(?searchText, \"just\"), 1, 0)"))
    #expect(query.contains("IF(CONTAINS(?searchText, \"says\"), 1, 0)"))
}

@Test func acceptedGraphTokensDropGlueWordsButKeepTheMeaningfulPhrase() {
    let tokens = OntologyAuthorityRetriever.tokens(
        "When Adam says just do it, what should you do next?"
    )

    #expect(tokens.contains("adam"))
    #expect(tokens.contains("says"))
    #expect(tokens.contains("just"))
    #expect(tokens.contains("next"))
    #expect(!tokens.contains("the"))
    #expect(!tokens.contains("and"))
    #expect(!tokens.contains("you"))
}

@Test func acceptedGraphScoringMatchesCapturingToCapture() {
    let score = OntologyAuthorityRetriever.score(
        ["capturing"],
        in: "Products capture potential that would otherwise slip away"
    )

    #expect(score == 1)
}

@Test func acceptedGraphLiveQueryRanksCapturingAsCapture() {
    let query = OntologyAuthorityRetriever.liveQuery(
        queryTokens: ["capturing", "value"],
        acceptedGraphIRI: "https://understood.app/graph/accepted",
        limit: 6
    )

    #expect(query.contains("IF(CONTAINS(?searchText, \"capture\"), 1, 0)"))
    #expect(!query.contains("IF(CONTAINS(?searchText, \"capturing\"), 1, 0)"))
    #expect(query.contains("?predicatePriority"))
    #expect(query.contains("?subjectMatchScore"))
    #expect(query.contains("ORDER BY DESC(?structuralPriority)"))
}

@Test func acceptedGraphSPARQLRequestUsesTwoSecondTimeout() {
    let request = OntologyAuthorityRetriever.liveRequest(
        query: "SELECT * WHERE { ?s ?p ?o }",
        endpoint: URL(string: "https://example.test/understood/sparql")!
    )

    #expect(request.timeoutInterval == 2)
}

@Test func exactApprovedCaptureQuestionRanksDirectAcceptedCaptureEvidenceInTopSix() async throws {
    let retriever = OntologyAuthorityRetriever(
        sparqlEndpoint: URL(string: "http://127.0.0.1:9/understood/sparql")!
    )

    let hits = try await retriever.retrieve(
        prompt: "what information do I have approved already that confirms the importance of capturing value?",
        ontology: OntologyLoader.load(),
        limit: 6
    )

    #expect(hits.contains { hit in
        hit.object.contains("Capture first, structure later")
            || hit.subject.contains("capture-potential")
    })
    #expect(hits.allSatisfy { $0.authorityLevel == .accepted })
}

@Test func mergedAcceptedHitsPreferCaptureLabelsAndMatchingSubjectsOverGenericLiveRows() {
    let queryTokens = OntologyAuthorityRetriever.retrievalTokens(
        "what information do I have approved already that confirms the importance of capturing value?"
    )
    let genericLiveHits = (1...6).map { index in
        GraphAuthorityHit(
            subject: "https://understood.app/ontology/instinct/generic-\(index)",
            predicate: "https://understood.app/ontology#evidenceNote",
            object: "Approved information confirms important value",
            source: "Fuseki /accepted named graph",
            queryTrace: "live",
            authorityLevel: .accepted,
            score: 4.0 / 7.0
        )
    }
    let directAcceptedHits = [
        GraphAuthorityHit(
            subject: "understood:axiom/capture-potential",
            predicate: "understood:consequentLabel",
            object: "Capture potential that would otherwise slip away",
            source: "offline bundled TTL fallback: accepted:adam-axioms.ttl",
            queryTrace: "bundled",
            authorityLevel: .accepted,
            score: 1.0 / 7.0
        ),
        GraphAuthorityHit(
            subject: "understood:connection/conn-010",
            predicate: "understood:label",
            object: "Capture first, structure later",
            source: "offline bundled TTL fallback: accepted:adam-beliefs.ttl",
            queryTrace: "bundled",
            authorityLevel: .accepted,
            score: 1.0 / 7.0
        ),
        GraphAuthorityHit(
            subject: "candidate:must-not-enter-authority",
            predicate: "understood:label",
            object: "Capture candidate",
            source: "candidate file",
            queryTrace: "candidate",
            authorityLevel: .candidate,
            score: 1
        ),
    ]

    let hits = OntologyAuthorityRetriever.mergedRankedHits(
        liveHits: genericLiveHits,
        bundledHits: directAcceptedHits,
        queryTokens: queryTokens,
        limit: 6
    )

    #expect(hits.first?.subject.contains("capture-potential") == true)
    #expect(hits.contains { $0.object == "Capture first, structure later" })
    #expect(hits.allSatisfy { $0.authorityLevel == .accepted })
}

@Test func acceptedGraphRetrievalSearchesTheMessageNotDelegationMetadata() {
    let prompt = """
    DELEGATION CONTEXT
    PreferredApproach: zebrametadata accepted graph authority
    DoneCondition: Name the source and next action

    ---
    When Adam says just do it, what should you do next?
    """

    let tokens = OntologyAuthorityRetriever.retrievalTokens(prompt)

    #expect(tokens.contains("adam"))
    #expect(tokens.contains("says"))
    #expect(tokens.contains("just"))
    #expect(!tokens.contains("zebrametadata"))
    #expect(!tokens.contains("authority"))
    #expect(!tokens.contains("source"))
}

@Test func canonicalAcceptedGraphRemainsAvailableWhenFusekiIsOffline() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("canonical-accepted-retrieval-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let graphURL = root.appendingPathComponent("accepted-graph.ttl")
    try """
    @prefix understood: <https://understood.app/ontology#> .

    <https://understood.app/ontology/connection/conn-news-calm> a understood:Connection ;
      understood:label "Adam prefers Palantir and knowledge graph news in a brief tone" ;
      understood:connectionType "stated_news_preference" ;
      .
    """.write(to: graphURL, atomically: true, encoding: .utf8)
    let retriever = CanonicalAcceptedGraphAuthorityRetriever(
        base: OntologyAuthorityRetriever(
            sparqlEndpoint: URL(string: "http://127.0.0.1:9/understood/sparql")!
        ),
        acceptedGraphURL: graphURL
    )

    let hits = try await retriever.retrieve(
        prompt: "Captured a preference for Palantir knowledge graph news with brief tone",
        ontology: .empty,
        limit: 6
    )

    #expect(hits.first?.object == "Adam prefers Palantir and knowledge graph news in a brief tone")
    #expect(hits.first?.source.contains("canonical local accepted graph") == true)
}

@Test func canonicalAcceptedGraphPreservesLiveFusekiProvenanceForDuplicateAcceptedFact() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("canonical-live-provenance-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let graphURL = root.appendingPathComponent("accepted-graph.ttl")
    let subject = "https://understood.app/ontology/connection/conn-capture"
    let label = "Capture first, structure later"
    let prompt = "Why capture first?"
    try """
    @prefix understood: <https://understood.app/ontology#> .

    <\(subject)> a understood:Connection ;
      understood:label "\(label)" ;
      understood:connectionType "stated_practice" ;
      .
    """.write(to: graphURL, atomically: true, encoding: .utf8)
    let liveHit = GraphAuthorityHit(
        subject: subject,
        predicate: "understood:label",
        object: label,
        source: "Fuseki /accepted named graph",
        queryTrace: "live fixture",
        authorityLevel: .accepted,
        score: OntologyAuthorityRetriever.score(
            OntologyAuthorityRetriever.retrievalTokens(prompt),
            in: "\(subject) understood:label \(label)"
        )
    )
    let retriever = CanonicalAcceptedGraphAuthorityRetriever(
        base: StaticAuthorityRetriever(hits: [liveHit]),
        acceptedGraphURL: graphURL
    )

    let hits = try await retriever.retrieve(
        prompt: prompt,
        ontology: .empty,
        limit: 6
    )

    #expect(hits.count == 1)
    #expect(hits.first?.source == "Fuseki /accepted named graph")
}

@Test func canonicalAcceptedGraphKeepsLiveProvenanceWhenRicherLocalHitsFillTheLimit() {
    let liveHit = GraphAuthorityHit(
        subject: "https://understood.app/ontology/connection/live-capture",
        predicate: "understood:label",
        object: "Live capture fact",
        source: "Fuseki /accepted named graph",
        queryTrace: "live fixture",
        authorityLevel: .accepted,
        score: 0.1
    )
    let canonicalHits = (1...6).map { index in
        GraphAuthorityHit(
            subject: "https://understood.app/ontology/connection/local-\(index)",
            predicate: "understood:label",
            object: "Richer local fact \(index)",
            source: "canonical local accepted graph: fixture",
            queryTrace: "local fixture",
            authorityLevel: .accepted,
            score: 1
        )
    }

    let hits = CanonicalAcceptedGraphAuthorityRetriever.mergeAcceptedShelfHits(
        baseHits: [liveHit],
        canonicalHits: canonicalHits,
        limit: 6
    )

    #expect(hits.count == 6)
    #expect(hits.contains { $0.source == "Fuseki /accepted named graph" })
    #expect(hits.contains { $0.source.hasPrefix("canonical local accepted graph") })
}
