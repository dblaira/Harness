import Testing
@testable import Harness

@Test func transcriptAssistantTurnParsesBackendFailureWithoutRuleFooter() {
    let parsed = TranscriptAssistantTurn.parse(
        "Backend failed: Codex session HTTP 400.\n\nRule: none"
    )
    #expect(parsed.isBackendFailure)
    #expect(parsed.displayBody == "Backend failed: Codex session HTTP 400.")
    #expect(parsed.rule == "none")
    #expect(parsed.showsMetadataFooter == false)
}

@Test func transcriptAssistantTurnParsesTrailingMarkersForSuccessAnswers() {
    let parsed = TranscriptAssistantTurn.parse(
        "Plain answer first.\n\nRule: conn-019\nAdam Pattern Step: 5"
    )
    #expect(!parsed.isBackendFailure)
    #expect(parsed.displayBody == "Plain answer first.")
    #expect(parsed.rule == "conn-019")
    #expect(parsed.patternStep == "5")
    #expect(parsed.showsMetadataFooter)
}

@Test func transcriptAssistantTurnFlagsReauthorizationErrors() {
    #expect(TranscriptAssistantTurn.suggestsReauthorization("Backend failed: Codex session HTTP 400."))
    #expect(TranscriptAssistantTurn.suggestsReauthorization("Grok authorization expired."))
    #expect(!TranscriptAssistantTurn.suggestsReauthorization("Backend failed: network timeout."))
}