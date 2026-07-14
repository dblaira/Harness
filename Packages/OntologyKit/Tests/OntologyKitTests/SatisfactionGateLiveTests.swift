import Foundation
import Testing
@testable import OntologyKit

/// The Satisfaction Gate, seed version: Adam's real question through the full
/// live pipeline — Fuseki accepted-graph authority, supporting memory, and the
/// local Hermes model — exactly the path the app's chat uses, with no
/// interactive deadline so the complete synthesis is captured.
///
/// Ordinary deterministic CI excludes this test by name. The signed Mac
/// handoff runs it with `HARNESS_REQUIRE_LIVE_SATISFACTION=1`, making absent
/// Ollama or Fuseki a hard failure and requiring an on-disk proof artifact.
private func liveEndpointUp(_ urlString: String) async -> Bool {
    guard let url = URL(string: urlString) else { return false }
    var request = URLRequest(url: url)
    request.timeoutInterval = 3
    guard let (_, response) = try? await URLSession.shared.data(for: request) else { return false }
    guard let status = (response as? HTTPURLResponse)?.statusCode else { return false }
    return (200..<300).contains(status)
}

private struct ProtectedAuthoritySnapshot: Decodable {
    struct Triple: Decodable, Hashable {
        let subject: String
        let predicate: String
        let object: String
        let sha256: String
    }

    let schema_version: Int
    let accepted_graph: String
    let sha256: String
    let triples: [Triple]
}

private func protectedAuthorityBindingErrors(
    authorityHits: [GraphAuthorityHit],
    snapshot: ProtectedAuthoritySnapshot
) -> [String] {
    func normalized(_ value: String) -> String {
        if value.hasPrefix("understood:") {
            return value.replacingOccurrences(
                of: "understood:",
                with: "https://understood.app/ontology#",
                options: [.anchored]
            )
        }
        return value
    }
    let accepted = Set(snapshot.triples.map {
        "\(normalized($0.subject))\u{001f}\(normalized($0.predicate))\u{001f}\(normalized($0.object))"
    })
    return authorityHits.compactMap { hit in
        let key = "\(normalized(hit.subject))\u{001f}\(normalized(hit.predicate))\u{001f}\(normalized(hit.object))"
        guard hit.authorityLevel == .accepted, accepted.contains(key) else {
            return "authority hit is not an exact pre-execution accepted binding: \(hit.subject)"
        }
        return nil
    }
}

private func loadProtectedAuthoritySnapshot(environment: [String: String]) throws -> ProtectedAuthoritySnapshot {
    guard let path = environment["HARNESS_PROTECTED_AUTHORITY_BINDINGS"] else {
        struct MissingProtectedAuthoritySnapshot: Error {}
        throw MissingProtectedAuthoritySnapshot()
    }
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    let snapshot = try JSONDecoder().decode(ProtectedAuthoritySnapshot.self, from: data)
    guard snapshot.schema_version == 1, !snapshot.triples.isEmpty else {
        struct InvalidProtectedAuthoritySnapshot: Error {}
        throw InvalidProtectedAuthoritySnapshot()
    }
    return snapshot
}

private func requiredLiveEvidenceErrors(
    health: GraphHealthReport,
    authorityHits: [GraphAuthorityHit]
) -> [String] {
    var errors: [String] = []
    if health.status != .healthy {
        errors.append("accepted Fuseki named graph is not healthy: \(health.status.rawValue)")
    }
    if !authorityHits.contains(where: { $0.source == "Fuseki /accepted named graph" }) {
        let observedSources = Set(authorityHits.map(\.source)).sorted().joined(separator: ", ")
        errors.append(
            "answer has no relevant authority hit sourced from the live Fuseki accepted graph; "
                + "observed sources: \(observedSources.isEmpty ? "none" : observedSources)"
        )
    }
    return errors
}

private func requiredAcceptedRouteErrors(
    health: GraphHealthReport,
    authorityHits: [GraphAuthorityHit]
) -> [String] {
    var errors: [String] = []
    if health.status != .healthy {
        errors.append("accepted Fuseki named graph is not healthy: \(health.status.rawValue)")
    }
    if authorityHits.isEmpty || !authorityHits.allSatisfy({ $0.authorityLevel == .accepted }) {
        errors.append("production accepted-only route did not return accepted authority")
    }
    return errors
}

private func authoritySeparationPassed(_ detail: HarnessRunDetail) -> Bool {
    detail.evalResults.contains {
        $0.checkName == "authority-memory-separated" && $0.passed
    }
}

private actor RecordingGraphHealthChecker: GraphHealthChecking {
    private let wrapped: any GraphHealthChecking
    private var latest: GraphHealthReport?

    init(wrapped: any GraphHealthChecking) {
        self.wrapped = wrapped
    }

    func checkAcceptedGraph() async -> GraphHealthReport {
        let report = await wrapped.checkAcceptedGraph()
        latest = report
        return report
    }

    func recordedReport() -> GraphHealthReport? {
        latest
    }
}

