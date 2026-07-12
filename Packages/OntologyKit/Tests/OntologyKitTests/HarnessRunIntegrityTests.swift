import Foundation
import Testing
@testable import OntologyKit

private struct IntegrityAuthorityRetriever: AuthorityRetrieving {
    func retrieve(prompt: String, ontology: Ontology, limit: Int) async throws -> [GraphAuthorityHit] { [] }
}

private struct IntegrityMemoryRetriever: SupportingMemoryRetrieving {
    func retrieve(prompt: String, limit: Int) async throws -> [MemoryHit] { [] }
}

private struct IntegrityGraphHealthChecker: GraphHealthChecking {
    func checkAcceptedGraph() async -> GraphHealthReport {
        GraphHealthReport(
            status: .unavailable,
            acceptedGraphIRI: "https://understood.app/graph/accepted",
            sparqlEndpoint: "unit-test",
            namedGraphCount: nil,
            defaultGraphTripleCount: nil,
            detail: "Graph health is not part of this unit test."
        )
    }
}

private func integrityService() throws -> HarnessRunService {
    HarnessRunService(
        ledger: try RunLedgerStore.inMemory(),
        authorityRetriever: IntegrityAuthorityRetriever(),
        memoryRetriever: IntegrityMemoryRetriever(),
        graphHealthChecker: IntegrityGraphHealthChecker()
    )
}

private struct IntegrityProviderError: LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
}

private struct ThrowingIntegrityBackend: ModelBackendAdapter {
    let metadata = BackendMetadata(
        backend: .grok,
        modelName: "error-fixture",
        invocationMethod: "unit-test"
    )
    let message: String

    func execute(packet: ModelPacket) async throws -> BackendResponse {
        throw IntegrityProviderError(message: message)
    }
}

private struct FixedIntegrityBackend: ModelBackendAdapter {
    let metadata = BackendMetadata(
        backend: .grok,
        modelName: "fixed-fixture",
        invocationMethod: "unit-test"
    )
    let response: BackendResponse

    func execute(packet: ModelPacket) async throws -> BackendResponse { response }
}

private actor CountingIntegrityBackend: ModelBackendAdapter {
    nonisolated let metadata = BackendMetadata(
        backend: .grok,
        modelName: "counting-fixture",
        invocationMethod: "unit-test"
    )
    private var calls = 0

    func execute(packet: ModelPacket) async throws -> BackendResponse {
        calls += 1
        return BackendResponse(text: "Provider should not run.", tokenCount: 99, cost: 1)
    }

    func callCount() -> Int { calls }
}

private actor UsageIntegrityBackend: ToolCapableModelBackend {
    nonisolated let metadata = BackendMetadata(
        backend: .grok,
        modelName: "usage-fixture",
        invocationMethod: "unit-test"
    )
    nonisolated let supportsTools = true
    private var call = 0

    func execute(packet: ModelPacket) async throws -> BackendResponse {
        try await execute(packet: packet, toolTranscript: [])
    }

    func execute(packet: ModelPacket, toolTranscript: [ToolLoopTurn]) async throws -> BackendResponse {
        defer { call += 1 }
        if call == 0 {
            return BackendResponse(
                text: "Checking available skills.",
                tokenCount: 11,
                cost: 0.01,
                toolCalls: [
                    ToolCallRequest(id: "skills-1", name: "skills_list", input: [:]),
                ]
            )
        }
        return BackendResponse(
            text: "Here is the completed answer.\n\nRule: none\nAdam Pattern Step: none",
            tokenCount: 7,
            cost: 0.02
        )
    }
}

private actor UsageThenAuthFailureBackend: ToolCapableModelBackend {
    nonisolated let metadata = BackendMetadata(
        backend: .grok,
        modelName: "usage-auth-fixture",
        invocationMethod: "unit-test"
    )
    nonisolated let supportsTools = true
    private var call = 0

    func execute(packet: ModelPacket) async throws -> BackendResponse {
        try await execute(packet: packet, toolTranscript: [])
    }

    func execute(packet: ModelPacket, toolTranscript: [ToolLoopTurn]) async throws -> BackendResponse {
        defer { call += 1 }
        if call == 0 {
            return BackendResponse(
                text: "Checking available skills.",
                tokenCount: 13,
                cost: 0.03,
                toolCalls: [
                    ToolCallRequest(id: "skills-auth-1", name: "skills_list", input: [:]),
                ]
            )
        }
        throw IntegrityProviderError(message: "request timed out after access token expired")
    }
}

