import Foundation
import Testing
@testable import OntologyKit

@Test func authorityRetrievalPrecedesMemoryAndModel() async throws {
    let ontology = OntologyLoader.load()
    let ledger = try RunLedgerStore.inMemory()
    let backend = StaticBackendAdapter(
        metadata: .init(backend: .codex, modelName: "test-codex", invocationMethod: "unit-test"),
        answer: "Plain answer first.\n\nRule: conn-019"
    )
    let service = HarnessRunService(
        ledger: ledger,
        authorityRetriever: OntologyAuthorityRetriever(),
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
        answer: "Plain answer first.\n\nRule: none"
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
        answer: "Plain answer first.\n\nRule: none"
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
        answer: "Plain answer first.\n\nRule: none"
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

@Test func runLedgerPersistsSearchableRunDetail() async throws {
    let ontology = OntologyLoader.load()
    let ledger = try RunLedgerStore.inMemory()
    let backend = StaticBackendAdapter(
        metadata: .init(backend: .grok, modelName: "test-grok", invocationMethod: "unit-test"),
        answer: "Plain answer first.\n\nRule: system-over-task"
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
        answer: "Plain answer first with sk-ant-secret-value.\n\nRule: none"
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
