import Foundation

public enum HarnessConnectorKind: String, Codable, Sendable, Equatable, CaseIterable {
    case github
    case obsidian
    case appleNotes = "apple-notes"
    case notebookLM = "notebooklm"
    case acceptedGraph = "accepted-graph"
    case skillDirectory = "skill-directory"
    case pluginDirectory = "plugin-directory"
    case agentBridge = "agent-bridge"
    case mcpServer = "mcp-server"
    case custom
}

public enum HarnessConnectorRole: String, Codable, Sendable, Equatable, CaseIterable {
    case authority
    case supportingMemory = "supporting-memory"
    case proceduralMemory = "procedural-memory"
    case plugin
    case toolBridge = "tool-bridge"
}

public enum HarnessConnectorState: String, Codable, Sendable, Equatable, CaseIterable {
    case available
    case missing
    case needsPermission = "needs-permission"
    case unavailable
}

public struct HarnessConnector: Identifiable, Codable, Sendable, Equatable {
    public let id: String
    public let title: String
    public let kind: HarnessConnectorKind
    public let role: HarnessConnectorRole
    public let sourceSystem: String
    public let root: URL
    public let state: HarnessConnectorState
    public let summary: String
    public let permission: String
    public let provenance: String
    public let weight: Double
    public let allowedExtensions: Set<String>?

    public init(
        id: String? = nil,
        title: String,
        kind: HarnessConnectorKind,
        role: HarnessConnectorRole,
        sourceSystem: String,
        root: URL,
        state: HarnessConnectorState? = nil,
        summary: String,
        permission: String,
        provenance: String,
        weight: Double = 1,
        allowedExtensions: Set<String>? = nil
    ) {
        self.id = id ?? "\(sourceSystem):\(kind.rawValue):\(root.path)"
        self.title = title
        self.kind = kind
        self.role = role
        self.sourceSystem = sourceSystem
        self.root = root
        self.state = state ?? (HarnessConnectorRegistry.pathExists(root) ? .available : .missing)
        self.summary = summary
        self.permission = permission
        self.provenance = provenance
        self.weight = weight
        self.allowedExtensions = allowedExtensions
    }
}

public enum HarnessConnectorRegistry {
    public static func defaultConnectors(
        homeDirectory: URL = URL(fileURLWithPath: NSHomeDirectory()),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        includeProtectedUserFolders: Bool = true
    ) -> [HarnessConnector] {
        deduplicated(
            memoryConnectors(
                homeDirectory: homeDirectory,
                environment: environment,
                includeProtectedUserFolders: includeProtectedUserFolders
            )
            + (includeProtectedUserFolders ? authorityConnectors(homeDirectory: homeDirectory) : [])
            + skillConnectors(homeDirectory: homeDirectory)
            + pluginConnectors(homeDirectory: homeDirectory)
            + mcpConnectors(environment: environment)
            + agentBridgeConnectors(homeDirectory: homeDirectory)
        )
    }

    public static func memorySources(from connectors: [HarnessConnector]) -> [LocalMemorySource] {
        connectors
            .filter { $0.role == .supportingMemory }
            .map { connector in
                LocalMemorySource(
                    id: connector.id,
                    title: connector.title,
                    kind: localSourceKind(for: connector.kind),
                    root: connector.root,
                    exists: connector.state == .available,
                    weight: connector.weight,
                    allowedExtensions: connector.allowedExtensions
                )
            }
    }

