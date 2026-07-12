import Foundation
import Testing
@testable import OntologyKit

private struct DeadlineAuthorityRetriever: AuthorityRetrieving {
    func retrieve(prompt: String, ontology: Ontology, limit: Int) async throws -> [GraphAuthorityHit] {
        [
            GraphAuthorityHit(
                subject: "understood:axiom/capture-potential",
                predicate: "understood:label",
                object: "Products fight potential slipping away",
                source: "accepted graph fixture",
                queryTrace: "unit-test accepted graph lookup",
                authorityLevel: .accepted,
                score: 1
            ),
            GraphAuthorityHit(
                subject: "understood:candidate/unreviewed",
                predicate: "understood:label",
                object: "Unreviewed candidate must never be labeled accepted",
                source: "candidate fixture",
                queryTrace: "unit-test candidate leak defense",
                authorityLevel: .candidate,
                score: 2
            )
        ]
    }
}

private struct DeadlineMemoryRetriever: SupportingMemoryRetrieving {
    func retrieve(prompt: String, limit: Int) async throws -> [MemoryHit] { [] }
}

private enum UnexpectedMemoryRetrieval: Error {
    case called
}

private struct FailingIfCalledMemoryRetriever: SupportingMemoryRetrieving {
    func retrieve(prompt: String, limit: Int) async throws -> [MemoryHit] {
        throw UnexpectedMemoryRetrieval.called
    }
}

private struct DeadlineGraphHealthChecker: GraphHealthChecking {
    func checkAcceptedGraph() async -> GraphHealthReport {
        GraphHealthReport(
            status: .healthy,
            acceptedGraphIRI: "https://understood.app/graph/accepted",
            sparqlEndpoint: "unit-test",
            namedGraphCount: 1,
            defaultGraphTripleCount: 0,
            detail: "Accepted graph fixture is healthy."
        )
    }
}

private func deadlineService() throws -> HarnessRunService {
    HarnessRunService(
        ledger: try RunLedgerStore.inMemory(),
        authorityRetriever: DeadlineAuthorityRetriever(),
        memoryRetriever: DeadlineMemoryRetriever(),
        graphHealthChecker: DeadlineGraphHealthChecker()
    )
}

private actor CountingToolBackend: ToolCapableModelBackend {
    nonisolated let metadata = BackendMetadata(
        backend: .grok,
        modelName: "interactive-fixture",
        invocationMethod: "unit-test"
    )
    nonisolated let supportsTools = true

    private var directCalls = 0
    private var toolCalls = 0

    func counts() -> (direct: Int, tool: Int) {
        (directCalls, toolCalls)
    }

    func execute(packet: ModelPacket) async throws -> BackendResponse {
        directCalls += 1
        return BackendResponse(text: "Single-shot answer", tokenCount: nil, cost: nil)
    }

    func execute(packet: ModelPacket, toolTranscript: [ToolLoopTurn]) async throws -> BackendResponse {
        toolCalls += 1
        return BackendResponse(text: "Agentic answer", tokenCount: nil, cost: nil)
    }
}

private struct CooperativeStalledBackend: ModelBackendAdapter {
    let metadata = BackendMetadata(
        backend: .grok,
        modelName: "stalled-fixture",
        invocationMethod: "unit-test"
    )

    func execute(packet: ModelPacket) async throws -> BackendResponse {
        try await Task.sleep(for: .seconds(30))
        return BackendResponse(text: "Late answer", tokenCount: nil, cost: nil)
    }
}

@Test func toolCapableBackendWithEmptyCatalogRunsSingleShotOnce() async throws {
    let backend = CountingToolBackend()
    let detail = try await deadlineService().createRun(
        prompt: "What accepted information confirms the importance of capturing value?",
        ontology: .empty,
        backend: backend,
        tools: []
    )

    #expect(detail.run.success)
    #expect(detail.run.finalAnswer == "Single-shot answer")
    let counts = await backend.counts()
    #expect(counts.direct == 1)
    #expect(counts.tool == 0)
}

@Test func acceptedAuthorityOnlyRunSkipsSupportingMemoryEntirely() async throws {
    let prompt = "what information do I have approved already that confirms the importance of capturing value?"
    let service = HarnessRunService(
        ledger: try RunLedgerStore.inMemory(),
        authorityRetriever: DeadlineAuthorityRetriever(),
        memoryRetriever: FailingIfCalledMemoryRetriever(),
        graphHealthChecker: DeadlineGraphHealthChecker()
    )
    let backend = CountingToolBackend()

    let detail = try await service.createRun(
        prompt: prompt,
        ontology: .empty,
        backend: backend,
        includeSupportingMemory: !InteractiveChatPolicy.requestsAcceptedAuthorityOnly(prompt),
        answerFromAcceptedAuthority: true
    )

    #expect(detail.memoryHits.isEmpty)
    #expect(detail.run.success)
    #expect(detail.run.finalAnswer.contains("Products fight potential slipping away"))
    #expect(!detail.run.finalAnswer.contains("Unreviewed candidate"))
    #expect(detail.run.finalAnswer.contains("No supporting memory, candidates, or tool evidence were used."))
    #expect(!detail.run.finalAnswer.contains("Supporting memory (not accepted authority):"))
    let counts = await backend.counts()
    #expect(counts.direct == 0)
    #expect(counts.tool == 0)
    #expect(detail.traceEvents.contains {
        $0.stage == .supportingRetrieval && $0.message.contains("Skipped supporting memory")
    })
    #expect(detail.traceEvents.contains {
        $0.stage == .modelExecution && $0.message.contains("model execution skipped")
    })
}

@Test func responseDeadlineReturnsAcceptedEvidenceWhenProviderStalls() async throws {
    let monitor = ToolLoopMonitor(terminatesSubprocesses: false)
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .milliseconds(40))
    let started = clock.now

    let run = Task {
        try await deadlineService().createRun(
            prompt: "What approved information confirms capturing value?",
            ontology: .empty,
            backend: CooperativeStalledBackend(),
            toolLoop: monitor,
            interactiveDeadline: deadline
        )
    }

    try await Task.sleep(for: .milliseconds(60))
    monitor.exceedDeadline()
    let detail = try await run.value
    let elapsed = started.duration(to: clock.now)

    #expect(elapsed < .seconds(1))
    #expect(!detail.run.success)
    #expect(detail.run.finalAnswer.contains("12 seconds to protect the 15-second visible response ceiling"))
    #expect(detail.run.finalAnswer.contains("Products fight potential slipping away"))
    #expect(detail.run.finalAnswer.contains("Accepted graph authority:"))
    #expect(detail.memoryCandidates.isEmpty)
    #expect(monitor.progressSnapshot().phase == .deadlineExceeded)
    #expect(detail.traceEvents.contains {
        $0.stage == .modelExecution && $0.message.contains("deadline")
    })
}
