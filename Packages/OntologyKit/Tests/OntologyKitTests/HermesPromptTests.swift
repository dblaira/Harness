import Foundation
import Testing
@testable import OntologyKit

@Test func hermesTranscriptEndsAtOneAssistantTurnBoundary() {
    let prompt = AgentRunner.transcriptPrompt(
        system: "System rules",
        history: [
            ConversationTurn(role: .user, text: "Earlier question"),
            ConversationTurn(role: .assistant, text: "Earlier answer"),
        ],
        user: "Current question"
    )

    #expect(prompt.contains("User: Earlier question"))
    #expect(prompt.contains("Assistant: Earlier answer"))
    #expect(prompt.hasSuffix("User: Current question\n\nAssistant:"))
}

@Test func hermesPayloadStopsBeforeInventedFutureUserTurns() throws {
    let payload = AgentRunner.hermesGeneratePayload(
        system: "System rules",
        history: [],
        user: "Current question"
    )
    let options = try #require(payload["options"] as? [String: Any])
    let stops = try #require(options["stop"] as? [String])

    #expect(stops.contains("\nUser:"))
    #expect(stops.contains("\n---\nUser:"))
    #expect(options["temperature"] as? Int == 0)
    #expect(options["seed"] as? Int == 7_102_026)
    #expect(options["num_predict"] as? Int == 800)
}
