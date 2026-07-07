import Foundation

/// The assembled system prompt as ordered tiers, Hermes-style:
///   STABLE          — SOUL.md identity first, doer-identity execution
///                     mandates, skills index. Never changes mid-session.
///   CONTEXT         — Adam's confirmed ontology offered as context, not cage.
///   RESPONSE FORMAT — Adam's response-rule skill files, loaded verbatim.
///   VOLATILE        — memory snapshot + date-only stamp, frozen per session.
public struct PromptTiers: Sendable, Equatable {
    public let stable: String
    public let context: String
    public let responseFormat: String
    public let volatile: String

    public init(stable: String, context: String, responseFormat: String, volatile: String) {
        self.stable = stable
        self.context = context
        self.responseFormat = responseFormat
        self.volatile = volatile
    }

    public var joined: String {
        [stable, context, responseFormat, volatile]
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }
}

/// Builds the Hermes-parity tiered system prompt. Byte-stable per session:
/// the memory snapshot and the session date are frozen the first time a
/// session id is seen and reused until the session id changes, which is the
/// only way to keep upstream prompt caches warm across turns.
public final class PromptAssembler: @unchecked Sendable {
    public static let shared = PromptAssembler()
    public static let defaultSessionId = "harness-app-session"

    /// Adam's response-rule skills, loaded VERBATIM at assembly time.
    /// Vault Skills/ wins; Harness Docs/skills is the fallback. Order is
    /// fixed so the rendered tier stays byte-stable.
    public static let responseRuleSkillNames: [String] = [
        "articulate-leadership-communication",
        "cognitive-fit",
        "no-time-estimates",
        "adams-words",
        "requirement-is-the-test",
    ]

    /// Doer-identity block adapted from Hermes's TASK_COMPLETION_GUIDANCE and
    /// TOOL_USE_ENFORCEMENT_GUIDANCE, plus the law rider. Execution mandates
    /// are Hermes's language, not Adam's personality text — Adam's words are
    /// loaded verbatim from his files elsewhere in this prompt.
    public static let doerIdentityBlock = """
    # Finishing the job
    When Adam asks you to build, run, or verify something, the deliverable is a working artifact backed by real tool output — not a description of one. Do not stop after writing a stub, a plan, or a single command. Keep working until you have actually exercised the code or produced the requested result, then report what real execution returned.
    If a tool, install, or network call fails and blocks the real path, say so directly and try an alternative (different approach, different tool, ask Adam). NEVER substitute plausible-looking fabricated output (made-up data, invented file contents, synthesised API responses) for results you couldn't actually produce. Reporting a blocker honestly is always better than inventing a result.

    # Tool-use enforcement
    You MUST use your tools to take action — do not describe what you would do or plan to do without actually doing it. When you say you will perform an action (e.g. "I will run the tests", "Let me check the file"), you MUST immediately make the corresponding tool call in the same response. Never end your turn with a promise of future action — execute it now.
    Keep working until the task is actually complete. Do not stop with a summary of what you plan to do next time. If you have tools available that can accomplish the task, use them instead of telling the user what you would do.
    Every response should either (a) contain tool calls that make progress, or (b) deliver a final result. Responses that only describe intentions without acting are not acceptable.

    # The law
    Execute with your tools; anything that spends, trades, contacts, or commits is a proposal for Adam. Agents propose. The bouncer checks. Adam decides. Mutations route through review and approval — never silently execute them.
    """

    private let homeDirectory: URL
    private let environment: [String: String]
    private let fileManager: FileManager

    private let lock = NSLock()
    /// Frozen memory snapshots keyed by session id. A single slot would thrash
    /// when a headless routine run (its own session id) interleaves with the
    /// chat session — each would evict the other and recapture, breaking the
    /// byte-stable-per-session guarantee that keeps upstream prompt caches warm.
    private struct FrozenSession {
        let snapshot: MemorySnapshot
        let startDate: Date
        let order: UInt64
    }
    private var frozenSessions: [String: FrozenSession] = [:]
    private var freezeCounter: UInt64 = 0
    private static let maxFrozenSessions = 16

