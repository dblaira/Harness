import Foundation
import Testing
@testable import OntologyKit

// MARK: - Fixtures

private func makeTempDirectory(_ prefix: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@discardableResult
private func write(_ text: String, to url: URL) throws -> URL {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try text.write(to: url, atomically: true, encoding: .utf8)
    return url
}

private func makeApprovalStore() -> ToolApprovalStore {
    let suiteName = "tool-loop-tests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return ToolApprovalStore(defaults: defaults)
}

private struct NoopStager: MemoryCandidateStaging {
    func stageMemoryCandidate(_ candidate: MemoryCandidate) throws {}
}

private func makeExecutor(
    home: URL,
    approvals: ToolApprovalStore = makeApprovalStore(),
    memoryStager: (any MemoryCandidateStaging)? = nil,
    capabilities: [HarnessCapability] = []
) -> ToolExecutor {
    ToolExecutor(
        configuration: ToolExecutor.Configuration(homeDirectory: home, shellTimeout: 20),
        approvals: approvals,
        memoryStager: memoryStager ?? NoopStager(),
        capabilitiesProvider: { capabilities }
    )
}

/// Wait (bounded) until the bouncer shows a pending request.
private func waitForPendingRequest(in store: ToolApprovalStore) async throws -> ToolApprovalRequest {
    for _ in 0..<250 {
        if let request = store.pendingSnapshot().first { return request }
        try await Task.sleep(nanoseconds: 20_000_000)
    }
    Issue.record("No approval request appeared within the timeout")
    throw CancellationError()
}

private struct NullMemoryRetriever: SupportingMemoryRetrieving {
    func retrieve(prompt: String, limit: Int) async throws -> [MemoryHit] { [] }
}

private struct NullGraphHealthChecker: GraphHealthChecking {
    func checkAcceptedGraph() async -> GraphHealthReport {
        GraphHealthReport(
            status: .unavailable,
            acceptedGraphIRI: "https://understood.app/graph/accepted",
            sparqlEndpoint: "http://127.0.0.1:9/understood/sparql",
            namedGraphCount: nil,
            defaultGraphTripleCount: nil,
            detail: "SPARQL graph health check unavailable in unit test."
        )
    }
}

private func makeService(ledger: RunLedgerStore) -> HarnessRunService {
    HarnessRunService(
        ledger: ledger,
        authorityRetriever: OntologyAuthorityRetriever(sparqlEndpoint: URL(string: "http://127.0.0.1:9/understood/sparql")!),
        memoryRetriever: NullMemoryRetriever(),
        graphHealthChecker: NullGraphHealthChecker()
    )
}

private let finalAnswerText = "Plain answer first.\n\nRule: none\nAdam Pattern Step: none"

private func toolCallResponse(_ text: String, _ calls: [ToolCallRequest]) -> BackendResponse {
    BackendResponse(text: text, tokenCount: nil, cost: nil, toolCalls: calls)
}

/// Deterministic scripted backend, following the StaticBackendAdapter
/// pattern: each model call pops the next scripted response; with
/// `repeatsLastResponse` the final entry repeats forever (the pathological
/// loop for the budget test).
private final class ScriptedToolBackend: ToolCapableModelBackend, @unchecked Sendable {
    let metadata = BackendMetadata(backend: .claude, modelName: "scripted-tools", invocationMethod: "unit-test")
    let supportsTools: Bool

    private let lock = NSLock()
    private var script: [BackendResponse]
    private let repeatsLastResponse: Bool
    private let delayNanoseconds: UInt64
    private var recordedTranscripts: [[ToolLoopTurn]] = []
    private var recordedPacket: ModelPacket?

    init(
        script: [BackendResponse],
        repeatsLastResponse: Bool = false,
        supportsTools: Bool = true,
        delayNanoseconds: UInt64 = 0
    ) {
        self.script = script
        self.repeatsLastResponse = repeatsLastResponse
        self.supportsTools = supportsTools
        self.delayNanoseconds = delayNanoseconds
    }

    var modelCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return recordedTranscripts.count
    }

    var lastTranscript: [ToolLoopTurn] {
        lock.lock()
        defer { lock.unlock() }
        return recordedTranscripts.last ?? []
    }

    var lastPacket: ModelPacket? {
        lock.lock()
        defer { lock.unlock() }
        return recordedPacket
    }

    func execute(packet: ModelPacket) async throws -> BackendResponse {
        try await execute(packet: packet, toolTranscript: [])
    }

    func execute(packet: ModelPacket, toolTranscript: [ToolLoopTurn]) async throws -> BackendResponse {
        if delayNanoseconds > 0 {
            // Cancellation is observed by the loop, not by the fake model.
            try? await Task.sleep(nanoseconds: delayNanoseconds)
        }
        lock.lock()
        defer { lock.unlock() }
        recordedTranscripts.append(toolTranscript)
        recordedPacket = packet
        if repeatsLastResponse, script.count == 1 {
            return script[0]
        }
        guard !script.isEmpty else {
            return BackendResponse(text: "script exhausted", tokenCount: nil, cost: nil)
        }
        return script.removeFirst()
    }
}

