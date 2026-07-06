import Foundation
import Testing
@testable import OntologyKit

@Test func codexSessionClientParsesOutputTextDeltas() {
    let lines = [
        "event: response.created",
        "data: {\"type\":\"response.created\"}",
        "event: response.output_text.delta",
        "data: {\"type\":\"response.output_text.delta\",\"delta\":\"Hello\"}",
        "data: {\"type\":\"response.output_text.delta\",\"delta\":\" world\"}",
    ]
    let text = CodexSessionClient.accumulateStreamingContent(from: lines)
    #expect(text == "Hello world")
}

@Test func codexSessionClientLoadsTokenFromAuthJSON() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("codex-auth-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let authFile = dir.appendingPathComponent("auth.json")
    let payload: [String: Any] = [
        "auth_mode": "chatgpt",
        "tokens": [
            "access_token": "codex-session-token-xyz",
            "refresh_token": "refresh",
        ],
    ]
    let data = try JSONSerialization.data(withJSONObject: payload)
    try data.write(to: authFile)

    #expect(CodexSessionClient.loadSessionToken(authFile: authFile) == "codex-session-token-xyz")
}