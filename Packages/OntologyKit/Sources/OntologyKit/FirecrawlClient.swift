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

public struct FirecrawlScrapeResponse: Codable, Sendable, Equatable {
    public let title: String
    public let url: String
    public let description: String
    public let markdown: String
    public let creditsUsed: Int?
    public let warning: String?

    public init(
        title: String,
        url: String,
        description: String,
        markdown: String,
        creditsUsed: Int? = nil,
        warning: String? = nil
    ) {
        self.title = title
        self.url = url
        self.description = description
        self.markdown = markdown
        self.creditsUsed = creditsUsed
        self.warning = warning
    }

    public func formattedBrief(for prompt: String) -> String {
        """
        # Firecrawl Scrape Result

        ## Executive Conclusion
        Firecrawl scraped a single page for: \(prompt)

        ## Consequence
        This is page-level external evidence from \(url), not accepted graph authority.

        ## Recommendation
        Use this page content for the next synthesis step, then promote only reviewed claims.

        ## Supporting Evidence
        \(String(markdown.prefix(1_200)))

        ## Sources
        - \(title): \(url)
          \(description.isEmpty ? "No description returned." : description)

        Credits used: \(creditsUsed.map(String.init) ?? "unknown")
        """
    }
}

public struct FirecrawlMapLink: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let url: String
    public let title: String
    public let description: String

    public init(url: String, title: String = "", description: String = "") {
        self.id = url
        self.url = url
        self.title = title
        self.description = description
    }
}

public struct FirecrawlMapResponse: Codable, Sendable, Equatable {
    public let links: [FirecrawlMapLink]
    public let creditsUsed: Int?
    public let warning: String?

    public init(
        links: [FirecrawlMapLink],
        creditsUsed: Int? = nil,
        warning: String? = nil
    ) {
        self.links = links
        self.creditsUsed = creditsUsed
        self.warning = warning
    }

    public func formattedBrief(for prompt: String) -> String {
        let linkLines = links.prefix(40).map { link in
            let label = link.title.isEmpty ? link.url : "\(link.title): \(link.url)"
            return "- \(label)"
        }.joined(separator: "\n")

        return """
        # Firecrawl Map Result

        ## Executive Conclusion
        Firecrawl discovered \(links.count) URL\(links.count == 1 ? "" : "s") for: \(prompt)

        ## Consequence
        This URL inventory can guide targeted scraping before synthesis.

        ## Recommendation
        Scrape the most relevant URLs rather than crawling the whole site unless broad coverage is needed.

        ## Sources
        \(linkLines.isEmpty ? "No URLs returned." : linkLines)

        Credits used: \(creditsUsed.map(String.init) ?? "unknown")
        """
    }
}

public struct FirecrawlClient: Sendable {
    public enum FirecrawlError: Error, LocalizedError, Equatable {
        case noKey
        case missingURL
        case badResponse(String)

