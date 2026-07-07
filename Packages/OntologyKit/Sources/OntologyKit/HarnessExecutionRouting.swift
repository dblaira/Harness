import Foundation

public enum HarnessRouteAction: String, Codable, Sendable, Equatable, CaseIterable {
    case inspectRepository = "inspect-repository"
    case searchMemory = "search-memory"
    case syncSource = "sync-source"
    case runSkill = "run-skill"
    case delegateAgent = "delegate-agent"
    case createArtifact = "create-artifact"

    public var displayLabel: String {
        switch self {
        case .inspectRepository:
            return "Inspect Repository"
        case .searchMemory:
            return "Search Memory"
        case .syncSource:
            return "Sync Source"
        case .runSkill:
            return "Run Skill"
        case .delegateAgent:
            return "Delegate Agent"
        case .createArtifact:
            return "Create Artifact"
        }
    }
}

public enum HarnessRouteGuardrail: String, Codable, Sendable, Equatable, CaseIterable {
    case readOnly = "read-only"
    case approvalRequired = "approval-required"
    case unavailable = "unavailable"

    public var displayLabel: String {
        switch self {
        case .readOnly:
            return "Read-only"
        case .approvalRequired:
            return "Needs Approval"
        case .unavailable:
            return "Unavailable"
        }
    }
}

public enum HarnessResearchSourceScope: String, Codable, Sendable, Equatable, CaseIterable {
    case localContext = "local-context"
    case externalWeb = "external-web"
    case literature = "literature"

    public var displayLabel: String {
        switch self {
        case .localContext:
            return "Local Context"
        case .externalWeb:
            return "External Web"
        case .literature:
            return "Literature"
        }
    }
}

public enum HarnessResearchExecutionKind: String, Codable, Sendable, Equatable, CaseIterable {
    case agentSynthesis = "agent-synthesis"
    case firecrawlSearch = "firecrawl-search"
    case firecrawlScrape = "firecrawl-scrape"
    case firecrawlMap = "firecrawl-map"
}

public struct HarnessResearchAdapter: Identifiable, Codable, Sendable, Equatable {
    public let id: String
    public let skillName: String
    public let displayName: String
    public let sourceScope: HarnessResearchSourceScope
    public let requiresApproval: Bool
    public let executionKind: HarnessResearchExecutionKind
    public let systemInstruction: String
    public let outputContract: String
    public let citationContract: String

    public init(
        id: String,
        skillName: String,
        displayName: String,
        sourceScope: HarnessResearchSourceScope,
        requiresApproval: Bool,
        executionKind: HarnessResearchExecutionKind = .agentSynthesis,
        systemInstruction: String,
        outputContract: String,
        citationContract: String
    ) {
        self.id = id
        self.skillName = skillName
        self.displayName = displayName
        self.sourceScope = sourceScope
        self.requiresApproval = requiresApproval
        self.executionKind = executionKind
        self.systemInstruction = systemInstruction
        self.outputContract = outputContract
        self.citationContract = citationContract
    }

