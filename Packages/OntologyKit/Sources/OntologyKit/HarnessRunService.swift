import Foundation
#if os(iOS)
import UIKit
#endif
#if canImport(Combine)
import Combine
#endif

// MARK: - ToolLoopMonitor

/// Observable window into a running tool loop: which iteration it is on,
/// which tool is executing, and a `cancel()` that aborts the loop's Task and
/// kills any CLI/shell subprocesses. Mirrors ToolApprovalStore's idiom —
/// `@Published` mutated on the main actor for SwiftUI, a lock-guarded
/// snapshot for deterministic reads.
public final class ToolLoopMonitor: ObservableObject, @unchecked Sendable {
    public enum Phase: String, Sendable, Equatable {
        case idle
        case callingModel
        case runningTool
        case finished
        case budgetExhausted
        case cancelled
        case failed
    }

    public struct Progress: Sendable, Equatable {
        public var iteration: Int
        public var maxIterations: Int
        public var currentTool: String?
        public var phase: Phase

        public init(iteration: Int = 0, maxIterations: Int = 30, currentTool: String? = nil, phase: Phase = .idle) {
            self.iteration = iteration
            self.maxIterations = maxIterations
            self.currentTool = currentTool
            self.phase = phase
        }
    }

    private let lock = NSLock()
    private var current = Progress()
    private var cancelled = false
    private var cancelHandlers: [@Sendable () -> Void] = []
    private let terminatesSubprocesses: Bool

    /// UI-facing mirror of the loop state; always mutated on the main actor.
    @Published public private(set) var progress = Progress()

    /// `terminatesSubprocesses: false` skips the global CLI-process kill on
    /// cancel — for tests, where the registry is shared and killing it would
    /// take out unrelated children. The app default stays true.
    public init(terminatesSubprocesses: Bool = true) {
        self.terminatesSubprocesses = terminatesSubprocesses
    }

    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    /// Lock-guarded snapshot (deterministic for tests; `progress` mirrors it
    /// asynchronously on the main actor).
    public func progressSnapshot() -> Progress {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    /// Abort: cancels the loop's Task (registered handlers) and terminates
    /// every live CLI/shell child process. A tool call already suspended on
    /// an approval card stays pending until Adam decides — the law's queue is
    /// never silently drained.
    public func cancel() {
        lock.lock()
        guard !cancelled else {
            lock.unlock()
            return
        }
        cancelled = true
        current.phase = .cancelled
        let handlers = cancelHandlers
        cancelHandlers = []
        let snapshot = current
        lock.unlock()
        publish(snapshot)
        for handler in handlers { handler() }
        #if os(macOS)
        if terminatesSubprocesses {
            AgentRunner.terminateRunningProcesses()
        }
        #endif
    }

    /// Register work to abort when Adam cancels (the run service registers
    /// its loop Task here). Fires immediately if already cancelled.
    public func registerCancelHandler(_ handler: @escaping @Sendable () -> Void) {
        lock.lock()
        if cancelled {
            lock.unlock()
            handler()
            return
        }
        cancelHandlers.append(handler)
        lock.unlock()
    }

    func update(_ mutate: (inout Progress) -> Void) {
        lock.lock()
        guard !cancelled else {
            lock.unlock()
            return
        }
        mutate(&current)
        let snapshot = current
        lock.unlock()
        publish(snapshot)
    }

    private func publish(_ snapshot: Progress) {
        Task { @MainActor [weak self] in
            self?.progress = snapshot
        }
    }
}

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

    /// Run one prompt. When `tools` + `toolExecutor` are provided AND the
    /// backend speaks native tool calls, this becomes the agentic loop:
    /// while the model returns tool calls (up to `maxToolIterations`), each
    /// call is classified by the bouncer (dangerous calls suspend on Adam's
    /// approve/deny card), executed, and fed back. Backends without native
    /// tools degrade to single-shot — nothing else changes for them.
    public func createRun(
        prompt: String,
        ontology: Ontology,
        backend: any ModelBackendAdapter,
        images: [ModelImageAttachment] = [],
        conversationHistory: [ConversationTurn] = [],
        soul: SoulDocument? = SoulLoader.load(),
        tools: [ToolSpec] = [],
        toolExecutor: ToolExecutor? = nil,
        toolLoop: ToolLoopMonitor? = nil,
        maxToolIterations: Int = 30,
        sessionId: String = PromptAssembler.defaultSessionId
    ) async throws -> HarnessRunDetail {
        let runId = UUID().uuidString
        var trace: [TraceEvent] = [
            TraceEvent(runId: runId, stage: .createRun, message: "Created local Harness run.")
        ]

        if let soul {
            trace.append(TraceEvent(
                runId: runId,
                stage: .soulLoad,
                message: "Loaded SOUL.md from \(soul.path) (\(soul.wordCount) words)."
            ))
        } else {
            trace.append(TraceEvent(
                runId: runId,
                stage: .soulLoad,
                message: "No SOUL.md found; identity anchor skipped."
            ))
        }

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
            memoryHits: memoryHits,
            soul: soul,
            conversationHistory: conversationHistory,
            images: images,
            sessionId: sessionId
        ).withTools(tools)