@Test func answerRunEvidenceRejectsUnavailableMissingAndHealthyPreflightWithFallbackOnlyAnswer() {
    let statuses: [GraphHealthStatus] = [.unavailable, .missingAcceptedNamedGraph]
    for status in statuses {
        let report = GraphHealthReport(
            status: status,
            acceptedGraphIRI: "https://understood.app/graph/accepted",
            sparqlEndpoint: "http://127.0.0.1:3030/understood/sparql",
            namedGraphCount: nil,
            defaultGraphTripleCount: nil,
            detail: "fixture"
        )
        #expect(!requiredLiveEvidenceErrors(health: report, authorityHits: []).isEmpty)
    }
    let healthyButFallbackOnly = GraphHealthReport(
        status: .healthy,
        acceptedGraphIRI: "https://understood.app/graph/accepted",
        sparqlEndpoint: "http://127.0.0.1:3030/understood/sparql",
        namedGraphCount: 1,
        defaultGraphTripleCount: 0,
        detail: "fixture"
    )
    let fallback = GraphAuthorityHit(
        subject: "fixture",
        predicate: "fixture",
        object: "capturing value",
        source: "offline bundled TTL fallback",
        queryTrace: "fixture"
    )
    #expect(!requiredLiveEvidenceErrors(health: healthyButFallbackOnly, authorityHits: [fallback]).isEmpty)
}

@Test func protectedAuthoritySnapshotRejectsFabricatedAcceptedHit() {
    let snapshot = ProtectedAuthoritySnapshot(
        schema_version: 1,
        accepted_graph: "https://understood.app/graph/accepted",
        sha256: "fixture",
        triples: [
            .init(subject: "allowed", predicate: "predicate", object: "object", sha256: "fixture")
        ]
    )
    let allowed = GraphAuthorityHit(
        subject: "allowed", predicate: "predicate", object: "object", source: "fixture", queryTrace: "fixture"
    )
    let fabricated = GraphAuthorityHit(
        subject: "fabricated", predicate: "predicate", object: "object", source: "fixture", queryTrace: "fixture"
    )
    #expect(protectedAuthorityBindingErrors(authorityHits: [allowed], snapshot: snapshot).isEmpty)
    #expect(!protectedAuthorityBindingErrors(authorityHits: [allowed, fabricated], snapshot: snapshot).isEmpty)
}

