import Foundation

public enum HarnessMCPTransport: String, Codable, Sendable, Equatable, CaseIterable {
    case localProcess = "local-process"
    case remoteHTTP = "remote-http"
}

public struct HarnessMCPServerConfiguration: Identifiable, Codable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let transport: HarnessMCPTransport
    public let command: String?
    public let arguments: [String]
    public let environment: [String: String]
    public let url: URL?

    public init(
        id: String? = nil,
        name: String,
        transport: HarnessMCPTransport,
        command: String? = nil,
        arguments: [String] = [],
        environment: [String: String] = [:],
        url: URL? = nil
    ) {
        self.id = id ?? name
        self.name = name
        self.transport = transport
        self.command = command
        self.arguments = arguments
        self.environment = environment
        self.url = url
    }

    public static func firecrawlLocal(apiKey: String) -> HarnessMCPServerConfiguration {
        HarnessMCPServerConfiguration(
            name: "firecrawl",
            transport: .localProcess,
            command: "npx",
            arguments: ["-y", "firecrawl-mcp"],
            environment: ["FIRECRAWL_API_KEY": apiKey]
        )
    }

    public var redactedEnvironment: [String: String] {
        environment.mapValues { value in
            value.isEmpty ? "" : "[configured]"
        }
    }

    public var redactedSummary: String {
        switch transport {
        case .localProcess:
            let executable = ([command].compactMap { $0 } + arguments).joined(separator: " ")
            let envKeys = environment.keys.sorted().joined(separator: ", ")
            return "\(name): \(executable) with \(envKeys.isEmpty ? "no environment keys" : envKeys)"
        case .remoteHTTP:
            return "\(name): \(redactedRemoteURL)"
        }
    }

    private var redactedRemoteURL: String {
        guard let url else { return "not configured" }
        let parts = url.pathComponents
        guard parts.count >= 3 else { return url.absoluteString }
        return "\(url.scheme ?? "https")://\(url.host ?? "mcp.firecrawl.dev")/[redacted]/\(parts.suffix(2).joined(separator: "/"))"
    }
}
