import Foundation

public enum ReviewQueueDecision: Sendable, Equatable {
    case yes
    case sometimes
    case no

    var acceptedFrequency: String? {
        switch self {
        case .yes:
            return "usually"
        case .sometimes:
            return "sometimes"
        case .no:
            return nil
        }
    }
}

public struct ReviewQueueOutcome: Sendable, Equatable {
    public let claimId: String
    public let accepted: Bool
    public let blockedReason: String?

    public init(claimId: String, accepted: Bool, blockedReason: String? = nil) {
        self.claimId = claimId
        self.accepted = accepted
        self.blockedReason = blockedReason
    }
}

public struct TurtleParseError: Error, LocalizedError, Sendable, Equatable {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? { message }
}

public protocol TurtleParsing: Sendable {
    func parse(_ turtle: String) throws
}

public struct PythonRdflibTurtleParser: TurtleParsing {
    private let pythonPath: String?

    public init(pythonPath: String? = nil) {
        self.pythonPath = pythonPath
    }

    public func parse(_ turtle: String) throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("harness-turtle-\(UUID().uuidString).ttl")
        try turtle.write(to: tempURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: try resolvePython())
        process.arguments = [
            "-c",
            "import rdflib, sys; g=rdflib.Graph(); g.parse(sys.argv[1], format='turtle'); print(len(g))",
            tempURL.path
        ]
        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = Pipe()
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw TurtleParseError(message?.isEmpty == false ? message! : "Turtle did not parse.")
        }
    }

    private func resolvePython() throws -> String {
        if let pythonPath, FileManager.default.isExecutableFile(atPath: pythonPath) {
            return pythonPath
        }
        if let envPath = ProcessInfo.processInfo.environment["HARNESS_RDFLIB_PYTHON"],
           FileManager.default.isExecutableFile(atPath: envPath) {
            return envPath
        }

        let candidates = [
            FileManager.default.currentDirectoryPath + "/.venv/bin/python3",
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Developer/GitHub/Harness/.venv/bin/python3").path,
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3",
            "/usr/bin/python3"
        ]
        if let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return path
        }
        throw TurtleParseError("Python 3 was not found for Turtle validation.")
    }
}

public final class ReviewQueueStore: Sendable {
    private let ontologyRoot: URL
    private let ledger: RunLedgerStore
    private let turtleParser: any TurtleParsing

    public init(
        ontologyRoot: URL = ReviewQueueStore.defaultOntologyRoot(),
        ledger: RunLedgerStore,
        turtleParser: any TurtleParsing = PythonRdflibTurtleParser()
    ) {
        self.ontologyRoot = ontologyRoot
        self.ledger = ledger
        self.turtleParser = turtleParser
    }

