import Foundation

/// Direct chat completions through the Grok CLI session proxy.
/// Harness already supplies ontology + authority as the system prompt, so this
/// bypasses the coding-agent CLI (grep, MCP, shell) that was timing out at 90s.
public struct GrokSessionClient: Sendable {
    private static let tokenAuthHeaderValue = "x" + "ai-grok-cli"

    public enum SessionStatus: Equatable, Sendable {
        case valid
        case expired
        case missing
    }

    public enum GrokSessionError: Error, LocalizedError {
        case noSessionToken
        case expiredSessionToken
        case badResponse(String)

        public var errorDescription: String? {
            switch self {
            case .noSessionToken:
                return "No Grok session token. Run `grok login` in Terminal."
            case .expiredSessionToken:
                return "Grok authorization expired. Run `grok login` in Terminal."
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

    /// Whether `grok login` left a usable bearer token on disk.
    public static func sessionStatus(
        authFile: URL = URL(fileURLWithPath: "\(NSHomeDirectory())/.grok/auth.json"),
        now: Date = Date()
    ) -> SessionStatus {
        guard let data = try? Data(contentsOf: authFile),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .missing
        }
        var sawExpired = false
        for value in object.values {
            guard let entry = value as? [String: Any],
                  let token = entry["key"] as? String else { continue }
            let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if isExpired(entry: entry, token: trimmed, now: now) {
                sawExpired = true
                continue
            }
            return .valid
        }
        return sawExpired ? .expired : .missing
    }

    /// Read the bearer token written by `grok login` (~/.grok/auth.json).
    public static func loadSessionToken(
        authFile: URL = URL(fileURLWithPath: "\(NSHomeDirectory())/.grok/auth.json"),
        now: Date = Date()
    ) -> String? {
        guard sessionStatus(authFile: authFile, now: now) == .valid else { return nil }
        guard let data = try? Data(contentsOf: authFile),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        for value in object.values {
            guard let entry = value as? [String: Any],
                  let token = entry["key"] as? String else { continue }
            let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !isExpired(entry: entry, token: trimmed, now: now) else { continue }
            return trimmed
        }
        return nil
    }

    static func isExpired(entry: [String: Any], token: String, now: Date) -> Bool {
        if let expiresAt = entry["expires_at"] as? String,
           let date = parseISO8601(expiresAt) {
            return date <= now
        }
        guard let exp = jwtExpirationDate(token: token) else { return false }
        return exp <= now
    }

    static func parseISO8601(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    static func jwtExpirationDate(token: String) -> Date? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1])
        let remainder = payload.count % 4
        if remainder > 0 { payload += String(repeating: "=", count: 4 - remainder) }
        let normalized = payload
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        guard let data = Data(base64Encoded: normalized),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp = object["exp"] as? TimeInterval else {
            return nil
        }
        return Date(timeIntervalSince1970: exp)
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
        var request = try makeRequest(sessionToken: sessionToken)

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

    /// Native OpenAI-compatible tool calling through the Grok CLI session
    /// proxy. The proxy accepts the same `tools` / `tool_calls` wire shape as
    /// xAI's HTTPS API, but authenticates with the short-lived `grok login`
    /// token instead of an API key.
    public func send(
        messages: [Message],
        system: String,
        tools: [ToolSpec],
        toolTranscript: [ToolLoopTurn],
        sessionToken: String? = nil
    ) async throws -> BackendResponse {
        var request = try makeRequest(sessionToken: sessionToken)
        request.httpBody = try JSONSerialization.data(withJSONObject: Self.toolRequestBody(
            model: model,
            system: system,
            messages: messages,
            tools: tools,
            toolTranscript: toolTranscript,
            maxTokens: maxTokens
        ))

        let (data, response) = try await URLSession.shared.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode
        return try Self.parseToolResponse(data: data, statusCode: statusCode)
    }

    private func makeRequest(sessionToken: String?) throws -> URLRequest {
        let token = sessionToken ?? Self.loadSessionToken()
        guard let token, !token.isEmpty else {
            switch Self.sessionStatus() {
            case .expired: throw GrokSessionError.expiredSessionToken
            case .missing, .valid: throw GrokSessionError.noSessionToken
            }
        }

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
        return request
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

    static func toolRequestBody(
        model: String,
        system: String,
        messages: [Message],
        tools: [ToolSpec],
        toolTranscript: [ToolLoopTurn],
        maxTokens: Int
    ) -> [String: Any] {
        var payload: [[String: Any]] = [["role": "system", "content": system]]
        payload.append(contentsOf: messages.map(Self.payloadMessage))
        for turn in toolTranscript {
            var assistant: [String: Any] = ["role": "assistant", "content": turn.assistantText]
            assistant["tool_calls"] = turn.toolCalls.map {
                [
                    "id": $0.id,
                    "type": "function",
                    "function": ["name": $0.name, "arguments": $0.input.jsonString],
                ] as [String: Any]
            }
            payload.append(assistant)
            for result in turn.toolResults {
                let content = result.result.isError ? "ERROR: \(result.result.output)" : result.result.output
                payload.append(["role": "tool", "tool_call_id": result.callId, "content": content])
            }
        }
        return [
            "model": model,
            "max_tokens": maxTokens,
            "messages": payload,
            "tools": tools.map {
                [
                    "type": "function",
                    "function": [
                        "name": $0.name,
                        "description": $0.description,
                        "parameters": $0.inputSchema.anyValue,
                    ] as [String: Any],
                ] as [String: Any]
            },
        ]
    }

    static func parseToolResponse(data: Data, statusCode: Int?) throws -> BackendResponse {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GrokSessionError.badResponse("Unparseable Grok session response.")
        }
        if let error = json["error"] as? [String: Any] {
            let message = error["message"] as? String ?? "Unknown Grok session error"
            if let statusCode {
                throw GrokSessionError.badResponse("Grok session \(statusCode): \(message)")
            }
            throw GrokSessionError.badResponse(message)
        }
        guard let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any] else {
            throw GrokSessionError.badResponse("Grok session response had no choices.")
        }

        let text = message["content"] as? String ?? ""
        var toolCalls: [ToolCallRequest] = []
        if let rawCalls = message["tool_calls"] as? [[String: Any]] {
            for rawCall in rawCalls {
                guard let id = rawCall["id"] as? String,
                      let function = rawCall["function"] as? [String: Any],
                      let name = function["name"] as? String else { continue }
                let arguments = function["arguments"] as? String ?? "{}"
                let input = JSONValue.parse(arguments) ?? .object([:])
                toolCalls.append(ToolCallRequest(id: id, name: name, input: input))
            }
        }

        var tokenCount: Int?
        if let usage = json["usage"] as? [String: Any],
           let total = usage["total_tokens"] as? Int, total > 0 {
            tokenCount = total
        }
        return BackendResponse(text: text, tokenCount: tokenCount, cost: nil, toolCalls: toolCalls)
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
