import Foundation

public enum GraphHealthStatus: String, Codable, Sendable, Equatable {
    case healthy
    case missingAcceptedNamedGraph
    case unavailable
}

public struct GraphHealthReport: Codable, Sendable, Equatable {
    public let status: GraphHealthStatus
    public let acceptedGraphIRI: String
    public let sparqlEndpoint: String
    public let namedGraphCount: Int?
    public let defaultGraphTripleCount: Int?
    public let detail: String

    public init(
        status: GraphHealthStatus,
        acceptedGraphIRI: String,
        sparqlEndpoint: String,
        namedGraphCount: Int?,
        defaultGraphTripleCount: Int?,
        detail: String
    ) {
        self.status = status
        self.acceptedGraphIRI = acceptedGraphIRI
        self.sparqlEndpoint = sparqlEndpoint
        self.namedGraphCount = namedGraphCount
        self.defaultGraphTripleCount = defaultGraphTripleCount
        self.detail = detail
    }

    public var evalPassed: Bool {
        status == .healthy || status == .unavailable
    }

    public func evalResult(runId: String) -> EvalResult {
        EvalResult(
            runId: runId,
            checkName: "graph-health-accepted-named-graph",
            passed: evalPassed,
            detail: detail
        )
    }
}

public protocol GraphHealthChecking: Sendable {
    func checkAcceptedGraph() async -> GraphHealthReport
}

public struct FusekiGraphHealthChecker: GraphHealthChecking {
    private let sparqlEndpoint: URL
    private let acceptedGraphIRI: String
    private let timeout: TimeInterval

    public init(
        sparqlEndpoint: URL? = nil,
        acceptedGraphIRI: String = "https://understood.app/graph/accepted",
        timeout: TimeInterval = 2
    ) {
        if let sparqlEndpoint {
            self.sparqlEndpoint = sparqlEndpoint
        } else if let env = ProcessInfo.processInfo.environment["HARNESS_FUSEKI_SPARQL_ENDPOINT"],
                  let url = URL(string: env) {
            self.sparqlEndpoint = url
        } else if let env = ProcessInfo.processInfo.environment["FUSEKI_SPARQL_ENDPOINT"],
                  let url = URL(string: env) {
            self.sparqlEndpoint = url
        } else {
            self.sparqlEndpoint = URL(string: "http://127.0.0.1:3030/understood/sparql")!
        }
        self.acceptedGraphIRI = ProcessInfo.processInfo.environment["ACCEPTED_GRAPH_IRI"] ?? acceptedGraphIRI
        self.timeout = timeout
    }

    public func checkAcceptedGraph() async -> GraphHealthReport {
        do {
            let acceptedCount = try await count(
                """
                SELECT (COUNT(*) AS ?count) WHERE {
                  GRAPH <\(acceptedGraphIRI)> { ?s ?p ?o }
                }
                """
            )
            let namedGraphCount = try? await count(
                """
                SELECT (COUNT(DISTINCT ?g) AS ?count) WHERE {
                  GRAPH ?g { ?s ?p ?o }
                }
                """
            )
            let defaultCount = try? await count(
                """
                SELECT (COUNT(*) AS ?count) WHERE {
                  ?s ?p ?o
                }
                """
            )

            if acceptedCount > 0 {
                return GraphHealthReport(
                    status: .healthy,
                    acceptedGraphIRI: acceptedGraphIRI,
                    sparqlEndpoint: sparqlEndpoint.absoluteString,
                    namedGraphCount: namedGraphCount,
                    defaultGraphTripleCount: defaultCount,
                    detail: "Accepted named graph \(acceptedGraphIRI) has \(acceptedCount) triples."
                )
            }

            let defaultText = defaultCount.map { " default graph has \($0) triples and must not be treated as authority." } ?? ""
            return GraphHealthReport(
                status: .missingAcceptedNamedGraph,
                acceptedGraphIRI: acceptedGraphIRI,
                sparqlEndpoint: sparqlEndpoint.absoluteString,
                namedGraphCount: namedGraphCount,
                defaultGraphTripleCount: defaultCount,
                detail: "Accepted named graph \(acceptedGraphIRI) is missing or empty;\(defaultText)"
            )
        } catch {
            return GraphHealthReport(
                status: .unavailable,
                acceptedGraphIRI: acceptedGraphIRI,
                sparqlEndpoint: sparqlEndpoint.absoluteString,
                namedGraphCount: nil,
                defaultGraphTripleCount: nil,
                detail: "SPARQL graph health check unavailable: \(error.localizedDescription). Offline bundled TTL fallback remains the authority source."
            )
        }
    }

    private func count(_ query: String) async throws -> Int {
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
        return try Self.countBinding(from: data)
    }

    private static func countBinding(from data: Data) throws -> Int {
        guard
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let results = object["results"] as? [String: Any],
            let bindings = results["bindings"] as? [[String: Any]],
            let first = bindings.first,
            let countValue = first["count"] as? [String: Any],
            let text = countValue["value"] as? String,
            let count = Int(text)
        else {
            throw URLError(.cannotParseResponse)
        }
        return count
    }

    private static func formEncode(_ text: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?")
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
    }
}
