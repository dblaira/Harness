import Foundation
import Testing
@testable import OntologyKit

private let cancelledPrompt =
    "what information do I have approved already that confirms the importance of capturing value?"

private func routePlan(
    prompt: String,
    actions: [HarnessRouteAction]
) -> HarnessExecutionRoutePlan {
    HarnessExecutionRoutePlan(
        prompt: prompt,
        steps: actions.enumerated().map { index, action in
            HarnessExecutionRouteStep(
                action: action,
                targetName: action.displayLabel,
                sourceSystem: "unit-test",
                reason: "Policy fixture",
                guardrail: .readOnly,
                state: .available,
                priority: index
            )
        }
    )
}

@Test func interactiveChatPublishesTheMeasuredCeilingAndWatchdogBudget() {
    #expect(InteractiveChatPolicy.visibleResponseCeilingSeconds == 15)
    #expect(InteractiveChatPolicy.watchdogBudgetSeconds == 12)
    #expect(
        InteractiveChatPolicy.watchdogBudgetSeconds
            < InteractiveChatPolicy.visibleResponseCeilingSeconds
    )
}

@Test func exactNewBeliefQuestionReturnsGroundedProductHelp() throws {
    let answer = try #require(
        InteractiveChatPolicy.productHelpAnswer(for: "How do I add a new belief?")
    )

    #expect(answer.contains("Use the memory tool to propose this belief"))
    #expect(answer.contains("Analysis → Candidates"))
    #expect(answer.contains("Yes → accepted as usually true"))
    #expect(answer.contains("Sometimes → accepted as sometimes true"))
    #expect(answer.contains("No → not adopted"))
    #expect(answer.contains("appends it to the accepted graph"))
    #expect(answer.contains("Rule: none"))
    #expect(answer.contains("Adam Pattern Step: 1"))
    #expect(!answer.contains("I'll load"))
}

@Test func newBeliefProductHelpMatcherIsNarrowButWhitespaceTolerant() {
    #expect(
        InteractiveChatPolicy.productHelpAnswer(
            for: "  HOW   DO I ADD A NEW BELIEF?!  "
        ) != nil
    )
    #expect(
        InteractiveChatPolicy.productHelpAnswer(
            for: "How do I add a new belief about exercise?"
        ) == nil
    )
}

@Test func agentRunnerReturnsNewBeliefHelpWithoutCallingABackend() async throws {
    let answer = try await AgentRunner().run(
        backend: .grok,
        system: "This backend must not be reached.",
        user: "How do I add a new belief?"
    )

    #expect(answer == InteractiveChatPolicy.productHelpAnswer(for: "How do I add a new belief?"))
}

@Test func responseShapedRunnerReturnsLocalProductHelpWithZeroUsage() async throws {
    let response = try await AgentRunner().runResponse(
        backend: .grok,
        system: "This backend must not be reached.",
        user: "How do I add a new belief?"
    )

    #expect(response.text == InteractiveChatPolicy.productHelpAnswer(for: "How do I add a new belief?"))
    #expect(response.tokenCount == 0)
    #expect(response.cost == 0)
    #expect(response.toolCalls.isEmpty)
}

@Test func cancelledSimpleQuestionIsSingleShotWithNoTools() {
    let plan = routePlan(prompt: cancelledPrompt, actions: [])

    #expect(InteractiveChatPolicy.requestsAcceptedAuthorityOnly(cancelledPrompt))
    #expect(InteractiveChatPolicy.mode(prompt: cancelledPrompt, routePlan: plan) == .singleShot)
    #expect(InteractiveChatPolicy.tools(prompt: cancelledPrompt, routePlan: plan).isEmpty)
    #expect(InteractiveChatPolicy.maxToolIterations(prompt: cancelledPrompt, routePlan: plan) == 0)
}

