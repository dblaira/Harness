import Foundation
import Testing
@testable import OntologyKit

@Test func delegationContextParsesPrompt() {
    let prompt = """
    DELEGATION CONTEXT
    Priority: High
    Pattern: Close the Gap

    ---

    Ship the fix tonight
    """
    let parsed = DelegationContext.parsePrompt(prompt)
    #expect(parsed.contextLines == ["Priority: High", "Pattern: Close the Gap"])
    #expect(parsed.message == "Ship the fix tonight")
}

@Test func delegationContextSystemInstructionWhenPresent() {
    let packet = PromptPacketBuilder.makePacket(
        prompt: "DELEGATION CONTEXT\nPriority: High\n\n---\nHello",
        ontology: .empty,
        authorityHits: [],
        memoryHits: []
    )
    #expect(packet.system.contains("DELEGATION CONTEXT RULE"))
}

@Test func delegationContextPreservesIntentionalMessageWhitespace() {
    let prompt = "DELEGATION CONTEXT\nPriority: High\n\n---\n\n  Preserve this padding  \n"
    let parsed = DelegationContext.parsePrompt(prompt)
    #expect(parsed.message == "  Preserve this padding  ")
}
