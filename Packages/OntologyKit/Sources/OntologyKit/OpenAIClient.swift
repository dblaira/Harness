import Foundation

/// ChatGPT via the OpenAI HTTPS API. Same OpenAI-compatible chat-completions
/// wire shape as XAIClient (function tools, assistant tool_calls, role:"tool"
/// results), pointed at api.openai.com — so the `.codex` backend becomes a
/// full tool-capable doer when an OpenAI API key is present, mirroring how
/// `.grok` uses the xAI API. No key → the run degrades to the ChatGPT session
/// path single-shot, keeping every option open.
public struct OpenAIClient: Sendable {
    public enum OpenAIError: Error, LocalizedError {
        case noKey, badResponse(String)

        public var errorDescription: String? {
            switch self {
            case .noKey:
                return "OpenAI API key required."
            case .badResponse(let message):
                return message
            }
        }
    }

    public var apiKey: String
    public var model: String

    public init(apiKey: String? = nil, model: String = "gpt-4o") {
        self.apiKey = apiKey ?? ProcessInfo.processInfo.environment["OPENAI_API_KEY"] ?? ""
        self.model = model
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

    public func send(messages: [Message], system: String) async throws -> String {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OpenAIError.noKey
        }

        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "max_tokens": 1024,
            "messages": [["role": "system", "content": system]] + messages.map(Self.payloadMessage),
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OpenAIError.badResponse("Unparseable OpenAI response")
        }

        if let choices = json["choices"] as? [[String: Any]],
           let message = choices.first?["message"] as? [String: Any],
           let content = message["content"] as? String {
            return content
        }
        if let error = json["error"] as? [String: Any] {
            let message = error["message"] as? String ?? "Unknown OpenAI API error"
            if let statusCode {
                throw OpenAIError.badResponse("OpenAI API \(statusCode): \(message)")
            }
            throw OpenAIError.badResponse(message)
        }
        return String(data: data, encoding: .utf8) ?? "(empty)"
    }

    /// Native tool calling over OpenAI chat completions. Sends the tool catalog
    /// as function tools, replays prior loop turns as assistant tool_calls +
    /// role:"tool" results, and returns any new tool calls alongside the text.
    public func send(
        messages: [Message],
        system: String,
        tools: [ToolSpec],
        toolTranscript: [ToolLoopTurn]
    ) async throws -> BackendResponse {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OpenAIError.noKey
        }

        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: Self.toolRequestBody(
            model: model,
            system: system,
            messages: messages,
            tools: tools,
            toolTranscript: toolTranscript
        ))

        let (data, response) = try await URLSession.shared.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode
        return try Self.parseToolResponse(data: data, statusCode: statusCode)
    }

    /// OpenAI chat body with function tools. Internal so tests can assert the
    /// exact wire shape without network access.
    static func toolRequestBody(
        model: String,
        system: String,
        messages: [Message],
        tools: [ToolSpec],
        toolTranscript: [ToolLoopTurn]
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
                // OpenAI has no is_error flag; prefix so the model can tell a
                // failure from ordinary output.
                let content = result.result.isError ? "ERROR: \(result.result.output)" : result.result.output
                payload.append(["role": "tool", "tool_call_id": result.callId, "content": content])
            }
        }
        return [
            "model": model,
            "max_tokens": 4096,
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

    /// Parse an OpenAI completion into text + tool_calls. Internal so tests can
    /// feed fixture payloads.
    static func parseToolResponse(data: Data, statusCode: Int?) throws -> BackendResponse {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OpenAIError.badResponse("Unparseable OpenAI response")
        }
        if let error = json["error"] as? [String: Any] {
            let message = error["message"] as? String ?? "Unknown OpenAI API error"
            if let statusCode {
                throw OpenAIError.badResponse("OpenAI API \(statusCode): \(message)")
            }
            throw OpenAIError.badResponse(message)
        }
        guard let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any] else {
            throw OpenAIError.badResponse("OpenAI response had no choices.")
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

    private static func payloadMessage(for message: Message) -> [String: Any] {
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
}
