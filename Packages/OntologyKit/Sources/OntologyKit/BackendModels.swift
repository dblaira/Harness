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
    case authorityRetrieval
    case supportingRetrieval
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

    public init(
        id: String = UUID().uuidString,
        runId: String? = nil,
        source: String,
        excerpt: String,
        score: Double,
        reasonSelected: String,
        authorityLevel: AuthorityLevel
    ) {
        self.id = id
        self.runId = runId
        self.source = source
        self.excerpt = excerpt
        self.score = score
        self.reasonSelected = reasonSelected
        self.authorityLevel = authorityLevel
    }

    public func attached(to runId: String) -> MemoryHit {
        MemoryHit(
            id: id,
            runId: runId,
            source: source,
            excerpt: excerpt,
            score: score,
            reasonSelected: reasonSelected,
            authorityLevel: authorityLevel
        )
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

    public init(id: String = UUID().uuidString, runId: String, checkName: String, passed: Bool, detail: String) {
        self.id = id
        self.runId = runId
        self.checkName = checkName
        self.passed = passed
        self.detail = detail
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
    public let promptPacketHash: String

    public init(
        userPrompt: String,
        system: String,
        authorityHits: [GraphAuthorityHit],
        memoryHits: [MemoryHit],
        promptPacketHash: String
    ) {
        self.userPrompt = userPrompt
        self.system = system
        self.authorityHits = authorityHits
        self.memoryHits = memoryHits
        self.promptPacketHash = promptPacketHash
    }
}

public struct BackendResponse: Codable, Sendable, Equatable {
    public let text: String
    public let tokenCount: Int?
    public let cost: Double?

    public init(text: String, tokenCount: Int?, cost: Double?) {
        self.text = text
        self.tokenCount = tokenCount
        self.cost = cost
    }
}

public protocol ModelBackendAdapter: Sendable {
    var metadata: BackendMetadata { get }
    func execute(packet: ModelPacket) async throws -> BackendResponse
}