    public static func defaultOntologyRoot() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/Documents/Main/Ontology", isDirectory: true)
    }

    public func loadPendingClaims() async throws -> [MemoryCandidate] {
        try loadQueue()
            .filter { $0.status == "pending" }
            .map { $0.memoryCandidate }
    }

    public func decide(claimId: String, decision: ReviewQueueDecision) async throws -> ReviewQueueOutcome {
        var queue = try loadQueue()
        guard let index = queue.firstIndex(where: { $0.id == claimId }) else {
            throw ReviewQueueError.claimNotFound(claimId)
        }
        var claim = queue[index]

        if let frequency = decision.acceptedFrequency {
            let turtle = Self.turtle(for: claim, frequency: frequency, acceptedAt: Date())
            do {
                try turtleParser.parse(Self.prefixes + turtle)
            } catch {
                let detail = "Blocked: \(plainValidationMessage(error))"
                claim.blockedReason = detail
                queue[index] = claim
                try saveQueue(queue)
                return ReviewQueueOutcome(claimId: claimId, accepted: false, blockedReason: detail)
            }

            try appendToAcceptedGraph(turtle)
            claim.status = "accepted"
            claim.frequency = frequency
            claim.blockedReason = nil
            queue[index] = claim
            try saveQueue(queue)
            try await ledger.recordReviewQueueDecision(
                ReviewQueueDecisionRecord(
                    claimId: claim.id,
                    decision: "accepted",
                    frequency: frequency,
                    claim: claim.plain,
                    evidenceNote: claim.evidence,
                    sourceRef: claim.source
                )
            )
            return ReviewQueueOutcome(claimId: claimId, accepted: true)
        }

        claim.status = "rejected"
        claim.blockedReason = nil
        queue[index] = claim
        try saveQueue(queue)
        try await ledger.recordReviewQueueDecision(
            ReviewQueueDecisionRecord(
                claimId: claim.id,
                decision: "rejected",
                frequency: nil,
                claim: claim.plain,
                evidenceNote: claim.evidence,
                sourceRef: claim.source
            )
        )
        return ReviewQueueOutcome(claimId: claimId, accepted: false)
    }

    private func loadQueue() throws -> [ReviewQueueClaim] {
        let data = try Data(contentsOf: queueURL)
        return try JSONDecoder().decode([ReviewQueueClaim].self, from: data)
    }

    private func saveQueue(_ queue: [ReviewQueueClaim]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(queue)
        try FileManager.default.createDirectory(at: candidatesURL, withIntermediateDirectories: true)
        try data.write(to: queueURL, options: .atomic)
    }

    private func appendToAcceptedGraph(_ turtle: String) throws {
        try FileManager.default.createDirectory(at: acceptedURL, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: acceptedGraphURL.path) {
            try ("# Accepted graph - claims approved by Adam via review queue.\n\n" + Self.prefixes)
                .write(to: acceptedGraphURL, atomically: true, encoding: .utf8)
        }
        let handle = try FileHandle(forWritingTo: acceptedGraphURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        if let data = turtle.data(using: .utf8) {
            try handle.write(contentsOf: data)
        }
    }

    private func plainValidationMessage(_ error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return error.localizedDescription
    }

    private var acceptedURL: URL { ontologyRoot.appendingPathComponent("accepted", isDirectory: true) }
    private var candidatesURL: URL { ontologyRoot.appendingPathComponent("candidates", isDirectory: true) }
    private var queueURL: URL { candidatesURL.appendingPathComponent("queue.json") }
    private var acceptedGraphURL: URL { acceptedURL.appendingPathComponent("accepted-graph.ttl") }

    private static let prefixes = """
    @prefix understood: <https://understood.app/ontology#> .
    @prefix xsd: <http://www.w3.org/2001/XMLSchema#> .

    """

    private static func turtle(for claim: ReviewQueueClaim, frequency: String, acceptedAt: Date) -> String {
        let cid = claim.id.replacingOccurrences(of: "cand-", with: "conn-obs-")
        let label = escapeLiteral(String(claim.plain.trimmingCharacters(in: CharacterSet(charactersIn: "."))))
        let evidence = escapeLiteral(claim.evidence)
        let timestamp = ISO8601DateFormatter.reviewQueue.string(from: acceptedAt)
        return """

        <https://understood.app/ontology/connection/\(cid)> a understood:Connection ;
          understood:label "\(label)" ;
          understood:connectionType "\(escapeLiteral(claim.connectionType))" ;
          understood:inLifeDomain <https://understood.app/ontology/domain/\(claim.domainA)> ;
          understood:inLifeDomain <https://understood.app/ontology/domain/\(claim.domainB)> ;
          understood:strength "\(String(format: "%.2f", claim.strength))"^^xsd:decimal ;
          understood:frequency "\(frequency)" ;
          understood:evidenceNote "\(evidence)" ;
          understood:acceptedAt "\(timestamp)"^^xsd:dateTime ;
          .

        """
    }

    private static func escapeLiteral(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
    }
}

public enum ReviewQueueError: Error, LocalizedError, Sendable, Equatable {
    case claimNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .claimNotFound(let id):
            return "Claim not found: \(id)"
        }
    }
}

private struct ReviewQueueClaim: Codable, Sendable, Equatable {
    var id: String
    var status: String
    var plain: String
    var evidence: String
    var source: String
    var domainA: String
    var domainB: String
    var strength: Double
    var connectionType: String
    var frequency: String?
    var blockedReason: String?

    enum CodingKeys: String, CodingKey {
        case id
        case status
        case plain
        case evidence
        case source
        case domainA = "domain_a"
        case domainB = "domain_b"
        case strength
        case connectionType = "connection_type"
        case frequency
        case blockedReason = "blocked_reason"
    }

    var memoryCandidate: MemoryCandidate {
        MemoryCandidate(
            id: id,
            runId: "review-queue",
            sourceRunIds: [],
            evidenceText: evidence,
            proposedClaim: plain,
            proposedGraph: nil,
            status: CandidateState(rawValue: status) ?? .candidate,
            validationResult: blockedReason,
            plainEnglish: plain,
            evidenceNote: evidence,
            sourceRef: source,
            strength: strength,
            frequency: frequency
        )
    }
}

private extension ISO8601DateFormatter {
    static let reviewQueue: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()
}