@Test func acceptedOnlyLookupStaysSingleShotWhenRoutePlannerAddsGraphWork() {
    for action in HarnessRouteAction.allCases where action != .searchMemory {
        let plan = routePlan(prompt: cancelledPrompt, actions: [action])

        #expect(
            InteractiveChatPolicy.mode(prompt: cancelledPrompt, routePlan: plan) == .singleShot,
            "Accepted-only lookup must outrank the planned \(action.rawValue) route."
        )
        #expect(InteractiveChatPolicy.tools(prompt: cancelledPrompt, routePlan: plan).isEmpty)
        #expect(InteractiveChatPolicy.maxToolIterations(prompt: cancelledPrompt, routePlan: plan) == 0)
    }
}

@Test func acceptedApprovedAndConfirmedGraphRequestsAreAuthorityOnly() {
    let prompts = [
        "Show me the accepted graph facts about capturing value.",
        "Which information have I approved about product value?",
        "What confirmed connections do I have about capturing potential?",
        "What does my confirmed graph authority say about this?",
    ]

    for prompt in prompts {
        #expect(
            InteractiveChatPolicy.requestsAcceptedAuthorityOnly(prompt),
            "Expected authority-only routing for: \(prompt)"
        )
    }
}

@Test func requestsMixingLowerTrustEvidenceAreNotAuthorityOnly() {
    let prompts = [
        "Compare my accepted graph facts with supporting memory.",
        "Include candidates alongside the approved facts.",
        "Show confirmed graph facts and my notes.",
        "Compare accepted authority with candidate evidence and notes.",
    ]

    for prompt in prompts {
        #expect(
            !InteractiveChatPolicy.requestsAcceptedAuthorityOnly(prompt),
            "Expected broader evidence routing for: \(prompt)"
        )
    }
}

@Test func genericConfirmationIsNotAcceptedGraphAuthority() {
    #expect(!InteractiveChatPolicy.requestsAcceptedAuthorityOnly("Is my reservation confirmed?"))
    #expect(!InteractiveChatPolicy.requestsAcceptedAuthorityOnly("What do my notes say?"))
    #expect(
        InteractiveChatPolicy.requestsAcceptedAuthorityOnly(
            "Show accepted graph facts without candidates or notes."
        )
    )
}

@Test func acceptedAndApprovedWordsWithoutAnAuthoritySubjectAreNotAuthorityOnly() {
    let prompts = [
        "Was my reservation approved?",
        "Was the GitHub pull request approved?",
        "Was the shell tool approved?",
        "Which tool approvals were accepted?",
        "What GitHub information was approved?",
        "What reservation information was confirmed?",
        "What tool information was approved?",
    ]

    for prompt in prompts {
        #expect(
            !InteractiveChatPolicy.requestsAcceptedAuthorityOnly(prompt),
            "Expected ordinary approval wording to stay out of graph authority: \(prompt)"
        )
    }
}

@Test func explicitToolIntentCannotEnterTheAuthorityOnlyBypass() {
    let prompt = "Use search_files to show approved graph information."
    let plan = routePlan(prompt: prompt, actions: [])

    #expect(!InteractiveChatPolicy.requestsAcceptedAuthorityOnly(prompt))
    #expect(InteractiveChatPolicy.mode(prompt: prompt, routePlan: plan) == .agentic)
}

@Test func memoryOnlyRouteRemainsSingleShot() {
    let plan = routePlan(prompt: cancelledPrompt, actions: [.searchMemory])

    #expect(InteractiveChatPolicy.mode(prompt: cancelledPrompt, routePlan: plan) == .singleShot)
    #expect(InteractiveChatPolicy.tools(prompt: cancelledPrompt, routePlan: plan).isEmpty)
}

@Test func explicitShellRunAndWritePromptsAreAgentic() {
    let prompts = [
        "Use the shell to inspect the current directory.",
        "Run the focused tests.",
        "Write the result to a file.",
    ]

    for prompt in prompts {
        let plan = routePlan(prompt: prompt, actions: [])
        #expect(InteractiveChatPolicy.mode(prompt: prompt, routePlan: plan) == .agentic)
        #expect(
            InteractiveChatPolicy.tools(prompt: prompt, routePlan: plan).map(\.name)
                == HarnessToolCatalog.v1.map(\.name)
        )
        #expect(
            InteractiveChatPolicy.maxToolIterations(prompt: prompt, routePlan: plan)
                == InteractiveChatPolicy.agenticMaxToolIterations
        )
    }
}

