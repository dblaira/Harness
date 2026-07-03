import Foundation

public struct AgentPolicyDirective: Identifiable, Codable, Sendable, Equatable {
    public let id: String
    public let category: String
    public let sourceRuleId: String
    public let instruction: String
    public let requiredMarker: String

    public init(
        id: String,
        category: String,
        sourceRuleId: String,
        instruction: String,
        requiredMarker: String
    ) {
        self.id = id
        self.category = category
        self.sourceRuleId = sourceRuleId
        self.instruction = instruction
        self.requiredMarker = requiredMarker
    }

    public var promptLine: String {
        "Policy: \(id) | Rule: \(sourceRuleId) | \(instruction) | Required marker: \(requiredMarker)"
    }
}

public enum AgentPolicyCompiler {
    public static func compile(
        prompt: String,
        ontology: Ontology,
        authorityHits: [GraphAuthorityHit] = []
    ) -> [AgentPolicyDirective] {
        var directives = compile(prompt: prompt, authorityHits: authorityHits)

        if codingPrompt(prompt),
           directives.contains(where: { $0.id == "reusable-systems" }) == false,
           ontology.connections.contains(where: { $0.id == "conn-019" }) {
            directives.append(reusableSystemsDirective)
        }

        if researchPrompt(prompt),
           directives.contains(where: { $0.id == "close-the-gap" }) == false {
            directives.append(closeTheGapDirective)
        }

        if delegationPrompt(prompt),
           directives.contains(where: { $0.id == "delegation-three-parts" }) == false,
           ontology.axioms.contains(where: { $0.id == "delegation-three-parts" })
                || ontology.connections.contains(where: { $0.id == "conn-004" }) {
            directives.append(delegationDirective)
        }

        return directives
    }

    public static func compile(prompt: String, authorityHits: [GraphAuthorityHit]) -> [AgentPolicyDirective] {
        guard codingPrompt(prompt) else { return [] }
        let hasReusableSystemsAuthority = authorityHits.contains { hit in
            hit.authorityLevel == .accepted
                && (
                    hit.subject.localizedCaseInsensitiveContains("conn-019")
                    || hit.object.localizedCaseInsensitiveContains("reusable systems")
                    || hit.object.localizedCaseInsensitiveContains("one-time wins")
                )
        }
        return hasReusableSystemsAuthority ? [reusableSystemsDirective] : []
    }

    static func codingPrompt(_ prompt: String) -> Bool {
        containsAny(prompt, [
            "app", "build", "code", "coding", "commit", "feature",
            "fix", "implement", "package", "repo", "swift", "test"
        ])
    }

    private static func researchPrompt(_ prompt: String) -> Bool {
        containsAny(prompt, [
            "caveat", "compare", "explain", "investigate", "research",
            "understand", "verify", "why"
        ])
    }

    private static func delegationPrompt(_ prompt: String) -> Bool {
        containsAny(prompt, [
            "delegate", "handoff", "implement", "task"
        ])
    }

    private static func containsAny(_ prompt: String, _ words: [String]) -> Bool {
        let tokens = OntologyAuthorityRetriever.tokens(prompt)
        return words.contains { tokens.contains($0) }
    }

    private static let reusableSystemsDirective = AgentPolicyDirective(
        id: "reusable-systems",
        category: "coding-style",
        sourceRuleId: "conn-019",
        instruction: "Prefer reusable systems over one-time wins when making coding or product choices.",
        requiredMarker: "Policy: reusable-systems"
    )

    private static let closeTheGapDirective = AgentPolicyDirective(
        id: "close-the-gap",
        category: "research-depth",
        sourceRuleId: "adam-pattern-3",
        instruction: "Close the specific expertise gap before pushing execution.",
        requiredMarker: "Policy: close-the-gap"
    )

    private static let delegationDirective = AgentPolicyDirective(
        id: "delegation-three-parts",
        category: "delegation-default",
        sourceRuleId: "delegation-three-parts",
        instruction: "When framing delegated work, preserve Intent, PreferredApproach, and DoneCondition.",
        requiredMarker: "Policy: delegation-three-parts"
    )
}