private struct IntegrityNoopStager: MemoryCandidateStaging {
    func stageMemoryCandidate(_ candidate: MemoryCandidate) throws {}
}

private func integrityToolExecutor() -> ToolExecutor {
    let suiteName = "harness-run-integrity-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return ToolExecutor(
        configuration: .init(
            homeDirectory: FileManager.default.temporaryDirectory,
            shellTimeout: 1
        ),
        approvals: ToolApprovalStore(defaults: defaults),
        memoryStager: IntegrityNoopStager(),
        capabilitiesProvider: { [] }
    )
}

@Test func authorizationFailureWinsOverTimeoutPresentation() async throws {
    let detail = try await integrityService().createRun(
        prompt: "Answer the question.",
        ontology: .empty,
        backend: ThrowingIntegrityBackend(
            message: "request timed out after access token expired"
        )
    )

    #expect(!detail.run.success)
    #expect(detail.run.finalAnswer == "Backend failed: Grok authorization failed. Re-authorize Grok, then send again.")
    #expect(!detail.run.finalAnswer.lowercased().contains("timed out"))
    #expect(detail.memoryCandidates.isEmpty)
    #expect(detail.traceEvents.contains {
        $0.stage == .modelExecution && $0.message.contains("Grok authorization failed")
    })
}

@Test func terminalProgressOnlyTextIsNeverRecordedAsSuccess() async throws {
    let detail = try await integrityService().createRun(
        prompt: "How do I add a new belief?",
        ontology: .empty,
        backend: FixedIntegrityBackend(response: BackendResponse(
            text: "I'll load Adam's working patterns and the full prompt so I can answer from the real request.",
            tokenCount: 23,
            cost: 0.04
        ))
    )

    #expect(!detail.run.success)
    #expect(detail.run.finalAnswer == "Backend failed: Grok returned a progress update instead of a completed answer.")
    #expect(detail.run.tokenCount == 23)
    #expect(detail.run.cost == 0.04)
    #expect(detail.memoryCandidates.isEmpty)
    #expect(detail.traceEvents.contains { $0.message.contains("progress-only") })
}

@Test func toolLoopUsageIsAccumulatedAcrossEveryProviderRound() async throws {
    let detail = try await integrityService().createRun(
        prompt: "List skills, then answer.",
        ontology: .empty,
        backend: UsageIntegrityBackend(),
        tools: [HarnessToolCatalog.spec(named: "skills_list")!],
        toolExecutor: integrityToolExecutor()
    )

    #expect(detail.run.success)
    #expect(detail.run.tokenCount == 18)
    #expect(abs((detail.run.cost ?? 0) - 0.03) < 0.000_001)
}

@Test func toolLoopPreservesUsageBeforeAuthorizationFailure() async throws {
    let detail = try await integrityService().createRun(
        prompt: "List skills, then answer.",
        ontology: .empty,
        backend: UsageThenAuthFailureBackend(),
        tools: [HarnessToolCatalog.spec(named: "skills_list")!],
        toolExecutor: integrityToolExecutor()
    )

    #expect(!detail.run.success)
    #expect(detail.run.finalAnswer.contains("Grok authorization failed"))
    #expect(!detail.run.finalAnswer.lowercased().contains("timed out"))
    #expect(detail.run.tokenCount == 13)
    #expect(detail.run.cost == 0.03)
}

@Test func deterministicLocalAnswerSkipsProviderAndCandidateExtraction() async throws {
    let backend = CountingIntegrityBackend()
    let answer = "Open Candidates, choose Add Belief, review the wording, then approve it."
    let detail = try await integrityService().createRun(
        prompt: "How do I add a new belief?",
        ontology: .empty,
        backend: backend,
        localAnswer: answer
    )

    #expect(detail.run.success)
    #expect(detail.run.finalAnswer == answer)
    #expect(detail.run.tokenCount == 0)
    #expect(detail.run.cost == 0)
    #expect(detail.memoryCandidates.isEmpty)
    #expect(await backend.callCount() == 0)
    #expect(detail.traceEvents.contains {
        $0.stage == .modelExecution && $0.message.contains("provider execution skipped")
    })
}
