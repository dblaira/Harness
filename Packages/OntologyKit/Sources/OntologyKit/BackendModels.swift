import Foundation

public enum AuthorityLevel: String, Codable, Sendable, Equatable {
    case accepted
    case supporting
    case candidate
}

public enum CandidateState: String, Codable, Sendable, Equatable, CaseIterable {
    case suggested
    case candidate
    case validated
    case accepted
    case rejected
}

public enum MessageRole: String, Codable, Sendable, Equatable {
    case user
    case assistant
    case system
}

public enum TraceStage: String, Codable, Sendable, Equatable {
    case createRun
    case soulLoad
    case graphHealth
    case authorityRetrieval
    case supportingRetrieval
    case toolCall
    case toolResult
    case modelExecution
    case evaluation
    case traceSaved
}

public struct HarnessRun: Identifiable, Codable, Sendable, Equatable {
    public let id: String
    public let prompt: String
    public let backend: String
    public let modelName: String
    public let invocationMethod: String
    public let promptPacketHash: String
    public let success: Bool
    public let duration: TimeInterval
    public let tokenCount: Int?
    public let cost: Double?
    public let finalAnswer: String
    public let deviceName: String
    public let createdAt: Date

    public init(
        id: String = UUID().uuidString,
        prompt: String,
        backend: String,
        modelName: String,
        invocationMethod: String,
        promptPacketHash: String,
        success: Bool,
        duration: TimeInterval,
        tokenCount: Int?,
        cost: Double?,
        finalAnswer: String,
        deviceName: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.prompt = prompt
        self.backend = backend
        self.modelName = modelName
        self.invocationMethod = invocationMethod
        self.promptPacketHash = promptPacketHash
        self.success = success
        self.duration = duration
        self.tokenCount = tokenCount
        self.cost = cost
        self.finalAnswer = finalAnswer
        self.deviceName = deviceName
        self.createdAt = createdAt
    }
}

public struct HarnessMessage: Identifiable, Codable, Sendable, Equatable {
    public let id: String
    public let runId: String
    public let role: MessageRole
    public let text: String
    public let createdAt: Date

    public init(id: String = UUID().uuidString, runId: String, role: MessageRole, text: String, createdAt: Date = Date()) {
        self.id = id
        self.runId = runId
        self.role = role
        self.text = text
        self.createdAt = createdAt
    }
}

public struct GraphAuthorityHit: Identifiable, Codable, Sendable, Equatable {
    public let id: String
    public let runId: String?
    public let subject: String
    public let predicate: String
    public let object: String
    public let source: String
    public let queryTrace: String
    public let authorityLevel: AuthorityLevel
    public let score: Double

    public var sparqlTrace: String { queryTrace }

    public init(
        id: String = UUID().uuidString,
        runId: String? = nil,
        subject: String,
        predicate: String,
        object: String,
        source: String,
        queryTrace: String,
        authorityLevel: AuthorityLevel = .accepted,
        score: Double = 0
    ) {
        self.id = id
        self.runId = runId
        self.subject = subject
        self.predicate = predicate
        self.object = object
        self.source = source
        self.queryTrace = queryTrace
        self.authorityLevel = authorityLevel
        self.score = score
    }

    public func attached(to runId: String) -> GraphAuthorityHit {
        GraphAuthorityHit(
            id: id,
            runId: runId,
            subject: subject,
            predicate: predicate,
            object: object,
            source: source,
            queryTrace: queryTrace,
            authorityLevel: authorityLevel,
            score: score
        )
    }
}

public struct MemoryHit: Identifiable, Codable, Sendable, Equatable {
    public let id: String
    public let runId: String?
    public let source: String
    public let excerpt: String
    public let score: Double
    public let reasonSelected: String
    public let authorityLevel: AuthorityLevel
    public let sourceCard: SourceCard?

    public init(
        id: String = UUID().uuidString,
        runId: String? = nil,
        source: String,
        excerpt: String,
        score: Double,
        reasonSelected: String,
        authorityLevel: AuthorityLevel,
        sourceCard: SourceCard? = nil
    ) {
        self.id = id
        self.runId = runId
        self.source = source
        self.excerpt = excerpt
        self.score = score
        self.reasonSelected = reasonSelected
        self.authorityLevel = authorityLevel
        self.sourceCard = sourceCard
    }