@Test func everyCatalogToolIdentifierAndNaturalNameIsAgenticWhenRequested() {
    for tool in HarnessToolCatalog.v1 {
        let naturalName = tool.name.replacingOccurrences(of: "_", with: " ")
        let prompts = [
            "Use the \(tool.name) tool.",
            "Please use \(naturalName) for this request.",
        ]

        for prompt in prompts {
            let plan = routePlan(prompt: prompt, actions: [])
            #expect(
                InteractiveChatPolicy.mode(prompt: prompt, routePlan: plan) == .agentic,
                "Expected explicit tool request to be agentic: \(prompt)"
            )
        }
    }
}

@Test func conversationalRunAndWriteLanguageRemainsSingleShot() {
    let prompts = [
        "What did I write about X?",
        "Why did that run fail?",
        "Can you explain what I wrote yesterday?",
        "Run me through why this matters.",
        "Write me a concise answer about this idea.",
    ]

    for prompt in prompts {
        let plan = routePlan(prompt: prompt, actions: [])
        #expect(
            InteractiveChatPolicy.mode(prompt: prompt, routePlan: plan) == .singleShot,
            "Expected conversational wording to avoid the tool loop: \(prompt)"
        )
        #expect(InteractiveChatPolicy.tools(prompt: prompt, routePlan: plan).isEmpty)
    }
}

@Test func everyNonMemoryRouteActionIsAgentic() {
    for action in HarnessRouteAction.allCases where action != .searchMemory {
        let plan = routePlan(prompt: "Please handle this.", actions: [action])
        #expect(
            InteractiveChatPolicy.mode(prompt: plan.prompt, routePlan: plan) == .agentic,
            "\(action.rawValue) must not enter the answer-only path."
        )
    }
}

@Test func deadlineFallbackKeepsTrustLayersOrderedAndDistinct() throws {
    let fallback = InteractiveChatPolicy.deadlineFallback(
        backendName: "Grok",
        acceptedEvidence: ["Accepted fact", "Shared fact", "Accepted third", "Accepted beyond display cap"],
        supportingEvidence: ["Supporting note", "shared fact"],
        toolEvidence: ["Tool result", "Accepted fact", "Accepted beyond display cap"]
    )

    let acceptedRange = try #require(fallback.range(of: "Accepted graph authority:"))
    let supportingRange = try #require(fallback.range(of: "Supporting memory (not accepted authority):"))
    let toolRange = try #require(fallback.range(of: "Tool evidence (unreviewed):"))

    #expect(acceptedRange.lowerBound < supportingRange.lowerBound)
    #expect(supportingRange.lowerBound < toolRange.lowerBound)
    #expect(fallback.contains("- Accepted fact"))
    #expect(fallback.contains("- Shared fact"))
    #expect(fallback.contains("- Supporting note"))
    #expect(fallback.contains("- Tool result"))
    #expect(fallback.components(separatedBy: "Shared fact").count == 2)
    #expect(fallback.components(separatedBy: "Accepted fact").count == 2)
    #expect(!fallback.contains("Accepted beyond display cap"))
    #expect(InteractiveChatPolicy.followsArticulateLeadershipFormat(fallback))
}

@Test func deadlineFallbackNamesEmptyTrustLayersWithoutInventingEvidence() {
    let fallback = InteractiveChatPolicy.deadlineFallback(
        backendName: "",
        acceptedEvidence: [],
        supportingEvidence: [],
        toolEvidence: []
    )

    #expect(fallback.hasPrefix("# ☀️ Harness stopped waiting for The selected backend"))
    #expect(InteractiveChatPolicy.followsArticulateLeadershipFormat(fallback))
    #expect(
        fallback.components(separatedBy: "- None retrieved before the ceiling.").count == 4
    )
}

