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

public protocol AcceptedGraphPosting: Sendable {
    func postAcceptedTriples(_ turtle: String) async throws
}

public struct FusekiAcceptedGraphPoster: AcceptedGraphPosting {
    private let dataEndpoint: URL
    private let graphIRI: String

    public init(
        dataEndpoint: URL? = nil,
        graphIRI: String = "https://understood.app/graph/accepted"
    ) {
        if let dataEndpoint {
            self.dataEndpoint = dataEndpoint
        } else if let env = ProcessInfo.processInfo.environment["HARNESS_FUSEKI_DATA_ENDPOINT"],
                  let url = URL(string: env) {
            self.dataEndpoint = url
        } else {
            self.dataEndpoint = URL(string: "http://127.0.0.1:3030/understood/data")!
        }
        self.graphIRI = graphIRI
    }

    public func postAcceptedTriples(_ turtle: String) async throws {
        var components = URLComponents(url: dataEndpoint, resolvingAgainstBaseURL: false)!
        var queryItems = components.queryItems ?? []
        queryItems.append(URLQueryItem(name: "graph", value: graphIRI))
        components.queryItems = queryItems
        guard let url = components.url else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("text/turtle", forHTTPHeaderField: "Content-Type")
        let (_, response) = try await URLSession.shared.upload(for: request, from: Data(turtle.utf8))
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
    }
}

public struct PythonSHACLConnectionValidator: TurtleParsing {
    private let pythonPath: String?
    private let scriptPath: String?
    static let validatorSourceFilePath = #filePath

    public init(pythonPath: String? = nil, scriptPath: String? = nil) {
        self.pythonPath = pythonPath
        self.scriptPath = scriptPath
    }

    public func parse(_ turtle: String) throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("harness-turtle-\(UUID().uuidString).ttl")
        try turtle.write(to: tempURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: try resolvePython())
        process.arguments = [try resolveScript(), "--json", tempURL.path]
        let errorPipe = Pipe()
        let outputPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = outputPipe
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let error = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let message = Self.plainMessage(from: output)
                ?? String(data: error, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw TurtleParseError(message?.isEmpty == false ? message! : "Claim does not match the accepted connection grammar.")
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
            Self.repositoryRootCandidates().flatMap {
                [
                    $0.appendingPathComponent(".venv/bin/python3").path,
                    $0.appendingPathComponent(".venv/bin/python").path
                ]
            },
            [
                "/opt/homebrew/bin/python3",
                "/usr/local/bin/python3",
                "/usr/bin/python3"
            ]
        ].flatMap { $0 }
        if let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return path
        }
        throw TurtleParseError("Python 3 was not found for Turtle validation.")
    }

    static func repositoryRootCandidates(sourceFilePath: String = validatorSourceFilePath) -> [URL] {
        var candidates: [URL] = []
        var seen: Set<String> = []

        func append(_ url: URL) {
            let standardized = url.standardizedFileURL
            guard !seen.contains(standardized.path) else { return }
            seen.insert(standardized.path)
            candidates.append(standardized)
        }

        func appendHarnessAncestors(from startURL: URL) {
            var cursor = startURL.standardizedFileURL
            while cursor.path != "/" {
                if isHarnessRepositoryRoot(cursor) {
                    append(cursor)
                }
                let parent = cursor.deletingLastPathComponent()
                if parent.path == cursor.path { break }
                cursor = parent
            }
        }

        let environment = ProcessInfo.processInfo.environment
        if let repoRoot = environment["HARNESS_REPO_ROOT"], !repoRoot.isEmpty {
            append(URL(fileURLWithPath: repoRoot, isDirectory: true))
        }
        appendHarnessAncestors(from: URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true))
        append(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Developer/GitHub/Harness"))
        if let home = environment["HOME"], !home.isEmpty {
            append(URL(fileURLWithPath: home, isDirectory: true).appendingPathComponent("Developer/GitHub/Harness"))
        }
        if let user = environment["USER"], !user.isEmpty {
            append(URL(fileURLWithPath: "/Users/\(user)/Developer/GitHub/Harness", isDirectory: true))
        }
        appendHarnessAncestors(from: URL(fileURLWithPath: sourceFilePath).deletingLastPathComponent())

        return candidates
    }

    private static func isHarnessRepositoryRoot(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.appendingPathComponent("scripts/validate_connection_turtle.py").path)
            || (
                FileManager.default.fileExists(atPath: url.appendingPathComponent("project.yml").path)
                && FileManager.default.fileExists(atPath: url.appendingPathComponent("Packages/OntologyKit/Package.swift").path)
            )
    }

    private func resolveScript() throws -> String {
        if let scriptPath, FileManager.default.isExecutableFile(atPath: scriptPath) {
            return scriptPath
        }
        if let envPath = ProcessInfo.processInfo.environment["HARNESS_SHACL_VALIDATOR"],
           FileManager.default.isExecutableFile(atPath: envPath) {
            return envPath
        }
        let candidates = Self.repositoryRootCandidates()
            .map { $0.appendingPathComponent("scripts/validate_connection_turtle.py").path }
        if let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return path
        }
        throw TurtleParseError("SHACL validator script was not found.")
    }

    private static func plainMessage(from data: Data) -> String? {
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let messages = object["messages"] as? [String],
            !messages.isEmpty
        else {
            return nil
        }
        return messages.joined(separator: "; ")
    }
}

public final class ReviewQueueStore: Sendable {
    private let ontologyRoot: URL
    private let ledger: RunLedgerStore
    private let turtleParser: any TurtleParsing
    private let acceptedGraphPoster: any AcceptedGraphPosting