    public func attached(to runId: String) -> MemoryHit {
        MemoryHit(
            id: id,
            runId: runId,
            source: source,
            excerpt: excerpt,
            score: score,
            reasonSelected: reasonSelected,
            authorityLevel: authorityLevel,
            sourceCard: sourceCard
        )
    }
}

public struct SourceCard: Identifiable, Codable, Sendable, Equatable {
    public let id: String
    public let source: String
    public let connectorTitle: String
    public let connectorKind: String
    public let type: String
    public let title: String?
    public let description: String?
    public let tags: [String]
    public let resource: String?
    public let timestamp: String?
    public let declaredTrustLevel: String?
    public let authorityLevel: AuthorityLevel
    public let trustNote: String?

    public init(
        id: String? = nil,
        source: String,
        connectorTitle: String,
        connectorKind: String,
        type: String,
        title: String? = nil,
        description: String? = nil,
        tags: [String] = [],
        resource: String? = nil,
        timestamp: String? = nil,
        declaredTrustLevel: String? = nil,
        authorityLevel: AuthorityLevel,
        trustNote: String? = nil
    ) {
        self.id = id ?? source
        self.source = source
        self.connectorTitle = connectorTitle
        self.connectorKind = connectorKind
        self.type = type
        self.title = title
        self.description = description
        self.tags = tags
        self.resource = resource
        self.timestamp = timestamp
        self.declaredTrustLevel = declaredTrustLevel
        self.authorityLevel = authorityLevel
        self.trustNote = trustNote
    }
}

public struct TraceEvent: Identifiable, Codable, Sendable, Equatable {
    public let id: String
    public let runId: String
    public let stage: TraceStage
    public let message: String
    public let createdAt: Date

    public init(id: String = UUID().uuidString, runId: String, stage: TraceStage, message: String, createdAt: Date = Date()) {
        self.id = id
        self.runId = runId
        self.stage = stage
        self.message = message
        self.createdAt = createdAt
    }
}

public struct EvalResult: Identifiable, Codable, Sendable, Equatable {
    public let id: String
    public let runId: String
    public let checkName: String
    public let passed: Bool
    public let detail: String
    /// CLAUDE.md hard rule 3: "A verification Pass is invalid without an
    /// on-disk artifact path." nil for checks that have no artifact
    /// (most existing checks); WO-Q's build-and-screenshot spike is the
    /// first to populate it, and its own `passed` is gated on this path
    /// actually existing on disk -- never on a shell exit code alone.
    public let artifactPath: String?

    public init(
        id: String = UUID().uuidString,
        runId: String,
        checkName: String,
        passed: Bool,
        detail: String,
        artifactPath: String? = nil
    ) {
        self.id = id
        self.runId = runId
        self.checkName = checkName
        self.passed = passed
        self.detail = detail
        self.artifactPath = artifactPath
    }
}

public struct ValidationResult: Identifiable, Codable, Sendable, Equatable {
    public let id: String
    public let runId: String?
    public let candidateId: String?
    public let kind: String
    public let passed: Bool
    public let detail: String
    public let createdAt: Date

    public init(
        id: String = UUID().uuidString,
        runId: String? = nil,
        candidateId: String? = nil,
        kind: String,
        passed: Bool,
        detail: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.runId = runId
        self.candidateId = candidateId
        self.kind = kind
        self.passed = passed
        self.detail = detail
        self.createdAt = createdAt
    }
}

public struct MemoryCandidate: Identifiable, Codable, Sendable, Equatable {
    public let id: String
    public let runId: String
    public let sourceRunIds: [String]
    public let evidenceText: String
    public let proposedClaim: String
    public let proposedGraph: String?
    public let status: CandidateState
    public let validationResult: String?
    public let createdAt: Date
    public let plainEnglish: String
    public let evidenceNote: String
    public let sourceRef: String
    public let strength: Double?
    public let frequency: String?

    public init(
        id: String = UUID().uuidString,
        runId: String,
        sourceRunIds: [String],
        evidenceText: String,
        proposedClaim: String,
        proposedGraph: String?,
        status: CandidateState,
        validationResult: String?,
        createdAt: Date = Date(),
        plainEnglish: String? = nil,
        evidenceNote: String? = nil,
        sourceRef: String? = nil,
        strength: Double? = nil,
        frequency: String? = nil
    ) {
        self.id = id
        self.runId = runId
        self.sourceRunIds = sourceRunIds
        self.evidenceText = evidenceText
        self.proposedClaim = proposedClaim
        self.proposedGraph = proposedGraph
        self.status = status
        self.validationResult = validationResult
        self.createdAt = createdAt
        self.plainEnglish = plainEnglish ?? proposedClaim
        self.evidenceNote = evidenceNote ?? evidenceText
        self.sourceRef = sourceRef ?? runId
        self.strength = strength
        self.frequency = frequency
    }
}