// MARK: - (a) read_file → executor result → final text

@Test func toolLoopReadsFileThenAnswers() async throws {
    let home = try makeTempDirectory("tool-loop-home")
    let note = try write("the vault truth", to: home.appendingPathComponent("Documents/Main/note.md"))
    let executor = makeExecutor(home: home)
    let backend = ScriptedToolBackend(script: [
        toolCallResponse("Reading the note.", [
            ToolCallRequest(id: "call-1", name: "read_file", input: ["path": .string(note.path)]),
        ]),
        BackendResponse(text: finalAnswerText, tokenCount: 9, cost: nil),
    ])

    let detail = try await makeService(ledger: try RunLedgerStore.inMemory()).createRun(
        prompt: "What does the note say?",
        ontology: OntologyLoader.load(),
        backend: backend,
        tools: HarnessToolCatalog.v1,
        toolExecutor: executor
    )

    #expect(detail.run.success)
    #expect(detail.run.finalAnswer.contains("Plain answer first."))
    #expect(backend.modelCallCount == 2)
    // The tool catalog rode in on the packet — the only capability grant.
    #expect(backend.lastPacket?.tools.map(\.name).contains("read_file") == true)
    // The second model call saw the executed tool result.
    let turn = try #require(backend.lastTranscript.first)
    #expect(turn.toolCalls.first?.name == "read_file")
    #expect(turn.toolResults.first?.callId == "call-1")
    #expect(turn.toolResults.first?.result.output.contains("the vault truth") == true)
    // Every call + result became a trace event in the ledger's idiom.
    #expect(detail.traceEvents.contains { $0.stage == .toolCall && $0.message.contains("read_file") })
    #expect(detail.traceEvents.contains { $0.stage == .toolResult && $0.message.contains("read_file ok") })
}

// MARK: - (b)+(c) the bouncer inside the loop

#if os(macOS)
@Test func dangerousShellSuspendsLoopUntilAdamApproves() async throws {
    let home = try makeTempDirectory("tool-loop-home")
    let store = makeApprovalStore()
    let executor = makeExecutor(home: home, approvals: store)
    let victim = try makeTempDirectory("tool-loop-victim")
    let backend = ScriptedToolBackend(script: [
        toolCallResponse("Cleaning up.", [
            ToolCallRequest(id: "call-rm", name: "shell", input: ["command": .string("rm -rf '\(victim.path)'")]),
        ]),
        BackendResponse(text: finalAnswerText, tokenCount: nil, cost: nil),
    ])
    let service = makeService(ledger: try RunLedgerStore.inMemory())
    let monitor = ToolLoopMonitor()

    let runTask = Task {
        try await service.createRun(
            prompt: "Remove the scratch folder.",
            ontology: OntologyLoader.load(),
            backend: backend,
            tools: HarnessToolCatalog.v1,
            toolExecutor: executor,
            toolLoop: monitor
        )
    }
    let request = try await waitForPendingRequest(in: store)
    #expect(request.toolName == "shell")
    #expect(request.summary.contains(victim.path))
    // Suspended: the model has not been called again while Adam decides.
    #expect(backend.modelCallCount == 1)
    #expect(monitor.progressSnapshot().currentTool == "shell")
    store.approve(id: request.id)

    let detail = try await runTask.value
    #expect(!FileManager.default.fileExists(atPath: victim.path))
    #expect(detail.run.finalAnswer.contains("Plain answer first."))
    #expect(backend.lastTranscript.first?.toolResults.first?.result.isError == false)
    #expect(monitor.progressSnapshot().phase == .finished)
}

