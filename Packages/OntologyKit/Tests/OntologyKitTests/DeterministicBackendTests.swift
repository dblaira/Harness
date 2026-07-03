import Foundation
import Testing
@testable import OntologyKit

@Test func hermesLocalBackendRunsAgainstOllamaWhenReachable() async throws {
    // Live integration check, not a mock: skips cleanly if `ollama serve` isn't
    // up (e.g. CI), but proves the real Backend.hermes code path against the
    // real local model when it is.
    guard let url = URL(string: "http://127.0.0.1:11434/api/tags"),
          let (_, response) = try? await URLSession.shared.data(from: url),
          (response as? HTTPURLResponse)?.statusCode == 200 else {
        return
    }
    let runner = AgentRunner()
    let reply = try await runner.run(backend: .hermes, system: "Reply with exactly one word.", user: "Say OK.")
    #expect(!reply.isEmpty)
}

@Test func claudeClientUsesCurrentDefaultModel() {
    #expect(ClaudeClient(apiKey: "test-key").model == "claude-sonnet-4-6")
}

@Test func openAIClientRequiresAPIKeyBeforeNetwork() async {
    do {
        _ = try await OpenAIClient(apiKey: "").send(messages: [(role: "user", text: "Hi")], system: "Reply briefly.")
        #expect(Bool(false), "OpenAIClient should require an API key.")
    } catch OpenAIClient.OpenAIError.noKey {
        #expect(Bool(true))
    } catch {
        #expect(Bool(false), "Unexpected error: \(error.localizedDescription)")
    }
}

@Test func xAIClientRequiresAPIKeyBeforeNetwork() async {
    do {
        _ = try await XAIClient(apiKey: "").send(messages: [(role: "user", text: "Hi")], system: "Reply briefly.")
        #expect(Bool(false), "XAIClient should require an API key.")
    } catch XAIClient.XAIError.noKey {
        #expect(Bool(true))
    } catch {
        #expect(Bool(false), "Unexpected error: \(error.localizedDescription)")
    }
}

@Test func authorityRetrievalPrecedesMemoryAndModel() async throws {
    let ontology = OntologyLoader.load()
    let ledger = try RunLedgerStore.inMemory()
    let backend = StaticBackendAdapter(
        metadata: .init(backend: .codex, modelName: "test-codex", invocationMethod: "unit-test"),
        answer: "Plain answer first.\n\nRule: conn-019\nAdam Pattern Step: 5"
    )
    let service = HarnessRunService(
        ledger: ledger,
        authorityRetriever: OntologyAuthorityRetriever(sparqlEndpoint: URL(string: "http://127.0.0.1:9/understood/sparql")!),
        memoryRetriever: StaticMemoryRetriever(hit: .init(
            source: "obsidian://test",
            excerpt: "Supporting note only.",
            score: 0.8,
            reasonSelected: "token overlap",
            authorityLevel: .supporting
        )),
        graphHealthChecker: StaticGraphHealthChecker(report: .unavailableFixture)
    )

    let detail = try await service.createRun(
        prompt: "How should I use leverage and reusable systems?",
        ontology: ontology,
        backend: backend
    )

    #expect(detail.authorityHits.contains { $0.subject.contains("conn-019") })
    #expect(detail.memoryHits.count == 1)
    #expect(detail.run.backend == "Codex")
    #expect(detail.run.modelName == "test-codex")
    #expect(detail.traceEvents.map(\.stage) == [
        .createRun,
        .graphHealth,
        .authorityRetrieval,
        .supportingRetrieval,
        .modelExecution,
        .evaluation,
        .traceSaved
    ])
}

@Test func promptPacketCompilesCodingPolicyFromAcceptedOntology() {
    let ontology = OntologyLoader.load()
    let packet = PromptPacketBuilder.makePacket(
        prompt: "Implement the next coding agent feature.",
        ontology: ontology,
        authorityHits: [],
        memoryHits: []
    )

    #expect(packet.system.contains("RDF POLICY DIRECTIVES"))
    #expect(packet.system.contains("Policy: reusable-systems"))
    #expect(packet.system.contains("Rule: conn-019"))
    #expect(packet.system.contains("Prefer reusable systems over one-time wins"))
}

@Test func answerEvalRequiresReusableSystemsPolicyMarkerWhenPolicyApplies() {
    let evaluator = DeterministicAnswerEvaluator()
    let authorityHit = GraphAuthorityHit(
        subject: "understood:connection/conn-019",
        predicate: "understood:label",
        object: "Adam prefers reusable systems over one-time wins. When there's a choice, build what compounds.",
        source: "unit-test accepted graph",
        queryTrace: "unit-test",
        authorityLevel: .accepted,
        score: 1
    )

    let missing = evaluator.evaluate(
        answer: "Plain answer first.\n\nRule: conn-019\nAdam Pattern Step: 5",
        authorityHits: [authorityHit],
        memoryHits: [],
        prompt: "Implement the next coding agent feature.",
        runId: "run-policy-missing"
    )
    #expect(missing.contains { $0.checkName == "policy-reusable-systems" && !$0.passed })

    let present = evaluator.evaluate(
        answer: "Plain answer first.\n\nPolicy: reusable-systems\nRule: conn-019\nAdam Pattern Step: 5",
        authorityHits: [authorityHit],
        memoryHits: [],
        prompt: "Implement the next coding agent feature.",
        runId: "run-policy-present"
    )
    #expect(present.contains { $0.checkName == "policy-reusable-systems" && $0.passed })
}

@Test func runRecordsWarningWhenAcceptedNamedGraphIsMissing() async throws {
    let ontology = OntologyLoader.load()
    let ledger = try RunLedgerStore.inMemory()
    let backend = StaticBackendAdapter(
        metadata: .init(backend: .codex, modelName: "test-codex", invocationMethod: "unit-test"),
        answer: "Plain answer first.\n\nRule: conn-019\nAdam Pattern Step: 1"
    )
    let service = HarnessRunService(
        ledger: ledger,
        authorityRetriever: OntologyAuthorityRetriever(sparqlEndpoint: URL(string: "http://127.0.0.1:9/understood/sparql")!),
        memoryRetriever: StaticMemoryRetriever(hit: nil),
        graphHealthChecker: StaticGraphHealthChecker(report: GraphHealthReport(
            status: .missingAcceptedNamedGraph,
            acceptedGraphIRI: "https://understood.app/graph/accepted",
            sparqlEndpoint: "http://example.invalid/understood/sparql",
            namedGraphCount: 0,
            defaultGraphTripleCount: 334_931,
            detail: "Accepted named graph is missing; default graph has 334931 triples and must not be treated as authority."
        ))
    )

    let detail = try await service.createRun(
        prompt: "Explain the Fuseki caveat.",
        ontology: ontology,
        backend: backend
    )

    #expect(detail.traceEvents.contains { $0.stage == .graphHealth && $0.message.contains("default graph has 334931") })
    #expect(detail.evalResults.contains { $0.checkName == "graph-health-accepted-named-graph" && !$0.passed })
    #expect(detail.evalResults.contains { $0.detail.contains("must not be treated as authority") })
}

@Test func candidateMemoryDoesNotBecomeAcceptedAuthority() async throws {
    let ontology = OntologyLoader.load()
    let ledger = try RunLedgerStore.inMemory()
    let backend = StaticBackendAdapter(
        metadata: .init(backend: .claude, modelName: "test-claude", invocationMethod: "unit-test"),
        answer: "Plain answer first.\n\nRule: none\nAdam Pattern Step: none"
    )
    let service = HarnessRunService(
        ledger: ledger,
        authorityRetriever: OntologyAuthorityRetriever(),
        memoryRetriever: StaticMemoryRetriever(hit: nil)
    )

    let detail = try await service.createRun(
        prompt: "Remember that I prefer graph-backed answers before model guesses.",
        ontology: ontology,
        backend: backend
    )

    #expect(detail.memoryCandidates.count == 1)
    #expect(detail.memoryCandidates.first?.status == .suggested)
    #expect(detail.authorityHits.allSatisfy { $0.authorityLevel == .accepted })
    #expect(detail.memoryCandidates.first?.status != .accepted)
}