    public static let all: [HarnessResearchAdapter] = [
        HarnessResearchAdapter(
            id: "research-response",
            skillName: "research-response",
            displayName: "Research Response",
            sourceScope: .localContext,
            requiresApproval: false,
            systemInstruction: "You are the Research Response adapter. Synthesize local graph, repository, and note context in Adam's preferred decision-first format.",
            outputContract: "Executive Conclusion, Consequence, Recommendation, Supporting Evidence.",
            citationContract: "Use local source names and file paths when available."
        ),
        HarnessResearchAdapter(
            id: "firecrawl-search",
            skillName: "firecrawl-search",
            displayName: "Firecrawl Search",
            sourceScope: .externalWeb,
            requiresApproval: true,
            executionKind: .firecrawlSearch,
            systemInstruction: "You are the Firecrawl Search adapter. Use approved live web search to produce a source shortlist before synthesis.",
            outputContract: "Executive Conclusion, Consequence, Recommendation, source shortlist, Sources.",
            citationContract: "Return source URLs for every listed result."
        ),
        HarnessResearchAdapter(
            id: "firecrawl-scrape",
            skillName: "firecrawl-scrape",
            displayName: "Firecrawl Scrape",
            sourceScope: .externalWeb,
            requiresApproval: true,
            executionKind: .firecrawlScrape,
            systemInstruction: "You are the Firecrawl Scrape adapter. Extract clean markdown from one approved URL.",
            outputContract: "Executive Conclusion, Consequence, Recommendation, single-page evidence, Sources.",
            citationContract: "Cite the scraped URL and do not generalize beyond the page content."
        ),
        HarnessResearchAdapter(
            id: "firecrawl-map",
            skillName: "firecrawl-map",
            displayName: "Firecrawl Map",
            sourceScope: .externalWeb,
            requiresApproval: true,
            executionKind: .firecrawlMap,
            systemInstruction: "You are the Firecrawl Map adapter. Discover URLs on one approved website before targeted scraping.",
            outputContract: "Executive Conclusion, Consequence, Recommendation, URL inventory, Sources.",
            citationContract: "Return discovered URLs and keep them distinct from extracted claims."
        ),
        HarnessResearchAdapter(
            id: "firecrawl-deep-research",
            skillName: "firecrawl-deep-research",
            displayName: "Firecrawl Deep Research",
            sourceScope: .externalWeb,
            requiresApproval: true,
            executionKind: .firecrawlSearch,
            systemInstruction: "You are the Firecrawl Deep Research adapter. Use approved external web research for competitive, market, and source-rich investigations.",
            outputContract: "Executive Conclusion, Consequence, Recommendation, Sources.",
            citationContract: "Cite every material claim with source URLs."
        ),
        HarnessResearchAdapter(
            id: "llm-wiki",
            skillName: "llm-wiki",
            displayName: "LLM Wiki",
            sourceScope: .localContext,
            requiresApproval: false,
            systemInstruction: "You are the LLM Wiki adapter. Convert local knowledge and skill context into a concise wiki-style explanation.",
            outputContract: "Short synthesis, key distinctions, reusable references.",
            citationContract: "Name the local notes, repos, or skill files used."
        ),
        HarnessResearchAdapter(
            id: "arxiv",
            skillName: "arxiv",
            displayName: "arXiv",
            sourceScope: .literature,
            requiresApproval: true,
            systemInstruction: "You are the arXiv literature adapter. Find, compare, and summarize relevant papers with careful claims.",
            outputContract: "Executive Conclusion, paper map, practical implication, open questions.",
            citationContract: "Cite paper titles, authors, years, and arXiv URLs."
        )
    ]

    public static func adapter(forSkillName skillName: String) -> HarnessResearchAdapter? {
        all.first { $0.skillName.caseInsensitiveCompare(skillName) == .orderedSame }
    }

    public var requiresURL: Bool {
        switch executionKind {
        case .firecrawlScrape, .firecrawlMap:
            return true
        case .agentSynthesis, .firecrawlSearch:
            return false
        }
    }
}

public struct HarnessResearchRequest: Codable, Sendable, Equatable {
    public let adapter: HarnessResearchAdapter
    public let stepID: String
    public let skillName: String
    public let action: HarnessRouteAction
    public let guardrail: HarnessRouteGuardrail
    public let reason: String
    public let skillContext: String
    public let userPrompt: String

    public var routePrompt: String {
        """
        Approved Harness research adapter:
        Adapter: \(adapter.displayName)
        Source scope: \(adapter.sourceScope.rawValue)
        Action: \(action.rawValue)
        Guardrail: \(guardrail.displayLabel)
        Reason: \(reason)
        Citation contract: \(adapter.citationContract)
        Output contract: \(adapter.outputContract)

        Skill context:
        \(skillContext)

        User request:
        \(userPrompt)
        """
    }

    public init(
        adapter: HarnessResearchAdapter,
        stepID: String,
        skillName: String,
        action: HarnessRouteAction,
        guardrail: HarnessRouteGuardrail,
        reason: String,
        skillContext: String,
        userPrompt: String
    ) {
        self.adapter = adapter
        self.stepID = stepID
        self.skillName = skillName
        self.action = action
        self.guardrail = guardrail
        self.reason = reason
        self.skillContext = skillContext
        self.userPrompt = userPrompt
    }
}

public struct HarnessExecutionRouteStep: Identifiable, Codable, Sendable, Equatable {
    public let id: String
    public let action: HarnessRouteAction
    public let targetName: String
    public let sourceSystem: String
    public let reason: String
    public let guardrail: HarnessRouteGuardrail
    public let state: HarnessConnectorState
    public let priority: Int
    public let connectorID: String?
    public let capabilityID: String?

    public var displayTitle: String {
        let action = action.displayLabel.replacingOccurrences(of: " Repository", with: "")
        return "\(action) \(Self.displayName(targetName))"
    }

    public var displaySubtitle: String {
        "\(sourceSystem) - \(guardrail.displayLabel)"
    }

