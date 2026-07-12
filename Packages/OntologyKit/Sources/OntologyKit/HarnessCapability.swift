import Foundation

public enum HarnessCapabilityKind: String, Codable, Sendable, Equatable, CaseIterable {
    case skill
    case plugin
    case connector
    case tool
}

public struct HarnessCapability: Identifiable, Codable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let kind: HarnessCapabilityKind
    public let sourceSystem: String
    public let category: String
    public let description: String
    public let path: URL
    public let state: HarnessConnectorState
    public let provenance: String
    /// YAML-frontmatter `platforms` list. Empty means every platform.
    public let platforms: [String]

    public init(
        id: String? = nil,
        name: String,
        kind: HarnessCapabilityKind,
        sourceSystem: String,
        category: String,
        description: String,
        path: URL,
        state: HarnessConnectorState = .available,
        provenance: String,
        platforms: [String] = []
    ) {
        self.id = id ?? "\(sourceSystem):\(kind.rawValue):\(path.path)"
        self.name = name
        self.kind = kind
        self.sourceSystem = sourceSystem
        self.category = category
        self.description = description
        self.path = path
        self.state = state
        self.provenance = provenance
        self.platforms = platforms
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        kind = try container.decode(HarnessCapabilityKind.self, forKey: .kind)
        sourceSystem = try container.decode(String.self, forKey: .sourceSystem)
        category = try container.decode(String.self, forKey: .category)
        description = try container.decode(String.self, forKey: .description)
        path = try container.decode(URL.self, forKey: .path)
        state = try container.decode(HarnessConnectorState.self, forKey: .state)
        provenance = try container.decode(String.self, forKey: .provenance)
        platforms = try container.decodeIfPresent([String].self, forKey: .platforms) ?? []
    }

    /// Whether this capability applies to the platform Harness runs on (macOS).
    /// An empty platforms list means the skill is universal.
    public var matchesCurrentPlatform: Bool {
        guard !platforms.isEmpty else { return true }
        let normalized = Set(platforms.map { $0.lowercased() })
        let current: Set<String> = ["macos", "mac", "darwin", "osx", "all", "any"]
        return !normalized.isDisjoint(with: current)
    }
}

public enum HarnessCapabilityRegistry {
    public static func defaultCapabilities(
        homeDirectory: URL = URL(fileURLWithPath: NSHomeDirectory()),
        includeProtectedUserFolders: Bool = true
    ) -> [HarnessCapability] {
        deduplicated(
            skillCapabilities(
                homeDirectory: homeDirectory,
                includeProtectedUserFolders: includeProtectedUserFolders
            ) + pluginCapabilities(homeDirectory: homeDirectory)
        )
    }

    public static func groupCounts(_ capabilities: [HarnessCapability]) -> [(key: String, value: Int)] {
        let grouped = Dictionary(grouping: capabilities) { capability in
            "\(capability.sourceSystem) / \(capability.category)"
        }
        return grouped
            .map { (key: $0.key, value: $0.value.count) }
            .sorted { lhs, rhs in
                if lhs.value == rhs.value { return lhs.key < rhs.key }
                return lhs.value > rhs.value
            }
    }

