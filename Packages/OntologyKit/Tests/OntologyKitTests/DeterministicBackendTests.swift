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