    public init(
        id: String? = nil,
        action: HarnessRouteAction,
        targetName: String,
        sourceSystem: String,
        reason: String,
        guardrail: HarnessRouteGuardrail,
        state: HarnessConnectorState,
        priority: Int,
        connectorID: String? = nil,
        capabilityID: String? = nil
    ) {
        self.id = id ?? "\(priority):\(action.rawValue):\(sourceSystem):\(targetName)"
        self.action = action
        self.targetName = targetName
        self.sourceSystem = sourceSystem
        self.reason = reason
        self.guardrail = guardrail
        self.state = state
        self.priority = priority
        self.connectorID = connectorID
        self.capabilityID = capabilityID
    }

    public static func displayName(_ name: String) -> String {
        name
            .split(separator: " ")
            .map { word in
                switch word.lowercased() {
                case "github":
                    return "GitHub"
                case "api":
                    return "API"
                case "pdf":
                    return "PDF"
                default:
                    return word.prefix(1).uppercased() + word.dropFirst()
                }
            }
            .joined(separator: " ")
    }
}

public struct HarnessExecutionRoutePlan: Codable, Sendable, Equatable {
    public let prompt: String
    public let steps: [HarnessExecutionRouteStep]

    public var requiresApproval: Bool {
        steps.contains { $0.guardrail == .approvalRequired }
    }

    public var unavailableCount: Int {
        steps.filter { $0.guardrail == .unavailable || $0.state == .missing || $0.state == .unavailable }.count
    }

    public var summary: String {
        if steps.isEmpty {
            return "No matching route found."
        }
        let approval = requiresApproval ? " Approval required before execution." : " Read-only route."
        return "\(steps.count) route step\(steps.count == 1 ? "" : "s") planned.\(approval)"
    }

    public init(prompt: String, steps: [HarnessExecutionRouteStep]) {
        self.prompt = prompt
        self.steps = steps.sorted { lhs, rhs in
            if lhs.priority == rhs.priority {
                return lhs.targetName.localizedCaseInsensitiveCompare(rhs.targetName) == .orderedAscending
            }
            return lhs.priority < rhs.priority
        }
    }
}

public enum HarnessExecutionRouter {
    public static func plan(
        prompt: String,
        connectors: [HarnessConnector],
        capabilities: [HarnessCapability]
    ) -> HarnessExecutionRoutePlan {
        let intent = PromptIntent(prompt)
        var steps: [HarnessExecutionRouteStep] = []

        if intent.needsRepositoryContext {
            steps.append(contentsOf: repositorySteps(connectors, intent: intent))
        }
        if intent.needsPersonalKnowledge {
            steps.append(contentsOf: personalKnowledgeSteps(connectors, intent: intent))
        }
        if intent.needsAppleNotesSync {
            steps.append(contentsOf: appleNotesSyncSteps(connectors))
        }
        if intent.needsResearch {
            steps.append(contentsOf: skillSteps(
                capabilities,
                names: ["research-response", "firecrawl-search", "firecrawl-scrape", "firecrawl-map", "firecrawl-deep-research", "llm-wiki", "arxiv"],
                defaultAction: .runSkill,
                intent: intent,
                priorityStart: 40
            ))
        }
        if intent.needsAgentDelegation {
            steps.append(contentsOf: skillSteps(
                capabilities,
                names: ["codex", "claude-code", "hermes-agent", "opencode"],
                defaultAction: .delegateAgent,
                intent: intent,
                priorityStart: 60
            ))
        }
        if intent.needsOutputCreation {
            steps.append(contentsOf: artifactSteps(capabilities, intent: intent))
        }

        return HarnessExecutionRoutePlan(prompt: prompt, steps: deduplicated(steps))
    }

    private static func repositorySteps(
        _ connectors: [HarnessConnector],
        intent: PromptIntent
    ) -> [HarnessExecutionRouteStep] {
        connectors
            .filter { $0.kind == .github && $0.role == .supportingMemory }
            .map { connector in
                HarnessExecutionRouteStep(
                    action: .inspectRepository,
                    targetName: connector.title,
                    sourceSystem: connector.sourceSystem,
                    reason: intent.contains("github") || intent.contains("repo")
                        ? "Prompt asks for repository context."
                        : "Repository context is useful for product and implementation questions.",
                    guardrail: guardrail(for: connector),
                    state: connector.state,
                    priority: 10,
                    connectorID: connector.id
                )
            }
    }

