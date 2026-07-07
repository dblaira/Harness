import Foundation
import Testing
@testable import Harness

@Test func composerIntentPromptOmitsDefaults() {
    let block = ComposerIntent().promptBlock()
    #expect(block == nil)
}

@Test func composerIntentPromptIncludesActiveSignals() {
    var intent = ComposerIntent()
    intent.priority = "High"
    intent.pattern = "Close the Gap"
    intent.isFlagged = true

    let block = intent.promptBlock()
    #expect(block?.contains("Priority: High") == true)
    #expect(block?.contains("Pattern: Close the Gap") == true)
    #expect(block?.contains("Flagged: yes") == true)
    #expect(block?.contains("Effort:") == false)
}

@Test func composedPromptPrependsDelegationContext() {
    var intent = ComposerIntent()
    intent.lift = "Leverage"

    let prompt = ComposerIntent.composedPrompt(
        userText: "Ship the fix",
        attachments: [],
        intent: intent
    )

    #expect(prompt.hasPrefix("DELEGATION CONTEXT"))
    #expect(prompt.contains("Lift: Leverage"))
    #expect(prompt.contains("Ship the fix"))
}