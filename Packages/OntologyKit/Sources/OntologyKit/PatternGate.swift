import Foundation

/// WO-D / WO-E (PLAN-blueprint-cockpit-v1): Adam's step evidence
/// ratings as accepted-graph claims, and the fail-closed gate that
/// keeps Adam Pattern steps 5-8 locked until steps 1-4 each carry a
/// rating >= 7. "If I can't say, I can't play."

public struct StepEvidenceRating: Sendable, Equatable {
    public let buildId: String
    public let step: Int
    public let rating: Int
    public let evidenceNote: String
    public let ratedAt: Date

    public init(buildId: String, step: Int, rating: Int, evidenceNote: String, ratedAt: Date = Date()) {
        self.buildId = buildId
        self.step = step
        self.rating = rating
        self.evidenceNote = evidenceNote
        self.ratedAt = ratedAt
    }
}

public enum PatternEvidenceError: Error, LocalizedError, Sendable, Equatable {
    case invalidStep(Int)
    case invalidRating(Int)
    case emptyEvidenceNote
    case stepAlreadyRated(step: Int, buildId: String)
    case blocked(String)

    public var errorDescription: String? {
        switch self {
        case .invalidStep(let step):
            return "Step \(step) is not one of the 8 Adam Pattern steps."
        case .invalidRating(let rating):
            return "Rating \(rating) is out of range; ratings are 1-10."
        case .emptyEvidenceNote:
            return "A rating requires an evidence note. If I can't say, I can't play."
        case .stepAlreadyRated(let step, let buildId):
            return "Step \(step) is already rated for \(buildId). Energy moves forward, not backward."
        case .blocked(let message):
            return "Blocked: \(message)"
        }
    }
}

/// Writes step evidence ratings through the proven accepted-graph
/// path: turtle-emit -> SHACL-validate -> append accepted-graph.ttl
/// -> best-effort POST to Fuseki (cloned from ReviewQueueStore.decide).
public final class PatternEvidenceStore: Sendable {
    private let ontologyRoot: URL
    private let turtleParser: any TurtleParsing
    private let acceptedGraphPoster: any AcceptedGraphPosting

    public init(
        ontologyRoot: URL = ReviewQueueStore.defaultOntologyRoot(),
        turtleParser: any TurtleParsing = PythonSHACLConnectionValidator(),
        acceptedGraphPoster: any AcceptedGraphPosting = FusekiAcceptedGraphPoster()
    ) {
        self.ontologyRoot = ontologyRoot
        self.turtleParser = turtleParser
        self.acceptedGraphPoster = acceptedGraphPoster
    }

    public func record(_ rating: StepEvidenceRating) async throws {
        guard (1...8).contains(rating.step) else {
            throw PatternEvidenceError.invalidStep(rating.step)
        }
        guard (1...10).contains(rating.rating) else {
            throw PatternEvidenceError.invalidRating(rating.rating)
        }
        guard !rating.evidenceNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PatternEvidenceError.emptyEvidenceNote
        }
        if try existingRatings(buildId: rating.buildId)[rating.step] != nil {
            throw PatternEvidenceError.stepAlreadyRated(step: rating.step, buildId: rating.buildId)
        }

        let turtle = Self.turtle(for: rating)
        do {
            try turtleParser.parse(Self.prefixes + turtle)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            throw PatternEvidenceError.blocked(message)
        }