    public init(
        ontologyRoot: URL = ReviewQueueStore.defaultOntologyRoot(),
        ledger: RunLedgerStore,
        turtleParser: any TurtleParsing = PythonSHACLConnectionValidator(),
        acceptedGraphPoster: any AcceptedGraphPosting = FusekiAcceptedGraphPoster()
    ) {
        self.ontologyRoot = ontologyRoot
        self.ledger = ledger
        self.turtleParser = turtleParser
        self.acceptedGraphPoster = acceptedGraphPoster
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
            await postAcceptedTriplesBestEffort(Self.prefixes + turtle)
            claim.status = "accepted"
            claim.frequency = frequency
            claim.blockedReason = nil
            queue[index] = claim
            try saveQueue(queue)
            let record = ReviewQueueDecisionRecord(
                claimId: claim.id,
                decision: "accepted",
                frequency: frequency,
                claim: claim.plain,
                evidenceNote: claim.evidence,
                sourceRef: claim.source
            )
            try await ledger.recordReviewQueueDecision(record)
            mirrorDecisionToCanonicalLedger(record)
            return ReviewQueueOutcome(claimId: claimId, accepted: true)
        }

        claim.status = "rejected"
        claim.blockedReason = nil
        queue[index] = claim
        try saveQueue(queue)
        let record = ReviewQueueDecisionRecord(
            claimId: claim.id,
            decision: "rejected",
            frequency: nil,
            claim: claim.plain,
            evidenceNote: claim.evidence,
            sourceRef: claim.source
        )
        try await ledger.recordReviewQueueDecision(record)
        mirrorDecisionToCanonicalLedger(record)
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

    private func mirrorDecisionToCanonicalLedger(_ record: ReviewQueueDecisionRecord) {
        let ledgerURL = acceptedURL.appendingPathComponent("decision-ledger.json")
        do {
            var entries: [[String: Any]] = []
            if FileManager.default.fileExists(atPath: ledgerURL.path) {
                let data = try Data(contentsOf: ledgerURL)
                guard let existing = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                    fputs("Canonical ledger mirror skipped: decision-ledger.json is not a JSON array; not overwriting.\n", stderr)
                    return
                }
                entries = existing
            }
            var entry: [String: Any] = [
                "ledger_id": String(record.id.prefix(8)),
                "app_ledger_id": record.id,
                "claim_id": record.claimId,
                "decision": record.decision,
                "claim": record.claim,
                "at": ISO8601DateFormatter.reviewQueue.string(from: record.createdAt),
                "source": "harness-app",
            ]
            if let frequency = record.frequency {
                entry["frequency"] = frequency
            }
            entries.append(entry)
            let data = try JSONSerialization.data(withJSONObject: entries, options: [.prettyPrinted, .sortedKeys])
            try FileManager.default.createDirectory(at: acceptedURL, withIntermediateDirectories: true)
            try data.write(to: ledgerURL, options: .atomic)
        } catch {
            fputs("Canonical ledger mirror skipped: \(error.localizedDescription)\n", stderr)
        }
    }

    private func postAcceptedTriplesBestEffort(_ turtle: String) async {
        do {
            try await acceptedGraphPoster.postAcceptedTriples(turtle)
        } catch {
            fputs("Harness Fuseki accepted graph sync skipped: \(error.localizedDescription)\n", stderr)
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
        let domainTriples = [claim.domainA, claim.domainB]
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { "  understood:inLifeDomain <https://understood.app/ontology/domain/\($0)> ;" }
        var lines = [
            "",
            "<https://understood.app/ontology/connection/\(cid)> a understood:Connection ;",
            "  understood:label \"\(label)\" ;",
            "  understood:connectionType \"\(escapeLiteral(claim.connectionType))\" ;",
        ] + domainTriples
        if let strength = claim.strength {
            lines.append("  understood:strength \"\(String(format: "%.2f", strength))\"^^xsd:decimal ;")
        }
        lines += [
            "  understood:frequency \"\(frequency)\" ;",
            "  understood:evidenceNote \"\(evidence)\" ;",
            "  understood:acceptedAt \"\(timestamp)\"^^xsd:dateTime ;",
            "  .",
            "",
            ""
        ]
        return lines.joined(separator: "\n")
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
    var strength: Double?
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

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        status = try container.decode(String.self, forKey: .status)
        plain = try container.decode(String.self, forKey: .plain)
        evidence = try container.decode(String.self, forKey: .evidence)
        source = try container.decode(String.self, forKey: .source)
        domainA = try container.decodeIfPresent(String.self, forKey: .domainA) ?? ""
        domainB = try container.decodeIfPresent(String.self, forKey: .domainB) ?? ""
        strength = try container.decodeIfPresent(Double.self, forKey: .strength)
        connectionType = try container.decode(String.self, forKey: .connectionType)
        frequency = try container.decodeIfPresent(String.self, forKey: .frequency)
        blockedReason = try container.decodeIfPresent(String.self, forKey: .blockedReason)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(status, forKey: .status)
        try container.encode(plain, forKey: .plain)
        try container.encode(evidence, forKey: .evidence)
        try container.encode(source, forKey: .source)
        try container.encode(domainA, forKey: .domainA)
        try container.encode(domainB, forKey: .domainB)
        try container.encodeIfPresent(strength, forKey: .strength)
        try container.encode(connectionType, forKey: .connectionType)
        try container.encodeIfPresent(frequency, forKey: .frequency)
        try container.encodeIfPresent(blockedReason, forKey: .blockedReason)
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
