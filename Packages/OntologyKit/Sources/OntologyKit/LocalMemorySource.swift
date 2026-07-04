import Foundation

public enum LocalMemorySourceKind: String, Codable, Sendable, Equatable, CaseIterable {
    case github
    case obsidian
    case appleNotes = "apple-notes"
    case notebookLM = "notebooklm"
    case harness
    case custom
}

public struct LocalMemorySource: Identifiable, Codable, Sendable, Equatable {
    public let id: String
    public let title: String
    public let kind: LocalMemorySourceKind
    public let root: URL
    public let exists: Bool
    public let weight: Double
    public let allowedExtensions: Set<String>?

    public init(
        id: String? = nil,
        title: String,
        kind: LocalMemorySourceKind,
        root: URL,
        exists: Bool? = nil,
        weight: Double,
        allowedExtensions: Set<String>? = nil
    ) {
        self.id = id ?? "\(kind.rawValue):\(root.path)"
        self.title = title
        self.kind = kind
        self.root = root
        self.exists = exists ?? LocalMemorySourceRegistry.directoryExists(root)
        self.weight = weight
        self.allowedExtensions = allowedExtensions
    }
}

public enum LocalMemorySourceRegistry {
    public static func defaultSources(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [LocalMemorySource] {
        HarnessConnectorRegistry.memorySources(
            from: HarnessConnectorRegistry.defaultConnectors(
                homeDirectory: homeDirectory,
                environment: environment
            )
        )
    }

    public static func existingDefaultSources(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [LocalMemorySource] {
        defaultSources(homeDirectory: homeDirectory, environment: environment).filter(\.exists)
    }

    public static func directoryExists(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    public static func noteExtensions() -> Set<String> {
        ["md", "markdown", "txt", "text", "ttl", "html", "rtf"]
    }

    public static func notebookLMExtensions() -> Set<String> {
        noteExtensions().union(["pdf", "ppt", "pptx", "doc", "docx", "key"])
    }

    public static func codeAndTextExtensions() -> Set<String> {
        noteExtensions().union([
            "swift", "py", "js", "jsx", "ts", "tsx", "json", "yml", "yaml",
            "toml", "plist", "sh", "sql", "rb", "go", "rs", "java", "kt"
        ])
    }

    private static func deduplicated(_ sources: [LocalMemorySource]) -> [LocalMemorySource] {
        var seen: Set<String> = []
        var result: [LocalMemorySource] = []
        for source in sources {
            let key = source.root.standardizedFileURL.path
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            result.append(source)
        }
        return result
    }
}