    private static func personalKnowledgeSteps(
        _ connectors: [HarnessConnector],
        intent: PromptIntent
    ) -> [HarnessExecutionRouteStep] {
        connectors
            .filter { connector in
                connector.role == .supportingMemory && [.obsidian, .appleNotes, .notebookLM].contains(connector.kind)
            }
            .filter { connector in
                if connector.kind == .appleNotes {
                    return intent.contains("apple notes") || intent.contains("notes")
                }
                if connector.kind == .notebookLM {
                    if connector.state != .available && !intent.needsNotebookLMContext {
                        return false
                    }
                    return intent.needsNotebookLMContext || intent.needsResearch
                }
                return true
            }
            .map { connector in
                HarnessExecutionRouteStep(
                    action: .searchMemory,
                    targetName: connector.title,
                    sourceSystem: connector.sourceSystem,
                    reason: personalKnowledgeReason(for: connector),
                    guardrail: guardrail(for: connector),
                    state: connector.state,
                    priority: personalKnowledgePriority(for: connector),
                    connectorID: connector.id
                )
            }
    }

    private static func personalKnowledgeReason(for connector: HarnessConnector) -> String {
        if connector.kind == .notebookLM {
            return "NotebookLM can provide synthesized research context after accepted graph authority; unlabeled notebooks are treated as web-synthesis only."
        }
        return "\(connector.sourceSystem) can provide personal context after accepted graph authority."
    }

    private static func personalKnowledgePriority(for connector: HarnessConnector) -> Int {
        switch connector.kind {
        case .obsidian:
            return 20
        case .notebookLM:
            return 22
        case .appleNotes:
            return 24
        default:
            return 26
        }
    }

    private static func appleNotesSyncSteps(_ connectors: [HarnessConnector]) -> [HarnessExecutionRouteStep] {
        connectors
            .filter { $0.kind == .appleNotes }
            .prefix(1)
            .map { connector in
                HarnessExecutionRouteStep(
                    action: .syncSource,
                    targetName: connector.title,
                    sourceSystem: connector.sourceSystem,
                    reason: "Apple Notes sync uses macOS Automation and must be explicit.",
                    guardrail: .approvalRequired,
                    state: connector.state,
                    priority: 5,
                    connectorID: connector.id
                )
            }
    }

    private static func skillSteps(
        _ capabilities: [HarnessCapability],
        names: [String],
        defaultAction: HarnessRouteAction,
        intent: PromptIntent,
        priorityStart: Int
    ) -> [HarnessExecutionRouteStep] {
        names.enumerated().compactMap { offset, name in
            guard let capability = capabilities.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
                return nil
            }
            let researchAdapter = HarnessResearchAdapter.adapter(forSkillName: capability.name)
            if researchAdapter?.requiresURL == true, !intent.hasURL {
                return nil
            }
            let externalResearch = researchAdapter?.requiresApproval == true
            let delegation = defaultAction == .delegateAgent
            let guardrail: HarnessRouteGuardrail = (externalResearch || delegation) ? .approvalRequired : guardrail(for: capability)
            return HarnessExecutionRouteStep(
                action: defaultAction,
                targetName: capability.name,
                sourceSystem: capability.sourceSystem,
                reason: routeReason(for: capability, action: defaultAction, intent: intent),
                guardrail: guardrail,
                state: capability.state,
                priority: priorityStart + offset,
                capabilityID: capability.id
            )
        }
    }

    private static func artifactSteps(
        _ capabilities: [HarnessCapability],
        intent: PromptIntent
    ) -> [HarnessExecutionRouteStep] {
        let preferredNames = ["web-artifacts-builder", "doc-coauthoring", "claude-design", "architecture-diagram"]
        return preferredNames.enumerated().compactMap { offset, name in
            guard let capability = capabilities.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
                return nil
            }
            return HarnessExecutionRouteStep(
                action: .createArtifact,
                targetName: capability.name,
                sourceSystem: capability.sourceSystem,
                reason: intent.contains("outline")
                    ? "Prompt asks for an output outline that can become a reusable artifact."
                    : "Prompt asks for a generated deliverable.",
                guardrail: .approvalRequired,
                state: capability.state,
                priority: 80 + offset,
                capabilityID: capability.id
            )
        }
    }

    private static func guardrail(for connector: HarnessConnector) -> HarnessRouteGuardrail {
        switch connector.state {
        case .available:
            return .readOnly
        case .needsPermission:
            return .approvalRequired
        case .missing, .unavailable:
            return .unavailable
        }
    }

    private static func guardrail(for capability: HarnessCapability) -> HarnessRouteGuardrail {
        switch capability.state {
        case .available:
            return .readOnly
        case .needsPermission:
            return .approvalRequired
        case .missing, .unavailable:
            return .unavailable
        }
    }

    private static func routeReason(
        for capability: HarnessCapability,
        action: HarnessRouteAction,
        intent: PromptIntent
    ) -> String {
        switch action {
        case .delegateAgent:
            return "Prompt asks for implementation or delegation; this bridge can run coding-agent work."
        case .runSkill:
            if intent.needsResearch {
                return "Prompt asks for research or synthesis; this skill supplies procedure."
            }
            return capability.description
        case .createArtifact:
            return "Prompt asks for a deliverable."
        case .inspectRepository, .searchMemory, .syncSource:
            return capability.description
        }
    }

    private static func deduplicated(_ steps: [HarnessExecutionRouteStep]) -> [HarnessExecutionRouteStep] {
        var seen: Set<String> = []
        var result: [HarnessExecutionRouteStep] = []
        for step in steps {
            let key = "\(step.action.rawValue):\(step.connectorID ?? step.capabilityID ?? step.targetName)"
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            result.append(step)
        }
        return result
    }
}