        try appendToAcceptedGraph(turtle)
        await postBestEffort(Self.prefixes + turtle)
    }

    /// Ratings already durable in the local accepted graph.
    public func existingRatings(buildId: String) throws -> [Int: Int] {
        guard FileManager.default.fileExists(atPath: acceptedGraphURL.path) else { return [:] }
        let text = try String(contentsOf: acceptedGraphURL, encoding: .utf8)
        return PatternGateChecker.ratings(inTurtle: text, buildId: buildId)
    }

    static func turtle(for rating: StepEvidenceRating) -> String {
        let subject = "https://understood.app/rating/\(iriSlug(rating.buildId))-step\(rating.step)"
        return """

        <\(subject)> a understood:StepEvidenceRating ;
          understood:forStep <http://nousresearch.com/adam-pattern#Step\(rating.step)> ;
          understood:forBuild \(turtleString(rating.buildId)) ;
          understood:rating \(rating.rating) ;
          understood:evidenceNote \(turtleString(rating.evidenceNote)) ;
          understood:ratedAt "\(ISO8601DateFormatter().string(from: rating.ratedAt))"^^xsd:dateTime .

        """
    }

    static func iriSlug(_ raw: String) -> String {
        let lowered = raw.lowercased()
        let mapped = lowered.map { character -> Character in
            character.isLetter || character.isNumber ? character : "-"
        }
        let collapsed = String(mapped)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        return collapsed.isEmpty ? "build" : collapsed
    }

    static func turtleString(_ raw: String) -> String {
        var escaped = raw
        escaped = escaped.replacingOccurrences(of: "\\", with: "\\\\")
        escaped = escaped.replacingOccurrences(of: "\"", with: "\\\"")
        escaped = escaped.replacingOccurrences(of: "\n", with: "\\n")
        escaped = escaped.replacingOccurrences(of: "\r", with: "\\n")
        return "\"\(escaped)\""
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

    private func postBestEffort(_ turtle: String) async {
        do {
            try await acceptedGraphPoster.postAcceptedTriples(turtle)
        } catch {
            fputs("Pattern evidence Fuseki sync skipped: \(error.localizedDescription)\n", stderr)
        }
    }

    private var acceptedURL: URL { ontologyRoot.appendingPathComponent("accepted", isDirectory: true) }
    private var acceptedGraphURL: URL { acceptedURL.appendingPathComponent("accepted-graph.ttl") }

    private static let prefixes = """
    @prefix understood: <https://understood.app/ontology#> .
    @prefix xsd: <http://www.w3.org/2001/XMLSchema#> .

    """
}

public enum PatternGateSource: String, Sendable, Equatable {
    case fuseki
    case localFile
    case unavailable
}

public struct PatternGateState: Sendable, Equatable {
    /// Step number -> rating, for every rated step of this build.
    public let ratings: [Int: Int]
    /// True only when steps 1-4 all carry a rating >= threshold.
    public let executionUnlocked: Bool
    public let source: PatternGateSource
    public let detail: String

    public init(ratings: [Int: Int], executionUnlocked: Bool, source: PatternGateSource, detail: String) {
        self.ratings = ratings
        self.executionUnlocked = executionUnlocked
        self.source = source
        self.detail = detail
    }

    /// The locked state used whenever no evidence can be read.
    /// The gate FAILS CLOSED - never the reverse.
    public static func locked(detail: String) -> PatternGateState {
        PatternGateState(ratings: [:], executionUnlocked: false, source: .unavailable, detail: detail)
    }
}

public protocol PatternGateChecking: Sendable {
    func checkGate(buildId: String) async -> PatternGateState
}

/// Reads gate state from Fuseki, falling back to the local accepted
/// graph file. Unlike FusekiGraphHealthChecker (which treats an
/// unreachable Fuseki as an eval PASS), this checker FAILS CLOSED:
/// no readable evidence means steps 5-8 stay locked.
public struct PatternGateChecker: PatternGateChecking {
    public static let unlockThreshold = 7
    public static let observationalSteps = [1, 2, 3, 4]

    private let sparqlEndpoint: URL
    private let acceptedGraphIRI: String
    private let timeout: TimeInterval
    private let localGraphURL: URL

    public init(
        sparqlEndpoint: URL? = nil,
        acceptedGraphIRI: String = "https://understood.app/graph/accepted",
        timeout: TimeInterval = 2,
        localGraphURL: URL? = nil
    ) {
        if let sparqlEndpoint {
            self.sparqlEndpoint = sparqlEndpoint
        } else if let env = ProcessInfo.processInfo.environment["HARNESS_FUSEKI_SPARQL_ENDPOINT"],
                  let url = URL(string: env) {
            self.sparqlEndpoint = url
        } else {
            self.sparqlEndpoint = URL(string: "http://127.0.0.1:3030/understood/sparql")!
        }
        self.acceptedGraphIRI = ProcessInfo.processInfo.environment["ACCEPTED_GRAPH_IRI"] ?? acceptedGraphIRI
        self.timeout = timeout
        self.localGraphURL = localGraphURL
            ?? ReviewQueueStore.defaultOntologyRoot()
                .appendingPathComponent("accepted", isDirectory: true)
                .appendingPathComponent("accepted-graph.ttl")
    }

