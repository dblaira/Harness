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
        case checkingGraph
        case retrievingAuthority
        case retrievingMemory
        case callingModel
        case runningTool
        case finished
        case budgetExhausted
        case deadlineExceeded
        case cancelled
        case failed
    }

    public struct Progress: Sendable, Equatable {
        public var iteration: Int
        public var maxIterations: Int
        public var currentTool: String?
        public var phase: Phase
        public var acceptedEvidence: [String]
        public var supportingEvidence: [String]
        public var toolEvidence: [String]
        public var completedAnswer: String?

        public init(
            iteration: Int = 0,
            maxIterations: Int = 30,
            currentTool: String? = nil,
            phase: Phase = .idle,
            acceptedEvidence: [String] = [],
            supportingEvidence: [String] = [],
            toolEvidence: [String] = [],
            completedAnswer: String? = nil
        ) {
            self.iteration = iteration
            self.maxIterations = maxIterations
            self.currentTool = currentTool
            self.phase = phase
            self.acceptedEvidence = acceptedEvidence
            self.supportingEvidence = supportingEvidence
            self.toolEvidence = toolEvidence
            self.completedAnswer = completedAnswer
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
    /// an approval card is resolved as cancelled and removed, so a stale later
    /// approval can never execute work from a stopped run.
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

    /// The interactive response contract expired. This is deliberately
    /// distinct from Adam pressing Cancel: the UI can publish the evidence it
    /// already has, while the service records that the backend exceeded its
    /// product deadline.
    public func exceedDeadline() {
        stop(phase: .deadlineExceeded)
    }

    private func stop(phase: Phase) {
        lock.lock()
        guard !cancelled else {
            lock.unlock()
            return
        }
        cancelled = true
        current.phase = phase
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

/// Defines whether a completed run is prose for Adam to read or machine-readable
/// data whose exact syntax is part of the caller's contract.
public enum HarnessResponseContract: Sendable, Equatable {
    case userFacingNarrative
    case structuredOutput
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
        localAnswer: String? = nil,
        responseContract: HarnessResponseContract = .userFacingNarrative,
        includeSupportingMemory: Bool = true,
        answerFromAcceptedAuthority: Bool = false,
        tools: [ToolSpec] = [],
        toolExecutor: ToolExecutor? = nil,
        toolLoop: ToolLoopMonitor? = nil,
        maxToolIterations: Int = 30,
        interactiveDeadline: ContinuousClock.Instant? = nil,
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

        toolLoop?.update { $0.phase = .checkingGraph }
        let graphHealth = await graphHealthChecker.checkAcceptedGraph()
        trace.append(TraceEvent(runId: runId, stage: .graphHealth, message: "Graph health: \(graphHealth.detail)"))

        toolLoop?.update { $0.phase = .retrievingAuthority }
        let authorityHits = try await authorityRetriever
            .retrieve(prompt: prompt, ontology: ontology, limit: 6)
            .map { $0.attached(to: runId) }
        trace.append(TraceEvent(runId: runId, stage: .authorityRetrieval, message: "Retrieved \(authorityHits.count) accepted graph authority hits."))
        toolLoop?.update {
            $0.acceptedEvidence = Self.acceptedEvidence(from: authorityHits)
        }

        let memoryHits: [MemoryHit]
        if includeSupportingMemory {
            toolLoop?.update { $0.phase = .retrievingMemory }
            memoryHits = try await memoryRetriever
                .retrieve(prompt: prompt, limit: 5)
                .map { $0.attached(to: runId) }
            trace.append(TraceEvent(runId: runId, stage: .supportingRetrieval, message: "Retrieved \(memoryHits.count) supporting memory hits."))
        } else {
            memoryHits = []
            trace.append(TraceEvent(
                runId: runId,
                stage: .supportingRetrieval,
                message: "Skipped supporting memory because the interactive prompt requested accepted authority only."
            ))
        }
        toolLoop?.update {
            $0.supportingEvidence = Self.supportingEvidence(from: memoryHits)
            $0.phase = .callingModel
        }

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
        var response: BackendResponse
        var success: Bool
        var suppressCandidateExtraction: Bool
        let trimmedLocalAnswer = localAnswer?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedLocalAnswer = trimmedLocalAnswer.flatMap { $0.isEmpty ? nil : $0 }
        if let resolvedLocalAnswer {
            response = BackendResponse(
                text: resolvedLocalAnswer,
                tokenCount: 0,
                cost: 0
            )
            success = true
            suppressCandidateExtraction = true
            toolLoop?.update {
                $0.completedAnswer = response.text
                $0.phase = .finished
            }
            trace.append(TraceEvent(
                runId: runId,
                stage: .modelExecution,
                message: "Answered from deterministic local product help; provider execution skipped."
            ))
        } else if answerFromAcceptedAuthority {
            response = BackendResponse(
                text: InteractiveChatPolicy.acceptedAuthorityAnswer(
                    acceptedEvidence: Self.acceptedEvidence(from: authorityHits)
                ),
                tokenCount: nil,
                cost: nil
            )
            success = true
            suppressCandidateExtraction = true
            toolLoop?.update {
                $0.completedAnswer = response.text
                $0.phase = .finished
            }
            trace.append(TraceEvent(
                runId: runId,
                stage: .modelExecution,
                message: "Answered directly from accepted graph authority; model execution skipped."
            ))
        } else if Self.deadlineExceeded(interactiveDeadline, monitor: toolLoop) {
            response = Self.deadlineFallbackResponse(backend: backend, monitor: toolLoop)
            success = false
            suppressCandidateExtraction = true
            trace.append(TraceEvent(
                runId: runId,
                stage: .modelExecution,
                message: "Interactive response deadline reached before model execution; returned bounded local evidence."
            ))
        } else if !tools.isEmpty,
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
                    maxIterations: maxToolIterations,
                    interactiveDeadline: interactiveDeadline
                )
            }
            toolLoop?.registerCancelHandler { loopTask.cancel() }
            let outcome = await loopTask.value
            response = outcome.response
            success = outcome.success
            suppressCandidateExtraction = outcome.deadlineExceeded || !outcome.success
            trace.append(contentsOf: outcome.events)
            trace.append(TraceEvent(runId: runId, stage: .modelExecution, message: outcome.executionMessage))
        } else {
            do {
                let modelTask = Task {
                    try await backend.execute(packet: packet)
                }
                toolLoop?.registerCancelHandler { modelTask.cancel() }
                let modelResponse = try await modelTask.value
                if Self.deadlineExceeded(interactiveDeadline, monitor: toolLoop) {
                    response = Self.deadlineFallbackResponse(backend: backend, monitor: toolLoop)
                    success = false
                    suppressCandidateExtraction = true
                    trace.append(TraceEvent(
                        runId: runId,
                        stage: .modelExecution,
                        message: "Model completed after the interactive response deadline; returned bounded local evidence instead."
                    ))
                } else {
                    response = modelResponse
                    success = true
                    suppressCandidateExtraction = false
                    toolLoop?.update {
                        $0.completedAnswer = modelResponse.text
                        $0.phase = .finished
                    }
                    trace.append(TraceEvent(runId: runId, stage: .modelExecution, message: "Model call completed with \(backend.metadata.invocationMethod)."))
                }
            } catch {
                if Self.isAuthorizationFailure(error) {
                    response = Self.providerFailureResponse(backend: backend, error: error)
                    success = false
                    suppressCandidateExtraction = true
                    toolLoop?.update { $0.phase = .failed }
                    trace.append(TraceEvent(
                        runId: runId,
                        stage: .modelExecution,
                        message: Self.providerFailureTrace(backend: backend, error: error)
                    ))
                } else if Self.deadlineExceeded(interactiveDeadline, monitor: toolLoop) {
                    response = Self.deadlineFallbackResponse(backend: backend, monitor: toolLoop)
                    success = false
                    suppressCandidateExtraction = true
                    trace.append(TraceEvent(
                        runId: runId,
                        stage: .modelExecution,
                        message: "Interactive response deadline cancelled the model; returned bounded local evidence."
                    ))
                } else {
                    response = Self.providerFailureResponse(backend: backend, error: error)
                    success = false
                    suppressCandidateExtraction = true
                    toolLoop?.update { $0.phase = .failed }
                    trace.append(TraceEvent(
                        runId: runId,
                        stage: .modelExecution,
                        message: Self.providerFailureTrace(backend: backend, error: error)
                    ))
                }
            }
        }

        // A provider process exiting normally is not a successful answer when
        // its terminal text merely promises to load, inspect, or search next.
        // Record an honest provider failure instead of preserving a nonanswer
        // as green ledger evidence. Deterministic local answers are already
        // complete product copy and intentionally bypass this provider check.
        if success,
           resolvedLocalAnswer == nil,
           Self.isTerminalProgressOnly(response.text) {
            response = BackendResponse(
                text: Self.progressOnlyFailureText(backend: backend),
                tokenCount: response.tokenCount,
                cost: response.cost
            )
            success = false
            suppressCandidateExtraction = true
            toolLoop?.update {
                $0.completedAnswer = response.text
                $0.phase = .failed
            }
            trace.append(TraceEvent(
                runId: runId,
                stage: .modelExecution,
                message: "\(backend.metadata.backend.rawValue) returned terminal progress-only text; run recorded as failed."
            ))
        }

        // Prompt injection is not enforcement. Every user-facing terminal
        // Harness answer passes through Adam's articulate-leadership gate before
        // evaluation, persistence, session reload, or UI presentation. Structured
        // callers keep their exact syntax. Preserve the raw semantic response for
        // candidate extraction so chapter scaffolding can never become ontology content.
        let candidateSourceText = response.text
        let formattingTrace: String
        switch responseContract {
        case .userFacingNarrative:
            let formattedResponseText = InteractiveChatPolicy
                .enforceArticulateLeadershipFormat(response.text)
            let articulateFormatWasApplied = formattedResponseText != response.text
            if articulateFormatWasApplied {
                response = BackendResponse(
                    text: formattedResponseText,
                    tokenCount: response.tokenCount,
                    cost: response.cost
                )
            }
            formattingTrace = articulateFormatWasApplied
                ? " Articulate-leadership four-chapter format applied before persistence."
                : " Articulate-leadership four-chapter format already satisfied."
        case .structuredOutput:
            formattingTrace = " Structured response contract preserved exact provider output before persistence."
        }
        toolLoop?.update {
            $0.completedAnswer = response.text
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
        trace.append(TraceEvent(
            runId: runId,
            stage: .evaluation,
            message: "Evaluated \(evalResults.count) deterministic checks.\(formattingTrace)"
        ))

        let candidates = suppressCandidateExtraction
            ? []
            : candidateExtractor.candidates(
                prompt: prompt,
                response: candidateSourceText,
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
        let deadlineExceeded: Bool
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
        maxIterations: Int,
        interactiveDeadline: ContinuousClock.Instant?
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
        var usage = UsageAccumulator()
        monitor?.update {
            $0.iteration = 0
            $0.maxIterations = maxIterations
            $0.currentTool = nil
            $0.phase = .callingModel
        }

        while true {
            if Self.deadlineExceeded(interactiveDeadline, monitor: monitor) {
                monitor?.exceedDeadline()
                return ToolLoopOutcome(
                    response: usage.applying(
                        to: Self.deadlineFallbackResponse(backend: backend, monitor: monitor)
                    ),
                    success: false,
                    deadlineExceeded: true,
                    events: events,
                    executionMessage: "Interactive response deadline stopped the tool loop during iteration \(iteration); returned bounded local evidence."
                )
            }
            if Task.isCancelled || monitor?.isCancelled == true {
                return ToolLoopOutcome(
                    response: usage.applying(to: BackendResponse(
                        text: "Run cancelled by Adam before the model finished.",
                        tokenCount: nil,
                        cost: nil
                    )),
                    success: false,
                    deadlineExceeded: false,
                    events: events,
                    executionMessage: "Tool loop cancelled during iteration \(iteration)."
                )
            }

            let response: BackendResponse
            do {
                response = try await backend.execute(packet: packet, toolTranscript: transcript)
            } catch {
                if Self.isAuthorizationFailure(error) {
                    monitor?.update { $0.phase = .failed }
                    return ToolLoopOutcome(
                        response: usage.applying(
                            to: Self.providerFailureResponse(backend: backend, error: error)
                        ),
                        success: false,
                        deadlineExceeded: false,
                        events: events,
                        executionMessage: Self.providerFailureTrace(
                            backend: backend,
                            error: error,
                            toolIteration: iteration
                        )
                    )
                }
                if Self.deadlineExceeded(interactiveDeadline, monitor: monitor) {
                    monitor?.exceedDeadline()
                    return ToolLoopOutcome(
                        response: usage.applying(
                            to: Self.deadlineFallbackResponse(backend: backend, monitor: monitor)
                        ),
                        success: false,
                        deadlineExceeded: true,
                        events: events,
                        executionMessage: "Interactive response deadline cancelled the model during tool iteration \(iteration); returned bounded local evidence."
                    )
                }
                if Task.isCancelled || monitor?.isCancelled == true {
                    return ToolLoopOutcome(
                        response: usage.applying(to: BackendResponse(
                            text: "Run cancelled by Adam before the model finished.",
                            tokenCount: nil,
                            cost: nil
                        )),
                        success: false,
                        deadlineExceeded: false,
                        events: events,
                        executionMessage: "Tool loop cancelled during iteration \(iteration)."
                    )
                }
                monitor?.update { $0.phase = .failed }
                return ToolLoopOutcome(
                    response: usage.applying(
                        to: Self.providerFailureResponse(backend: backend, error: error)
                    ),
                    success: false,
                    deadlineExceeded: false,
                    events: events,
                    executionMessage: Self.providerFailureTrace(
                        backend: backend,
                        error: error,
                        toolIteration: iteration
                    )
                )
            }
            usage.record(response)

            if Self.deadlineExceeded(interactiveDeadline, monitor: monitor) {
                monitor?.exceedDeadline()
                return ToolLoopOutcome(
                    response: usage.applying(
                        to: Self.deadlineFallbackResponse(backend: backend, monitor: monitor)
                    ),
                    success: false,
                    deadlineExceeded: true,
                    events: events,
                    executionMessage: "Model completed after the interactive response deadline during tool iteration \(iteration); returned bounded local evidence."
                )
            }

            guard !response.toolCalls.isEmpty else {
                monitor?.update {
                    $0.currentTool = nil
                    $0.completedAnswer = response.text
                    $0.phase = .finished
                }
                return ToolLoopOutcome(
                    response: usage.applying(to: response),
                    success: true,
                    deadlineExceeded: false,
                    events: events,
                    executionMessage: "Tool loop completed after \(iteration) tool iteration(s) with \(backend.metadata.invocationMethod)."
                )
            }

            guard iteration < maxIterations else {
                events.append(TraceEvent(
                    runId: runId,
                    stage: .toolCall,
                    message: "Iteration budget of \(maxIterations) reached; \(response.toolCalls.count) pending tool call(s) were not executed."
                ))
                let text = response.text.isEmpty
                    ? "Tool loop stopped: the iteration budget of \(maxIterations) was reached before a final answer."
                    : response.text + "\n\n[Tool loop stopped: the iteration budget of \(maxIterations) was reached.]"
                monitor?.update {
                    $0.completedAnswer = text
                    $0.phase = .budgetExhausted
                }
                return ToolLoopOutcome(
                    response: usage.applying(
                        to: BackendResponse(text: text, tokenCount: nil, cost: nil)
                    ),
                    success: true,
                    deadlineExceeded: false,
                    events: events,
                    executionMessage: "Tool loop stopped at the \(maxIterations)-iteration budget."
                )
            }

            iteration += 1
            monitor?.update { $0.iteration = iteration }

            var results: [ToolCallResult] = []
            for call in response.toolCalls {
                if Self.deadlineExceeded(interactiveDeadline, monitor: monitor) {
                    monitor?.exceedDeadline()
                    return ToolLoopOutcome(
                        response: usage.applying(
                            to: Self.deadlineFallbackResponse(backend: backend, monitor: monitor)
                        ),
                        success: false,
                        deadlineExceeded: true,
                        events: events,
                        executionMessage: "Interactive response deadline stopped tool execution during iteration \(iteration); returned bounded local evidence."
                    )
                }
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
                if !result.isError {
                    let evidence = redactor.redact("\(call.name): \(String(result.output.prefix(240)))")
                    monitor?.update {
                        guard !$0.toolEvidence.contains(evidence) else { return }
                        $0.toolEvidence = Array(($0.toolEvidence + [evidence]).prefix(4))
                    }
                }
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

    /// The ledger has one usage slot per run, while an agentic run can make
    /// several provider requests. Accumulate every provider-reported round so
    /// the saved value is the run total rather than only the terminal call.
    private struct UsageAccumulator: Sendable {
        private var tokens = 0
        private var observedTokens = false
        private var cost = 0.0
        private var observedCost = false

        mutating func record(_ response: BackendResponse) {
            if let tokenCount = response.tokenCount, tokenCount >= 0 {
                observedTokens = true
                let (sum, overflow) = tokens.addingReportingOverflow(tokenCount)
                tokens = overflow ? Int.max : sum
            }
            if let responseCost = response.cost,
               responseCost.isFinite,
               responseCost >= 0 {
                observedCost = true
                cost += responseCost
            }
        }

        func applying(to response: BackendResponse) -> BackendResponse {
            BackendResponse(
                text: response.text,
                tokenCount: observedTokens ? tokens : response.tokenCount,
                cost: observedCost ? cost : response.cost,
                toolCalls: response.toolCalls
            )
        }
    }

    /// Authentication takes priority over deadline presentation. A 401 or an
    /// expired session token can arrive after a slow proxy response; calling it
    /// a timeout would hide the one action that can actually recover the run.
    private static func isAuthorizationFailure(_ error: any Error) -> Bool {
        let message = normalizedEvidence(error.localizedDescription)
            .lowercased()
            .replacingOccurrences(of: "’", with: "'")
        let signals = [
            "api key",
            "session token",
            "access token",
            "expired token",
            "invalid token",
            "bearer",
            "unauthorized",
            "authorization",
            "authentication",
            "credentials",
            "auth context",
            "http 401",
            "api 401",
            "session 401",
        ]
        return signals.contains { message.contains($0) }
    }

    private static func isTimeoutFailure(_ error: any Error) -> Bool {
        if let urlError = error as? URLError, urlError.code == .timedOut {
            return true
        }
        let message = error.localizedDescription.lowercased()
        return message.contains("timed out") || message.contains("timeout")
    }

    private static func providerFailureResponse(
        backend: any ModelBackendAdapter,
        error: any Error
    ) -> BackendResponse {
        BackendResponse(
            text: providerFailureText(backend: backend, error: error),
            tokenCount: nil,
            cost: nil
        )
    }

    private static func providerFailureText(
        backend: any ModelBackendAdapter,
        error: any Error
    ) -> String {
        let provider = backend.metadata.backend.rawValue
        if isAuthorizationFailure(error) {
            let lower = error.localizedDescription.lowercased()
            if lower.contains("api key") {
                return "Backend failed: \(provider) authorization failed. Add a valid API key, then send again."
            }
            return "Backend failed: \(provider) authorization failed. Re-authorize \(provider), then send again."
        }
        if isTimeoutFailure(error) {
            return "Backend failed: \(provider) timed out before returning an answer."
        }

        let description = conciseErrorDescription(error)
        if description.isEmpty {
            return "Backend failed: \(provider) failed before returning an answer."
        }
        return "Backend failed: \(provider) failed: \(description)"
    }

    private static func providerFailureTrace(
        backend: any ModelBackendAdapter,
        error: any Error,
        toolIteration: Int? = nil
    ) -> String {
        let provider = backend.metadata.backend.rawValue
        let location = toolIteration.map { " during tool iteration \($0)" } ?? ""
        if isAuthorizationFailure(error) {
            return "\(provider) authorization failed\(location); surfaced a provider-specific recovery message."
        }
        if isTimeoutFailure(error) {
            return "\(provider) timed out\(location) before returning an answer."
        }
        return "\(provider) failed\(location): \(conciseErrorDescription(error))"
    }

    private static func conciseErrorDescription(_ error: any Error) -> String {
        let normalized = normalizedEvidence(error.localizedDescription)
        guard normalized.count > 240 else { return normalized }
        return String(normalized.prefix(239)) + "…"
    }

    /// Detect terminal process narration, not answers that happen to discuss
    /// loading or searching. Completed answers normally contain a result
    /// marker, structure, or more than the short one-step promise emitted by a
    /// coding-agent CLI when its sole turn was consumed by planning.
    private static func isTerminalProgressOnly(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 500 else { return false }

        let lower = trimmed
            .lowercased()
            .replacingOccurrences(of: "’", with: "'")
        let normalized = normalizedEvidence(lower)
        let progressPrefixes = [
            "i'll load", "i will load", "i'm loading", "i am loading", "loading ",
            "i'll inspect", "i will inspect", "i'm inspecting", "i am inspecting",
            "i'll check", "i will check", "i'm checking", "i am checking",
            "i'll search", "i will search", "i'm searching", "i am searching",
            "let me load", "let me inspect", "let me check", "let me search",
            "working on ", "i'm going to load", "i am going to load",
        ]
        guard progressPrefixes.contains(where: { normalized.hasPrefix($0) }) else {
            return false
        }

        let completionSignals = [
            "here is", "here's", "the answer is", "answer:", "result:",
            "i found", "i completed", "completed:", "done:",
            "\n#", "\n- ", "\n1. ", "```",
        ]
        return !completionSignals.contains { lower.contains($0) }
    }

    private static func progressOnlyFailureText(backend: any ModelBackendAdapter) -> String {
        "Backend failed: \(backend.metadata.backend.rawValue) returned a progress update instead of a completed answer."
    }

    private static func summarizeToolInput(_ input: JSONValue) -> String {
        let text = input.jsonString
        guard text.count > 300 else { return text }
        return String(text.prefix(300)) + "…"
    }

    private static func deadlineExceeded(
        _ deadline: ContinuousClock.Instant?,
        monitor: ToolLoopMonitor?
    ) -> Bool {
        if monitor?.progressSnapshot().phase == .deadlineExceeded {
            return true
        }
        guard let deadline else { return false }
        return ContinuousClock().now >= deadline
    }

    private static func deadlineFallbackResponse(
        backend: any ModelBackendAdapter,
        monitor: ToolLoopMonitor?
    ) -> BackendResponse {
        let evidence = monitor?.progressSnapshot() ?? ToolLoopMonitor.Progress()
        return BackendResponse(
            text: InteractiveChatPolicy.deadlineFallback(
                backendName: backend.metadata.backend.rawValue,
                acceptedEvidence: evidence.acceptedEvidence,
                supportingEvidence: evidence.supportingEvidence,
                toolEvidence: evidence.toolEvidence
            ),
            tokenCount: nil,
            cost: nil
        )
    }

    private static func acceptedEvidence(from hits: [GraphAuthorityHit]) -> [String] {
        boundedDistinctEvidence(hits.filter { $0.authorityLevel == .accepted }.map { hit in
            "\(normalizedEvidence(hit.object)) — \(normalizedEvidence(hit.source))"
        }, limit: 5)
    }

    private static func supportingEvidence(from hits: [MemoryHit]) -> [String] {
        boundedDistinctEvidence(hits.map { hit in
            let sourceName = URL(fileURLWithPath: hit.source).lastPathComponent
            return "\(normalizedEvidence(hit.excerpt)) — \(sourceName)"
        }, limit: 3)
    }

    private static func boundedDistinctEvidence(_ values: [String], limit: Int) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for value in values {
            let normalized = normalizedEvidence(value)
            guard !normalized.isEmpty else { continue }
            let key = normalized.lowercased()
            guard seen.insert(key).inserted else { continue }
            result.append(String(normalized.prefix(320)))
            if result.count == limit { break }
        }
        return result
    }

    private static func normalizedEvidence(_ value: String) -> String {
        value
            .split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
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
        try await runner.runResponse(
            backend: backend,
            system: packet.system,
            user: packet.userPrompt,
            conversationHistory: packet.conversationHistory,
            images: packet.images,
            apiKey: apiKey
        )
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