    /// Hard-sell skills index for the STABLE prompt tier. The header language
    /// is adapted verbatim from Hermes's build_skills_system_prompt so the
    /// model actually loads skills instead of winging it. Vault Skills/ wins
    /// name collisions; skills whose frontmatter names other platforms are
    /// filtered out.
    public static func skillsIndexPrompt(capabilities: [HarnessCapability]) -> String {
        let skills = vaultPreferred(
            capabilities.filter { $0.kind == .skill && $0.matchesCurrentPlatform }
        )
        guard !skills.isEmpty else { return "" }

        let grouped = Dictionary(grouping: skills) { $0.category }
        var indexLines: [String] = []
        for category in grouped.keys.sorted(by: { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }) {
            indexLines.append("  \(category):")
            var seen: Set<String> = []
            let entries = grouped[category, default: []]
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            for skill in entries {
                let key = skill.name.lowercased()
                guard !seen.contains(key) else { continue }
                seen.insert(key)
                if skill.description.isEmpty {
                    indexLines.append("    - \(skill.name)")
                } else {
                    indexLines.append("    - \(skill.name): \(skill.description)")
                }
            }
        }

        return """
        ## Skills (mandatory)
        Before replying, scan the skills below. If a skill matches or is even partially relevant to your task, you MUST load its file and follow its instructions. Err on the side of loading — it is always better to have context you don't need than to miss critical steps, pitfalls, or established workflows. Skills contain specialized knowledge — proven workflows, exact commands, and pitfalls that outperform general-purpose approaches. Load the skill even if you think you could handle the task with basic tools. Skills also encode Adam's preferred approach, conventions, and quality standards for tasks like code review, planning, and testing — load them even for tasks you already know how to do, because the skill defines how it should be done here.

        <available_skills>
        \(indexLines.joined(separator: "\n"))
        </available_skills>

        Only proceed without loading a skill if genuinely none are relevant to the task.
        """
    }

    /// Collapses name collisions so the vault copy wins — the vault is the
    /// canonical home of Adam's skills; deployed copies are replicas.
    public static func vaultPreferred(_ capabilities: [HarnessCapability]) -> [HarnessCapability] {
        var winners: [String: HarnessCapability] = [:]
        var order: [String] = []
        for capability in capabilities {
            let key = capability.name.lowercased()
            if let existing = winners[key] {
                if existing.sourceSystem != "Vault" && capability.sourceSystem == "Vault" {
                    winners[key] = capability
                }
            } else {
                winners[key] = capability
                order.append(key)
            }
        }
        return order.compactMap { winners[$0] }
    }

    public static let adamCommunicationSkillNames: Set<String> = [
        "articulate-leadership-communication",
        "cognitive-fit",
        "no-time-estimates",
        "requirement-is-the-test",
        "market-inefficiency",
        "adams-words",
    ]

    private static func skillCapabilities(
        homeDirectory: URL,
        includeProtectedUserFolders: Bool
    ) -> [HarnessCapability] {
        var roots: [(source: String, root: URL)] = [
            ("Harness", homeDirectory.appendingPathComponent("Developer/GitHub/Harness/Docs/skills", isDirectory: true)),
            ("Harness", homeDirectory.appendingPathComponent("GitHub/Harness/Docs/skills", isDirectory: true)),
            ("Hermes", homeDirectory.appendingPathComponent(".hermes/skills", isDirectory: true)),
            ("Hermes Studio", homeDirectory.appendingPathComponent(".hermes/profiles/studio/skills", isDirectory: true)),
            ("Claude", homeDirectory.appendingPathComponent(".claude/skills", isDirectory: true)),
            ("Codex", homeDirectory.appendingPathComponent(".codex/skills", isDirectory: true)),
            ("Grok", homeDirectory.appendingPathComponent(".grok/skills", isDirectory: true)),
            ("Agents", homeDirectory.appendingPathComponent(".agents/skills", isDirectory: true)),
        ]
        if includeProtectedUserFolders {
            roots.insert(("Vault", homeDirectory.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/Documents/Main/Skills", isDirectory: true)), at: 0)
            roots.insert(("Vault", homeDirectory.appendingPathComponent("Documents/Main/Skills", isDirectory: true)), at: 0)
        }

        let packaged = roots.flatMap { source, root in
            skillFiles(in: root).compactMap { skillFile in
                skillCapability(sourceSystem: source, root: root, skillFile: skillFile)
            }
        }
        let vaultNotes = includeProtectedUserFolders
            ? vaultSkillCapabilities(homeDirectory: homeDirectory)
            : []
        return packaged + vaultNotes
    }

    private static func vaultSkillCapabilities(homeDirectory: URL) -> [HarnessCapability] {
        let candidates = [
            homeDirectory.appendingPathComponent("Documents/Main/Skills", isDirectory: true),
            homeDirectory.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/Documents/Main/Skills", isDirectory: true)
        ]
        guard let root = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }),
              let files = try? FileManager.default.contentsOfDirectory(
                  at: root,
                  includingPropertiesForKeys: [.isRegularFileKey],
                  options: [.skipsHiddenFiles]
              )
        else { return [] }

        return files
            .filter { $0.pathExtension.lowercased() == "md" && $0.lastPathComponent != "Skills Hub.md" }
            .compactMap { vaultSkillCapability(root: root, file: $0) }
    }

