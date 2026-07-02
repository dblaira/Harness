import Foundation
import Testing
@testable import OntologyKit

@Test func claudeClientUsesCurrentDefaultModel() {
    #expect(ClaudeClient(apiKey: "test-key").model == "claude-sonnet-4-6")
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
        ))
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
        .authorityRetrieval,
        .supportingRetrieval,
        .modelExecution,
        .evaluation,
        .traceSaved
    ])
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
}

private actor RecordingAcceptedGraphPoster: AcceptedGraphPosting {
    private(set) var posted: [String] = []

    func postAcceptedTriples(_ turtle: String) async throws {
        posted.append(turtle)
    }
}

private struct FailingAcceptedGraphPoster: AcceptedGraphPosting {
    func postAcceptedTriples(_ turtle: String) async throws {
        throw URLError(.cannotConnectToHost)
    }
}