public struct ReviewQueueDecisionRecord: Identifiable, Codable, Sendable, Equatable {
    public let id: String
    public let claimId: String
    public let decision: String
    public let frequency: String?
    public let claim: String
    public let evidenceNote: String
    public let sourceRef: String
    public let createdAt: Date

    public init(
        id: String = UUID().uuidString,
        claimId: String,
        decision: String,
        frequency: String?,
        claim: String,
        evidenceNote: String,
        sourceRef: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.claimId = claimId
        self.decision = decision
        self.frequency = frequency
        self.claim = claim
        self.evidenceNote = evidenceNote
        self.sourceRef = sourceRef
        self.createdAt = createdAt
    }
}

public struct HarnessRunDetail: Identifiable, Codable, Sendable, Equatable {
    public var id: String { run.id }
    public let run: HarnessRun
    public let messages: [HarnessMessage]
    public let authorityHits: [GraphAuthorityHit]
    public let memoryHits: [MemoryHit]
    public let traceEvents: [TraceEvent]
    public let evalResults: [EvalResult]
    public let memoryCandidates: [MemoryCandidate]
    public let validationResults: [ValidationResult]

    public init(
        run: HarnessRun,
        messages: [HarnessMessage],
        authorityHits: [GraphAuthorityHit],
        memoryHits: [MemoryHit],
        traceEvents: [TraceEvent],
        evalResults: [EvalResult],
        memoryCandidates: [MemoryCandidate],
        validationResults: [ValidationResult]
    ) {
        self.run = run
        self.messages = messages
        self.authorityHits = authorityHits
        self.memoryHits = memoryHits
        self.traceEvents = traceEvents
        self.evalResults = evalResults
        self.memoryCandidates = memoryCandidates
        self.validationResults = validationResults
    }
}

public struct BackendMetadata: Codable, Sendable, Equatable {
    public let backend: Backend
    public let modelName: String
    public let invocationMethod: String

    public init(backend: Backend, modelName: String, invocationMethod: String) {
        self.backend = backend
        self.modelName = modelName
        self.invocationMethod = invocationMethod
    }
}

public struct ModelPacket: Codable, Sendable, Equatable {
    public let userPrompt: String
    public let system: String
    public let authorityHits: [GraphAuthorityHit]
    public let memoryHits: [MemoryHit]
    public let policyDirectives: [AgentPolicyDirective]
    public let images: [ModelImageAttachment]
    public let conversationHistory: [ConversationTurn]
    public let soulPath: String?
    public let promptPacketHash: String
    /// Tool definitions the model may call (empty means single-shot). The
    /// tools list is the ONLY capability grant — no spend/trade/contact/
    /// commit tool exists in `HarnessToolCatalog`, and every mutation a tool
    /// can reach routes through the bouncer.
    public let tools: [ToolSpec]

    public init(
        userPrompt: String,
        system: String,
        authorityHits: [GraphAuthorityHit],
        memoryHits: [MemoryHit],
        policyDirectives: [AgentPolicyDirective] = [],
        images: [ModelImageAttachment] = [],
        conversationHistory: [ConversationTurn] = [],
        soulPath: String? = nil,
        promptPacketHash: String,
        tools: [ToolSpec] = []
    ) {
        self.userPrompt = userPrompt
        self.system = system
        self.authorityHits = authorityHits
        self.memoryHits = memoryHits
        self.policyDirectives = policyDirectives
        self.images = images
        self.conversationHistory = conversationHistory
        self.soulPath = soulPath
        self.promptPacketHash = promptPacketHash
        self.tools = tools
    }

    /// Copy of this packet with a tool catalog attached. Lets the run
    /// service grant tools without changing `PromptPacketBuilder.makePacket`
    /// call sites (WS-A1 owns that file).
    public func withTools(_ tools: [ToolSpec]) -> ModelPacket {
        ModelPacket(
            userPrompt: userPrompt,
            system: system,
            authorityHits: authorityHits,
            memoryHits: memoryHits,
            policyDirectives: policyDirectives,
            images: images,
            conversationHistory: conversationHistory,
            soulPath: soulPath,
            promptPacketHash: promptPacketHash,
            tools: tools
        )
    }
}