public struct HarnessRouteExecutionResult: Codable, Sendable, Equatable {
    public let plan: HarnessExecutionRoutePlan
    public let executedSteps: [HarnessExecutionRouteStep]
    public let blockedSteps: [HarnessExecutionRouteStep]
    public let memoryHits: [MemoryHit]
    public let actionResults: [HarnessRouteActionResult]

    public var summary: String {
        let hitCount = memoryHits.count
        let blockedCount = blockedSteps.count
        return "\(executedSteps.count) step\(executedSteps.count == 1 ? "" : "s") executed, \(hitCount) hit\(hitCount == 1 ? "" : "s"), \(actionResults.count) action\(actionResults.count == 1 ? "" : "s"), \(blockedCount) blocked."
    }

    public init(
        plan: HarnessExecutionRoutePlan,
        executedSteps: [HarnessExecutionRouteStep],
        blockedSteps: [HarnessExecutionRouteStep],
        memoryHits: [MemoryHit],
        actionResults: [HarnessRouteActionResult] = []
    ) {
        self.plan = plan
        self.executedSteps = executedSteps
        self.blockedSteps = blockedSteps
        self.memoryHits = memoryHits
        self.actionResults = actionResults
    }
}

public struct HarnessRouteActionResult: Identifiable, Codable, Sendable, Equatable {
    public let id: String
    public let stepID: String
    public let action: HarnessRouteAction
    public let targetName: String
    public let summary: String
    public let artifactURL: URL?
    public let pdfURL: URL?
    public let adapterName: String?

    public init(
        id: String? = nil,
        stepID: String,
        action: HarnessRouteAction,
        targetName: String,
        summary: String,
        artifactURL: URL? = nil,
        pdfURL: URL? = nil,
        adapterName: String? = nil
    ) {
        self.id = id ?? "\(stepID):result"
        self.stepID = stepID
        self.action = action
        self.targetName = targetName
        self.summary = summary
        self.artifactURL = artifactURL
        self.pdfURL = pdfURL
        self.adapterName = adapterName
    }
}

public struct HarnessRouteExecutor: Sendable {
    public let connectors: [HarnessConnector]
    public let capabilities: [HarnessCapability]
    public let memoryLimitPerStep: Int
    public let maxFiles: Int

    public init(
        connectors: [HarnessConnector],
        capabilities: [HarnessCapability] = [],
        memoryLimitPerStep: Int = 4,
        maxFiles: Int = 600
    ) {
        self.connectors = connectors
        self.capabilities = capabilities
        self.memoryLimitPerStep = memoryLimitPerStep
        self.maxFiles = maxFiles
    }

    public func executeReadOnly(_ plan: HarnessExecutionRoutePlan) async throws -> HarnessRouteExecutionResult {
        var executed: [HarnessExecutionRouteStep] = []
        var blocked: [HarnessExecutionRouteStep] = []
        var hits: [MemoryHit] = []

        for step in plan.steps {
            guard step.guardrail == .readOnly else {
                blocked.append(step)
                continue
            }
            guard [.inspectRepository, .searchMemory].contains(step.action) else {
                blocked.append(step)
                continue
            }
            guard let connector = connector(for: step), connector.state == .available else {
                blocked.append(step)
                continue
            }

            let source = HarnessConnectorRegistry.memorySources(from: [connector])
            let retriever = DirectoryMemoryRetriever(sources: source, maxFiles: maxFiles)
            let stepHits = try await retriever.retrieve(prompt: plan.prompt, limit: memoryLimitPerStep)
            hits.append(contentsOf: stepHits)
            executed.append(step)
        }

        return HarnessRouteExecutionResult(
            plan: plan,
            executedSteps: executed,
            blockedSteps: blocked,
            memoryHits: deduplicated(hits)
        )
    }

