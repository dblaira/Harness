import Foundation
import Testing
@testable import OntologyKit

@Test func grokSessionClientParsesStreamingContentChunks() {
    let lines = [
        "data: {\"choices\":[{\"delta\":{\"reasoning_content\":\"thinking\"}}]}",
        "data: {\"choices\":[{\"delta\":{\"content\":\"Hello\"}}]}",
        "data: {\"choices\":[{\"delta\":{\"content\":\" world\"}}]}",
        "data: [DONE]",
    ]
    let text = GrokSessionClient.accumulateStreamingContent(from: lines)
    #expect(text == "Hello world")
}

@Test func grokSessionClientBuildsToolRequestBody() throws {
    let tool = try #require(HarnessToolCatalog.spec(named: "shell"))
    let priorCall = ToolCallRequest(id: "call-1", name: "shell", input: ["command": "pwd"])
    let turn = ToolLoopTurn(
        assistantText: "",
        toolCalls: [priorCall],
        toolResults: [
            ToolCallResult(
                callId: "call-1",
                result: ToolResult(toolName: "shell", output: "/tmp/harness\n")
            )
        ]
    )

    let body = GrokSessionClient.toolRequestBody(
        model: "grok-build",
        system: "system",
        messages: [.init(role: "user", text: "run pwd")],
        tools: [tool],
        toolTranscript: [turn],
        maxTokens: 123
    )

    #expect(body["model"] as? String == "grok-build")
    #expect(body["max_tokens"] as? Int == 123)
    let tools = try #require(body["tools"] as? [[String: Any]])
    #expect((tools.first?["function"] as? [String: Any])?["name"] as? String == "shell")

    let messages = try #require(body["messages"] as? [[String: Any]])
    #expect(messages.map { $0["role"] as? String } == ["system", "user", "assistant", "tool"])
    let assistant = messages[2]
    let toolCalls = try #require(assistant["tool_calls"] as? [[String: Any]])
    #expect(toolCalls.first?["id"] as? String == "call-1")
    let function = try #require(toolCalls.first?["function"] as? [String: Any])
    #expect(function["name"] as? String == "shell")
    #expect(function["arguments"] as? String == "{\"command\":\"pwd\"}")
    #expect(messages[3]["tool_call_id"] as? String == "call-1")
}

@Test func grokSessionClientParsesToolCalls() throws {
    let payload: [String: Any] = [
        "choices": [
            [
                "message": [
                    "content": "",
                    "tool_calls": [
                        [
                            "id": "call-pwd",
                            "type": "function",
                            "function": [
                                "name": "shell",
                                "arguments": "{\"command\":\"pwd\"}",
                            ],
                        ],
                    ],
                ],
            ],
        ],
        "usage": ["total_tokens": 42],
    ]
    let data = try JSONSerialization.data(withJSONObject: payload)

    let response = try GrokSessionClient.parseToolResponse(data: data, statusCode: 200)

    #expect(response.text == "")
    #expect(response.tokenCount == 42)
    #expect(response.toolCalls == [
        ToolCallRequest(id: "call-pwd", name: "shell", input: ["command": "pwd"])
    ])
}

@Test func grokSessionClientLoadsTokenFromAuthJSON() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("grok-auth-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let authFile = dir.appendingPathComponent("auth.json")
    let payload: [String: Any] = [
        "https://auth.x.ai::test-client": [
            "key": "session-token-abc",
            "email": "test@example.com",
        ]
    ]
    let data = try JSONSerialization.data(withJSONObject: payload)
    try data.write(to: authFile)

    #expect(GrokSessionClient.loadSessionToken(authFile: authFile) == "session-token-abc")
    #expect(GrokSessionClient.sessionStatus(authFile: authFile) == .valid)
}

@Test func grokSessionClientIgnoresExpiredToken() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("grok-auth-expired-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let authFile = dir.appendingPathComponent("auth.json")
    let payload: [String: Any] = [
        "https://auth.x.ai::test-client": [
            "key": "session-token-expired",
            "expires_at": "2020-01-01T00:00:00.000000Z",
        ]
    ]
    let data = try JSONSerialization.data(withJSONObject: payload)
    try data.write(to: authFile)

    #expect(GrokSessionClient.sessionStatus(authFile: authFile) == .expired)
    #expect(GrokSessionClient.loadSessionToken(authFile: authFile) == nil)
}

@Test func grokSessionClientDetectsJWTExpiration() {
    let header = Data("{\"alg\":\"none\"}".utf8).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    let body = Data("{\"exp\":1}".utf8).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    let token = "\(header).\(body).sig"
    let entry: [String: Any] = [:]
    #expect(GrokSessionClient.isExpired(entry: entry, token: token, now: Date(timeIntervalSince1970: 2)))
}