@Test func candidateStatusUpdatesPersistWithoutPromotingAuthority() async throws {
    let ontology = OntologyLoader.load()
    let ledger = try RunLedgerStore.inMemory()
    let backend = StaticBackendAdapter(
        metadata: .init(backend: .claude, modelName: "test-claude", invocationMethod: "unit-test"),
        answer: "Plain answer first.\n\nRule: none\nAdam Pattern Step: none"
    )
    let service = HarnessRunService(
        ledger: ledger,
        authorityRetriever: OntologyAuthorityRetriever(),
        memoryRetriever: StaticMemoryRetriever(hit: nil)
    )

    let detail = try await service.createRun(
        prompt: "Remember that candidate memories require review before graph promotion.",
        ontology: ontology,
        backend: backend
    )
    let candidate = try #require(detail.memoryCandidates.first)

    try await ledger.updateCandidateStatus(
        id: candidate.id,
        status: .candidate,
        validationResult: "Marked for review."
    )
    let candidateReview = try #require(try await ledger.runDetail(id: detail.run.id))
    #expect(candidateReview.memoryCandidates.first?.status == .candidate)
    #expect(candidateReview.memoryCandidates.first?.validationResult == "Marked for review.")
    #expect(candidateReview.authorityHits.allSatisfy { $0.authorityLevel == .accepted })

    try await ledger.updateCandidateStatus(
        id: candidate.id,
        status: .rejected,
        validationResult: "Rejected from review."
    )
    let rejectedReview = try #require(try await ledger.runDetail(id: detail.run.id))
    #expect(rejectedReview.memoryCandidates.first?.status == .rejected)
    #expect(rejectedReview.memoryCandidates.first?.validationResult == "Rejected from review.")
    #expect(rejectedReview.authorityHits.allSatisfy { $0.authorityLevel == .accepted })
    #expect(rejectedReview.memoryCandidates.first?.status != .accepted)
}

@Test func candidateGraphDraftCanBeMarkedValidatedWithoutAcceptedPromotion() async throws {
    let ontology = OntologyLoader.load()
    let ledger = try RunLedgerStore.inMemory()
    let backend = StaticBackendAdapter(
        metadata: .init(backend: .claude, modelName: "test-claude", invocationMethod: "unit-test"),
        answer: "Plain answer first.\n\nRule: none\nAdam Pattern Step: none"
    )
    let service = HarnessRunService(
        ledger: ledger,
        authorityRetriever: OntologyAuthorityRetriever(),
        memoryRetriever: StaticMemoryRetriever(hit: nil)
    )

    let detail = try await service.createRun(
        prompt: "Remember that graph claims need explicit review before promotion.",
        ontology: ontology,
        backend: backend
    )
    let candidate = try #require(detail.memoryCandidates.first)
    let proposedGraph = CandidateGraphDraftBuilder().draft(for: candidate)
    let validation = TurtleCandidateValidator().validate(candidate: MemoryCandidate(
        id: candidate.id,
        runId: candidate.runId,
        sourceRunIds: candidate.sourceRunIds,
        evidenceText: candidate.evidenceText,
        proposedClaim: candidate.proposedClaim,
        proposedGraph: proposedGraph,
        status: .candidate,
        validationResult: candidate.validationResult,
        createdAt: candidate.createdAt
    ))

    #expect(validation.passed)

    try await ledger.updateCandidateReview(
        id: candidate.id,
        status: .validated,
        proposedGraph: proposedGraph,
        validationResult: "Ready for graph review. Not accepted authority."
    )
    let loaded = try #require(try await ledger.runDetail(id: detail.run.id))
    let loadedCandidate = try #require(loaded.memoryCandidates.first)

    #expect(loadedCandidate.status == .validated)
    #expect(loadedCandidate.proposedGraph?.contains("urn:harness:proposedClaim") == true)
    #expect(loadedCandidate.validationResult == "Ready for graph review. Not accepted authority.")
    #expect(loaded.authorityHits.allSatisfy { $0.authorityLevel == .accepted })
    #expect(loadedCandidate.status != .accepted)
}

@Test func reviewQueueLoadsPendingClaimsFromCanonicalCandidatesFolder() async throws {
    let root = try makeReviewQueueFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ReviewQueueStore(
        ontologyRoot: root,
        ledger: try RunLedgerStore.inMemory(),
        turtleParser: AcceptingTurtleParser(),
        acceptedGraphPoster: NoopAcceptedGraphPoster()
    )

    let pending = try await store.loadPendingClaims()
    let claim = try #require(pending.first)

    #expect(pending.count == 1)
    #expect(claim.id == "cand-seed-001")
    #expect(claim.plainEnglish == "Focus and Sleep rise together in the same week.")
    #expect(claim.evidenceNote == "Seed evidence for app review.")
    #expect(claim.sourceRef == "Harness Review Queue Seed, 2026-07-01")
    #expect(claim.strength == 0.42)
}

@Test func pythonSHACLValidatorDiscoversHarnessRootFromSourcePath() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("HarnessRootDiscovery-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let scripts = root.appendingPathComponent("scripts", isDirectory: true)
    let sourceDir = root.appendingPathComponent("Packages/OntologyKit/Sources/OntologyKit", isDirectory: true)
    try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
    try "".write(to: scripts.appendingPathComponent("validate_connection_turtle.py"), atomically: true, encoding: .utf8)

    let roots = PythonSHACLConnectionValidator.repositoryRootCandidates(
        sourceFilePath: sourceDir.appendingPathComponent("ReviewQueueStore.swift").path
    )

    #expect(roots.contains(root.standardizedFileURL))
}

@Test func pythonSHACLValidatorRunsWithDefaultRepoResolutionWhenAvailable() throws {
    let roots = PythonSHACLConnectionValidator.repositoryRootCandidates()
    guard roots.contains(where: {
        FileManager.default.isExecutableFile(atPath: $0.appendingPathComponent(".venv/bin/python").path)
            || FileManager.default.isExecutableFile(atPath: $0.appendingPathComponent(".venv/bin/python3").path)
    }) else {
        return
    }

    let turtle = """
    @prefix understood: <https://understood.app/ontology#> .
    @prefix xsd: <http://www.w3.org/2001/XMLSchema#> .

    <https://understood.app/ontology/connection/conn-test-validator-resolution> a understood:Connection ;
      understood:label "Validator resolution test" ;
      understood:connectionType "observed_correlation" ;
      understood:inLifeDomain <https://understood.app/ontology/domain/sleep> ;
      understood:inLifeDomain <https://understood.app/ontology/domain/health> ;
      understood:strength "0.50"^^xsd:decimal ;
      understood:frequency "sometimes" ;
      understood:evidenceNote "Local resolver regression test." ;
      understood:acceptedAt "2026-07-02T00:00:00Z"^^xsd:dateTime ;
      .
    """

    try PythonSHACLConnectionValidator().parse(turtle)
}

@Test func reviewQueueSometimesAppendsAcceptedConnectionAndLogsDecision() async throws {
    let root = try makeReviewQueueFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let ledger = try RunLedgerStore.inMemory()
    let store = ReviewQueueStore(
        ontologyRoot: root,
        ledger: ledger,
        turtleParser: AcceptingTurtleParser(),
        acceptedGraphPoster: NoopAcceptedGraphPoster()
    )

    let outcome = try await store.decide(claimId: "cand-seed-001", decision: .sometimes)
    let graph = try String(contentsOf: root.appendingPathComponent("accepted/accepted-graph.ttl"), encoding: .utf8)
    let reloaded = try await store.loadPendingClaims()
    let decisions = try await ledger.listReviewQueueDecisions()

    #expect(outcome.accepted)
    #expect(graph.contains("conn-obs-seed-001"))
    #expect(graph.contains(#"understood:frequency "sometimes""#))
    #expect(graph.contains(#"understood:evidenceNote "Seed evidence for app review.""#))
    #expect(reloaded.isEmpty)
    #expect(decisions.count == 1)
    #expect(decisions.first?.claimId == "cand-seed-001")
    #expect(decisions.first?.decision == "accepted")
    #expect(decisions.first?.frequency == "sometimes")
}