    private static func vaultSkillCapability(root: URL, file: URL) -> HarnessCapability? {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        let frontmatter = parseFrontmatter(text)
        if let type = frontmatter["type"], type != "skill" { return nil }
        let name = frontmatter["title"] ?? file.deletingPathExtension().lastPathComponent
        let description = frontmatter["summary"] ?? firstMarkdownText(text) ?? "Vault skill note."
        return HarnessCapability(
            name: name,
            kind: .skill,
            sourceSystem: "Vault",
            category: "communication",
            description: description,
            path: file,
            provenance: "Vault note: \(relativePath(root: root, file: file))",
            platforms: parseListValue(frontmatter["platforms"])
        )
    }

    private static func pluginCapabilities(homeDirectory: URL) -> [HarnessCapability] {
        let roots: [(source: String, root: URL)] = [
            ("Claude", homeDirectory.appendingPathComponent(".claude/plugins/cache", isDirectory: true)),
            ("Codex", homeDirectory.appendingPathComponent(".codex/plugins/cache", isDirectory: true)),
            ("Grok", homeDirectory.appendingPathComponent(".grok/installed-plugins", isDirectory: true)),
            ("Hermes", homeDirectory.appendingPathComponent(".hermes/hermes-agent/plugins", isDirectory: true))
        ]

        return roots.flatMap { source, root in
            pluginManifestFiles(in: root).compactMap { manifest in
                pluginCapability(sourceSystem: source, root: root, manifest: manifest)
            }
        }
    }