/// The chat card observes the @Published `pendingRequests` mirror, not the
/// sync `pendingSnapshot()`. This proves the mirror empties after a decision —
/// i.e. the card can dismiss. (If the live card lingered, the cause is the model
/// re-issuing the tool call, not a stale store mirror.)
@MainActor
private func mirrorSettles(_ store: ToolApprovalStore, to count: Int) async -> Int {
    for _ in 0..<300 {
        if store.pendingRequests.count == count { return count }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return store.pendingRequests.count
}

@Test func approvalMirrorEmptiesAfterDecision() async throws {
    let store = makeApprovalStore()
    let request = ToolApprovalRequest(toolName: "write_file", summary: "~/x.txt", reason: "test")
    let decision = Task { await store.awaitDecision(request) }
    #expect(await mirrorSettles(store, to: 1) == 1)   // card appears
    store.approve(id: request.id)
    _ = await decision.value
    #expect(await mirrorSettles(store, to: 0) == 0)   // card dismisses
    #expect(store.pendingSnapshot().isEmpty)
}

@Test func approvalMirrorEmptiesAfterDenial() async throws {
    let store = makeApprovalStore()
    let request = ToolApprovalRequest(toolName: "shell", summary: "rm -rf x", reason: "test")
    let decision = Task { await store.awaitDecision(request) }
    #expect(await mirrorSettles(store, to: 1) == 1)
    store.deny(id: request.id)
    _ = await decision.value
    #expect(await mirrorSettles(store, to: 0) == 0)
}

@Test func deniedShellFeedsDenialResultAndLoopContinues() async throws {
    let home = try makeTempDirectory("tool-loop-home")
    let store = makeApprovalStore()
    let executor = makeExecutor(home: home, approvals: store)
    let victim = try makeTempDirectory("tool-loop-victim")
    let backend = ScriptedToolBackend(script: [
        toolCallResponse("Cleaning up.", [
            ToolCallRequest(id: "call-rm", name: "shell", input: ["command": .string("rm -rf '\(victim.path)'")]),
        ]),
        BackendResponse(text: finalAnswerText, tokenCount: nil, cost: nil),
    ])
    let service = makeService(ledger: try RunLedgerStore.inMemory())

    let runTask = Task {
        try await service.createRun(
            prompt: "Remove the scratch folder.",
            ontology: OntologyLoader.load(),
            backend: backend,
            tools: HarnessToolCatalog.v1,
            toolExecutor: executor
        )
    }
    let request = try await waitForPendingRequest(in: store)
    store.deny(id: request.id)

    let detail = try await runTask.value
    // Nothing executed, but the loop CONTINUED to the final answer.
    #expect(FileManager.default.fileExists(atPath: victim.path))
    #expect(detail.run.success)
    #expect(detail.run.finalAnswer.contains("Plain answer first."))
    let deniedResult = try #require(backend.lastTranscript.first?.toolResults.first)
    #expect(deniedResult.result.isError)
    #expect(deniedResult.result.output.contains("denied"))
    #expect(detail.traceEvents.contains { $0.stage == .toolResult && $0.message.contains("shell failed") })
}
#endif

// MARK: - (d) iteration budget

@Test func toolLoopStopsPathologicalLoopAtIterationBudget() async throws {
    let home = try makeTempDirectory("tool-loop-home")
    let executor = makeExecutor(home: home)
    // The model asks for the same harmless tool forever.
    let backend = ScriptedToolBackend(
        script: [
            toolCallResponse("Just one more look.", [
                ToolCallRequest(id: "call-again", name: "skills_list", input: [:]),
            ]),
        ],
        repeatsLastResponse: true
    )
    let monitor = ToolLoopMonitor()

    let detail = try await makeService(ledger: try RunLedgerStore.inMemory()).createRun(
        prompt: "Loop forever.",
        ontology: OntologyLoader.load(),
        backend: backend,
        tools: HarnessToolCatalog.v1,
        toolExecutor: executor,
        toolLoop: monitor
    )

    // 30 tool iterations + the model call that hit the budget = 31 calls.
    #expect(backend.modelCallCount == 31)
    #expect(detail.run.finalAnswer.contains("iteration budget"))
    #expect(monitor.progressSnapshot().phase == .budgetExhausted)
    #expect(monitor.progressSnapshot().iteration == 30)
    #expect(detail.traceEvents.contains { $0.stage == .toolCall && $0.message.contains("Iteration budget of 30 reached") })
}

// MARK: - (d.2) repeated-call dedupe (no duplicate approval cards)

#if os(macOS)
@Test func repeatedIdenticalToolCallIsDedupedNotRePrompted() async throws {
    let home = try makeTempDirectory("tool-loop-home")
    let store = makeApprovalStore()
    let executor = makeExecutor(home: home, approvals: store)
    let target = home.appendingPathComponent("Documents/Harness/proof.txt")
    let writeInput: JSONValue = ["path": .string(target.path), "content": "once"]
    // The model re-issues the identical write after it already succeeded.
    let backend = ScriptedToolBackend(script: [
        toolCallResponse("Writing.", [ToolCallRequest(id: "w1", name: "write_file", input: writeInput)]),
        toolCallResponse("Writing again.", [ToolCallRequest(id: "w2", name: "write_file", input: writeInput)]),
        BackendResponse(text: finalAnswerText, tokenCount: nil, cost: nil),
    ])
    let service = makeService(ledger: try RunLedgerStore.inMemory())

    let runTask = Task {
        try await service.createRun(
            prompt: "write it",
            ontology: OntologyLoader.load(),
            backend: backend,
            tools: HarnessToolCatalog.v1,
            toolExecutor: executor
        )
    }
    // Exactly ONE approval card — for the first write. The repeat never prompts.
    let request = try await waitForPendingRequest(in: store)
    #expect(request.toolName == "write_file")
    store.approve(id: request.id)

    let detail = try await runTask.value
    #expect(detail.run.success)
    #expect(store.pendingSnapshot().isEmpty)
    // The repeat was deduped, not re-executed or re-prompted.
    #expect(detail.traceEvents.contains { $0.stage == .toolResult && $0.message.contains("deduped") })
    // File written exactly once, with the content.
    #expect(try String(contentsOf: target, encoding: .utf8) == "once")
    // The model was told it already did this, so it can stop.
    #expect(backend.lastTranscript.contains { turn in
        turn.toolResults.contains { $0.result.output.contains("already made this exact") }
    })
}
#endif