    public func executeApproved(
        _ plan: HarnessExecutionRoutePlan,
        approvedStepIDs: Set<String>,
        artifactDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/Harness/Artifacts", isDirectory: true),
        appleNotesSync: @Sendable (HarnessExecutionRouteStep) async throws -> AppleNotesExportResult = { _ in
            try await AppleNotesExporter().export()
        },
        codexDelegate: @Sendable (String) async throws -> String = { prompt in
            try await AgentRunner().run(
                backend: .codex,
                system: "You are a delegated coding agent. Execute only the approved task and report the result clearly.",
                user: prompt
            )
        },
        claudeDelegate: @Sendable (String) async throws -> String = { prompt in
            try await AgentRunner().run(
                backend: .claude,
                system: "You are a delegated coding agent. Execute only the approved task and report the result clearly.",
                user: prompt
            )
        },
        hermesDelegate: @Sendable (String) async throws -> String = { prompt in
            try await AgentRunner().run(
                backend: .hermes,
                system: "You are a delegated local agent. Execute only the approved task and report the result clearly.",
                user: prompt
            )
        },
        researchDelegate: @Sendable (HarnessResearchRequest) async throws -> String = { request in
            try await AgentRunner().run(
                backend: .harnessDefault,
                system: request.adapter.systemInstruction,
                user: request.routePrompt
            )
        },
        externalResearchDelegate: @Sendable (HarnessResearchRequest) async throws -> String = { request in
            try await AgentRunner().run(
                backend: .harnessDefault,
                system: request.adapter.systemInstruction,
                user: request.routePrompt
            )
        }
    ) async throws -> HarnessRouteExecutionResult {
        var executed: [HarnessExecutionRouteStep] = []
        var blocked: [HarnessExecutionRouteStep] = []
        var hits: [MemoryHit] = []
        var actionResults: [HarnessRouteActionResult] = []

        for step in plan.steps {
            if step.guardrail == .readOnly {
                if let localResult = try await executeLocalEvidence(step: step, prompt: plan.prompt) {
                    hits.append(contentsOf: localResult)
                    executed.append(step)
                    continue
                }
                if !approvedStepIDs.contains(step.id) {
                    blocked.append(step)
                    continue
                } else {
                    // Approved read-only skills continue into the explicit skill handlers below.
                }
            }

            guard approvedStepIDs.contains(step.id) else {
                blocked.append(step)
                continue
            }

            if step.action == .syncSource && step.targetName == "Apple Notes export" {
                let result = try await appleNotesSync(step)
                actionResults.append(HarnessRouteActionResult(
                    stepID: step.id,
                    action: step.action,
                    targetName: step.targetName,
                    summary: "Synced \(result.exportedCount) note\(result.exportedCount == 1 ? "" : "s") to \(result.outputDirectory.path)."
                ))
                executed.append(step)
            } else if step.action == .delegateAgent && step.targetName == "codex" {
                let output = try await codexDelegate(delegationPrompt(for: step, plan: plan))
                actionResults.append(HarnessRouteActionResult(
                    stepID: step.id,
                    action: step.action,
                    targetName: step.targetName,
                    summary: output
                ))
                executed.append(step)
            } else if step.action == .delegateAgent && step.targetName == "claude-code" {
                let output = try await claudeDelegate(delegationPrompt(for: step, plan: plan))
                actionResults.append(HarnessRouteActionResult(
                    stepID: step.id,
                    action: step.action,
                    targetName: step.targetName,
                    summary: output
                ))
                executed.append(step)
            } else if step.action == .delegateAgent && step.targetName == "hermes-agent" {
                let output = try await hermesDelegate(delegationPrompt(for: step, plan: plan))
                actionResults.append(HarnessRouteActionResult(
                    stepID: step.id,
                    action: step.action,
                    targetName: step.targetName,
                    summary: output
                ))
                executed.append(step)
            } else if step.action == .runSkill,
                      let request = researchRequest(for: step, plan: plan),
                      !request.adapter.requiresApproval {
                let output = try await researchDelegate(request)
                actionResults.append(HarnessRouteActionResult(
                    stepID: step.id,
                    action: step.action,
                    targetName: step.targetName,
                    summary: output,
                    adapterName: request.adapter.displayName
                ))
                executed.append(step)
            } else if step.action == .runSkill,
                      let request = researchRequest(for: step, plan: plan),
                      request.adapter.requiresApproval {
                let output = try await externalResearchDelegate(request)
                actionResults.append(HarnessRouteActionResult(
                    stepID: step.id,
                    action: step.action,
                    targetName: step.targetName,
                    summary: output,
                    adapterName: request.adapter.displayName
                ))
                executed.append(step)
            } else if step.action == .createArtifact {
                let artifact = try writeArtifactFiles(
                    step: step,
                    plan: plan,
                    memoryHits: hits,
                    directory: artifactDirectory
                )
                actionResults.append(HarnessRouteActionResult(
                    stepID: step.id,
                    action: step.action,
                    targetName: step.targetName,
                    summary: "Created markdown artifact at \(artifact.markdown.path) and PDF at \(artifact.pdf.path).",
                    artifactURL: artifact.markdown,
                    pdfURL: artifact.pdf
                ))
                executed.append(step)
            } else {
                blocked.append(step)
            }
        }

        return HarnessRouteExecutionResult(
            plan: plan,
            executedSteps: executed,
            blockedSteps: blocked,
            memoryHits: deduplicated(hits),
            actionResults: actionResults
        )
    }

