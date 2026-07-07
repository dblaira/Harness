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

    /// Native tool calling through the ChatGPT subscriber `/responses` API,
    /// authenticated with the `codex login` session token instead of an API
    /// key — so `.codex` is a full doer off the ChatGPT subscription. The
    /// endpoint REQUIRES `stream: true`, so this reads the SSE event stream and
    /// assembles text + function calls from it. The Responses tool shape is
    /// flat (no nested "function").
    public func send(
        messages: [Message],
        system: String,
        tools: [ToolSpec],
        toolTranscript: [ToolLoopTurn],
        sessionToken: String? = nil
    ) async throws -> BackendResponse {
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
        request.httpBody = try JSONSerialization.data(withJSONObject: Self.toolRequestBody(
            model: model,
            system: system,
            messages: messages,
            tools: tools,
            toolTranscript: toolTranscript
        ))

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode
        var lines: [String] = []
        for try await line in bytes.lines { lines.append(line) }
        return try Self.parseToolStream(lines: lines, statusCode: statusCode)
    }

    /// Responses-API request body with function tools. Prior loop turns replay
    /// as `function_call` + `function_call_output` input items. `stream` is
    /// true because the codex `/responses` endpoint rejects non-streaming
    /// requests ("Stream must be set to true"). Internal so tests can assert
    /// the wire shape without network access.
    static func toolRequestBody(
        model: String,
        system: String,
        messages: [Message],
        tools: [ToolSpec],
        toolTranscript: [ToolLoopTurn]
    ) -> [String: Any] {
        var input: [[String: Any]] = messages.map(Self.payloadMessage)
        for turn in toolTranscript {
            if !turn.assistantText.isEmpty {
                input.append([
                    "role": "assistant",
                    "content": [["type": "output_text", "text": turn.assistantText]],
                ])
            }
            for call in turn.toolCalls {
                input.append([
                    "type": "function_call",
                    "call_id": call.id,
                    "name": call.name,
                    "arguments": call.input.jsonString,
                ])
            }
            for result in turn.toolResults {
                let content = result.result.isError ? "ERROR: \(result.result.output)" : result.result.output
                input.append([
                    "type": "function_call_output",
                    "call_id": result.callId,
                    "output": content,
                ])
            }
        }
        return [
            "model": model,
            "instructions": system,
            "input": input,
            "store": false,
            "stream": true,
            "tools": tools.map {
                [
                    "type": "function",
                    "name": $0.name,
                    "description": $0.description,
                    "parameters": $0.inputSchema.anyValue,
                ] as [String: Any]
            },
        ]
    }

    /// Parse the Responses-API SSE stream into text + tool calls. Text comes
    /// from `response.output_text.delta`; each completed function call arrives
    /// whole in a `response.output_item.done` event (call_id + name +
    /// arguments); usage rides on `response.completed`. Internal so tests can
    /// feed fixture SSE lines.
    static func parseToolStream(lines: [String], statusCode: Int?) throws -> BackendResponse {
        var text = ""
        var toolCalls: [ToolCallRequest] = []
        var tokenCount: Int?
        var streamedError: String?

        for line in lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            switch event["type"] as? String {
            case "response.output_text.delta":
                if let piece = event["delta"] as? String { text += piece }
            case "response.output_item.done":
                if let item = event["item"] as? [String: Any],
                   item["type"] as? String == "function_call",
                   let name = item["name"] as? String,
                   let callId = item["call_id"] as? String {
                    let arguments = item["arguments"] as? String ?? "{}"
                    toolCalls.append(ToolCallRequest(id: callId, name: name, input: JSONValue.parse(arguments) ?? .object([:])))
                }
            case "response.completed":
                if let resp = event["response"] as? [String: Any],
                   let usage = resp["usage"] as? [String: Any],
                   let total = usage["total_tokens"] as? Int, total > 0 {
                    tokenCount = total
                }
            case "error", "response.failed":
                streamedError = (event["error"] as? [String: Any])?["message"] as? String
                    ?? event["message"] as? String
                    ?? (event["response"] as? [String: Any]).flatMap { ($0["error"] as? [String: Any])?["message"] as? String }
            default:
                continue
            }
        }

        if let statusCode, statusCode != 200 {
            let body = lines.joined(separator: "\n")
            let message = Self.firstErrorMessage(from: body) ?? streamedError
            if let message {
                throw CodexSessionError.badResponse("Codex session \(statusCode): \(message)")
            }
            throw CodexSessionError.badResponse("Codex session HTTP \(statusCode).")
        }
        if text.isEmpty, toolCalls.isEmpty, let streamedError {
            throw CodexSessionError.badResponse(streamedError)
        }
        return BackendResponse(text: text, tokenCount: tokenCount, cost: nil, toolCalls: toolCalls)
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