// MARK: - (e) memory tool → MemoryCandidate row

@Test func memoryToolCallLandsAReviewQueueCandidate() async throws {
    let home = try makeTempDirectory("tool-loop-home")
    let ontologyRoot = try makeTempDirectory("tool-loop-ontology")
    let executor = makeExecutor(
        home: home,
        memoryStager: ReviewQueueMemoryStager(ontologyRoot: ontologyRoot)
    )
    let backend = ScriptedToolBackend(script: [
        toolCallResponse("Noting that.", [
            ToolCallRequest(id: "call-mem", name: "memory", input: [
                "content": "Adam prefers the pyramid format for substantive answers",
                "evidence": "Adam said so in this session",
                "source": "tool-loop-test",
            ]),
        ]),
        BackendResponse(text: finalAnswerText, tokenCount: nil, cost: nil),
    ])

    let detail = try await makeService(ledger: try RunLedgerStore.inMemory()).createRun(
        prompt: "Remember my format preference.",
        ontology: OntologyLoader.load(),
        backend: backend,
        tools: HarnessToolCatalog.v1,
        toolExecutor: executor
    )

    #expect(detail.run.success)
    // The proposal is a pending row in Adam's review queue — not memory yet.
    let queue = ReviewQueueStore(ontologyRoot: ontologyRoot, ledger: try RunLedgerStore.inMemory())
    let pending = try await queue.loadPendingClaims()
    #expect(pending.count == 1)
    #expect(pending.first?.proposedClaim == "Adam prefers the pyramid format for substantive answers")
    #expect(pending.first?.sourceRef == "tool-loop-test")
    #expect(backend.lastTranscript.first?.toolResults.first?.result.output.contains("review queue") == true)
}