    public static func pathExists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    private static func memoryConnectors(
        homeDirectory: URL,
        environment: [String: String],
        includeProtectedUserFolders: Bool
    ) -> [HarnessConnector] {
        var connectors: [HarnessConnector] = [
            HarnessConnector(
                title: "GitHub repositories",
                kind: .github,
                role: .supportingMemory,
                sourceSystem: "Local",
                root: homeDirectory.appendingPathComponent("Developer/GitHub", isDirectory: true),
                summary: "Local repositories, code, docs, and product context.",
                permission: "Read-only filesystem access.",
                provenance: "File paths are shown on memory hits.",
                weight: 1.22,
                allowedExtensions: LocalMemorySourceRegistry.codeAndTextExtensions()
            ),
            HarnessConnector(
                title: "Obsidian vault",
                kind: .obsidian,
                role: .supportingMemory,
                sourceSystem: "Obsidian",
                root: homeDirectory.appendingPathComponent("Developer/GitHub/obsidian-vault", isDirectory: true),
                summary: "Markdown vault notes used as supporting memory.",
                permission: "Read-only filesystem access.",
                provenance: "Vault notes are never treated as accepted authority.",
                weight: 1.14,
                allowedExtensions: LocalMemorySourceRegistry.noteExtensions()
            )
        ]

        if includeProtectedUserFolders {
            connectors += protectedMemoryConnectors(homeDirectory: homeDirectory)
            connectors.append(contentsOf: notebookLMConnectors(homeDirectory: homeDirectory, environment: environment))
            connectors.append(contentsOf: customMemoryConnectors(from: environment, homeDirectory: homeDirectory))
        }
        return connectors
    }

    private static func protectedMemoryConnectors(homeDirectory: URL) -> [HarnessConnector] {
        [
            HarnessConnector(
                title: "GitHub repositories",
                kind: .github,
                role: .supportingMemory,
                sourceSystem: "Local",
                root: homeDirectory.appendingPathComponent("Documents/GitHub", isDirectory: true),
                summary: "Alternate local GitHub repository root.",
                permission: "Read-only filesystem access.",
                provenance: "File paths are shown on memory hits.",
                weight: 1.16,
                allowedExtensions: LocalMemorySourceRegistry.codeAndTextExtensions()
            ),
            HarnessConnector(
                title: "Obsidian Main vault",
                kind: .obsidian,
                role: .supportingMemory,
                sourceSystem: "Obsidian",
                root: homeDirectory.appendingPathComponent("Documents/Main", isDirectory: true),
                summary: "Markdown vault notes used as supporting memory.",
                permission: "Read-only filesystem access.",
                provenance: "Vault notes are never treated as accepted authority.",
                weight: 1.18,
                allowedExtensions: LocalMemorySourceRegistry.noteExtensions()
            ),
            HarnessConnector(
                title: "Obsidian iCloud vaults",
                kind: .obsidian,
                role: .supportingMemory,
                sourceSystem: "Obsidian",
                root: homeDirectory.appendingPathComponent("Library/Mobile Documents/iCloud~md~obsidian/Documents", isDirectory: true),
                summary: "iCloud-hosted Obsidian vaults.",
                permission: "Read-only filesystem access.",
                provenance: "Vault notes are never treated as accepted authority.",
                weight: 1.1,
                allowedExtensions: LocalMemorySourceRegistry.noteExtensions()
            ),
            HarnessConnector(
                title: "Apple Notes export",
                kind: .appleNotes,
                role: .supportingMemory,
                sourceSystem: "Apple Notes",
                root: homeDirectory.appendingPathComponent("Documents/Harness/Apple Notes Export", isDirectory: true),
                state: appleNotesState(homeDirectory: homeDirectory),
                summary: "Local Notes export searched as supporting memory.",
                permission: "Requires macOS Automation permission on first sync.",
                provenance: "Exported note files are shown as memory hits.",
                weight: 1.08,
                allowedExtensions: LocalMemorySourceRegistry.noteExtensions()
            ),
            HarnessConnector(
                title: "Apple Notes export",
                kind: .appleNotes,
                role: .supportingMemory,
                sourceSystem: "Apple Notes",
                root: homeDirectory.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/Harness/Apple Notes Export", isDirectory: true),
                summary: "iCloud-hosted Notes export searched as supporting memory.",
                permission: "Requires macOS Automation permission on first sync.",
                provenance: "Exported note files are shown as memory hits.",
                weight: 1.05,
                allowedExtensions: LocalMemorySourceRegistry.noteExtensions()
            )
        ]
    }

