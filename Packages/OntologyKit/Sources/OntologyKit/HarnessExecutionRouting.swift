import Foundation

public enum HarnessRouteAction: String, Codable, Sendable, Equatable, CaseIterable {
    case inspectRepository = "inspect-repository"
    case searchMemory = "search-memory"
    case syncSource = "sync-source"
    case runSkill = "run-skill"
    case delegateAgent = "delegate-agent"
    case createArtifact = "create-artifact"
}

public enum HarnessRouteGuardrail: String, Codable, Sendable, Equatable, CaseIterable {
    case readOnly = "read-only"
    case approvalRequired = "approval-required"
    case unavailable = "unavailable"
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
                names: ["research-response", "firecrawl-deep-research", "llm-wiki", "arxiv"],
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
                connector.role == .supportingMemory && [.obsidian, .appleNotes].contains(connector.kind)
            }
            .filter { connector in
                if connector.kind == .appleNotes {
                    return intent.contains("apple notes") || intent.contains("notes")
                }
                return true
            }
            .map { connector in
                HarnessExecutionRouteStep(
                    action: .searchMemory,
                    targetName: connector.title,
                    sourceSystem: connector.sourceSystem,
                    reason: "\(connector.sourceSystem) can provide personal context after accepted graph authority.",
                    guardrail: guardrail(for: connector),
                    state: connector.state,
                    priority: connector.kind == .obsidian ? 20 : 24,
                    connectorID: connector.id
                )
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
            let externalResearch = capability.name.contains("firecrawl") || capability.name == "arxiv"
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

    public init(
        id: String? = nil,
        stepID: String,
        action: HarnessRouteAction,
        targetName: String,
        summary: String,
        artifactURL: URL? = nil
    ) {
        self.id = id ?? "\(stepID):result"
        self.stepID = stepID
        self.action = action
        self.targetName = targetName
        self.summary = summary
        self.artifactURL = artifactURL
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
        researchDelegate: @Sendable (String) async throws -> String = { prompt in
            try await AgentRunner().run(
                backend: .codex,
                system: "You are a research-response skill. Produce a concise, source-aware brief from available context.",
                user: prompt
            )
        },
        externalResearchDelegate: @Sendable (String) async throws -> String = { prompt in
            try await AgentRunner().run(
                backend: .codex,
                system: "You are an approved external research skill. Use external research only for the approved request and report sources clearly.",
                user: prompt
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
            } else if step.action == .runSkill && ["research-response", "llm-wiki"].contains(step.targetName) {
                let output = try await researchDelegate(skillPrompt(for: step, plan: plan))
                actionResults.append(HarnessRouteActionResult(
                    stepID: step.id,
                    action: step.action,
                    targetName: step.targetName,
                    summary: output
                ))
                executed.append(step)
            } else if step.action == .runSkill && ["firecrawl-deep-research", "arxiv"].contains(step.targetName) {
                let output = try await externalResearchDelegate(skillPrompt(for: step, plan: plan))
                actionResults.append(HarnessRouteActionResult(
                    stepID: step.id,
                    action: step.action,
                    targetName: step.targetName,
                    summary: output
                ))
                executed.append(step)
            } else if step.action == .createArtifact {
                let artifact = try writeMarkdownArtifact(
                    step: step,
                    plan: plan,
                    memoryHits: hits,
                    directory: artifactDirectory
                )
                actionResults.append(HarnessRouteActionResult(
                    stepID: step.id,
                    action: step.action,
                    targetName: step.targetName,
                    summary: "Created markdown artifact at \(artifact.path).",
                    artifactURL: artifact
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

    private func skillPrompt(
        for step: HarnessExecutionRouteStep,
        plan: HarnessExecutionRoutePlan
    ) -> String {
        """
        Approved Harness skill route:
        Skill: \(step.targetName)
        Action: \(step.action.rawValue)
        Guardrail: \(step.guardrail.rawValue)
        Reason: \(step.reason)

        Skill context:
        \(skillContext(for: step))

        User request:
        \(plan.prompt)
        """
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

    private func writeMarkdownArtifact(
        step: HarnessExecutionRouteStep,
        plan: HarnessExecutionRoutePlan,
        memoryHits: [MemoryHit],
        directory: URL
    ) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let filename = "harness-\(Self.slug(plan.prompt))-\(Self.timestamp()).md"
        let file = directory.appendingPathComponent(filename)
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
        try body.write(to: file, atomically: true, encoding: .utf8)
        return file
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
        containsAny(["my ", "apple notes", "obsidian", "notes", "personal", "understood", "marketing", "features"])
    }

    var needsAppleNotesSync: Bool {
        contains("sync apple notes") || contains("export apple notes")
    }

    var needsResearch: Bool {
        containsAny(["research", "deep dive", "look into", "investigate", "market", "marketing", "outline", "synthesis"])
    }

    var needsAgentDelegation: Bool {
        containsAny(["delegate", "implement", "code", "coding", "fix", "build", "pr", "pull request"])
    }

    var needsOutputCreation: Bool {
        containsAny(["create", "outline", "pdf", "deck", "diagram", "artifact", "write", "draft", "marketing"])
    }

    func contains(_ token: String) -> Bool {
        normalized.contains(token.lowercased())
    }

    private func containsAny(_ tokens: [String]) -> Bool {
        tokens.contains { contains($0) }
    }
}
