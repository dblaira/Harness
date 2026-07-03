import Foundation
#if os(iOS)
import UIKit
#endif

public struct HarnessRunService: Sendable {
    public let ledger: RunLedgerStore
    public let authorityRetriever: any AuthorityRetrieving
    public let memoryRetriever: any SupportingMemoryRetrieving
    public let graphHealthChecker: any GraphHealthChecking
    public let evaluator: any AnswerEvaluating
    public let candidateExtractor: any CandidateMemoryExtracting
    public let redactor: any SecretRedacting

    public init(
        ledger: RunLedgerStore,
        authorityRetriever: any AuthorityRetrieving = OntologyAuthorityRetriever(),
        memoryRetriever: any SupportingMemoryRetrieving = DirectoryMemoryRetriever(),
        graphHealthChecker: any GraphHealthChecking = FusekiGraphHealthChecker(),
        evaluator: any AnswerEvaluating = DeterministicAnswerEvaluator(),
        candidateExtractor: any CandidateMemoryExtracting = HeuristicCandidateMemoryExtractor(),
        redactor: any SecretRedacting = SecretRedactor()
    ) {
        self.ledger = ledger
        self.authorityRetriever = authorityRetriever
        self.memoryRetriever = memoryRetriever
        self.graphHealthChecker = graphHealthChecker
        self.evaluator = evaluator
        self.candidateExtractor = candidateExtractor
        self.redactor = redactor
    }

    public func createRun(prompt: String, ontology: Ontology, backend: any ModelBackendAdapter) async throws -> HarnessRunDetail {
        let runId = UUID().uuidString
        var trace: [TraceEvent] = [
            TraceEvent(runId: runId, stage: .createRun, message: "Created local Harness run.")
        ]

        let graphHealth = await graphHealthChecker.checkAcceptedGraph()
        trace.append(TraceEvent(runId: runId, stage: .graphHealth, message: "Graph health: \(graphHealth.detail)"))

        let authorityHits = try await authorityRetriever
            .retrieve(prompt: prompt, ontology: ontology, limit: 6)
            .map { $0.attached(to: runId) }
        trace.append(TraceEvent(runId: runId, stage: .authorityRetrieval, message: "Retrieved \(authorityHits.count) accepted graph authority hits."))

        let memoryHits = try await memoryRetriever
            .retrieve(prompt: prompt, limit: 5)
            .map { $0.attached(to: runId) }
        trace.append(TraceEvent(runId: runId, stage: .supportingRetrieval, message: "Retrieved \(memoryHits.count) supporting memory hits."))

        let packet = PromptPacketBuilder.makePacket(
            prompt: prompt,
            ontology: ontology,
            authorityHits: authorityHits,
            memoryHits: memoryHits
        )

        let start = Date()
        let response: BackendResponse
        let success: Bool
        do {
            response = try await backend.execute(packet: packet)
            success = true
            trace.append(TraceEvent(runId: runId, stage: .modelExecution, message: "Model call completed with \(backend.metadata.invocationMethod)."))
        } catch {
            response = BackendResponse(text: "Backend failed: \(error.localizedDescription)\n\nRule: none", tokenCount: nil, cost: nil)
            success = false
            trace.append(TraceEvent(runId: runId, stage: .modelExecution, message: "Model call failed: \(error.localizedDescription)"))
        }
        let duration = Date().timeIntervalSince(start)

        let redactedPrompt = redactor.redact(prompt)
        let redactedAnswer = redactor.redact(response.text)
        var evalResults = evaluator.evaluate(
            answer: redactedAnswer,
            authorityHits: authorityHits,
            memoryHits: memoryHits,
            prompt: redactedPrompt,
            runId: runId,
            policyDirectives: packet.policyDirectives
        )
        evalResults.insert(graphHealth.evalResult(runId: runId), at: 0)
        trace.append(TraceEvent(runId: runId, stage: .evaluation, message: "Evaluated \(evalResults.count) deterministic checks."))

        let candidates = candidateExtractor.candidates(
            prompt: prompt,
            response: response.text,
            runId: runId,
            redactor: redactor
        )
        let validations = candidates.map { TurtleCandidateValidator().validate(candidate: $0) }

        trace.append(TraceEvent(runId: runId, stage: .traceSaved, message: "Saved run trace to local ledger."))

        let run = HarnessRun(
            id: runId,
            prompt: redactedPrompt,
            backend: backend.metadata.backend.rawValue,
            modelName: backend.metadata.modelName,
            invocationMethod: backend.metadata.invocationMethod,
            promptPacketHash: packet.promptPacketHash,
            success: success,
            duration: duration,
            tokenCount: response.tokenCount,
            cost: response.cost,
            finalAnswer: redactedAnswer,
            deviceName: DeviceIdentity.currentName(),
            createdAt: Date()
        )
        let messages = [
            HarnessMessage(runId: runId, role: .user, text: redactedPrompt),
            HarnessMessage(runId: runId, role: .assistant, text: redactedAnswer)
        ]

        let detail = HarnessRunDetail(
            run: run,
            messages: messages,
            authorityHits: authorityHits,
            memoryHits: memoryHits,
            traceEvents: trace,
            evalResults: evalResults,
            memoryCandidates: candidates,
            validationResults: validations
        )
        try await ledger.save(detail)
        return detail
    }
}

enum DeviceIdentity {
    static func currentName() -> String {
        #if os(macOS)
        Host.current().localizedName ?? "Mac"
        #elseif os(iOS)
        UIDevice.current.name
        #else
        "Device"
        #endif
    }
}

public struct AgentRunnerBackendAdapter: ModelBackendAdapter {
    public let metadata: BackendMetadata
    private let backend: Backend
    private let apiKey: String?
    private let runner: AgentRunner

    public init(backend: Backend, apiKey: String? = nil, runner: AgentRunner = AgentRunner()) {
        self.backend = backend
        self.apiKey = apiKey
        self.runner = runner
        self.metadata = BackendMetadata(
            backend: backend,
            modelName: backend.defaultModelName,
            invocationMethod: backend.invocationMethod
        )
    }

    public func execute(packet: ModelPacket) async throws -> BackendResponse {
        let text = try await runner.run(
            backend: backend,
            system: packet.system,
            user: packet.userPrompt,
            apiKey: apiKey
        )
        return BackendResponse(text: text, tokenCount: nil, cost: nil)
    }
}

public extension Backend {
    var defaultModelName: String {
        switch self {
        case .codex: return "gpt-4.1"
        case .grok: return "grok-4.3"
        case .claude: return "claude-sonnet-4-20250514"
        case .hermes: return "hermes3:8b"
        }
    }

    var invocationMethod: String {
        switch self {
        case .codex: return "openai-api-or-local-cli"
        case .grok: return "xAI-api-or-local-cli"
        case .claude: return "https-api"
        case .hermes: return "local-http"
        }
    }
}