    public func checkGate(buildId: String) async -> PatternGateState {
        if let ratings = try? await fusekiRatings(buildId: buildId) {
            return Self.state(from: ratings, source: .fuseki, buildId: buildId)
        }
        if let text = try? String(contentsOf: localGraphURL, encoding: .utf8) {
            let ratings = Self.ratings(inTurtle: text, buildId: buildId)
            return Self.state(from: ratings, source: .localFile, buildId: buildId)
        }
        return .locked(
            detail: "No evidence readable for \(buildId): Fuseki unreachable at \(sparqlEndpoint.absoluteString) and no local accepted graph at \(localGraphURL.path). The gate stays closed."
        )
    }

    static func state(from ratings: [Int: Int], source: PatternGateSource, buildId: String) -> PatternGateState {
        let unlocked = observationalSteps.allSatisfy { (ratings[$0] ?? 0) >= unlockThreshold }
        let summary = observationalSteps
            .map { step in "step \(step): \(ratings[step].map(String.init) ?? "unrated")" }
            .joined(separator: ", ")
        return PatternGateState(
            ratings: ratings,
            executionUnlocked: unlocked,
            source: source,
            detail: unlocked
                ? "Execution unlocked for \(buildId) (\(summary); read from \(source.rawValue))."
                : "Execution locked for \(buildId) (\(summary); threshold \(unlockThreshold); read from \(source.rawValue))."
        )
    }

    /// Parses rating claims out of turtle text - the local fallback
    /// and the duplicate-rating guard both use this. It matches the
    /// claim blocks PatternEvidenceStore emits.
    static func ratings(inTurtle text: String, buildId: String) -> [Int: Int] {
        var ratings: [Int: Int] = [:]
        let escapedBuild = NSRegularExpression.escapedPattern(
            for: PatternEvidenceStore.turtleString(buildId)
        )
        let pattern = #"understood:forStep\s+<http://nousresearch\.com/adam-pattern#Step(\d)>\s*;\s*understood:forBuild\s+"# + escapedBuild + #"\s*;\s*understood:rating\s+(\d+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return [:]
        }
        let range = NSRange(text.startIndex..., in: text)
        for match in regex.matches(in: text, options: [], range: range) {
            guard
                let stepRange = Range(match.range(at: 1), in: text),
                let ratingRange = Range(match.range(at: 2), in: text),
                let step = Int(text[stepRange]),
                let rating = Int(text[ratingRange])
            else { continue }
            ratings[step] = rating
        }
        return ratings
    }

    private func fusekiRatings(buildId: String) async throws -> [Int: Int] {
        let query = """
        PREFIX understood: <https://understood.app/ontology#>
        SELECT ?step ?rating WHERE {
          GRAPH <\(acceptedGraphIRI)> {
            ?claim a understood:StepEvidenceRating ;
                   understood:forBuild \(PatternEvidenceStore.turtleString(buildId)) ;
                   understood:forStep ?step ;
                   understood:rating ?rating .
          }
        }
        """
        var request = URLRequest(url: sparqlEndpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/sparql-results+json", forHTTPHeaderField: "Accept")
        request.httpBody = "query=\(Self.formEncode(query))".data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }

        guard
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let results = object["results"] as? [String: Any],
            let bindings = results["bindings"] as? [[String: Any]]
        else {
            throw URLError(.cannotParseResponse)
        }

        var ratings: [Int: Int] = [:]
        for binding in bindings {
            guard
                let stepValue = (binding["step"] as? [String: Any])?["value"] as? String,
                let ratingValue = (binding["rating"] as? [String: Any])?["value"] as? String,
                let stepDigit = stepValue.split(separator: "#").last?.dropFirst(4),
                let step = Int(stepDigit),
                let rating = Int(ratingValue)
            else { continue }
            ratings[step] = rating
        }
        return ratings
    }

    private static func formEncode(_ text: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?")
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
    }
}
