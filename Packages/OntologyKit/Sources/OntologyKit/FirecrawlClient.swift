import Foundation

public struct FirecrawlSearchResult: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let url: String
    public let description: String
    public let markdown: String?

    public init(
        title: String,
        url: String,
        description: String,
        markdown: String? = nil
    ) {
        self.id = url.isEmpty ? title : url
        self.title = title
        self.url = url
        self.description = description
        self.markdown = markdown
    }
}

public struct FirecrawlSearchResponse: Codable, Sendable, Equatable {
    public let results: [FirecrawlSearchResult]
    public let creditsUsed: Int?
    public let warning: String?

    public init(
        results: [FirecrawlSearchResult],
        creditsUsed: Int? = nil,
        warning: String? = nil
    ) {
        self.results = results
        self.creditsUsed = creditsUsed
        self.warning = warning
    }

    public func formattedBrief(for prompt: String) -> String {
        let sourceLines = results.prefix(8).map { result in
            let description = result.description.isEmpty ? "No description returned." : result.description
            return "- \(result.title): \(result.url)\n  \(description)"
        }.joined(separator: "\n")
        let evidenceLines = results.prefix(3).compactMap { result -> String? in
            guard let markdown = result.markdown?.trimmingCharacters(in: .whitespacesAndNewlines), !markdown.isEmpty else {
                return nil
            }
            return "- \(result.title): \(String(markdown.prefix(420)))"
        }.joined(separator: "\n")

        return """
        # Firecrawl Research Result

        ## Executive Conclusion
        Firecrawl returned \(results.count) web source\(results.count == 1 ? "" : "s") for: \(prompt)

        ## Consequence
        This result used the approved Firecrawl connector and should be treated as external supporting evidence, not accepted graph authority.

        ## Recommendation
        Use these sources to ground the next synthesis step, then promote only reviewed claims into the accepted graph.

        ## Supporting Evidence
        \(evidenceLines.isEmpty ? "No markdown excerpts were returned for the top sources." : evidenceLines)

        ## Sources
        \(sourceLines.isEmpty ? "No sources returned." : sourceLines)

        Credits used: \(creditsUsed.map(String.init) ?? "unknown")
        """
    }
}

public struct FirecrawlClient: Sendable {
    public enum FirecrawlError: Error, LocalizedError, Equatable {
        case noKey
        case badResponse(String)

        public var errorDescription: String? {
            switch self {
            case .noKey:
                return "Firecrawl API key required."
            case .badResponse(let message):
                return message
            }
        }
    }

    public let apiKey: String
    public let baseURL: URL

    public init(
        apiKey: String? = nil,
        baseURL: URL = URL(string: "https://api.firecrawl.dev/v2")!
    ) {
        self.apiKey = apiKey ?? ProcessInfo.processInfo.environment["FIRECRAWL_API_KEY"] ?? ""
        self.baseURL = baseURL
    }

    public func search(query: String, limit: Int = 5) async throws -> FirecrawlSearchResponse {
        let request = try Self.searchRequest(apiKey: apiKey, query: query, limit: limit, baseURL: baseURL)
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let text = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw FirecrawlError.badResponse("Firecrawl API \(http.statusCode): \(text)")
        }
        return try Self.parseSearchResponse(data)
    }

    public static func searchRequest(
        apiKey: String,
        query: String,
        limit: Int,
        baseURL: URL = URL(string: "https://api.firecrawl.dev/v2")!
    ) throws -> URLRequest {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { throw FirecrawlError.noKey }

        var request = URLRequest(url: baseURL.appendingPathComponent("search"))
        request.timeoutInterval = 30
        request.httpMethod = "POST"
        request.setValue("Bearer \(trimmedKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "query": query,
            "limit": max(1, min(limit, 10)),
            "scrapeOptions": [
                "formats": [
                    ["type": "markdown"]
                ]
            ]
        ])
        return request
    }

    public static func parseSearchResponse(_ data: Data) throws -> FirecrawlSearchResponse {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FirecrawlError.badResponse("Unparseable Firecrawl response.")
        }
        if let success = object["success"] as? Bool, !success {
            let message = object["error"] as? String ?? object["message"] as? String ?? "Firecrawl request failed."
            throw FirecrawlError.badResponse(message)
        }

        let rows = searchRows(from: object)
        let results = rows.map(parseResult)
        return FirecrawlSearchResponse(
            results: results,
            creditsUsed: object["creditsUsed"] as? Int,
            warning: object["warning"] as? String
        )
    }

    private static func searchRows(from object: [String: Any]) -> [[String: Any]] {
        if let data = object["data"] as? [[String: Any]] {
            return data
        }
        if let data = object["data"] as? [String: Any],
           let results = data["results"] as? [[String: Any]] {
            return results
        }
        if let results = object["results"] as? [[String: Any]] {
            return results
        }
        return []
    }

    private static func parseResult(_ row: [String: Any]) -> FirecrawlSearchResult {
        let metadata = row["metadata"] as? [String: Any] ?? [:]
        let title = stringValue(row["title"])
            ?? stringValue(metadata["title"])
            ?? "Untitled source"
        let url = stringValue(row["url"])
            ?? stringValue(row["sourceURL"])
            ?? stringValue(metadata["sourceURL"])
            ?? stringValue(metadata["url"])
            ?? ""
        let description = stringValue(row["description"])
            ?? stringValue(metadata["description"])
            ?? ""
        let markdown = stringValue(row["markdown"])
            ?? stringValue(row["content"])
            ?? stringValue(row["text"])
        return FirecrawlSearchResult(
            title: title,
            url: url,
            description: description,
            markdown: markdown
        )
    }

    private static func stringValue(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