    private func connector(for step: HarnessExecutionRouteStep) -> HarnessConnector? {
        guard let connectorID = step.connectorID else { return nil }
        return connectors.first { $0.id == connectorID }
    }

    private func delegationPrompt(
        for step: HarnessExecutionRouteStep,
        plan: HarnessExecutionRoutePlan
    ) -> String {
        """
        Approved Harness delegation step:
        Target: \(step.targetName)
        Action: \(step.action.rawValue)
        Guardrail: \(step.guardrail.rawValue)
        Reason: \(step.reason)

        User request:
        \(plan.prompt)
        """
    }

    private func researchRequest(
        for step: HarnessExecutionRouteStep,
        plan: HarnessExecutionRoutePlan
    ) -> HarnessResearchRequest? {
        guard let adapter = HarnessResearchAdapter.adapter(forSkillName: step.targetName) else {
            return nil
        }
        return HarnessResearchRequest(
            adapter: adapter,
            stepID: step.id,
            skillName: step.targetName,
            action: step.action,
            guardrail: step.guardrail,
            reason: step.reason,
            skillContext: skillContext(for: step),
            userPrompt: plan.prompt
        )
    }

    private func skillContext(for step: HarnessExecutionRouteStep) -> String {
        guard let capabilityID = step.capabilityID,
              let capability = capabilities.first(where: { $0.id == capabilityID })
        else {
            return "No local skill context attached."
        }
        guard let text = try? String(contentsOf: capability.path, encoding: .utf8) else {
            return capability.description
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 1_600 else { return trimmed }
        return String(trimmed.prefix(1_600)) + "\n..."
    }

    private struct ArtifactFiles {
        let markdown: URL
        let pdf: URL
    }

    private func writeArtifactFiles(
        step: HarnessExecutionRouteStep,
        plan: HarnessExecutionRoutePlan,
        memoryHits: [MemoryHit],
        directory: URL
    ) throws -> ArtifactFiles {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stem = "harness-\(Self.slug(plan.prompt))-\(Self.timestamp())"
        let markdown = directory.appendingPathComponent("\(stem).md")
        let pdf = directory.appendingPathComponent("\(stem).pdf")
        let evidence = memoryHits.prefix(8).map { hit in
            "- \(hit.source): \(hit.excerpt)"
        }.joined(separator: "\n")
        let body = """
        # Harness Artifact

        Source prompt:
        \(plan.prompt)

        Route step:
        - Target: \(step.targetName)
        - Action: \(step.action.rawValue)
        - Reason: \(step.reason)

        Supporting evidence:
        \(evidence.isEmpty ? "No supporting evidence was attached to this artifact." : evidence)
        """
        try body.write(to: markdown, atomically: true, encoding: .utf8)
        try Self.pdfData(for: body).write(to: pdf, options: .atomic)
        return ArtifactFiles(markdown: markdown, pdf: pdf)
    }

    private static func pdfData(for text: String) -> Data {
        let lines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .prefix(44)
            .map { escapePDFText(String($0.prefix(95))) }
        let stream = """
        BT
        /F1 11 Tf
        72 760 Td
        14 TL
        \(lines.map { "(\($0)) Tj\nT*" }.joined(separator: "\n"))
        ET

        """
        let streamLength = Data(stream.utf8).count
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
            "<< /Length \(streamLength) >>\nstream\n\(stream)endstream"
        ]
        var pdf = "%PDF-1.4\n"
        var offsets: [Int] = [0]
        for (index, object) in objects.enumerated() {
            offsets.append(Data(pdf.utf8).count)
            pdf += "\(index + 1) 0 obj\n\(object)\nendobj\n"
        }
        let xrefOffset = Data(pdf.utf8).count
        pdf += "xref\n0 \(objects.count + 1)\n"
        pdf += "0000000000 65535 f \n"
        for offset in offsets.dropFirst() {
            pdf += String(format: "%010d 00000 n \n", offset)
        }
        pdf += """
        trailer
        << /Size \(objects.count + 1) /Root 1 0 R >>
        startxref
        \(xrefOffset)
        %%EOF
        """
        return Data(pdf.utf8)
    }

