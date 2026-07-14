import Foundation

/// BORROW layer (conn-019): commodity model call over URLSession.
/// The BUILD part is what we feed it — Adam's ontology as the system prompt.
public struct ClaudeClient {

    public enum ClaudeError: Error, LocalizedError {
        case noKey, badResponse(String)
        public var errorDescription: String? {
            switch self {
            case .noKey: return "No API key. Set ANTHROPIC_API_KEY in the scheme's environment, or paste a key in Settings."
            case .badResponse(let s): return s
            }
        }
    }

    public var apiKey: String
    public var model: String

    public init(apiKey: String? = nil, model: String = "claude-sonnet-4-6") {
        self.apiKey = apiKey ?? ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] ?? ""
        self.model = model
    }

    /// Adam's confirmed graph offered as context, not cage. The full tiered
    /// system prompt is assembled by PromptAssembler; this passes through the
    /// shared ontology-context block so existing call sites keep working.
    public static func systemPrompt(from onto: Ontology) -> String {
        PromptAssembler.ontologyContext(from: onto)
    }

    public func send(messages: [(role: String, text: String)], system: String) async throws -> String {
        guard !apiKey.isEmpty else { throw ClaudeError.noKey }
        var req = Self.makeRequest(apiKey: apiKey)

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 1024,
            "system": system,
            "messages": messages.map { ["role": $0.role, "content": $0.text] }
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)
        let statusCode = (response as? HTTPURLResponse)?.statusCode
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClaudeError.badResponse("Unparseable response")
        }
        if let content = json["content"] as? [[String: Any]],
           let text = content.first?["text"] as? String {
            return text
        }
        try Self.throwIfErrorEnvelope(json, statusCode: statusCode)
        return String(data: data, encoding: .utf8) ?? "(empty)"
    }

    /// Small authenticated request used by Harness's explicit Connections
    /// check. It validates the API path without sending the user's prompt.
    public func probe() async throws {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ClaudeError.noKey
        }
        var req = Self.makeRequest(apiKey: apiKey)
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "max_tokens": 1,
            "system": "Connection check.",
            "messages": [["role": "user", "content": "Reply with OK."]]
        ])
        let (data, response) = try await URLSession.shared.data(for: req)
        let statusCode = (response as? HTTPURLResponse)?.statusCode
        guard let statusCode, (200..<300).contains(statusCode) else {
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            try Self.throwIfErrorEnvelope(json, statusCode: statusCode)
            throw ClaudeError.badResponse("Claude API did not confirm the connection.")
        }
    }

    /// Native Anthropic tool use: sends the tool catalog, replays prior loop
    /// turns as tool_use/tool_result content blocks, and returns any new tool
    /// calls alongside the text. The tools list is the only capability grant.
    public func send(
        messages: [(role: String, text: String)],
        system: String,
        tools: [ToolSpec],
        toolTranscript: [ToolLoopTurn]
    ) async throws -> BackendResponse {
        guard !apiKey.isEmpty else { throw ClaudeError.noKey }
        var req = Self.makeRequest(apiKey: apiKey)
        req.httpBody = try JSONSerialization.data(withJSONObject: Self.toolRequestBody(
            model: model,
            system: system,
            messages: messages,
            tools: tools,
            toolTranscript: toolTranscript
        ))

        let (data, response) = try await URLSession.shared.data(for: req)
        let statusCode = (response as? HTTPURLResponse)?.statusCode
        return try Self.parseToolResponse(data: data, statusCode: statusCode)
    }

    private static func makeRequest(apiKey: String) -> URLRequest {
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        return req
    }

    /// Anthropic messages body with tools. Internal so tests can assert the
    /// exact wire shape without network access.
    static func toolRequestBody(
        model: String,
        system: String,
        messages: [(role: String, text: String)],
        tools: [ToolSpec],
        toolTranscript: [ToolLoopTurn]
    ) -> [String: Any] {
        var payload: [[String: Any]] = messages.map { ["role": $0.role, "content": $0.text] }
        for turn in toolTranscript {
            var assistantBlocks: [[String: Any]] = []
            if !turn.assistantText.isEmpty {
                assistantBlocks.append(["type": "text", "text": turn.assistantText])
            }
            for call in turn.toolCalls {
                assistantBlocks.append([
                    "type": "tool_use",
                    "id": call.id,
                    "name": call.name,
                    "input": call.input.anyValue,
                ])
            }
            payload.append(["role": "assistant", "content": assistantBlocks])
            let resultBlocks: [[String: Any]] = turn.toolResults.map {
                [
                    "type": "tool_result",
                    "tool_use_id": $0.callId,
                    "content": $0.result.output,
                    "is_error": $0.result.isError,
                ]
            }
            payload.append(["role": "user", "content": resultBlocks])
        }
        return [
            "model": model,
            "max_tokens": 4096,
            "system": system,
            "tools": tools.map {
                ["name": $0.name, "description": $0.description, "input_schema": $0.inputSchema.anyValue]
            },
            "messages": payload,
        ]
    }

    /// Parse an Anthropic messages response into text + tool_use calls.
    /// Internal so tests can feed fixture payloads.
    static func parseToolResponse(data: Data, statusCode: Int?) throws -> BackendResponse {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClaudeError.badResponse("Unparseable response")
        }
        try throwIfErrorEnvelope(json, statusCode: statusCode)
        guard let content = json["content"] as? [[String: Any]] else {
            throw ClaudeError.badResponse("Claude response had no content blocks.")
        }

        var text = ""
        var toolCalls: [ToolCallRequest] = []
        for block in content {
            switch block["type"] as? String {
            case "text":
                text += block["text"] as? String ?? ""
            case "tool_use":
                guard let id = block["id"] as? String, let name = block["name"] as? String else { continue }
                let input = block["input"].flatMap { JSONValue(any: $0) } ?? .object([:])
                toolCalls.append(ToolCallRequest(id: id, name: name, input: input))
            default:
                break
            }
        }

        var tokenCount: Int?
        if let usage = json["usage"] as? [String: Any] {
            let total = (usage["input_tokens"] as? Int ?? 0) + (usage["output_tokens"] as? Int ?? 0)
            if total > 0 { tokenCount = total }
        }
        return BackendResponse(text: text, tokenCount: tokenCount, cost: nil, toolCalls: toolCalls)
    }

    private static func throwIfErrorEnvelope(_ json: [String: Any], statusCode: Int?) throws {
        guard let err = json["error"] as? [String: Any] else { return }
        let type = err["type"] as? String
        let message = err["message"] as? String ?? "Unknown Claude API error"
        if let statusCode {
            throw ClaudeError.badResponse("Claude API \(statusCode): \(formattedClaudeError(type: type, message: message))")
        }
        throw ClaudeError.badResponse(formattedClaudeError(type: type, message: message))
    }

    private static func formattedClaudeError(type: String?, message: String) -> String {
        guard let type, !type.isEmpty else { return message }
        return "\(type): \(message)"
    }
}