        let start = Date()
        let response: BackendResponse
        let success: Bool
        if !tools.isEmpty,
           let toolExecutor,
           let toolBackend = backend as? ToolCapableModelBackend,
           toolBackend.supportsTools {
            // The loop runs in its own Task so ToolLoopMonitor.cancel() can
            // abort an in-flight model call, not just poll between steps.
            let service = self
            let capturedPacket = packet
            let loopTask = Task {
                await service.runToolLoop(
                    runId: runId,
                    packet: capturedPacket,
                    backend: toolBackend,
                    executor: toolExecutor,
                    monitor: toolLoop,
                    maxIterations: maxToolIterations
                )
            }
            toolLoop?.registerCancelHandler { loopTask.cancel() }
            let outcome = await loopTask.value
            response = outcome.response
            success = outcome.success
            trace.append(contentsOf: outcome.events)
            trace.append(TraceEvent(runId: runId, stage: .modelExecution, message: outcome.executionMessage))
        } else {
            do {
                response = try await backend.execute(packet: packet)
                success = true
                trace.append(TraceEvent(runId: runId, stage: .modelExecution, message: "Model call completed with \(backend.metadata.invocationMethod)."))
            } catch {
                response = BackendResponse(text: "Backend failed: \(error.localizedDescription)\n\nRule: none", tokenCount: nil, cost: nil)
                success = false
                trace.append(TraceEvent(runId: runId, stage: .modelExecution, message: "Model call failed: \(error.localizedDescription)"))
            }
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

    // MARK: - The agentic tool loop

    private struct ToolLoopOutcome: Sendable {
        let response: BackendResponse
        let success: Bool
        let events: [TraceEvent]
        let executionMessage: String
    }

    /// "Agents propose. The bouncer checks. You decide." — every tool call
    /// the model makes goes through ToolExecutor, which routes mutations to
    /// the ToolApprovalStore; a dangerous call suspends HERE (inside
    /// `executor.execute`) until Adam approves or denies. A denial comes back
    /// as an error tool result and the loop continues, so the model can
    /// propose a different approach instead of dying.
    private func runToolLoop(
        runId: String,
        packet: ModelPacket,
        backend: any ToolCapableModelBackend,
        executor: ToolExecutor,
        monitor: ToolLoopMonitor?,
        maxIterations: Int
    ) async -> ToolLoopOutcome {
        var events: [TraceEvent] = []
        var transcript: [ToolLoopTurn] = []
        var iteration = 0
        // Some models re-issue an identical tool call after it already
        // succeeded (a benign re-loop). Re-running it would spawn a second
        // approval card for the same action and could loop to the budget. So a
        // repeat of an identical (name + input) call this run returns the prior
        // result with a "you already did this" note — never re-executed, never
        // re-prompted. The bouncer still gates every genuinely-new call.
        var executedCalls: [String: ToolResult] = [:]
        monitor?.update {
            $0.iteration = 0
            $0.maxIterations = maxIterations
            $0.currentTool = nil
            $0.phase = .callingModel
        }

        while true {
            if Task.isCancelled || monitor?.isCancelled == true {
                return ToolLoopOutcome(
                    response: BackendResponse(
                        text: "Run cancelled by Adam before the model finished.",
                        tokenCount: nil,
                        cost: nil
                    ),
                    success: false,
                    events: events,
                    executionMessage: "Tool loop cancelled during iteration \(iteration)."
                )
            }

            let response: BackendResponse
            do {
                response = try await backend.execute(packet: packet, toolTranscript: transcript)
            } catch {
                if Task.isCancelled || monitor?.isCancelled == true {
                    return ToolLoopOutcome(
                        response: BackendResponse(
                            text: "Run cancelled by Adam before the model finished.",
                            tokenCount: nil,
                            cost: nil
                        ),
                        success: false,
                        events: events,
                        executionMessage: "Tool loop cancelled during iteration \(iteration)."
                    )
                }
                monitor?.update { $0.phase = .failed }
                return ToolLoopOutcome(
                    response: BackendResponse(
                        text: "Backend failed: \(error.localizedDescription)\n\nRule: none",
                        tokenCount: nil,
                        cost: nil
                    ),
                    success: false,
                    events: events,
                    executionMessage: "Model call failed in tool loop (iteration \(iteration)): \(error.localizedDescription)"
                )
            }

            guard !response.toolCalls.isEmpty else {
                monitor?.update {
                    $0.currentTool = nil
                    $0.phase = .finished
                }
                return ToolLoopOutcome(
                    response: response,
                    success: true,
                    events: events,
                    executionMessage: "Tool loop completed after \(iteration) tool iteration(s) with \(backend.metadata.invocationMethod)."
                )
            }

            guard iteration < maxIterations else {
                monitor?.update { $0.phase = .budgetExhausted }
                events.append(TraceEvent(
                    runId: runId,
                    stage: .toolCall,
                    message: "Iteration budget of \(maxIterations) reached; \(response.toolCalls.count) pending tool call(s) were not executed."
                ))
                let text = response.text.isEmpty
                    ? "Tool loop stopped: the iteration budget of \(maxIterations) was reached before a final answer."
                    : response.text + "\n\n[Tool loop stopped: the iteration budget of \(maxIterations) was reached.]"
                return ToolLoopOutcome(
                    response: BackendResponse(text: text, tokenCount: response.tokenCount, cost: response.cost),
                    success: true,
                    events: events,
                    executionMessage: "Tool loop stopped at the \(maxIterations)-iteration budget."
                )
            }

            iteration += 1
            monitor?.update { $0.iteration = iteration }

            var results: [ToolCallResult] = []
            for call in response.toolCalls {
                if Task.isCancelled || monitor?.isCancelled == true { break }
                monitor?.update {
                    $0.currentTool = call.name
                    $0.phase = .runningTool
                }
                let signature = "\(call.name)\u{1}\(call.input.jsonString)"
                if let prior = executedCalls[signature] {
                    // Identical call already handled this run — do not re-run or
                    // re-prompt; hand back the prior result and tell the model to
                    // stop repeating it.
                    let deduped = ToolResult(
                        toolName: call.name,
                        output: "You already made this exact \(call.name) call this turn — do not repeat it. Its result was:\n\(prior.output)",
                        isError: prior.isError
                    )
                    events.append(TraceEvent(
                        runId: runId,
                        stage: .toolResult,
                        message: redactor.redact("\(call.name) deduped: repeated identical call skipped")
                    ))
                    results.append(ToolCallResult(callId: call.id, result: deduped))
                    continue
                }
                events.append(TraceEvent(
                    runId: runId,
                    stage: .toolCall,
                    message: redactor.redact("\(call.name): \(Self.summarizeToolInput(call.input))")
                ))
                let result = await executor.execute(name: call.name, input: call.input)
                events.append(TraceEvent(
                    runId: runId,
                    stage: .toolResult,
                    message: redactor.redact("\(call.name) \(result.isError ? "failed" : "ok"): \(String(result.output.prefix(300)))")
                ))
                executedCalls[signature] = result
                results.append(ToolCallResult(callId: call.id, result: result))
            }
            transcript.append(ToolLoopTurn(
                assistantText: response.text,
                toolCalls: response.toolCalls,
                toolResults: results
            ))
            monitor?.update {
                $0.currentTool = nil
                $0.phase = .callingModel
            }
        }
    }

    private static func summarizeToolInput(_ input: JSONValue) -> String {
        let text = input.jsonString
        guard text.count > 300 else { return text }
        return String(text.prefix(300)) + "…"
    }
}

/// Standard tool executor for the app: the shared bouncer plus episodic
/// session search wired through WS-A4's SessionStore (via the
/// SessionSearching seam) so the model's `session_search` tool hits the same
/// SQLite the chat UI persists to.
public extension ToolExecutor {
    static func standard(
        approvals: ToolApprovalStore,
        ledger: RunLedgerStore,
        configuration: ToolExecutor.Configuration = .init()
    ) -> ToolExecutor {
        ToolExecutor(
            configuration: configuration,
            approvals: approvals,
            sessionSearcher: SessionStore(ledger: ledger)
        )
    }
}

public enum DeviceIdentity {
    public static func currentName() -> String {
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
            conversationHistory: packet.conversationHistory,
            images: packet.images,
            apiKey: apiKey
        )
        return BackendResponse(text: text, tokenCount: nil, cost: nil)
    }
}

