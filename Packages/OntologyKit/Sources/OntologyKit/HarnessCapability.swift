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

    public init(
        id: String? = nil,
        name: String,
        kind: HarnessCapabilityKind,
        sourceSystem: String,
        category: String,
        description: String,
        path: URL,
        state: HarnessConnectorState = .available,
        provenance: String
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
    }
}

public enum HarnessCapabilityRegistry {
    public static func defaultCapabilities(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [HarnessCapability] {
        deduplicated(skillCapabilities(homeDirectory: homeDirectory) + pluginCapabilities(homeDirectory: homeDirectory))
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

    private static func skillCapabilities(homeDirectory: URL) -> [HarnessCapability] {
        let roots: [(source: String, root: URL)] = [
            ("Hermes", homeDirectory.appendingPathComponent(".hermes/skills", isDirectory: true)),
            ("Claude", homeDirectory.appendingPathComponent(".claude/skills", isDirectory: true)),
            ("Codex", homeDirectory.appendingPathComponent(".codex/skills", isDirectory: true)),
            ("Grok", homeDirectory.appendingPathComponent(".grok/skills", isDirectory: true)),
            ("Agents", homeDirectory.appendingPathComponent(".agents/skills", isDirectory: true))
        ]

        return roots.flatMap { source, root in
            skillFiles(in: root).compactMap { skillFile in
                skillCapability(sourceSystem: source, root: root, skillFile: skillFile)
            }
        }
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
            provenance: "\(sourceSystem) skill: \(relativePath(root: root, file: skillFile))"
        )
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