@Test func acceptedAuthorityAnswerAlwaysUsesTheFourChapters() {
    let answer = InteractiveChatPolicy.acceptedAuthorityAnswer(
        acceptedEvidence: [
            "Leverage, then Automation, then Lift decides what Adam builds next — accepted-graph.ttl",
            "Everything Adam does works in the same direction — accepted-graph.ttl",
        ]
    )

    #expect(InteractiveChatPolicy.followsArticulateLeadershipFormat(answer))
    #expect(answer.contains("(Executive Conclusion)"))
    #expect(answer.contains("(Consequence)"))
    #expect(answer.contains("(Recommendation)"))
    #expect(answer.contains("(Supporting Evidence on Request)"))
    #expect(answer.contains("Only accepted graph authority shaped this answer."))
}

@Test func responseFormatGatePreservesCompliantAnswersAndWrapsRawProviderText() {
    let compliant = try! #require(
        InteractiveChatPolicy.productHelpAnswer(for: "How do I add a new belief?")
    )
    #expect(InteractiveChatPolicy.enforceArticulateLeadershipFormat(compliant) == compliant)

    let raw = "The strongest next move is leverage.\n- Start with the highest-value repeated task."
    let formatted = InteractiveChatPolicy.enforceArticulateLeadershipFormat(raw)
    #expect(InteractiveChatPolicy.followsArticulateLeadershipFormat(formatted))
    #expect(formatted.contains(raw))
}

@Test func articulateLeadershipValidatorRejectsMalformedChapterSequences() {
    let executive = "# ☀️ Answer first 💥 (Executive Conclusion)"
    let consequence = "# What this changes (Consequence)"
    let recommendation = "# What to do next (Recommendation)"
    let evidence = "# The full record (Supporting Evidence on Request)"

    #expect(!InteractiveChatPolicy.followsArticulateLeadershipFormat(
        [executive, recommendation, consequence, evidence].joined(separator: "\n\n")
    ))
    #expect(!InteractiveChatPolicy.followsArticulateLeadershipFormat(
        [executive, consequence, evidence].joined(separator: "\n\n")
    ))
    #expect(!InteractiveChatPolicy.followsArticulateLeadershipFormat(
        [executive, consequence, recommendation, recommendation, evidence].joined(separator: "\n\n")
    ))
    #expect(!InteractiveChatPolicy.followsArticulateLeadershipFormat(
        "Executive Conclusion\nConsequence\nRecommendation\nSupporting Evidence on Request"
    ))
}

@Test func responseFormatGateDemotesProviderHeadingsThatCouldBecomeExtraChapters() {
    let raw = """
    # A partial provider answer (Executive Conclusion)

    Provider detail stays intact.

    # A misplaced provider section (Recommendation)

    Final evidence sentinel.
    """

    let formatted = InteractiveChatPolicy.enforceArticulateLeadershipFormat(raw)

    #expect(InteractiveChatPolicy.followsArticulateLeadershipFormat(formatted))
    #expect(formatted.contains("## A partial provider answer (Executive Conclusion)"))
    #expect(formatted.contains("## A misplaced provider section (Recommendation)"))
    #expect(formatted.contains("Final evidence sentinel."))
}

@Test func terminalFailureAndCancellationUseTheFourChapters() {
    let failure = InteractiveChatPolicy.enforceArticulateLeadershipFormat(
        "Backend failed: Grok authorization expired."
    )
    let cancellation = InteractiveChatPolicy.cancelledAnswer()

    #expect(InteractiveChatPolicy.followsArticulateLeadershipFormat(failure))
    #expect(failure.contains("Harness status: backend failure"))
    #expect(failure.contains("Grok authorization expired."))
    #expect(InteractiveChatPolicy.followsArticulateLeadershipFormat(cancellation))
    #expect(cancellation.contains("Cancelled in Harness before completion."))
}