// MARK: - Graceful degradation

private struct SingleShotBackend: ModelBackendAdapter {
    let metadata = BackendMetadata(backend: .codex, modelName: "single-shot", invocationMethod: "unit-test")
    let answer: String

    func execute(packet: ModelPacket) async throws -> BackendResponse {
        BackendResponse(text: answer, tokenCount: nil, cost: nil)
    }
}

@Test func backendWithoutNativeToolsDegradesToSingleShot() async throws {
    let home = try makeTempDirectory("tool-loop-home")
    let executor = makeExecutor(home: home)

    let detail = try await makeService(ledger: try RunLedgerStore.inMemory()).createRun(
        prompt: "Answer plainly.",
        ontology: OntologyLoader.load(),
        backend: SingleShotBackend(answer: finalAnswerText),
        tools: HarnessToolCatalog.v1,
        toolExecutor: executor
    )

    #expect(detail.run.success)
    #expect(detail.run.finalAnswer.contains("Plain answer first."))
    #expect(!detail.traceEvents.contains { $0.stage == .toolCall || $0.stage == .toolResult })
    #expect(detail.traceEvents.contains { $0.stage == .modelExecution })
}

@Test func toolCapableBackendReportingNoSupportDegradesToSingleShot() async throws {
    let home = try makeTempDirectory("tool-loop-home")
    let executor = makeExecutor(home: home)
    let backend = ScriptedToolBackend(
        script: [BackendResponse(text: finalAnswerText, tokenCount: nil, cost: nil)],
        supportsTools: false
    )

    let detail = try await makeService(ledger: try RunLedgerStore.inMemory()).createRun(
        prompt: "Answer plainly.",
        ontology: OntologyLoader.load(),
        backend: backend,
        tools: HarnessToolCatalog.v1,
        toolExecutor: executor
    )

    #expect(detail.run.success)
    #expect(backend.modelCallCount == 1)
    #expect(backend.lastTranscript.isEmpty)
    #expect(!detail.traceEvents.contains { $0.stage == .toolCall })
}

@Test func toolLoopCapabilityDetectionMatchesBackendAndKey() {
    let runner = AgentRunner()
    // All three API backends are tool-capable once their key is present.
    #expect(runner.supportsToolLoop(backend: .claude, apiKey: "test-anthropic-key"))
    #expect(runner.supportsToolLoop(backend: .grok, apiKey: "test-grok-key"))
    #expect(runner.supportsToolLoop(backend: .codex, apiKey: "test-openai-key"))
    // Local Hermes stays single-shot no matter what — no API tool path.
    #expect(!runner.supportsToolLoop(backend: .hermes, apiKey: "irrelevant"))
}

// MARK: - Cancellation