@Test func reviewQueueMirrorsDecisionsToCanonicalJSONLedger() async throws {
    let root = try makeReviewQueueFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let ledger = try RunLedgerStore.inMemory()
    let store = ReviewQueueStore(
        ontologyRoot: root,
        ledger: ledger,
        turtleParser: AcceptingTurtleParser(),
        acceptedGraphPoster: NoopAcceptedGraphPoster()
    )

    _ = try await store.decide(claimId: "cand-seed-001", decision: .sometimes)

    let ledgerURL = root.appendingPathComponent("accepted/decision-ledger.json")
    let data = try Data(contentsOf: ledgerURL)
    let entries = try #require(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
    let entry = try #require(entries.first)
    let appRecord = try #require(try await ledger.listReviewQueueDecisions().first)

    #expect(entries.count == 1)
    #expect(entry["claim_id"] as? String == "cand-seed-001")
    #expect(entry["decision"] as? String == "accepted")
    #expect(entry["frequency"] as? String == "sometimes")
    #expect(entry["source"] as? String == "harness-app")
    #expect(entry["app_ledger_id"] as? String == appRecord.id)
}

@Test func reviewQueueCanAcceptClaimWithoutStrength() async throws {
    let root = try makeReviewQueueFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let queueURL = root.appendingPathComponent("candidates/queue.json")
    try """
    [
      {
        "id": "cand-clear-sign-2026-q3",
        "status": "pending",
        "plain": "Clear Sign for this season.",
        "evidence": "Defined before the fact.",
        "source": "Adam Pattern Step 7",
        "domain_a": "ambition",
        "domain_b": "social",
        "connection_type": "clear_sign_commitment"
      }
    ]
    """.write(to: queueURL, atomically: true, encoding: .utf8)
    let store = ReviewQueueStore(
        ontologyRoot: root,
        ledger: try RunLedgerStore.inMemory(),
        turtleParser: AcceptingTurtleParser(),
        acceptedGraphPoster: NoopAcceptedGraphPoster()
    )

    let pending = try await store.loadPendingClaims()
    let outcome = try await store.decide(claimId: "cand-clear-sign-2026-q3", decision: .yes)
    let graph = try String(contentsOf: root.appendingPathComponent("accepted/accepted-graph.ttl"), encoding: .utf8)

    #expect(pending.first?.strength == nil)
    #expect(outcome.accepted)
    #expect(graph.contains("conn-obs-clear-sign-2026-q3"))
    #expect(!graph.contains("understood:strength"))
}

@Test func reviewQueuePostsAcceptedTriplesToFusekiBestEffort() async throws {
    let root = try makeReviewQueueFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let poster = RecordingAcceptedGraphPoster()
    let store = ReviewQueueStore(
        ontologyRoot: root,
        ledger: try RunLedgerStore.inMemory(),
        turtleParser: AcceptingTurtleParser(),
        acceptedGraphPoster: poster
    )

    let outcome = try await store.decide(claimId: "cand-seed-001", decision: .yes)
    let posted = await poster.posted

    #expect(outcome.accepted)
    #expect(posted.count == 1)
    #expect(posted.first?.contains("@prefix understood:") == true)
    #expect(posted.first?.contains("conn-obs-seed-001") == true)
}

@Test func reviewQueueCanReplaceFusekiAcceptedNamedGraphFromSnapshot() async throws {
    let root = try makeReviewQueueFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let poster = RecordingAcceptedGraphPoster()
    let store = ReviewQueueStore(
        ontologyRoot: root,
        ledger: try RunLedgerStore.inMemory(),
        turtleParser: AcceptingTurtleParser(),
        acceptedGraphPoster: poster
    )

    try await store.syncAcceptedGraphSnapshot()
    let replaced = await poster.replaced

    #expect(replaced.count == 1)
    #expect(replaced.first?.contains("@prefix understood:") == true)
}

@Test func reviewQueueFusekiPostFailureDoesNotBlockFileAuthority() async throws {
    let root = try makeReviewQueueFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ReviewQueueStore(
        ontologyRoot: root,
        ledger: try RunLedgerStore.inMemory(),
        turtleParser: AcceptingTurtleParser(),
        acceptedGraphPoster: FailingAcceptedGraphPoster()
    )

    let outcome = try await store.decide(claimId: "cand-seed-001", decision: .yes)
    let graph = try String(contentsOf: root.appendingPathComponent("accepted/accepted-graph.ttl"), encoding: .utf8)
    let reloaded = try await store.loadPendingClaims()

    #expect(outcome.accepted)
    #expect(graph.contains("conn-obs-seed-001"))
    #expect(reloaded.isEmpty)
}

@Test func reviewQueueValidationFailureLeavesClaimPending() async throws {
    let root = try makeReviewQueueFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let ledger = try RunLedgerStore.inMemory()
    let store = ReviewQueueStore(
        ontologyRoot: root,
        ledger: ledger,
        turtleParser: RejectingTurtleParser(message: "Turtle did not parse."),
        acceptedGraphPoster: NoopAcceptedGraphPoster()
    )

    let outcome = try await store.decide(claimId: "cand-seed-001", decision: .yes)
    let graph = try String(contentsOf: root.appendingPathComponent("accepted/accepted-graph.ttl"), encoding: .utf8)
    let reloaded = try await store.loadPendingClaims()
    let decisions = try await ledger.listReviewQueueDecisions()

    #expect(!outcome.accepted)
    #expect(outcome.blockedReason == "Blocked: Turtle did not parse.")
    #expect(!graph.contains("conn-obs-seed-001"))
    #expect(reloaded.count == 1)
    #expect(reloaded.first?.validationResult == "Blocked: Turtle did not parse.")
    #expect(decisions.isEmpty)
}

@Test func reviewQueueSHACLFailureLeavesClaimPending() async throws {
    let root = try makeReviewQueueFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let ledger = try RunLedgerStore.inMemory()
    let store = ReviewQueueStore(
        ontologyRoot: root,
        ledger: ledger,
        turtleParser: RejectingTurtleParser(message: "missing life domain; strength must be a number from 0 to 1"),
        acceptedGraphPoster: NoopAcceptedGraphPoster()
    )

    let outcome = try await store.decide(claimId: "cand-seed-001", decision: .yes)
    let graph = try String(contentsOf: root.appendingPathComponent("accepted/accepted-graph.ttl"), encoding: .utf8)
    let reloaded = try await store.loadPendingClaims()

    #expect(!outcome.accepted)
    #expect(outcome.blockedReason == "Blocked: missing life domain; strength must be a number from 0 to 1")
    #expect(!graph.contains("conn-obs-seed-001"))
    #expect(reloaded.first?.validationResult == "Blocked: missing life domain; strength must be a number from 0 to 1")
}

@Test func answerEvalRequiresPatternStepAndWarnsOnExecutionWithoutObservation() {
    let evaluator = DeterministicAnswerEvaluator()

    let missing = evaluator.evaluate(
        answer: "Plain answer first.\n\nRule: none",
        authorityHits: [],
        memoryHits: [],
        runId: "run-pattern-missing"
    )
    #expect(missing.contains { $0.checkName == "pattern-step-named" && !$0.passed })

    let execution = evaluator.evaluate(
        answer: "Plain answer first.\n\nRule: none\nAdam Pattern Step: 5",
        authorityHits: [],
        memoryHits: [],
        runId: "run-pattern-execution"
    )
    #expect(execution.contains { $0.checkName == "pattern-step-named" && $0.passed })
    #expect(execution.contains { $0.checkName == "observational-zone-before-execution" && !$0.passed && $0.detail.contains("Warning") })
}

