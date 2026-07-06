import Foundation

/// Direct chat through the ChatGPT subscriber Codex API.
/// Harness already supplies ontology + authority as `instructions`, so this
/// bypasses the Codex coding-agent CLI (plugins, MCP, shell) that times out.
public struct CodexSessionClient: Sendable {
    public enum CodexSessionError: Error, LocalizedError {
        case noSessionToken
        case badResponse(String)

        public var errorDescription: String? {
            switch self {
            case .noSessionToken:
                return "No ChatGPT session token. Run `codex login` in Terminal."
            case .badResponse(let message):
                return message
            }
        }
    }

    public var model: String
    public var baseURL: String
    public var requestTimeout: TimeInterval

    public init(
        model: String = "gpt-5.5",
        baseURL: String = "https://chatgpt.com/backend-api/codex",
        requestTimeout: TimeInterval = 300
    ) {
        self.model = model
        self.baseURL = baseURL
        self.requestTimeout = requestTimeout
    }

    /// Read the bearer token written by `codex login` (~/.codex/auth.json).
    public static func loadSessionToken(
        authFile: URL = URL(fileURLWithPath: "\(NSHomeDirectory())/.codex/auth.json")
    ) -> String? {
        guard let data = try? Data(contentsOf: authFile),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = object["tokens"] as? [String: Any],
              let token = tokens["access_token"] as? String else {
            return nil
        }
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
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
        guard let token, !token.isEmpty else { throw CodexSessionError.noSessionToken }

        guard let url = URL(string: "\(baseURL)/responses") else {
            throw CodexSessionError.badResponse("Invalid Codex API URL.")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let input = messages.map { Self.payloadMessage(for: $0) }
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "instructions": system,
            "input": input,
            "store": false,
            "stream": true,
            "tools": [],
        ])

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode

        var lines: [String] = []
        for try await line in bytes.lines {
            lines.append(line)
        }

        if let statusCode, statusCode != 200 {
            let body = lines.joined(separator: "\n")
            if let error = Self.firstErrorMessage(from: body) {
                throw CodexSessionError.badResponse("Codex session \(statusCode): \(error)")
            }
            throw CodexSessionError.badResponse("Codex session HTTP \(statusCode).")
        }

        let text = Self.accumulateStreamingContent(from: lines)
        guard !text.isEmpty else {
            let body = lines.joined(separator: "\n")
            if let error = Self.firstErrorMessage(from: body) {
                throw CodexSessionError.badResponse(error)
            }
            throw CodexSessionError.badResponse("Empty Codex session response.")
        }
        return text
    }

    static func payloadMessage(for message: Message) -> [String: Any] {
        guard !message.images.isEmpty else {
            return ["role": message.role, "content": message.text]
        }
        var content: [[String: Any]] = [["type": "input_text", "text": message.text]]
        for image in message.images {
            content.append([
                "type": "input_image",
                "image_url": image.dataURI,
            ])
        }
        return ["role": message.role, "content": content]
    }

    /// Parse Codex `/responses` SSE events.
    static func accumulateStreamingContent(from lines: [String]) -> String {
        var content = ""
        for line in lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard !payload.isEmpty,
                  let data = payload.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            if json["type"] as? String == "response.output_text.delta",
               let piece = json["delta"] as? String {
                content += piece
            }
        }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func firstErrorMessage(from body: String) -> String? {
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
            if let detail = json["detail"] as? String { return detail }
            if let error = json["error"] as? String { return error }
            if let error = json["error"] as? [String: Any],
               let message = error["message"] as? String { return message }
            if let response = json["response"] as? [String: Any],
               let error = response["error"] as? [String: Any],
               let message = error["message"] as? String { return message }
        }
        return nil
    }
}