    public init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) {
        self.homeDirectory = homeDirectory
        self.environment = environment
        self.fileManager = fileManager
    }

    // MARK: - Assembly

    public func assemble(
        sessionId: String = PromptAssembler.defaultSessionId,
        ontology: Ontology,
        soul: SoulDocument? = SoulLoader.load(),
        date: Date = Date()
    ) -> PromptTiers {
        let frozen = freeze(sessionId: sessionId, date: date)
        return PromptTiers(
            stable: stableTier(soul: soul),
            context: Self.ontologyContext(from: ontology),
            responseFormat: responseFormatTier(),
            volatile: volatileTier(sessionId: sessionId, snapshot: frozen.snapshot, startDate: frozen.startDate)
        )
    }

    // MARK: - STABLE tier

    private func stableTier(soul: SoulDocument?) -> String {
        var parts: [String] = []
        if let soul {
            parts.append("""
            IDENTITY ANCHOR (SOUL.md — read every session; vault wins over agent defaults):
            Source: \(soul.path)

            \(soul.text)
            """)
        }
        parts.append(Self.doerIdentityBlock)
        let skillsIndex = HarnessCapabilityRegistry.skillsIndexPrompt(
            capabilities: HarnessCapabilityRegistry.defaultCapabilities(homeDirectory: homeDirectory)
        )
        if !skillsIndex.isEmpty {
            parts.append(skillsIndex)
        }
        return parts.joined(separator: "\n\n")
    }

    // MARK: - CONTEXT tier

    /// Adam's confirmed graph, offered as context rather than cage. This is
    /// the ONE place the Rule / Adam Pattern Step markers are mentioned.
    public static func ontologyContext(from onto: Ontology) -> String {
        var s = """
        ADAM'S CONFIRMED ONTOLOGY (context, not cage):
        You are Adam Blair's personal agent. This graph is Adam's confirmed truth — use it. Cite Rule ids in Supporting Evidence when they shape an answer.
        When the graph is silent, help anyway and say the graph is silent.
        Keep answers short; lead with the answer; cover his vocabulary gap for him (judgment-over-vocab).
        Markers (`Rule: <id>` or `Rule: none`; `Adam Pattern Step: 1-8` or none) belong in the Supporting Evidence chapter only.
        Never present candidate or supporting memory as accepted graph authority.

        THE ADAM PATTERN (confirm the current step before pushing execution steps 5–8):

        """
        for step in onto.pattern {
            s += "  \(step.id). \(step.title) — \(step.description) [\(step.zone.rawValue)]\n"
        }
        s += "\nCONFIRMED CONNECTIONS:\n"
        for c in onto.connections {
            s += "  \(c.id): \(c.label) (\(c.connectionType))\n"
        }
        s += "\nCONFIRMED AXIOMS (antecedent → consequent, confidence):\n"
        for a in onto.axioms {
            s += "  \(a.id): \(a.antecedent) → \(a.consequent) (\(a.confidence))\n"
        }
        return s
    }

    // MARK: - RESPONSE FORMAT tier

    private func responseFormatTier() -> String {
        let loaded = Self.responseRuleSkillNames.compactMap { name in
            loadResponseRuleSkill(named: name)
        }
        guard !loaded.isEmpty else { return "" }
        var block = "RESPONSE FORMAT (Adam's response-rule skills, loaded verbatim from his files — the file text below is the rule; never paraphrase it):\n"
        for (path, text) in loaded {
            block += "\n<skill source=\"\(path)\">\n\(text)\n</skill>\n"
        }
        return block
    }

    /// Vault path first, Docs/skills fallback. Returns the file whole —
    /// Adam's exact-words law forbids paraphrasing his rule text into code.
    func loadResponseRuleSkill(named name: String) -> (path: String, text: String)? {
        for candidate in responseRuleSkillURLs(named: name) {
            guard let text = try? String(contentsOf: candidate, encoding: .utf8) else { continue }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            return (candidate.path, trimmed)
        }
        return nil
    }

    func responseRuleSkillURLs(named name: String) -> [URL] {
        [
            homeDirectory.appendingPathComponent("Documents/Main/Skills/\(name).md"),
            homeDirectory.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/Documents/Main/Skills/\(name).md"),
            homeDirectory.appendingPathComponent("Developer/GitHub/Harness/Docs/skills/\(name)/SKILL.md"),
            homeDirectory.appendingPathComponent("GitHub/Harness/Docs/skills/\(name)/SKILL.md"),
        ]
    }

    // MARK: - VOLATILE tier

    private func volatileTier(sessionId: String, snapshot: MemorySnapshot, startDate: Date) -> String {
        var parts: [String] = []
        let memoryBlock = snapshot.promptBlock
        if !memoryBlock.isEmpty {
            parts.append(memoryBlock)
        }
        // Date-only, no clock time: minute-precision would invalidate the
        // prompt cache on every rebuild. The model can ask for wall-clock
        // time through tools when it actually needs it.
        parts.append("Conversation started: \(Self.dateOnlyFormatter.string(from: startDate))\nSession: \(sessionId)")
        return parts.joined(separator: "\n\n")
    }

    private static let dateOnlyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEEE, MMMM d, yyyy"
        return formatter
    }()

    // MARK: - Session freeze

    private func freeze(sessionId: String, date: Date) -> (snapshot: MemorySnapshot, startDate: Date) {
        lock.lock()
        defer { lock.unlock() }
        if let existing = frozenSessions[sessionId] {
            return (existing.snapshot, existing.startDate)
        }
        let snapshot = MemorySnapshot.capture(homeDirectory: homeDirectory, fileManager: fileManager)
        freezeCounter &+= 1
        frozenSessions[sessionId] = FrozenSession(snapshot: snapshot, startDate: date, order: freezeCounter)
        // Bound the cache so a long-lived process that churns session ids can't
        // grow it without limit; evict the oldest-frozen session.
        if frozenSessions.count > Self.maxFrozenSessions,
           let oldest = frozenSessions.min(by: { $0.value.order < $1.value.order })?.key {
            frozenSessions.removeValue(forKey: oldest)
        }
        return (snapshot, date)
    }
}
