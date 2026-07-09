import Foundation
import OntologyKit
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

    #expect(prompt.hasPrefix(DelegationContext.header))
    #expect(prompt.contains("Lift: Leverage"))
    #expect(prompt.contains("Ship the fix"))
}

@Test func composedPromptCarriesIntentPreferredApproachAndDoneConditionVerbatim() {
    let prompt = ComposerIntent.composedPrompt(
        userText: "Ship the fix",
        attachments: [],
        intent: ComposerIntent(),
        preferredApproach: "When I am heads-down I like to batch small fixes",
        doneCondition: "Done looks like the build going green"
    )

    #expect(prompt.hasPrefix(DelegationContext.header))
    #expect(prompt.contains("PreferredApproach: When I am heads-down I like to batch small fixes"))
    #expect(prompt.contains("DoneCondition: Done looks like the build going green"))
    #expect(prompt.contains("Ship the fix"))
}

@Test func composedPromptOmitsBlankPreferredApproachAndDoneCondition() {
    let prompt = ComposerIntent.composedPrompt(
        userText: "Ship the fix",
        attachments: [],
        intent: ComposerIntent(),
        preferredApproach: "   ",
        doneCondition: ""
    )

    #expect(prompt == "Ship the fix")
}

@Test func composerIntentPromptIncludesScheduleAndTagSignals() {
    var intent = ComposerIntent()
    intent.startDeferEnabled = true
    intent.repeatRule = "Weekly"
    intent.endEnabled = true
    intent.tags = ["Delegate", "handoff"]

    let block = intent.promptBlock()
    #expect(block?.contains("Start / defer:") == true)
    #expect(block?.contains("Repeat: Weekly") == true)
    #expect(block?.contains("End:") == true)
    #expect(block?.contains("Tags: Delegate, handoff") == true)
}