    private static func authorityConnectors(homeDirectory: URL) -> [HarnessConnector] {
        [
            HarnessConnector(
                title: "Accepted Understood graph",
                kind: .acceptedGraph,
                role: .authority,
                sourceSystem: "Understood",
                root: homeDirectory.appendingPathComponent("Documents/Main/Ontology/Alignment/accepted-alignment-graph.ttl"),
                summary: "Deterministic approved graph authority.",
                permission: "Read-only unless promoted through review.",
                provenance: "Loaded into the accepted named graph after validation."
            )
        ]
    }

    private static func skillConnectors(homeDirectory: URL) -> [HarnessConnector] {
        [
            skillConnector("Claude", homeDirectory.appendingPathComponent(".claude/skills", isDirectory: true)),
            skillConnector("Codex", homeDirectory.appendingPathComponent(".codex/skills", isDirectory: true)),
            skillConnector("Grok", homeDirectory.appendingPathComponent(".grok/skills", isDirectory: true)),
            skillConnector("Hermes", homeDirectory.appendingPathComponent(".hermes/skills", isDirectory: true)),
            skillConnector("Agents", homeDirectory.appendingPathComponent(".agents/skills", isDirectory: true))
        ]
    }

    private static func pluginConnectors(homeDirectory: URL) -> [HarnessConnector] {
        [
            pluginConnector("Claude", homeDirectory.appendingPathComponent(".claude/plugins/cache", isDirectory: true)),
            pluginConnector("Codex", homeDirectory.appendingPathComponent(".codex/plugins/cache", isDirectory: true)),
            pluginConnector("Grok", homeDirectory.appendingPathComponent(".grok/installed-plugins", isDirectory: true)),
            pluginConnector("Hermes", homeDirectory.appendingPathComponent(".hermes/plugins", isDirectory: true))
        ]
    }

    private static func mcpConnectors(environment: [String: String]) -> [HarnessConnector] {
        [
            HarnessConnector(
                title: "Firecrawl MCP",
                kind: .mcpServer,
                role: .toolBridge,
                sourceSystem: "Firecrawl",
                root: URL(string: "https://mcp.firecrawl.dev/v2/mcp")!,
                state: hasFirecrawlKey(environment) ? .available : .needsPermission,
                summary: "Approved external web research: search, scrape, crawl, map, and extract through Firecrawl MCP.",
                permission: "Requires Firecrawl API key and per-step approval before external web calls.",
                provenance: "Key is stored outside the connector catalog; MCP launch config is generated at runtime."
            )
        ]
    }

    private static func agentBridgeConnectors(homeDirectory: URL) -> [HarnessConnector] {
        [
            HarnessConnector(
                title: "Hermes tool registry",
                kind: .agentBridge,
                role: .toolBridge,
                sourceSystem: "Hermes",
                root: homeDirectory.appendingPathComponent(".hermes/hermes-agent/tools", isDirectory: true),
                summary: "Hermes-style self-registering tool modules and toolsets.",
                permission: "Read-only architecture discovery.",
                provenance: "Used to mirror tool registry patterns in Harness."
            ),
            HarnessConnector(
                title: "Understood ontology steward",
                kind: .agentBridge,
                role: .toolBridge,
                sourceSystem: "Hermes",
                root: homeDirectory.appendingPathComponent(".hermes/ontology-steward", isDirectory: true),
                summary: "Understood graph bridge, Fuseki helpers, and review queue commands.",
                permission: "Read-only unless explicit graph sync actions are invoked.",
                provenance: "Graph mutations remain behind review and validation."
            )
        ]
    }

    private static func skillConnector(_ sourceSystem: String, _ root: URL) -> HarnessConnector {
        HarnessConnector(
            title: "\(sourceSystem) skills",
            kind: .skillDirectory,
            role: .proceduralMemory,
            sourceSystem: sourceSystem,
            root: root,
            summary: "Installed skill instructions and reusable procedures.",
            permission: "Read-only discovery by default.",
            provenance: "Skill paths and source systems are shown in the connector catalog."
        )
    }