    private static func skillFiles(in root: URL) -> [URL] {
        guard FileManager.default.fileExists(atPath: root.path),
              let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsPackageDescendants]
              )
        else { return [] }

        var files: [URL] = []
        for case let file as URL in enumerator {
            if file.lastPathComponent == "SKILL.md" {
                files.append(file)
            }
        }
        return files.sorted { $0.path < $1.path }
    }

    private static func pluginManifestFiles(in root: URL) -> [URL] {
        guard FileManager.default.fileExists(atPath: root.path),
              let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsPackageDescendants]
              )
        else { return [] }

        let allowed = Set(["plugin.json", ".app.json", ".mcp.json", "plugin.yaml", "plugin.yml"])
        var files: [URL] = []
        for case let file as URL in enumerator {
            if file.pathComponents.contains("node_modules") {
                enumerator.skipDescendants()
                continue
            }
            if allowed.contains(file.lastPathComponent) || file.path.hasSuffix("/.claude-plugin/plugin.json") || file.path.hasSuffix("/.codex-plugin/plugin.json") {
                files.append(file)
            }
        }
        return files.sorted { $0.path < $1.path }
    }

    private static func skillCapability(sourceSystem: String, root: URL, skillFile: URL) -> HarnessCapability? {
        guard let text = try? String(contentsOf: skillFile, encoding: .utf8) else { return nil }
        let frontmatter = parseFrontmatter(text)
        let name = frontmatter["name"] ?? skillFile.deletingLastPathComponent().lastPathComponent
        let description = frontmatter["description"] ?? firstMarkdownText(text) ?? "Skill instruction."
        let category = categoryName(root: root, file: skillFile.deletingLastPathComponent())
        return HarnessCapability(
            name: name,
            kind: .skill,
            sourceSystem: sourceSystem,
            category: category,
            description: description,
            path: skillFile,
            provenance: "\(sourceSystem) skill: \(relativePath(root: root, file: skillFile))",
            platforms: parseListValue(frontmatter["platforms"])
        )
    }

    /// Parses a frontmatter list value: `[macos, ios]`, `macos, ios`, or a
    /// single bare token all yield the same normalized array.
    static func parseListValue(_ raw: String?) -> [String] {
        guard let raw else { return [] }
        return raw
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .split(separator: ",")
            .map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            }
            .filter { !$0.isEmpty }
    }

    private static func pluginCapability(sourceSystem: String, root: URL, manifest: URL) -> HarnessCapability? {
        guard let text = try? String(contentsOf: manifest, encoding: .utf8) else { return nil }
        let metadata = manifest.pathExtension.lowercased().hasPrefix("y")
            ? parseSimpleYAML(text)
            : parseSimpleJSON(text)
        let fallback = manifest.deletingLastPathComponent().lastPathComponent
        let name = metadata["name"] ?? metadata["displayName"] ?? fallback
        let description = metadata["description"] ?? metadata["shortDescription"] ?? "Installed plugin manifest."
        return HarnessCapability(
            name: name,
            kind: .plugin,
            sourceSystem: sourceSystem,
            category: "plugin",
            description: description,
            path: manifest,
            provenance: "\(sourceSystem) plugin manifest: \(relativePath(root: root, file: manifest))"
        )
    }

    private static func parseFrontmatter(_ text: String) -> [String: String] {
        guard text.hasPrefix("---\n"),
              let endRange = text.range(of: "\n---", range: text.index(text.startIndex, offsetBy: 4)..<text.endIndex)
        else { return [:] }
        let body = text[text.index(text.startIndex, offsetBy: 4)..<endRange.lowerBound]
        return parseKeyValueLines(String(body))
    }

    private static func parseSimpleYAML(_ text: String) -> [String: String] {
        parseKeyValueLines(text)
    }

    private static func parseSimpleJSON(_ text: String) -> [String: String] {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        var result: [String: String] = [:]
        for key in ["name", "displayName", "description", "shortDescription", "version"] {
            if let value = object[key] as? String {
                result[key] = value
            }
        }
        if let interface = object["interface"] as? [String: Any] {
            for key in ["displayName", "shortDescription", "longDescription"] {
                if let value = interface[key] as? String {
                    result[key == "longDescription" ? "description" : key] = value
                }
            }
        }
        return result
    }

    private static func parseKeyValueLines(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespacesAndNewlines)
            let valueStart = line.index(after: colon)
            let value = line[valueStart...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            guard !key.isEmpty, !value.isEmpty else { continue }
            result[key] = value
        }
        return result
    }

    private static func firstMarkdownText(_ text: String) -> String? {
        text
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty && !$0.hasPrefix("---") && !$0.hasPrefix("#") }
    }

    private static func categoryName(root: URL, file: URL) -> String {
        let relative = relativePath(root: root, file: file)
        let components = relative.split(separator: "/").map(String.init)
        if components.count > 1 {
            return components[0]
        }
        return "personal"
    }

    private static func relativePath(root: URL, file: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let filePath = file.standardizedFileURL.path
        guard filePath.hasPrefix(rootPath) else { return filePath }
        return String(filePath.dropFirst(rootPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private static func deduplicated(_ capabilities: [HarnessCapability]) -> [HarnessCapability] {
        var seen: Set<String> = []
        var result: [HarnessCapability] = []
        for capability in capabilities {
            let key = "\(capability.sourceSystem):\(capability.kind.rawValue):\(capability.path.standardizedFileURL.path)"
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            result.append(capability)
        }
        return result.sorted { lhs, rhs in
            if lhs.sourceSystem == rhs.sourceSystem {
                if lhs.category == rhs.category {
                    return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                }
                return lhs.category.localizedCaseInsensitiveCompare(rhs.category) == .orderedAscending
            }
            return lhs.sourceSystem < rhs.sourceSystem
        }
    }
}