/// One tool call the model asked for: the provider call id (tool_use id for
/// Anthropic, tool_call id for OpenAI-compatible APIs), the tool name, and
/// the parsed JSON input.
public struct ToolCallRequest: Codable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let input: JSONValue

    public init(id: String, name: String, input: JSONValue) {
        self.id = id
        self.name = name
        self.input = input
    }
}

/// The executor's answer to one tool call, keyed by the provider call id so
/// clients can pair tool_result/tool messages with the originating call.
public struct ToolCallResult: Codable, Sendable, Equatable {
    public let callId: String
    public let result: ToolResult

    public init(callId: String, result: ToolResult) {
        self.callId = callId
        self.result = result
    }
}

/// One completed round of the agentic loop: what the model said, the tool
/// calls it made, and what the tools returned. Backends replay these as
/// provider-native tool_use/tool_result (Anthropic) or tool_calls/tool
/// (OpenAI-compatible) messages when continuing the conversation.
public struct ToolLoopTurn: Codable, Sendable, Equatable {
    public let assistantText: String
    public let toolCalls: [ToolCallRequest]
    public let toolResults: [ToolCallResult]

    public init(assistantText: String, toolCalls: [ToolCallRequest], toolResults: [ToolCallResult]) {
        self.assistantText = assistantText
        self.toolCalls = toolCalls
        self.toolResults = toolResults
    }
}

public struct BackendResponse: Codable, Sendable, Equatable {
    public let text: String
    public let tokenCount: Int?
    public let cost: Double?
    /// Tool calls the model wants executed before it can finish. Empty for
    /// single-shot backends and for the final answer of a tool loop.
    public let toolCalls: [ToolCallRequest]

    public init(text: String, tokenCount: Int?, cost: Double?, toolCalls: [ToolCallRequest] = []) {
        self.text = text
        self.tokenCount = tokenCount
        self.cost = cost
        self.toolCalls = toolCalls
    }
}

public protocol ModelBackendAdapter: Sendable {
    var metadata: BackendMetadata { get }
    func execute(packet: ModelPacket) async throws -> BackendResponse
}

/// A backend that can run the native tool loop: it accepts the packet's tool
/// catalog, replays prior loop turns, and surfaces new tool calls on the
/// response. Backends without native tool support simply never conform (or
/// report `supportsTools == false`) and stay single-shot.
public protocol ToolCapableModelBackend: ModelBackendAdapter {
    /// Whether this backend can actually speak native tool calls right now
    /// (e.g. Grok can through xAI API keys or the Grok session proxy; CLI
    /// subprocess fallbacks stay single-shot with their safety flags).
    var supportsTools: Bool { get }
    func execute(packet: ModelPacket, toolTranscript: [ToolLoopTurn]) async throws -> BackendResponse
}

// MARK: - JSONValue <-> Foundation bridging

public extension JSONValue {
    /// Foundation representation for JSONSerialization request bodies.
    var anyValue: Any {
        switch self {
        case .null:
            return NSNull()
        case .bool(let value):
            return value
        case .number(let value):
            if let int = Int(exactly: value) { return int }
            return value
        case .string(let value):
            return value
        case .array(let values):
            return values.map(\.anyValue)
        case .object(let values):
            return values.mapValues(\.anyValue)
        }
    }

    /// Parse a JSONSerialization tree (the shape provider responses arrive in).
    init?(any: Any) {
        if any is NSNull {
            self = .null
            return
        }
        if let number = any as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else {
                self = .number(number.doubleValue)
            }
            return
        }
        if let string = any as? String {
            self = .string(string)
            return
        }
        if let array = any as? [Any] {
            var values: [JSONValue] = []
            values.reserveCapacity(array.count)
            for element in array {
                guard let value = JSONValue(any: element) else { return nil }
                values.append(value)
            }
            self = .array(values)
            return
        }
        if let dictionary = any as? [String: Any] {
            var values: [String: JSONValue] = [:]
            values.reserveCapacity(dictionary.count)
            for (key, element) in dictionary {
                guard let value = JSONValue(any: element) else { return nil }
                values[key] = value
            }
            self = .object(values)
            return
        }
        return nil
    }

    /// Compact JSON text (OpenAI-compatible tool_calls carry arguments as a
    /// JSON string).
    var jsonString: String {
        guard let data = try? JSONSerialization.data(
            withJSONObject: anyValue,
            options: [.fragmentsAllowed, .sortedKeys]
        ), let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }
}