@Test func pyramidFormatEvalAcceptsCanonicalHeadings() {
    let evaluator = DeterministicAnswerEvaluator()
    let answer = """
    # This is the takeaway (Executive Conclusion)

    - First point.
    - Second point.

    # What changes now (Consequence)

    - Serious items first.

    # Do this next (Recommendation)

    Keep the next step short.

    # Details if needed (Supporting Evidence on Request)

    Rule: none
    Adam Pattern Step: none
    """

    let results = evaluator.evaluate(
        answer: answer,
        authorityHits: [],
        memoryHits: [],
        prompt: "Explain the pyramid format.",
        runId: "run-pyramid-happy"
    )

    #expect(results.contains { $0.checkName == "plain-answer-first" && $0.passed })
    #expect(results.contains { $0.checkName == "pyramid-format" && $0.passed })
}

@Test func pyramidFormatEvalRejectsWrongOrder() {
    let evaluator = DeterministicAnswerEvaluator()
    let answer = """
    # This is the takeaway (Executive Conclusion)

    # Do this next (Recommendation)

    Rule: none
    Adam Pattern Step: none

    # What changes now (Consequence)
    """

    let results = evaluator.evaluate(
        answer: answer,
        authorityHits: [],
        memoryHits: [],
        prompt: "Explain the pyramid format.",
        runId: "run-pyramid-order"
    )

    #expect(results.contains { $0.checkName == "pyramid-format" && !$0.passed })
}

@Test func pyramidFormatEvalRejectsLabelAtStart() {
    let evaluator = DeterministicAnswerEvaluator()
    let answer = """
    # (Executive Conclusion) This is the takeaway

    Rule: none
    Adam Pattern Step: none
    """

    let results = evaluator.evaluate(
        answer: answer,
        authorityHits: [],
        memoryHits: [],
        prompt: "Explain the pyramid format.",
        runId: "run-pyramid-label-start"
    )

    #expect(results.contains { $0.checkName == "pyramid-format" && !$0.passed })
}

@Test func pyramidFormatEvalExemptsCasualShortPrompts() {
    let evaluator = DeterministicAnswerEvaluator()
    let results = evaluator.evaluate(
        answer: "You're welcome.\n\nRule: none\nAdam Pattern Step: none",
        authorityHits: [],
        memoryHits: [],
        prompt: "thanks",
        runId: "run-pyramid-casual"
    )

    #expect(results.contains { $0.checkName == "pyramid-format" && $0.passed && $0.detail == "exempt-casual" })
}

@Test func runLedgerPersistsSearchableRunDetail() async throws {
    let ontology = OntologyLoader.load()
    let ledger = try RunLedgerStore.inMemory()
    let backend = StaticBackendAdapter(
        metadata: .init(backend: .grok, modelName: "test-grok", invocationMethod: "unit-test"),
        answer: "Plain answer first.\n\nRule: system-over-task\nAdam Pattern Step: 1"
    )
    let service = HarnessRunService(
        ledger: ledger,
        authorityRetriever: OntologyAuthorityRetriever(),
        memoryRetriever: StaticMemoryRetriever(hit: nil)
    )

    let saved = try await service.createRun(
        prompt: "Build the system instead of one task.",
        ontology: ontology,
        backend: backend
    )
    let loaded = try await ledger.runDetail(id: saved.run.id)
    let results = try await ledger.searchRuns("system")

    #expect(loaded?.run.id == saved.run.id)
    #expect(loaded?.messages.contains { $0.role == .assistant } == true)
    #expect(results.contains { $0.id == saved.run.id })
}

@Test func redactsSecretsBeforePersistence() async throws {
    let ontology = OntologyLoader.load()
    let ledger = try RunLedgerStore.inMemory()
    let backend = StaticBackendAdapter(
        metadata: .init(backend: .claude, modelName: "test-claude", invocationMethod: "unit-test"),
        answer: "Plain answer first.\n\nRule: none\nAdam Pattern Step: none"
    )
    let service = HarnessRunService(
        ledger: ledger,
        authorityRetriever: OntologyAuthorityRetriever(),
        memoryRetriever: StaticMemoryRetriever(hit: nil)
    )

    let detail = try await service.createRun(
        prompt: "My key is sk-ant-secret-value",
        ontology: ontology,
        backend: backend
    )
    let loaded = try #require(try await ledger.runDetail(id: detail.run.id))
    let persistedText = ([loaded.run.prompt, loaded.run.finalAnswer] + loaded.messages.map(\.text)).joined(separator: "\n")

    #expect(!persistedText.contains("sk-ant-secret-value"))
    #expect(persistedText.contains("[REDACTED_SECRET]"))
}

@Test func directoryMemoryPrefersProjectDocsOverGenericLibraryNotes() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("HarnessMemoryRetrieverTests-\(UUID().uuidString)", isDirectory: true)
    let docs = root.appendingPathComponent("Docs", isDirectory: true)
    let books = root.appendingPathComponent("ibooks", isDirectory: true)
    try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: books, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    try """
    Harness run ledger memory says graph-backed answers should separate accepted graph authority from supporting memory.
    Candidate review must not promote model guesses into accepted graph authority.
    """.write(to: docs.appendingPathComponent("harness-memory.md"), atomically: true, encoding: .utf8)

    try """
    A general book note mentions graph backed model guesses and memory but is not project context.
    """.write(to: books.appendingPathComponent("book-note.md"), atomically: true, encoding: .utf8)

    let retriever = DirectoryMemoryRetriever(roots: [root], maxFiles: 20)
    let hits = try await retriever.retrieve(
        prompt: "Remember that I prefer graph-backed answers before model guesses.",
        limit: 2
    )

    #expect(hits.first?.source.contains("Docs/harness-memory.md") == true)
    #expect(hits.first?.reasonSelected.contains("project-context") == true)
    #expect(hits.allSatisfy { !$0.source.contains("/ibooks/") })
}

@Test func directoryMemorySkipsHiddenBuildAndPackageArtifacts() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("HarnessMemorySkipTests-\(UUID().uuidString)", isDirectory: true)
    let build = root.appendingPathComponent("build", isDirectory: true)
    let hidden = root.appendingPathComponent(".cache", isDirectory: true)
    let docs = root.appendingPathComponent("Docs", isDirectory: true)
    try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    try "graph backed memory from a build artifact".write(
        to: build.appendingPathComponent("artifact.md"),
        atomically: true,
        encoding: .utf8
    )
    try "graph backed memory from a hidden cache".write(
        to: hidden.appendingPathComponent("cache.md"),
        atomically: true,
        encoding: .utf8
    )
    try "graph backed memory from Harness docs".write(
        to: docs.appendingPathComponent("memory.md"),
        atomically: true,
        encoding: .utf8
    )

    let retriever = DirectoryMemoryRetriever(roots: [root], maxFiles: 20)
    let hits = try await retriever.retrieve(prompt: "graph backed memory", limit: 5)

    #expect(hits.count == 1)
    #expect(hits.first?.source.contains("Docs/memory.md") == true)
}