    private static func escapePDFText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "(", with: "\\(")
            .replacingOccurrences(of: ")", with: "\\)")
    }

    private static func slug(_ text: String) -> String {
        let allowed = CharacterSet.alphanumerics
        let scalars = text.lowercased().unicodeScalars.map { scalar -> Character in
            allowed.contains(scalar) ? Character(scalar) : "-"
        }
        let collapsed = String(scalars)
            .split(separator: "-")
            .prefix(8)
            .joined(separator: "-")
        return collapsed.isEmpty ? "artifact" : collapsed
    }

    private static func timestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: Date())
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: ".", with: "")
    }

    private func executeLocalEvidence(
        step: HarnessExecutionRouteStep,
        prompt: String
    ) async throws -> [MemoryHit]? {
        guard [.inspectRepository, .searchMemory].contains(step.action),
              let connector = connector(for: step),
              connector.state == .available
        else {
            return nil
        }

        let source = HarnessConnectorRegistry.memorySources(from: [connector])
        let retriever = DirectoryMemoryRetriever(sources: source, maxFiles: maxFiles)
        return try await retriever.retrieve(prompt: prompt, limit: memoryLimitPerStep)
    }

    private func deduplicated(_ hits: [MemoryHit]) -> [MemoryHit] {
        var seen: Set<String> = []
        var result: [MemoryHit] = []
        for hit in hits.sorted(by: { lhs, rhs in
            if lhs.score == rhs.score { return lhs.source < rhs.source }
            return lhs.score > rhs.score
        }) {
            let key = "\(hit.source):\(hit.excerpt)"
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            result.append(hit)
        }
        return result
    }
}

private struct PromptIntent {
    private let normalized: String

    init(_ prompt: String) {
        normalized = prompt.lowercased()
    }

    var needsRepositoryContext: Bool {
        containsAny(["github", "repo", "repository", "codebase", "implementation", "suite", "features"])
    }

    var needsPersonalKnowledge: Bool {
        containsAny([
            "my ",
            "apple notes",
            "obsidian",
            "notes",
            "notebooklm",
            "notebook lm",
            "notebook",
            "personal",
            "understood",
            "marketing",
            "features"
        ])
    }

    var needsNotebookLMContext: Bool {
        containsAny(["notebooklm", "notebook lm", "notebook", "study guide", "source pack", "synthesized research"])
    }

    var needsAppleNotesSync: Bool {
        contains("sync apple notes") || contains("export apple notes")
    }

    var needsResearch: Bool {
        containsAny(["research", "deep dive", "look into", "investigate", "market", "marketing", "outline", "synthesis", "scrape", "map ", "website", "url"])
    }

    var needsAgentDelegation: Bool {
        containsAny(["delegate", "implement", "code", "coding", "fix", "build", "pr", "pull request"])
    }

    var needsOutputCreation: Bool {
        containsAny(["create", "outline", "pdf", "deck", "diagram", "artifact", "write", "draft", "marketing"])
    }

    var hasURL: Bool {
        normalized.contains("http://") || normalized.contains("https://")
    }

    func contains(_ token: String) -> Bool {
        normalized.contains(token.lowercased())
    }

    private func containsAny(_ tokens: [String]) -> Bool {
        tokens.contains { contains($0) }
    }
}