@Test func satisfactionGateAdamRealQuestionGetsCompleteAnswer() async throws {
    let environment = ProcessInfo.processInfo.environment
    let requireLiveProof = environment["HARNESS_REQUIRE_LIVE_SATISFACTION"] == "1"
    let ollamaBaseURL = environment["HARNESS_OLLAMA_BASE_URL"] ?? "http://127.0.0.1:11434"
    let ollamaAvailable = await liveEndpointUp(
        ollamaBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/api/tags"
    )
    guard ollamaAvailable else {
        if requireLiveProof {
            struct MissingLiveDependency: Error {}
            throw MissingLiveDependency()
        }
        return
    }
    guard environment["HARNESS_PROTECTED_AUTHORITY_BINDINGS"] != nil else {
        if requireLiveProof {
            struct MissingProtectedAuthoritySnapshot: Error {}
            throw MissingProtectedAuthoritySnapshot()
        }
        return
    }
    let protectedAuthoritySnapshot = try loadProtectedAuthoritySnapshot(environment: environment)

    let ledger = try RunLedgerStore.inMemory()
    let graphHealthChecker = RecordingGraphHealthChecker(wrapped: FusekiGraphHealthChecker())
    let ontology = OntologyLoader.load()

    let service = HarnessRunService(
        ledger: ledger,
        authorityRetriever: CanonicalAcceptedGraphAuthorityRetriever(),
        graphHealthChecker: graphHealthChecker
    )
    let backend = AgentRunnerBackendAdapter(backend: .hermes, apiKey: nil)

    // Adam's own question, verbatim from the app ledger — the one that
    // repeatedly hit the response ceiling on 2026-07-11.
    let prompt = "what information do I have approved already that confirms the importance of capturing value?"

    let acceptedDetail = try await service.createRun(
        prompt: prompt,
        ontology: ontology,
        backend: backend,
        includeSupportingMemory: !InteractiveChatPolicy.requestsAcceptedAuthorityOnly(prompt),
        answerFromAcceptedAuthority: true
    )
    let acceptedRecordedGraphHealth = await graphHealthChecker.recordedReport()
    let acceptedGraphHealth = try #require(acceptedRecordedGraphHealth)
    let acceptedEvidenceErrors = requiredAcceptedRouteErrors(
        health: acceptedGraphHealth,
        authorityHits: acceptedDetail.authorityHits
    )
    try #require(acceptedEvidenceErrors.isEmpty, Comment(rawValue: acceptedEvidenceErrors.joined(separator: "; ")))
    let acceptedBindingErrors = protectedAuthorityBindingErrors(
        authorityHits: acceptedDetail.authorityHits,
        snapshot: protectedAuthoritySnapshot
    )
    try #require(acceptedBindingErrors.isEmpty, Comment(rawValue: acceptedBindingErrors.joined(separator: "; ")))
    #expect(acceptedDetail.memoryHits.isEmpty)
    #expect(acceptedDetail.run.success)
    #expect(authoritySeparationPassed(acceptedDetail))

    let directFusekiHits = try await OntologyAuthorityRetriever().retrieve(
        prompt: prompt,
        ontology: ontology,
        limit: 6
    )
    let directFusekiErrors = requiredLiveEvidenceErrors(
        health: acceptedGraphHealth,
        authorityHits: directFusekiHits
    )
    try #require(directFusekiErrors.isEmpty, Comment(rawValue: directFusekiErrors.joined(separator: "; ")))
    let directBindingErrors = protectedAuthorityBindingErrors(
        authorityHits: directFusekiHits,
        snapshot: protectedAuthoritySnapshot
    )
    try #require(directBindingErrors.isEmpty, Comment(rawValue: directBindingErrors.joined(separator: "; ")))

    let synthesisPrompt = "Synthesize accepted information and supporting memory about capturing value while keeping every trust layer separate."
    let started = Date()
    let synthesisDetail = try await service.createRun(
        prompt: synthesisPrompt,
        ontology: ontology,
        backend: backend,
        includeSupportingMemory: true,
        answerFromAcceptedAuthority: false
    )
    let elapsed = Date().timeIntervalSince(started)
    let recordedGraphHealth = await graphHealthChecker.recordedReport()
    let graphHealth = try #require(recordedGraphHealth)
    let liveEvidenceErrors = requiredAcceptedRouteErrors(
        health: graphHealth,
        authorityHits: synthesisDetail.authorityHits
    )
    try #require(liveEvidenceErrors.isEmpty, Comment(rawValue: liveEvidenceErrors.joined(separator: "; ")))
    let synthesisBindingErrors = protectedAuthorityBindingErrors(
        authorityHits: synthesisDetail.authorityHits,
        snapshot: protectedAuthoritySnapshot
    )
    try #require(synthesisBindingErrors.isEmpty, Comment(rawValue: synthesisBindingErrors.joined(separator: "; ")))

    let acceptedAnswer = acceptedDetail.messages.last(where: { $0.role == .assistant })?.text
        ?? acceptedDetail.run.finalAnswer
    let answer = synthesisDetail.messages.last(where: { $0.role == .assistant })?.text
        ?? synthesisDetail.run.finalAnswer
    #expect(!answer.isEmpty)
    #expect(synthesisDetail.run.success)
    #expect(!answer.hasPrefix("Harness stopped "))
    #expect(authoritySeparationPassed(synthesisDetail))

    let defaultOutput = "/Users/adamblair/Developer/GitHub/Harness/output/satisfaction-gate"
    let dir = URL(fileURLWithPath: environment["HARNESS_SATISFACTION_OUTPUT_DIR"] ?? defaultOutput)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let stamp = ISO8601DateFormatter().string(from: Date())
        .replacingOccurrences(of: ":", with: "-")
    let artifact = dir.appendingPathComponent("gate-\(stamp).md")
    let report = """
    # Satisfaction Gate — live full-pipeline proof

    - Question (Adam's words, verbatim): \(prompt)
    - Accepted-only production route: supporting memory disabled; model execution disabled
    - Accepted-only supporting memory hits: \(acceptedDetail.memoryHits.count)
    - Accepted-only authority separation: \(authoritySeparationPassed(acceptedDetail) ? "PASS" : "FAIL")
    - Direct accepted-only Fuseki preflight hits: \(directFusekiHits.filter { $0.source == "Fuseki /accepted named graph" }.count)
    - Live synthesis prompt: \(synthesisPrompt)
    - Backend: Hermes local (Ollama), no interactive deadline
    - Authority hits from accepted graph: \(synthesisDetail.authorityHits.count)
    - Supporting memory hits: \(synthesisDetail.memoryHits.count)
    - Synthesis authority separation: \(authoritySeparationPassed(synthesisDetail) ? "PASS" : "FAIL")
    - Elapsed: \(String(format: "%.1f", elapsed)) seconds
    - Run id: \(synthesisDetail.run.id)
    - Run success: \(synthesisDetail.run.success)
    - Commit: \(environment["HARNESS_SATISFACTION_COMMIT"] ?? "UNBOUND")
    - Fuseki graph health: \(graphHealth.status.rawValue)
    - Fuseki authority hits: \(directFusekiHits.filter { $0.source == "Fuseki /accepted named graph" }.count)
    - Protected accepted binding snapshot SHA-256: \(protectedAuthoritySnapshot.sha256)

    ## Accepted-only answer as produced

    \(acceptedAnswer)

    ## Answer as produced

    \(answer)
    """
    try report.write(to: artifact, atomically: true, encoding: .utf8)

    print("SATISFACTION_GATE_ARTIFACT: \(artifact.path)")
    print("ELAPSED_SECONDS: \(String(format: "%.1f", elapsed))")
    print("AUTHORITY_HITS: \(synthesisDetail.authorityHits.count)")
    print("ANSWER_BEGIN")
    print(answer)
    print("ANSWER_END")
}