@Test func localMemorySourceRegistryDiscoversPersonalSourceRoots() throws {
    let home = FileManager.default.temporaryDirectory
        .appendingPathComponent("HarnessLocalSourceRegistryTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: home) }

    let github = home.appendingPathComponent("Developer/GitHub", isDirectory: true)
    let obsidian = home.appendingPathComponent("Documents/Main", isDirectory: true)
    let notes = home.appendingPathComponent("Documents/Harness/Apple Notes Export", isDirectory: true)
    try FileManager.default.createDirectory(at: github, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: obsidian, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)

    let sources = LocalMemorySourceRegistry.defaultSources(homeDirectory: home)
    let existing = sources.filter(\.exists)

    #expect(existing.contains { $0.kind == .github && $0.root == github })
    #expect(existing.contains { $0.kind == .obsidian && $0.root == obsidian })
    #expect(existing.contains { $0.kind == .appleNotes && $0.root == notes })
}

@Test func directoryMemorySearchesGitHubObsidianAndAppleNotesSources() async throws {
    let home = FileManager.default.temporaryDirectory
        .appendingPathComponent("HarnessLocalSourceSearchTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: home) }

    let repo = home.appendingPathComponent("Developer/GitHub/UnderstoodSuite", isDirectory: true)
    let vault = home.appendingPathComponent("Documents/Main", isDirectory: true)
    let notes = home.appendingPathComponent("Documents/Harness/Apple Notes Export", isDirectory: true)
    try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)

    try "Understood suite marketing feature: graph authority and repo research workflow.".write(
        to: repo.appendingPathComponent("README.md"),
        atomically: true,
        encoding: .utf8
    )
    try "Understood suite market outline should explain ontology-backed judgement.".write(
        to: vault.appendingPathComponent("understood.md"),
        atomically: true,
        encoding: .utf8
    )
    try "Understood suite marketing note: make the product feel personal and useful.".write(
        to: notes.appendingPathComponent("positioning.txt"),
        atomically: true,
        encoding: .utf8
    )

    let sources = LocalMemorySourceRegistry.defaultSources(homeDirectory: home)
    let retriever = DirectoryMemoryRetriever(sources: sources, maxFiles: 50)
    let hits = try await retriever.retrieve(
        prompt: "Research the Understood suite and outline market features.",
        limit: 5
    )

    #expect(hits.contains { $0.reasonSelected.contains("local-source github") })
    #expect(hits.contains { $0.reasonSelected.contains("local-source obsidian") })
    #expect(hits.contains { $0.reasonSelected.contains("local-source apple-notes") })
}

@Test func appleNotesExporterBuildsAutomationScriptForExportFolder() {
    let output = URL(fileURLWithPath: "/tmp/Harness Apple Notes", isDirectory: true)
    let script = AppleNotesExporter.appleScript(outputDirectory: output)

    #expect(script.contains("tell application \"Notes\""))
    #expect(script.contains("/tmp/Harness Apple Notes"))
    #expect(script.contains(".html"))
    #expect(script.contains("exportedCount"))
}

@Test func connectorRegistrySurfacesSourcesSkillsPluginsAndAgentBridges() throws {
    let home = FileManager.default.temporaryDirectory
        .appendingPathComponent("HarnessConnectorRegistryTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: home) }

    let paths = [
        "Developer/GitHub",
        "Documents/Main",
        "Documents/Harness/Apple Notes Export",
        ".claude/skills",
        ".claude/plugins/cache/example-plugin/example/1.0.0",
        ".codex/skills",
        ".codex/plugins/cache/openai-curated/github/3fdeeb49",
        ".hermes/skills",
        ".hermes/hermes-agent/tools",
        ".hermes/ontology-steward"
    ]
    for path in paths {
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(path, isDirectory: true),
            withIntermediateDirectories: true
        )
    }

    let connectors = HarnessConnectorRegistry.defaultConnectors(homeDirectory: home)

    #expect(connectors.contains { $0.kind == .github && $0.role == .supportingMemory && $0.state == .available })
    #expect(connectors.contains { $0.kind == .obsidian && $0.role == .supportingMemory && $0.state == .available })
    #expect(connectors.contains { $0.kind == .appleNotes && $0.role == .supportingMemory && $0.state == .available })
    #expect(connectors.contains { $0.kind == .skillDirectory && $0.role == .proceduralMemory && $0.sourceSystem == "Claude" })
    #expect(connectors.contains { $0.kind == .pluginDirectory && $0.role == .plugin && $0.sourceSystem == "Codex" })
    #expect(connectors.contains { $0.kind == .agentBridge && $0.role == .toolBridge && $0.sourceSystem == "Hermes" })
    #expect(HarnessConnectorRegistry.memorySources(from: connectors).contains { $0.kind == .github })
}

@Test func capabilityRegistryDiscoversAgentSkillsAndPluginManifests() throws {
    let home = FileManager.default.temporaryDirectory
        .appendingPathComponent("HarnessCapabilityRegistryTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: home) }

    try writeSkill(
        home.appendingPathComponent(".hermes/skills/apple/apple-notes/SKILL.md"),
        name: "apple-notes",
        description: "Manage Apple Notes via memo CLI: create, search, edit."
    )
    try writeSkill(
        home.appendingPathComponent(".hermes/skills/autonomous-ai-agents/codex/SKILL.md"),
        name: "codex",
        description: "Delegate coding to OpenAI Codex CLI."
    )
    try writeSkill(
        home.appendingPathComponent(".claude/skills/research-response/SKILL.md"),
        name: "research-response",
        description: "Research responses matched to Adam's visual-first profile."
    )
    try writeSkill(
        home.appendingPathComponent(".agents/skills/firecrawl-deep-research/SKILL.md"),
        name: "firecrawl-deep-research",
        description: "Produce an intensive cited research report."
    )

    let claudePlugin = home.appendingPathComponent(".claude/plugins/cache/compound-engineering/compound-engineering/3.12.0/.claude-plugin/plugin.json")
    try FileManager.default.createDirectory(at: claudePlugin.deletingLastPathComponent(), withIntermediateDirectories: true)
    try """
    {
      "name": "compound-engineering",
      "version": "3.12.0",
      "description": "AI-powered development tools for code review, research, design, and workflow automation."
    }
    """.write(to: claudePlugin, atomically: true, encoding: .utf8)

    let codexPlugin = home.appendingPathComponent(".codex/plugins/cache/openai-curated/github/3fdeeb49/.app.json")
    try FileManager.default.createDirectory(at: codexPlugin.deletingLastPathComponent(), withIntermediateDirectories: true)
    try """
    {
      "name": "GitHub",
      "description": "Access repositories, issues, and pull requests."
    }
    """.write(to: codexPlugin, atomically: true, encoding: .utf8)

    let capabilities = HarnessCapabilityRegistry.defaultCapabilities(homeDirectory: home)

    #expect(capabilities.contains { $0.kind == .skill && $0.name == "apple-notes" && $0.category == "apple" && $0.sourceSystem == "Hermes" })
    #expect(capabilities.contains { $0.kind == .skill && $0.name == "research-response" && $0.sourceSystem == "Claude" })
    #expect(capabilities.contains { $0.kind == .skill && $0.name == "firecrawl-deep-research" && $0.sourceSystem == "Agents" })
    #expect(capabilities.contains { $0.kind == .plugin && $0.name == "compound-engineering" && $0.sourceSystem == "Claude" })
    #expect(capabilities.contains { $0.kind == .plugin && $0.name == "GitHub" && $0.sourceSystem == "Codex" })
    #expect(HarnessCapabilityRegistry.groupCounts(capabilities).contains { $0.key == "Hermes / apple" && $0.value == 1 })
}

@Test func executionRouterPlansGuardedPersonalKnowledgeResearch() throws {
    let home = FileManager.default.temporaryDirectory
        .appendingPathComponent("HarnessExecutionRouterTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: home) }

    for path in [
        "Developer/GitHub/Understood",
        "Documents/Main",
        "Documents/Harness/Apple Notes Export",
        ".hermes/skills/research/llm-wiki",
        ".claude/skills/research-response",
        ".agents/skills/firecrawl-deep-research",
        ".hermes/skills/autonomous-ai-agents/codex",
        ".claude/skills/web-artifacts-builder"
    ] {
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(path, isDirectory: true),
            withIntermediateDirectories: true
        )
    }
    try writeSkill(
        home.appendingPathComponent(".hermes/skills/research/llm-wiki/SKILL.md"),
        name: "llm-wiki",
        description: "Research and summarize AI topics."
    )
    try writeSkill(
        home.appendingPathComponent(".claude/skills/research-response/SKILL.md"),
        name: "research-response",
        description: "Source-rich research responses matched to Adam."
    )
    try writeSkill(
        home.appendingPathComponent(".agents/skills/firecrawl-deep-research/SKILL.md"),
        name: "firecrawl-deep-research",
        description: "Produce cited deep research."
    )
    try writeSkill(
        home.appendingPathComponent(".hermes/skills/autonomous-ai-agents/codex/SKILL.md"),
        name: "codex",
        description: "Delegate coding to OpenAI Codex CLI."
    )
    try writeSkill(
        home.appendingPathComponent(".claude/skills/web-artifacts-builder/SKILL.md"),
        name: "web-artifacts-builder",
        description: "Build polished web artifacts."
    )

    let connectors = HarnessConnectorRegistry.defaultConnectors(homeDirectory: home)
    let capabilities = HarnessCapabilityRegistry.defaultCapabilities(homeDirectory: home)
    let plan = HarnessExecutionRouter.plan(
        prompt: "Research the Understood suite in my GitHub repos and create an outline for marketing their features.",
        connectors: connectors,
        capabilities: capabilities
    )

    #expect(plan.steps.contains { $0.action == .inspectRepository && $0.targetName == "GitHub repositories" && $0.guardrail == .readOnly })
    #expect(plan.steps.contains { $0.action == .searchMemory && $0.targetName.contains("Obsidian") && $0.guardrail == .readOnly })
    #expect(plan.steps.contains { $0.action == .runSkill && $0.targetName == "research-response" && $0.guardrail == .readOnly })
    #expect(plan.steps.contains { $0.action == .runSkill && $0.targetName == "firecrawl-deep-research" && $0.guardrail == .approvalRequired })
    #expect(plan.steps.contains { $0.action == .createArtifact && $0.targetName == "web-artifacts-builder" })
    #expect(plan.steps.first?.action == .inspectRepository)
}

@Test func executionRouterRequiresApprovalForAppleNotesSyncAndAgentDelegation() throws {
    let home = FileManager.default.temporaryDirectory
        .appendingPathComponent("HarnessExecutionRouterApprovalTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: home) }

    for path in [
        "Developer/GitHub",
        ".hermes/skills/apple/apple-notes",
        ".hermes/skills/autonomous-ai-agents/claude-code",
        ".hermes/skills/autonomous-ai-agents/codex"
    ] {
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(path, isDirectory: true),
            withIntermediateDirectories: true
        )
    }
    try writeSkill(
        home.appendingPathComponent(".hermes/skills/apple/apple-notes/SKILL.md"),
        name: "apple-notes",
        description: "Manage Apple Notes via memo CLI: create, search, edit."
    )
    try writeSkill(
        home.appendingPathComponent(".hermes/skills/autonomous-ai-agents/claude-code/SKILL.md"),
        name: "claude-code",
        description: "Delegate coding to Claude Code CLI."
    )
    try writeSkill(
        home.appendingPathComponent(".hermes/skills/autonomous-ai-agents/codex/SKILL.md"),
        name: "codex",
        description: "Delegate coding to OpenAI Codex CLI."
    )

    let connectors = HarnessConnectorRegistry.defaultConnectors(homeDirectory: home)
    let capabilities = HarnessCapabilityRegistry.defaultCapabilities(homeDirectory: home)
    let plan = HarnessExecutionRouter.plan(
        prompt: "Sync Apple Notes, then delegate the repo implementation to Codex or Claude Code.",
        connectors: connectors,
        capabilities: capabilities
    )

    #expect(plan.requiresApproval)
    #expect(plan.steps.contains { $0.action == .syncSource && $0.targetName == "Apple Notes export" && $0.guardrail == .approvalRequired })
    #expect(plan.steps.contains { $0.action == .delegateAgent && $0.targetName == "codex" && $0.guardrail == .approvalRequired })
    #expect(plan.steps.contains { $0.action == .delegateAgent && $0.targetName == "claude-code" && $0.guardrail == .approvalRequired })
}

@Test func routeExecutorRunsReadOnlyLocalEvidenceSteps() async throws {
    let home = FileManager.default.temporaryDirectory
        .appendingPathComponent("HarnessRouteExecutorTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: home) }

    let repo = home.appendingPathComponent("Developer/GitHub/UnderstoodSuite", isDirectory: true)
    let vault = home.appendingPathComponent("Documents/Main", isDirectory: true)
    let notes = home.appendingPathComponent("Documents/Harness/Apple Notes Export", isDirectory: true)
    try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)

    try "Understood suite feature: repo inspection explains graph authority and agent routing.".write(
        to: repo.appendingPathComponent("README.md"),
        atomically: true,
        encoding: .utf8
    )
    try "Understood suite note: marketing should lead with personalized judgement.".write(
        to: vault.appendingPathComponent("positioning.md"),
        atomically: true,
        encoding: .utf8
    )
    try "Understood suite Apple Notes capture: explain safe local execution.".write(
        to: notes.appendingPathComponent("capture.txt"),
        atomically: true,
        encoding: .utf8
    )

    let connectors = HarnessConnectorRegistry.defaultConnectors(homeDirectory: home)
    let capabilities = HarnessCapabilityRegistry.defaultCapabilities(homeDirectory: home)
    let plan = HarnessExecutionRouter.plan(
        prompt: "Research the Understood suite from my GitHub repos, notes, and Obsidian.",
        connectors: connectors,
        capabilities: capabilities
    )

    let result = try await HarnessRouteExecutor(
        connectors: connectors,
        memoryLimitPerStep: 3,
        maxFiles: 40
    ).executeReadOnly(plan)

    #expect(result.executedSteps.contains { $0.action == .inspectRepository })
    #expect(result.executedSteps.contains { $0.action == .searchMemory })
    #expect(result.memoryHits.contains { $0.reasonSelected.contains("local-source github") })
    #expect(result.memoryHits.contains { $0.reasonSelected.contains("local-source obsidian") })
    #expect(result.memoryHits.contains { $0.reasonSelected.contains("local-source apple-notes") })
    #expect(result.blockedSteps.allSatisfy { $0.guardrail != .readOnly })
}

@Test func routeExecutorBlocksApprovalRequiredSteps() async throws {
    let home = FileManager.default.temporaryDirectory
        .appendingPathComponent("HarnessRouteExecutorBlockTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: home) }

    for path in [
        "Developer/GitHub",
        ".hermes/skills/autonomous-ai-agents/codex",
        ".hermes/skills/apple/apple-notes"
    ] {
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(path, isDirectory: true),
            withIntermediateDirectories: true
        )
    }
    try writeSkill(
        home.appendingPathComponent(".hermes/skills/autonomous-ai-agents/codex/SKILL.md"),
        name: "codex",
        description: "Delegate coding to OpenAI Codex CLI."
    )
    try writeSkill(
        home.appendingPathComponent(".hermes/skills/apple/apple-notes/SKILL.md"),
        name: "apple-notes",
        description: "Manage Apple Notes via memo CLI."
    )

    let connectors = HarnessConnectorRegistry.defaultConnectors(homeDirectory: home)
    let capabilities = HarnessCapabilityRegistry.defaultCapabilities(homeDirectory: home)
    let plan = HarnessExecutionRouter.plan(
        prompt: "Sync Apple Notes and delegate implementation to Codex.",
        connectors: connectors,
        capabilities: capabilities
    )

    let result = try await HarnessRouteExecutor(connectors: connectors).executeReadOnly(plan)

    #expect(result.blockedSteps.contains { $0.action == .syncSource && $0.targetName == "Apple Notes export" })
    #expect(result.blockedSteps.contains { $0.action == .delegateAgent && $0.targetName == "codex" })
    #expect(!result.executedSteps.contains { $0.guardrail == .approvalRequired })
}

@Test func routeExecutorRunsApprovedAppleNotesSyncOnly() async throws {
    let home = FileManager.default.temporaryDirectory
        .appendingPathComponent("HarnessRouteExecutorApprovalTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: home) }

    for path in [
        "Developer/GitHub",
        ".hermes/skills/autonomous-ai-agents/codex"
    ] {
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(path, isDirectory: true),
            withIntermediateDirectories: true
        )
    }
    try writeSkill(
        home.appendingPathComponent(".hermes/skills/autonomous-ai-agents/codex/SKILL.md"),
        name: "codex",
        description: "Delegate coding to OpenAI Codex CLI."
    )

    let connectors = HarnessConnectorRegistry.defaultConnectors(homeDirectory: home)
    let capabilities = HarnessCapabilityRegistry.defaultCapabilities(homeDirectory: home)
    let plan = HarnessExecutionRouter.plan(
        prompt: "Sync Apple Notes and delegate implementation to Codex.",
        connectors: connectors,
        capabilities: capabilities
    )
    let syncStep = try #require(plan.steps.first { $0.action == .syncSource })
    let codexStep = try #require(plan.steps.first { $0.action == .delegateAgent })

    let result = try await HarnessRouteExecutor(connectors: connectors).executeApproved(
        plan,
        approvedStepIDs: [syncStep.id],
        appleNotesSync: { step in
            return AppleNotesExportResult(
                outputDirectory: URL(fileURLWithPath: "/tmp/Harness Notes"),
                exportedCount: step.targetName == "Apple Notes export" ? 3 : 0,
                rawOutput: "3"
            )
        }
    )

    #expect(result.executedSteps.contains { $0.id == syncStep.id })
    #expect(result.actionResults.contains { $0.stepID == syncStep.id && $0.summary.contains("3 notes") })
    #expect(result.blockedSteps.contains { $0.id == codexStep.id })
    #expect(!result.executedSteps.contains { $0.id == codexStep.id })
}

@Test func routeExecutorRunsApprovedCodexDelegation() async throws {
    let home = FileManager.default.temporaryDirectory
        .appendingPathComponent("HarnessRouteExecutorCodexTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: home) }

    for path in [
        "Developer/GitHub",
        ".hermes/skills/autonomous-ai-agents/codex",
        ".hermes/skills/autonomous-ai-agents/claude-code"
    ] {
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(path, isDirectory: true),
            withIntermediateDirectories: true
        )
    }
    try writeSkill(
        home.appendingPathComponent(".hermes/skills/autonomous-ai-agents/codex/SKILL.md"),
        name: "codex",
        description: "Delegate coding to OpenAI Codex CLI."
    )
    try writeSkill(
        home.appendingPathComponent(".hermes/skills/autonomous-ai-agents/claude-code/SKILL.md"),
        name: "claude-code",
        description: "Delegate coding to Claude Code CLI."
    )

    let connectors = HarnessConnectorRegistry.defaultConnectors(homeDirectory: home)
    let capabilities = HarnessCapabilityRegistry.defaultCapabilities(homeDirectory: home)
    let plan = HarnessExecutionRouter.plan(
        prompt: "Delegate implementation to Codex or Claude Code.",
        connectors: connectors,
        capabilities: capabilities
    )
    let codexStep = try #require(plan.steps.first { $0.action == .delegateAgent && $0.targetName == "codex" })
    let claudeStep = try #require(plan.steps.first { $0.action == .delegateAgent && $0.targetName == "claude-code" })

    let result = try await HarnessRouteExecutor(connectors: connectors).executeApproved(
        plan,
        approvedStepIDs: [codexStep.id],
        codexDelegate: { prompt in
            "Codex received: \(prompt)"
        }
    )

    #expect(result.executedSteps.contains { $0.id == codexStep.id })
    #expect(result.actionResults.contains { $0.stepID == codexStep.id && $0.summary.contains("Codex received") })
    #expect(result.blockedSteps.contains { $0.id == claudeStep.id })
    #expect(!result.executedSteps.contains { $0.id == claudeStep.id })
}

@Test func routeExecutorRunsApprovedClaudeAndHermesDelegation() async throws {
    let home = FileManager.default.temporaryDirectory
        .appendingPathComponent("HarnessRouteExecutorAgentTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: home) }

    for path in [
        "Developer/GitHub",
        ".hermes/skills/autonomous-ai-agents/claude-code",
        ".hermes/skills/autonomous-ai-agents/hermes-agent",
        ".hermes/skills/autonomous-ai-agents/codex"
    ] {
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(path, isDirectory: true),
            withIntermediateDirectories: true
        )
    }
    try writeSkill(
        home.appendingPathComponent(".hermes/skills/autonomous-ai-agents/claude-code/SKILL.md"),
        name: "claude-code",
        description: "Delegate coding to Claude Code CLI."
    )
    try writeSkill(
        home.appendingPathComponent(".hermes/skills/autonomous-ai-agents/hermes-agent/SKILL.md"),
        name: "hermes-agent",
        description: "Configure, extend, or contribute to Hermes Agent."
    )
    try writeSkill(
        home.appendingPathComponent(".hermes/skills/autonomous-ai-agents/codex/SKILL.md"),
        name: "codex",
        description: "Delegate coding to OpenAI Codex CLI."
    )

    let connectors = HarnessConnectorRegistry.defaultConnectors(homeDirectory: home)
    let capabilities = HarnessCapabilityRegistry.defaultCapabilities(homeDirectory: home)
    let plan = HarnessExecutionRouter.plan(
        prompt: "Delegate implementation to Claude Code and Hermes Agent.",
        connectors: connectors,
        capabilities: capabilities
    )
    let claudeStep = try #require(plan.steps.first { $0.action == .delegateAgent && $0.targetName == "claude-code" })
    let hermesStep = try #require(plan.steps.first { $0.action == .delegateAgent && $0.targetName == "hermes-agent" })
    let codexStep = try #require(plan.steps.first { $0.action == .delegateAgent && $0.targetName == "codex" })

    let result = try await HarnessRouteExecutor(connectors: connectors).executeApproved(
        plan,
        approvedStepIDs: [claudeStep.id, hermesStep.id],
        claudeDelegate: { prompt in
            "Claude received: \(prompt)"
        },
        hermesDelegate: { prompt in
            "Hermes received: \(prompt)"
        }
    )

    #expect(result.executedSteps.contains { $0.id == claudeStep.id })
    #expect(result.executedSteps.contains { $0.id == hermesStep.id })
    #expect(result.actionResults.contains { $0.stepID == claudeStep.id && $0.summary.contains("Claude received") })
    #expect(result.actionResults.contains { $0.stepID == hermesStep.id && $0.summary.contains("Hermes received") })
    #expect(result.blockedSteps.contains { $0.id == codexStep.id })
}

@Test func routeExecutorCreatesApprovedMarkdownArtifact() async throws {
    let home = FileManager.default.temporaryDirectory
        .appendingPathComponent("HarnessRouteExecutorArtifactTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: home) }

    let skill = home.appendingPathComponent(".claude/skills/web-artifacts-builder/SKILL.md")
    try writeSkill(
        skill,
        name: "web-artifacts-builder",
        description: "Build polished web artifacts."
    )

    let connectors = HarnessConnectorRegistry.defaultConnectors(homeDirectory: home)
    let capabilities = HarnessCapabilityRegistry.defaultCapabilities(homeDirectory: home)
    let plan = HarnessExecutionRouter.plan(
        prompt: "Create an outline for marketing the Understood suite.",
        connectors: connectors,
        capabilities: capabilities
    )
    let artifactStep = try #require(plan.steps.first { $0.action == .createArtifact })
    let outputDirectory = home.appendingPathComponent("Documents/Harness/Artifacts", isDirectory: true)

    let result = try await HarnessRouteExecutor(connectors: connectors).executeApproved(
        plan,
        approvedStepIDs: [artifactStep.id],
        artifactDirectory: outputDirectory
    )

    let action = try #require(result.actionResults.first { $0.stepID == artifactStep.id })
    let artifactURL = try #require(action.artifactURL)
    let text = try String(contentsOf: artifactURL, encoding: .utf8)

    #expect(result.executedSteps.contains { $0.id == artifactStep.id })
    #expect(artifactURL.path.hasPrefix(outputDirectory.path))
    #expect(text.contains("# Harness Artifact"))
    #expect(text.contains("Create an outline for marketing the Understood suite."))
    #expect(action.summary.contains(artifactURL.path))
}

@Test func routeExecutorRunsApprovedResearchSkills() async throws {
    let home = FileManager.default.temporaryDirectory
        .appendingPathComponent("HarnessRouteExecutorResearchTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: home) }

    try writeSkill(
        home.appendingPathComponent(".claude/skills/research-response/SKILL.md"),
        name: "research-response",
        description: "Source-rich research responses matched to Adam."
    )
    try writeSkill(
        home.appendingPathComponent(".agents/skills/firecrawl-deep-research/SKILL.md"),
        name: "firecrawl-deep-research",
        description: "Produce cited deep research."
    )

    let connectors = HarnessConnectorRegistry.defaultConnectors(homeDirectory: home)
    let capabilities = HarnessCapabilityRegistry.defaultCapabilities(homeDirectory: home)
    let plan = HarnessExecutionRouter.plan(
        prompt: "Research the Understood market and produce a concise synthesis.",
        connectors: connectors,
        capabilities: capabilities
    )
    let localResearch = try #require(plan.steps.first { $0.action == .runSkill && $0.targetName == "research-response" })
    let externalResearch = try #require(plan.steps.first { $0.action == .runSkill && $0.targetName == "firecrawl-deep-research" })

    let result = try await HarnessRouteExecutor(connectors: connectors).executeApproved(
        plan,
        approvedStepIDs: [localResearch.id],
        researchDelegate: { prompt in
            "Research brief: \(prompt)"
        }
    )

    #expect(result.executedSteps.contains { $0.id == localResearch.id })
    #expect(result.actionResults.contains { $0.stepID == localResearch.id && $0.summary.contains("Research brief") })
    #expect(result.blockedSteps.contains { $0.id == externalResearch.id })
}

@Test func routeExecutorIncludesResearchSkillInstructionContext() async throws {
    let home = FileManager.default.temporaryDirectory
        .appendingPathComponent("HarnessRouteExecutorResearchContextTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: home) }

    try writeSkill(
        home.appendingPathComponent(".claude/skills/research-response/SKILL.md"),
        name: "research-response",
        description: "Source-rich research responses matched to Adam."
    )
    let connectors = HarnessConnectorRegistry.defaultConnectors(homeDirectory: home)
    let capabilities = HarnessCapabilityRegistry.defaultCapabilities(homeDirectory: home)
    let plan = HarnessExecutionRouter.plan(
        prompt: "Research positioning for Harness.",
        connectors: connectors,
        capabilities: capabilities
    )
    let localResearch = try #require(plan.steps.first { $0.action == .runSkill && $0.targetName == "research-response" })

    let result = try await HarnessRouteExecutor(
        connectors: connectors,
        capabilities: capabilities
    ).executeApproved(
        plan,
        approvedStepIDs: [localResearch.id],
        researchDelegate: { prompt in
            prompt.contains("Source-rich research responses matched to Adam.")
                ? "Skill context present"
                : "Skill context missing"
        }
    )

    #expect(result.actionResults.contains { $0.stepID == localResearch.id && $0.summary == "Skill context present" })
}

@Test func routeExecutorRunsApprovedExternalResearchSkill() async throws {
    let home = FileManager.default.temporaryDirectory
        .appendingPathComponent("HarnessRouteExecutorExternalResearchTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: home) }

    try writeSkill(
        home.appendingPathComponent(".agents/skills/firecrawl-deep-research/SKILL.md"),
        name: "firecrawl-deep-research",
        description: "Produce cited deep research."
    )

    let connectors = HarnessConnectorRegistry.defaultConnectors(homeDirectory: home)
    let capabilities = HarnessCapabilityRegistry.defaultCapabilities(homeDirectory: home)
    let plan = HarnessExecutionRouter.plan(
        prompt: "Research competitors with deep web sources.",
        connectors: connectors,
        capabilities: capabilities
    )
    let externalResearch = try #require(plan.steps.first { $0.action == .runSkill && $0.targetName == "firecrawl-deep-research" })

    let result = try await HarnessRouteExecutor(connectors: connectors).executeApproved(
        plan,
        approvedStepIDs: [externalResearch.id],
        externalResearchDelegate: { prompt in
            "External research brief: \(prompt)"
        }
    )

    #expect(result.executedSteps.contains { $0.id == externalResearch.id })
    #expect(result.actionResults.contains { $0.stepID == externalResearch.id && $0.summary.contains("External research brief") })
}

private struct StaticMemoryRetriever: SupportingMemoryRetrieving {
    let hit: MemoryHit?

    func retrieve(prompt: String, limit: Int) async throws -> [MemoryHit] {
        hit.map { [$0] } ?? []
    }
}

private struct StaticBackendAdapter: ModelBackendAdapter {
    let metadata: BackendMetadata
    let answer: String

    func execute(packet: ModelPacket) async throws -> BackendResponse {
        BackendResponse(text: answer, tokenCount: 12, cost: nil)
    }
}

private func writeSkill(_ url: URL, name: String, description: String) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try """
    ---
    name: \(name)
    description: \(description)
    ---

    # \(name)
    """.write(to: url, atomically: true, encoding: .utf8)
}

private struct StaticGraphHealthChecker: GraphHealthChecking {
    let report: GraphHealthReport

    func checkAcceptedGraph() async -> GraphHealthReport {
        report
    }
}

private extension GraphHealthReport {
    static let unavailableFixture = GraphHealthReport(
        status: .unavailable,
        acceptedGraphIRI: "https://understood.app/graph/accepted",
        sparqlEndpoint: "http://127.0.0.1:9/understood/sparql",
        namedGraphCount: nil,
        defaultGraphTripleCount: nil,
        detail: "SPARQL graph health check unavailable in unit test."
    )
}

private func makeReviewQueueFixture() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("HarnessReviewQueueTests-\(UUID().uuidString)", isDirectory: true)
    let accepted = root.appendingPathComponent("accepted", isDirectory: true)
    let candidates = root.appendingPathComponent("candidates", isDirectory: true)
    try FileManager.default.createDirectory(at: accepted, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: candidates, withIntermediateDirectories: true)
    try """
    @prefix understood: <https://understood.app/ontology#> .
    @prefix xsd: <http://www.w3.org/2001/XMLSchema#> .

    """.write(to: accepted.appendingPathComponent("accepted-graph.ttl"), atomically: true, encoding: .utf8)
    try """
    [
      {
        "id": "cand-seed-001",
        "status": "pending",
        "plain": "Focus and Sleep rise together in the same week.",
        "evidence": "Seed evidence for app review.",
        "source": "Harness Review Queue Seed, 2026-07-01",
        "domain_a": "focus",
        "domain_b": "sleep",
        "strength": 0.42,
        "connection_type": "observed_correlation"
      },
      {
        "id": "cand-old-001",
        "status": "accepted",
        "plain": "Old accepted claim.",
        "evidence": "Old evidence.",
        "source": "Old source.",
        "domain_a": "old",
        "domain_b": "claim",
        "strength": 0.1,
        "connection_type": "observed_correlation"
      }
    ]
    """.write(to: candidates.appendingPathComponent("queue.json"), atomically: true, encoding: .utf8)
    return root
}

private struct AcceptingTurtleParser: TurtleParsing {
    func parse(_ turtle: String) throws {}
}

private struct RejectingTurtleParser: TurtleParsing {
    let message: String

    func parse(_ turtle: String) throws {
        throw TurtleParseError(message)
    }
}

private struct NoopAcceptedGraphPoster: AcceptedGraphPosting {
    func postAcceptedTriples(_ turtle: String) async throws {}
    func replaceAcceptedGraph(_ turtle: String) async throws {}
}

private actor RecordingAcceptedGraphPoster: AcceptedGraphPosting {
    private(set) var posted: [String] = []
    private(set) var replaced: [String] = []

    func postAcceptedTriples(_ turtle: String) async throws {
        posted.append(turtle)
    }

    func replaceAcceptedGraph(_ turtle: String) async throws {
        replaced.append(turtle)
    }
}

private struct FailingAcceptedGraphPoster: AcceptedGraphPosting {
    func postAcceptedTriples(_ turtle: String) async throws {
        throw URLError(.cannotConnectToHost)
    }

    func replaceAcceptedGraph(_ turtle: String) async throws {
        throw URLError(.cannotConnectToHost)
    }
}