    private static func pluginConnector(_ sourceSystem: String, _ root: URL) -> HarnessConnector {
        HarnessConnector(
            title: "\(sourceSystem) plugins",
            kind: .pluginDirectory,
            role: .plugin,
            sourceSystem: sourceSystem,
            root: root,
            summary: "Installed plugin bundles, apps, MCP servers, or skills.",
            permission: "Read-only discovery by default.",
            provenance: "Plugin install paths and source systems are shown in the connector catalog."
        )
    }

    private static func hasFirecrawlKey(_ environment: [String: String]) -> Bool {
        environment["FIRECRAWL_API_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    private static func appleNotesState(homeDirectory: URL) -> HarnessConnectorState {
        let exportRoot = homeDirectory.appendingPathComponent("Documents/Harness/Apple Notes Export", isDirectory: true)
        return pathExists(exportRoot) ? .available : .needsPermission
    }

    private static func notebookLMConnectors(homeDirectory: URL, environment: [String: String]) -> [HarnessConnector] {
        let defaultRoots = [
            homeDirectory.appendingPathComponent("Documents/Harness/NotebookLM", isDirectory: true),
            homeDirectory.appendingPathComponent(
                "Library/Mobile Documents/com~apple~CloudDocs/Harness/NotebookLM",
                isDirectory: true
            )
        ]
        let configuredRoots = configuredPathList(
            environment["HARNESS_NOTEBOOKLM_ROOTS"],
            homeDirectory: homeDirectory
        )
        return (defaultRoots + configuredRoots).map { root in
            HarnessConnector(
                title: "NotebookLM notebooks",
                kind: .notebookLM,
                role: .supportingMemory,
                sourceSystem: "NotebookLM",
                root: root,
                state: pathExists(root) ? .available : .needsPermission,
                summary: "Exported NotebookLM notebooks, study guides, briefs, and source packs used as synthesized research context.",
                permission: "Read-only access to exported files; direct NotebookLM account control is not invoked.",
                provenance: "Treated like external synthesized research unless a file labels source-class: personal-data or source-class: direct-thought.",
                weight: 0.9,
                allowedExtensions: LocalMemorySourceRegistry.notebookLMExtensions()
            )
        }
    }

    private static func customMemoryConnectors(from environment: [String: String], homeDirectory: URL) -> [HarnessConnector] {
        guard let raw = environment["HARNESS_MEMORY_ROOTS"], !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return []
        }
        return configuredPathList(raw, homeDirectory: homeDirectory)
            .filter { !$0.path.isEmpty }
            .map {
                HarnessConnector(
                    title: "Custom memory root",
                    kind: .custom,
                    role: .supportingMemory,
                    sourceSystem: "Custom",
                    root: $0,
                    summary: "User-configured supporting memory root.",
                    permission: "Read-only filesystem access.",
                    provenance: "Configured through HARNESS_MEMORY_ROOTS.",
                    allowedExtensions: LocalMemorySourceRegistry.codeAndTextExtensions()
                )
            }
    }

    private static func configuredPathList(_ raw: String?, homeDirectory: URL) -> [URL] {
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return []
        }
        return raw
            .split { character in character == ":" || character == "\n" }
            .map(String.init)
            .map { expandHome($0.trimmingCharacters(in: .whitespacesAndNewlines), homeDirectory: homeDirectory) }
    }

    private static func expandHome(_ path: String, homeDirectory: URL) -> URL {
        if path == "~" {
            return homeDirectory
        }
        if path.hasPrefix("~/") {
            return homeDirectory.appendingPathComponent(String(path.dropFirst(2)), isDirectory: true)
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private static func localSourceKind(for kind: HarnessConnectorKind) -> LocalMemorySourceKind {
        switch kind {
        case .github:
            return .github
        case .obsidian:
            return .obsidian
        case .appleNotes:
            return .appleNotes
        case .notebookLM:
            return .notebookLM
        default:
            return .custom
        }
    }

    private static func deduplicated(_ connectors: [HarnessConnector]) -> [HarnessConnector] {
        var seen: Set<String> = []
        var result: [HarnessConnector] = []
        for connector in connectors {
            let key = "\(connector.role.rawValue):\(connector.root.standardizedFileURL.path)"
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            result.append(connector)
        }
        return result
    }
}