@Test func monitorCancelStopsTheLoop() async throws {
    let home = try makeTempDirectory("tool-loop-home")
    let executor = makeExecutor(home: home)
    let backend = ScriptedToolBackend(
        script: [
            toolCallResponse("Again.", [
                ToolCallRequest(id: "call-again", name: "skills_list", input: [:]),
            ]),
        ],
        repeatsLastResponse: true,
        delayNanoseconds: 50_000_000
    )
    // terminatesSubprocesses: false — the process registry is global and
    // killing it here would take out unrelated test children.
    let monitor = ToolLoopMonitor(terminatesSubprocesses: false)
    let service = makeService(ledger: try RunLedgerStore.inMemory())

    let runTask = Task {
        try await service.createRun(
            prompt: "Loop until cancelled.",
            ontology: OntologyLoader.load(),
            backend: backend,
            tools: HarnessToolCatalog.v1,
            toolExecutor: executor,
            toolLoop: monitor
        )
    }
    // Let the loop take a few turns, then Adam cancels.
    for _ in 0..<200 {
        if backend.modelCallCount >= 2 { break }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    monitor.cancel()

    let detail = try await runTask.value
    #expect(!detail.run.success)
    #expect(detail.run.finalAnswer.contains("cancelled"))
    #expect(monitor.isCancelled)
    #expect(monitor.progressSnapshot().phase == .cancelled)
    #expect(backend.modelCallCount < 31)
}

// MARK: - Wire formats (no network)

@Test func claudeToolRequestBodyEncodesToolUseAndResults() throws {
    let turn = ToolLoopTurn(
        assistantText: "Checking the vault.",
        toolCalls: [
            ToolCallRequest(id: "toolu_1", name: "read_file", input: ["path": "~/Documents/Main/x.md"]),
        ],
        toolResults: [
            ToolCallResult(callId: "toolu_1", result: ToolResult(toolName: "read_file", output: "1|hello")),
        ]
    )
    let body = ClaudeClient.toolRequestBody(
        model: "claude-sonnet-4-6",
        system: "system prompt",
        messages: [(role: "user", text: "hi")],
        tools: [HarnessToolCatalog.spec(named: "read_file")!],
        toolTranscript: [turn]
    )

    let tools = try #require(body["tools"] as? [[String: Any]])
    #expect(tools.first?["name"] as? String == "read_file")
    #expect(tools.first?["input_schema"] is [String: Any])

    let messages = try #require(body["messages"] as? [[String: Any]])
    #expect(messages.count == 3)
    let assistant = try #require(messages[1]["content"] as? [[String: Any]])
    #expect(assistant.contains { $0["type"] as? String == "tool_use" && $0["id"] as? String == "toolu_1" })
    let toolResults = try #require(messages[2]["content"] as? [[String: Any]])
    #expect(toolResults.first?["type"] as? String == "tool_result")
    #expect(toolResults.first?["tool_use_id"] as? String == "toolu_1")
    #expect(toolResults.first?["content"] as? String == "1|hello")
}

@Test func claudeParsesToolUseBlocksAndUsage() throws {
    let fixture = """
    {
      "content": [
        {"type": "text", "text": "Let me check."},
        {"type": "tool_use", "id": "toolu_9", "name": "shell", "input": {"command": "ls", "timeout": 30}}
      ],
      "stop_reason": "tool_use",
      "usage": {"input_tokens": 20, "output_tokens": 10}
    }
    """.data(using: .utf8)!

    let response = try ClaudeClient.parseToolResponse(data: fixture, statusCode: 200)

    #expect(response.text == "Let me check.")
    #expect(response.tokenCount == 30)
    #expect(response.toolCalls.count == 1)
    #expect(response.toolCalls.first?.id == "toolu_9")
    #expect(response.toolCalls.first?.name == "shell")
    #expect(response.toolCalls.first?.input["command"]?.stringValue == "ls")
    #expect(response.toolCalls.first?.input["timeout"]?.intValue == 30)
}

@Test func xaiToolRequestBodyEncodesFunctionToolsAndToolMessages() throws {
    let turn = ToolLoopTurn(
        assistantText: "",
        toolCalls: [
            ToolCallRequest(id: "call_7", name: "shell", input: ["command": "echo hi"]),
        ],
        toolResults: [
            ToolCallResult(callId: "call_7", result: ToolResult(toolName: "shell", output: "nope", isError: true)),
        ]
    )
    let body = XAIClient.toolRequestBody(
        model: "grok-4.3",
        system: "system prompt",
        messages: [XAIClient.Message(role: "user", text: "hi")],
        tools: [HarnessToolCatalog.spec(named: "shell")!],
        toolTranscript: [turn]
    )

    let tools = try #require(body["tools"] as? [[String: Any]])
    let function = try #require(tools.first?["function"] as? [String: Any])
    #expect(tools.first?["type"] as? String == "function")
    #expect(function["name"] as? String == "shell")
    #expect(function["parameters"] is [String: Any])

    let messages = try #require(body["messages"] as? [[String: Any]])
    #expect(messages.count == 4) // system, user, assistant tool_calls, tool result
    let assistant = messages[2]
    let toolCalls = try #require(assistant["tool_calls"] as? [[String: Any]])
    #expect(toolCalls.first?["id"] as? String == "call_7")
    let arguments = try #require((toolCalls.first?["function"] as? [String: Any])?["arguments"] as? String)
    #expect(arguments.contains("echo hi"))
    let toolMessage = messages[3]
    #expect(toolMessage["role"] as? String == "tool")
    #expect(toolMessage["tool_call_id"] as? String == "call_7")
    // Errors are prefixed so the OpenAI shape (no is_error) still signals failure.
    #expect((toolMessage["content"] as? String)?.hasPrefix("ERROR:") == true)
}

@Test func xaiParsesToolCallsWithJSONStringArguments() throws {
    let fixture = """
    {
      "choices": [
        {
          "message": {
            "content": null,
            "tool_calls": [
              {"id": "call_3", "type": "function", "function": {"name": "search_files", "arguments": "{\\"pattern\\": \\"fuseki\\", \\"path\\": \\"~/Documents/Main\\"}"}}
            ]
          }
        }
      ],
      "usage": {"total_tokens": 42}
    }
    """.data(using: .utf8)!

    let response = try XAIClient.parseToolResponse(data: fixture, statusCode: 200)

    #expect(response.text.isEmpty)
    #expect(response.tokenCount == 42)
    #expect(response.toolCalls.first?.id == "call_3")
    #expect(response.toolCalls.first?.name == "search_files")
    #expect(response.toolCalls.first?.input["pattern"]?.stringValue == "fuseki")
}

@Test func openAIToolRequestBodyEncodesFunctionToolsAndToolMessages() throws {
    let turn = ToolLoopTurn(
        assistantText: "",
        toolCalls: [
            ToolCallRequest(id: "call_9", name: "shell", input: ["command": "echo hi"]),
        ],
        toolResults: [
            ToolCallResult(callId: "call_9", result: ToolResult(toolName: "shell", output: "nope", isError: true)),
        ]
    )
    let body = OpenAIClient.toolRequestBody(
        model: "gpt-4o",
        system: "system prompt",
        messages: [OpenAIClient.Message(role: "user", text: "hi")],
        tools: [HarnessToolCatalog.spec(named: "shell")!],
        toolTranscript: [turn]
    )

    let tools = try #require(body["tools"] as? [[String: Any]])
    let function = try #require(tools.first?["function"] as? [String: Any])
    #expect(tools.first?["type"] as? String == "function")
    #expect(function["name"] as? String == "shell")
    #expect(function["parameters"] is [String: Any])

    let messages = try #require(body["messages"] as? [[String: Any]])
    #expect(messages.count == 4) // system, user, assistant tool_calls, tool result
    let toolCalls = try #require((messages[2])["tool_calls"] as? [[String: Any]])
    #expect(toolCalls.first?["id"] as? String == "call_9")
    let toolMessage = messages[3]
    #expect(toolMessage["role"] as? String == "tool")
    #expect(toolMessage["tool_call_id"] as? String == "call_9")
    #expect((toolMessage["content"] as? String)?.hasPrefix("ERROR:") == true)
}

@Test func openAIParsesToolCallsWithJSONStringArguments() throws {
    let fixture = """
    {
      "choices": [
        {
          "message": {
            "content": null,
            "tool_calls": [
              {"id": "call_5", "type": "function", "function": {"name": "read_file", "arguments": "{\\"path\\": \\"~/Documents/Main/SOUL.md\\"}"}}
            ]
          }
        }
      ],
      "usage": {"total_tokens": 17}
    }
    """.data(using: .utf8)!

    let response = try OpenAIClient.parseToolResponse(data: fixture, statusCode: 200)

    #expect(response.tokenCount == 17)
    #expect(response.toolCalls.first?.id == "call_5")
    #expect(response.toolCalls.first?.name == "read_file")
    #expect(response.toolCalls.first?.input["path"]?.stringValue == "~/Documents/Main/SOUL.md")
}

@Test func codexToolRequestBodyUsesResponsesFunctionFormat() throws {
    let turn = ToolLoopTurn(
        assistantText: "",
        toolCalls: [ToolCallRequest(id: "fc_1", name: "shell", input: ["command": "echo hi"])],
        toolResults: [ToolCallResult(callId: "fc_1", result: ToolResult(toolName: "shell", output: "nope", isError: true))]
    )
    let body = CodexSessionClient.toolRequestBody(
        model: "gpt-5.5",
        system: "system prompt",
        messages: [CodexSessionClient.Message(role: "user", text: "hi")],
        tools: [HarnessToolCatalog.spec(named: "shell")!],
        toolTranscript: [turn]
    )
    // Responses API: system rides in `instructions`; tools are FLAT functions
    // (no nested "function" key like chat/completions); streaming is required.
    #expect(body["instructions"] as? String == "system prompt")
    #expect(body["stream"] as? Bool == true)
    let tools = try #require(body["tools"] as? [[String: Any]])
    #expect(tools.first?["type"] as? String == "function")
    #expect(tools.first?["name"] as? String == "shell")
    #expect(tools.first?["parameters"] is [String: Any])
    // Prior turn replays as function_call + function_call_output input items.
    let input = try #require(body["input"] as? [[String: Any]])
    #expect(input.contains { $0["type"] as? String == "function_call" && $0["call_id"] as? String == "fc_1" })
    let output = try #require(input.first { $0["type"] as? String == "function_call_output" })
    #expect(output["call_id"] as? String == "fc_1")
    #expect((output["output"] as? String)?.hasPrefix("ERROR:") == true)
}

@Test func codexParsesStreamingFunctionCall() throws {
    // Real Responses SSE event shapes: text deltas, a completed function call
    // in output_item.done (call_id + name + arguments), usage on completed.
    let lines = [
        #"data: {"type":"response.output_text.delta","delta":"look"}"#,
        #"data: {"type":"response.output_item.done","item":{"id":"fc_x","type":"function_call","status":"completed","arguments":"{\"pattern\":\"fuseki\",\"path\":\"~/Documents/Main\"}","call_id":"call_9","name":"search_files"}}"#,
        #"data: {"type":"response.completed","response":{"usage":{"total_tokens":21}}}"#,
        "data: [DONE]",
    ]
    let response = try CodexSessionClient.parseToolStream(lines: lines, statusCode: 200)
    #expect(response.text == "look")
    #expect(response.tokenCount == 21)
    #expect(response.toolCalls.first?.id == "call_9")
    #expect(response.toolCalls.first?.name == "search_files")
    #expect(response.toolCalls.first?.input["pattern"]?.stringValue == "fuseki")
}

@Test func codexToolStreamSurfacesHTTPError() {
    let lines = [#"data: {"detail":"Stream must be set to true"}"#]
    #expect(throws: CodexSessionClient.CodexSessionError.self) {
        try CodexSessionClient.parseToolStream(lines: lines, statusCode: 400)
    }
}

/// The whole point of this change: all three API backends report tool-capable
/// when their key is present, so none of them silently falls back to a
/// tool-less single-shot run.
@Test func allThreeAPIBackendsSupportToolLoopWithAKey() {
    let runner = AgentRunner()
    #expect(runner.supportsToolLoop(backend: .claude, apiKey: "test-anthropic-key"))
    #expect(runner.supportsToolLoop(backend: .grok, apiKey: "test-grok-key"))
    #expect(runner.supportsToolLoop(backend: .codex, apiKey: "test-openai-key"))
    // Local Hermes stays single-shot by design.
    #expect(!runner.supportsToolLoop(backend: .hermes, apiKey: "x"))
}