extension AgentRunnerBackendAdapter: ToolCapableModelBackend {
    /// Only the HTTPS API paths speak native tool calls (Anthropic tool_use,
    /// xAI tool_calls). CLI and session-proxy paths report false and the run
    /// service degrades them to single-shot with their safety flags intact.
    public var supportsTools: Bool {
        runner.supportsToolLoop(backend: backend, apiKey: apiKey)
    }

    public func execute(packet: ModelPacket, toolTranscript: [ToolLoopTurn]) async throws -> BackendResponse {
        try await runner.runWithTools(
            backend: backend,
            system: packet.system,
            user: packet.userPrompt,
            conversationHistory: packet.conversationHistory,
            images: packet.images,
            apiKey: apiKey,
            tools: packet.tools,
            toolTranscript: toolTranscript
        )
    }
}

public extension Backend {
    var defaultModelName: String {
        switch self {
        case .codex: return "gpt-5.5"
        case .grok: return "grok-4.3"
        case .claude: return "claude-sonnet-4-20250514"
        case .hermes: return "hermes3:8b"
        }
    }

    var invocationMethod: String {
        switch self {
        case .codex: return "chatgpt-session-proxy"
        case .grok: return "grok-session-proxy-or-api"
        case .claude: return "https-api"
        case .hermes: return "local-http"
        }
    }
}