        public var errorDescription: String? {
            switch self {
            case .noKey:
                return "Firecrawl API key required."
            case .missingURL:
                return "A URL is required for this Firecrawl action."
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
        try Self.validate(data: data, response: response)
        return try Self.parseSearchResponse(data)
    }

    public func scrape(url: URL) async throws -> FirecrawlScrapeResponse {
        let request = try Self.scrapeRequest(apiKey: apiKey, url: url, baseURL: baseURL)
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.validate(data: data, response: response)
        return try Self.parseScrapeResponse(data)
    }

    public func map(url: URL, limit: Int = 100) async throws -> FirecrawlMapResponse {
        let request = try Self.mapRequest(apiKey: apiKey, url: url, limit: limit, baseURL: baseURL)
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.validate(data: data, response: response)
        return try Self.parseMapResponse(data)
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

    public static func scrapeRequest(
        apiKey: String,
        url: URL,
        baseURL: URL = URL(string: "https://api.firecrawl.dev/v2")!
    ) throws -> URLRequest {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { throw FirecrawlError.noKey }

        var request = URLRequest(url: baseURL.appendingPathComponent("scrape"))
        request.timeoutInterval = 45
        request.httpMethod = "POST"
        request.setValue("Bearer \(trimmedKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "url": url.absoluteString,
            "formats": ["markdown"],
            "onlyMainContent": true
        ])
        return request
    }

    public static func mapRequest(
        apiKey: String,
        url: URL,
        limit: Int,
        baseURL: URL = URL(string: "https://api.firecrawl.dev/v2")!
    ) throws -> URLRequest {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { throw FirecrawlError.noKey }

        var request = URLRequest(url: baseURL.appendingPathComponent("map"))
        request.timeoutInterval = 45
        request.httpMethod = "POST"
        request.setValue("Bearer \(trimmedKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "url": url.absoluteString,
            "limit": max(1, min(limit, 100_000)),
            "sitemap": "include",
            "includeSubdomains": true,
            "ignoreQueryParameters": true
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

    public static func parseScrapeResponse(_ data: Data) throws -> FirecrawlScrapeResponse {
        let object = try responseObject(data)
        let page = object["data"] as? [String: Any] ?? object
        let metadata = page["metadata"] as? [String: Any] ?? [:]
        let markdown = stringValue(page["markdown"])
            ?? stringValue(page["content"])
            ?? stringValue(page["text"])
            ?? ""
        let title = stringValue(page["title"])
            ?? stringValue(metadata["title"])
            ?? "Untitled page"
        let url = stringValue(page["url"])
            ?? stringValue(page["sourceURL"])
            ?? stringValue(metadata["sourceURL"])
            ?? stringValue(metadata["url"])
            ?? ""
        let description = stringValue(page["description"])
            ?? stringValue(metadata["description"])
            ?? ""

        return FirecrawlScrapeResponse(
            title: title,
            url: url,
            description: description,
            markdown: markdown,
            creditsUsed: object["creditsUsed"] as? Int,
            warning: object["warning"] as? String
        )
    }

    public static func parseMapResponse(_ data: Data) throws -> FirecrawlMapResponse {
        let object = try responseObject(data)
        let rows = mapRows(from: object)
        return FirecrawlMapResponse(
            links: rows.compactMap(parseMapLink),
            creditsUsed: object["creditsUsed"] as? Int,
            warning: object["warning"] as? String
        )
    }

    public static func firstURL(in text: String) -> URL? {
        let pattern = #"https?://[^\s<>"')\]]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let matchRange = Range(match.range, in: text)
        else {
            return nil
        }
        let trimmed = text[matchRange]
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?"))
        return URL(string: trimmed)
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

    private static func mapRows(from object: [String: Any]) -> [Any] {
        if let links = object["links"] as? [Any] {
            return links
        }
        if let data = object["data"] as? [String: Any],
           let links = data["links"] as? [Any] {
            return links
        }
        if let data = object["data"] as? [Any] {
            return data
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

    private static func parseMapLink(_ row: Any) -> FirecrawlMapLink? {
        if let url = stringValue(row) {
            return FirecrawlMapLink(url: url)
        }
        guard let object = row as? [String: Any],
              let url = stringValue(object["url"]) ?? stringValue(object["href"])
        else {
            return nil
        }
        return FirecrawlMapLink(
            url: url,
            title: stringValue(object["title"]) ?? "",
            description: stringValue(object["description"]) ?? ""
        )
    }

    private static func validate(data: Data, response: URLResponse) throws {
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let text = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw FirecrawlError.badResponse("Firecrawl API \(http.statusCode): \(text)")
        }
    }

    private static func responseObject(_ data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FirecrawlError.badResponse("Unparseable Firecrawl response.")
        }
        if let success = object["success"] as? Bool, !success {
            let message = object["error"] as? String ?? object["message"] as? String ?? "Firecrawl request failed."
            throw FirecrawlError.badResponse(message)
        }
        return object
    }

    private static func stringValue(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
