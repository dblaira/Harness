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
}