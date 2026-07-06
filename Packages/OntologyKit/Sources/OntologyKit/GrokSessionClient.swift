import Foundation

/// Direct chat completions through the Grok CLI session proxy.
/// Harness already supplies ontology + authority as the system prompt, so this
/// bypasses the coding-agent CLI (grep, MCP, shell) that was timing out at 90s.
public struct GrokSessionClient: Sendable {
    private static let tokenAuthHeaderValue = "x" + "ai-grok-cli"

    public enum GrokSessionError: Error, LocalizedError {
        case noSessionToken
        case badResponse(String)

        public var errorDescription: String? {
            switch self {
            case .noSessionToken:
                return "No Grok session token. Run `grok login` in Terminal."
            case .badResponse(let message):
                return message
            }
        }
    }

    public var model: String
    public var clientVersion: String
    public var baseURL: String
    public var requestTimeout: TimeInterval
    public var maxTokens: Int

    public init(
        model: String = "grok-build",
        clientVersion: String = "0.2.87",
        baseURL: String = "https://cli-chat-proxy.grok.com/v1",
        requestTimeout: TimeInterval = 300,
        maxTokens: Int = 4096
    ) {
        self.model = model
        self.clientVersion = clientVersion
        self.baseURL = baseURL
        self.requestTimeout = requestTimeout
        self.maxTokens = maxTokens
    }

    /// Read the bearer token written by `grok login` (~/.grok/auth.json).
    public static func loadSessionToken(
        authFile: URL = URL(fileURLWithPath: "\(NSHomeDirectory())/.grok/auth.json")
    ) -> String? {
        guard let data = try? Data(contentsOf: authFile),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        for value in object.values {
            guard let entry = value as? [String: Any],
                  let token = entry["key"] as? String else { continue }
            let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    public struct Message: Sendable {
        public let role: String
        public let text: String
        public let images: [ModelImageAttachment]

        public init(role: String, text: String, images: [ModelImageAttachment] = []) {
            self.role = role
            self.text = text
            self.images = images
        }
    }

    public func send(
        messages: [Message],
        system: String,
        sessionToken: String? = nil
    ) async throws -> String {
        let token = sessionToken ?? Self.loadSessionToken()
        guard let token, !token.isEmpty else { throw GrokSessionError.noSessionToken }

        guard let url = URL(string: "\(baseURL)/chat/completions") else {
            throw GrokSessionError.badResponse("Invalid Grok proxy URL.")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(Self.tokenAuthHeaderValue, forHTTPHeaderField: "X-XAI-Token-Auth")
        request.setValue(model, forHTTPHeaderField: "x-grok-model-override")
        request.setValue(clientVersion, forHTTPHeaderField: "x-grok-client-version")

        var payloadMessages: [[String: Any]] = [["role": "system", "content": system]]
        payloadMessages += messages.map { Self.payloadMessage(for: $0) }

        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "messages": payloadMessages,
            "stream": true,
            "max_tokens": maxTokens,
        ])

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode

        var lines: [String] = []
        for try await line in bytes.lines {
            lines.append(line)
        }

        if let statusCode, statusCode != 200 {
            let body = lines.joined(separator: "\n")
            if let error = Self.firstJSONErrorMessage(from: body) {
                throw GrokSessionError.badResponse("Grok session \(statusCode): \(error)")
            }
            throw GrokSessionError.badResponse("Grok session HTTP \(statusCode).")
        }

        let text = Self.accumulateStreamingContent(from: lines)
        guard !text.isEmpty else {
            let body = lines.joined(separator: "\n")
            if let error = Self.firstJSONErrorMessage(from: body) {
                throw GrokSessionError.badResponse(error)
            }
            throw GrokSessionError.badResponse("Empty Grok session response.")
        }
        return text
    }

    static func payloadMessage(for message: Message) -> [String: Any] {
        guard !message.images.isEmpty else {
            return ["role": message.role, "content": message.text]
        }
        var content: [[String: Any]] = [["type": "text", "text": message.text]]
        for image in message.images {
            content.append([
                "type": "image_url",
                "image_url": ["url": image.dataURI, "detail": "high"],
            ])
        }
        return ["role": message.role, "content": content]
    }

    /// Parse OpenAI-style SSE chunks from the CLI chat proxy.
    static func accumulateStreamingContent(from lines: [String]) -> String {
        var content = ""
        for line in lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let delta = choices.first?["delta"] as? [String: Any],
                  let piece = delta["content"] as? String else { continue }
            content += piece
        }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func firstJSONErrorMessage(from body: String) -> String? {
        for line in body.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let jsonText: String
            if trimmed.hasPrefix("data:") {
                jsonText = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            } else if trimmed.hasPrefix("{") {
                jsonText = trimmed
            } else {
                continue
            }
            guard let data = jsonText.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            if let error = json["error"] as? String { return error }
            if let error = json["error"] as? [String: Any],
               let message = error["message"] as? String { return message }
        }
        return nil
    }
}