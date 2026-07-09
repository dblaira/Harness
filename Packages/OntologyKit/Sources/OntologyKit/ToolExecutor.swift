import Foundation

// MARK: - ToolResult

/// The outcome of one tool call, in the shape the loop feeds back to the model.
public struct ToolResult: Codable, Sendable, Equatable {
    public let toolName: String
    public let output: String
    public let isError: Bool

    public init(toolName: String, output: String, isError: Bool = false) {
        self.toolName = toolName
        self.output = output
        self.isError = isError
    }

    public static func failure(_ toolName: String, _ message: String) -> ToolResult {
        ToolResult(toolName: toolName, output: message, isError: true)
    }
}

// MARK: - Integration protocols

/// Episodic search seam so WS-B1 can inject WS-A4's SessionStore without
/// ToolExecutor depending on a concrete store at init time.
public protocol SessionSearching: Sendable {
    func searchSessions(query: String, limit: Int) async throws -> [SessionSearchHit]
}

extension SessionStore: SessionSearching {}

/// Staging seam for the memory tool. The law: the memory tool NEVER writes
/// memory files directly — it stages a candidate row that surfaces in Adam's
/// review queue (`ReviewQueueStore.loadPendingClaims()`); only Adam's
/// decision moves anything into accepted truth.
public protocol MemoryCandidateStaging: Sendable {
    func stageMemoryCandidate(_ candidate: MemoryCandidate) throws
}

/// Default stager: appends a pending claim to the same
/// `candidates/queue.json` that `ReviewQueueStore` loads its review queue
/// from (ReviewQueueStore has no public staging API yet — when it grows one,
/// conform it to `MemoryCandidateStaging` and delete this).
public struct ReviewQueueMemoryStager: MemoryCandidateStaging {
    private let ontologyRoot: URL

    public init(ontologyRoot: URL = ReviewQueueStore.defaultOntologyRoot()) {
        self.ontologyRoot = ontologyRoot
    }

    public func stageMemoryCandidate(_ candidate: MemoryCandidate) throws {
        let candidatesURL = ontologyRoot.appendingPathComponent("candidates", isDirectory: true)
        let queueURL = candidatesURL.appendingPathComponent("queue.json")

        // JSONSerialization round-trip (not Codable) so fields other agents
        // put on existing claims survive the append untouched.
        var entries: [[String: Any]] = []
        if FileManager.default.fileExists(atPath: queueURL.path) {
            let data = try Data(contentsOf: queueURL)
            guard let existing = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                throw ToolExecutorError.staging("queue.json is not a JSON array; refusing to overwrite it")
            }
            entries = existing
        }

        var entry: [String: Any] = [
            "id": candidate.id,
            "status": "pending",
            "plain": candidate.proposedClaim,
            "evidence": candidate.evidenceNote,
            "source": candidate.sourceRef,
            "domain_a": "",
            "domain_b": "",
            "connection_type": "memory-note",
        ]
        if let strength = candidate.strength {
            entry["strength"] = strength
        }
        entries.append(entry)

        let data = try JSONSerialization.data(withJSONObject: entries, options: [.prettyPrinted, .sortedKeys])
        try FileManager.default.createDirectory(at: candidatesURL, withIntermediateDirectories: true)
        try data.write(to: queueURL, options: .atomic)
    }
}

public enum ToolExecutorError: Error, LocalizedError, Sendable {
    case staging(String)

    public var errorDescription: String? {
        switch self {
        case .staging(let message): return message
        }
    }
}

// MARK: - ToolExecutor

/// Executes the v1 tool catalog. Every mutation path (write_file, dangerous
/// shell) suspends on the ToolApprovalStore; memory stages a candidate for
/// Adam's review queue. Reads are path-guarded to Adam's vault, his GitHub
/// checkouts, and ~/.hermes — secrets (.env, auth.json) are never readable.
public final class ToolExecutor: Sendable {
    public struct Configuration: Sendable {
        public var homeDirectory: URL
        public var shellTimeout: TimeInterval
        public var maxShellTimeout: TimeInterval
        public var outputCap: Int

        public init(
            homeDirectory: URL = URL(fileURLWithPath: NSHomeDirectory()),
            shellTimeout: TimeInterval = 120,
            maxShellTimeout: TimeInterval = 600,
            outputCap: Int = 40_000
        ) {
            self.homeDirectory = homeDirectory
            self.shellTimeout = shellTimeout
            self.maxShellTimeout = maxShellTimeout
            self.outputCap = outputCap
        }
    }

    private let configuration: Configuration
    private let approvals: ToolApprovalStore
    private let memoryStager: any MemoryCandidateStaging
    private let sessionSearcher: (any SessionSearching)?
    private let capabilitiesProvider: @Sendable () -> [HarnessCapability]

    public init(
        configuration: Configuration = Configuration(),
        approvals: ToolApprovalStore,
        memoryStager: (any MemoryCandidateStaging)? = nil,
        sessionSearcher: (any SessionSearching)? = nil,
        capabilitiesProvider: (@Sendable () -> [HarnessCapability])? = nil
    ) {
        self.configuration = configuration
        self.approvals = approvals
        self.memoryStager = memoryStager ?? ReviewQueueMemoryStager()
        self.sessionSearcher = sessionSearcher
        self.capabilitiesProvider = capabilitiesProvider ?? { HarnessCapabilityRegistry.defaultCapabilities() }
    }

    /// Convenience for backends that hand over the raw JSON arguments string.
    public func execute(name: String, inputJSON: String) async -> ToolResult {
        guard let input = JSONValue.parse(inputJSON) else {
            return .failure(name, "Tool input was not valid JSON.")
        }
        return await execute(name: name, input: input)
    }

    /// Execute one tool call. Never throws — failures come back as
    /// `ToolResult(isError: true)` so the loop can show the model what went
    /// wrong and let it recover.
    public func execute(name: String, input: JSONValue) async -> ToolResult {
        switch name {
        case "shell":
            return await runShell(input: input)
        case "read_file":
            return readFile(input: input)
        case "search_files":
            return searchFiles(input: input)
        case "write_file":
            return await writeFile(input: input)
        case "memory":
            return stageMemory(input: input)
        case "skills_list":
            return skillsList(input: input)
        case "skill_view":
            return skillView(input: input)
        case "session_search":
            return await sessionSearch(input: input)
        default:
            return .failure(name, "Unknown tool '\(name)'. Available tools: \(HarnessToolCatalog.v1.map(\.name).joined(separator: ", ")).")
        }
    }

    // MARK: - Path guard

    /// Roots readable by read_file / search_files. ~/Documents/Main appears
    /// in both its local and iCloud (CloudDocs) locations because the vault
    /// lives in either depending on the Mac.
    var readRoots: [URL] {
        let home = configuration.homeDirectory
        return [
            home.appendingPathComponent("Documents/Main", isDirectory: true),
            home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/Documents/Main", isDirectory: true),
            home.appendingPathComponent("Developer/GitHub", isDirectory: true),
            home.appendingPathComponent(".hermes", isDirectory: true),
        ]
    }

    /// Roots writable by write_file (after Adam approves).
    var writeRoots: [URL] {
        let home = configuration.homeDirectory
        return [
            home.appendingPathComponent("Documents/Main", isDirectory: true),
            home.appendingPathComponent("Documents/Harness", isDirectory: true),
            home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/Documents/Main", isDirectory: true),
            home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/Documents/Harness", isDirectory: true),
        ]
    }

    enum PathGuardResult {
        case allowed(URL)
        case refused(String)
    }

    /// Resolve and check a caller-supplied path against an allowlist of
    /// roots. Standardizes `..` segments and resolves symlinks on both sides
    /// so `Main/../../secret` and symlink escapes are caught; denies secrets
    /// files anywhere.
    func guardPath(_ rawPath: String, roots: [URL]) -> PathGuardResult {
        let expanded: String
        if rawPath == "~" {
            expanded = configuration.homeDirectory.path
        } else if rawPath.hasPrefix("~/") {
            expanded = configuration.homeDirectory.path + "/" + String(rawPath.dropFirst(2))
        } else {
            expanded = rawPath
        }
        guard expanded.hasPrefix("/") else {
            return .refused("Use an absolute path (or ~/path); relative paths are not allowed.")
        }

        let resolved = URL(fileURLWithPath: expanded)
            .standardizedFileURL
            .resolvingSymlinksInPath()

        for component in resolved.pathComponents {
            let lowered = component.lowercased()
            if lowered == ".env" || lowered.hasPrefix(".env.") || lowered == "auth.json" {
                return .refused("Secrets files (.env, auth.json) are off-limits to agents.")
            }
        }

        for root in roots {
            let resolvedRoot = root.standardizedFileURL.resolvingSymlinksInPath()
            if resolved.path == resolvedRoot.path || resolved.path.hasPrefix(resolvedRoot.path + "/") {
                return .allowed(resolved)
            }
        }
        let allowed = roots.map { displayPath($0) }.joined(separator: ", ")
        return .refused("Path is outside the allowed roots (\(allowed)).")
    }

    private func displayPath(_ url: URL) -> String {
        let homePath = configuration.homeDirectory.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        if path.hasPrefix(homePath) {
            return "~" + path.dropFirst(homePath.count)
        }
        return path
    }

    // MARK: - shell

    private func runShell(input: JSONValue) async -> ToolResult {
        guard let rawCommand = input["command"]?.stringValue,
              !rawCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure("shell", "shell: missing required field 'command'.")
        }

        // Compose the exact string that will run BEFORE the bouncer sees it,
        // so a workdir can't smuggle anything past the pattern check.
        var command = rawCommand
        if let workdir = input["workdir"]?.stringValue, !workdir.isEmpty {
            let escaped = workdir.replacingOccurrences(of: "'", with: "'\\''")
            command = "cd '\(escaped)' && (\(rawCommand))"
        }

        switch approvals.decision(toolName: "shell", payload: command) {
        case .denied(let reason):
            return .failure("shell", "Denied by the bouncer: \(reason). This command cannot run in Harness.")
        case .requiresApproval(let reason, let patternIds):
            let request = ToolApprovalRequest(
                toolName: "shell",
                summary: command,
                reason: reason,
                patternIds: patternIds
            )
            let resolution = await approvals.awaitDecision(request)
            guard resolution == .approved else {
                return .failure("shell", "Adam denied this command: \(reason). Do not retry it; propose a different approach or ask Adam.")
            }
        case .autoAllow:
            break
        }

        let timeout = min(
            TimeInterval(input["timeout"]?.intValue ?? Int(configuration.shellTimeout)),
            configuration.maxShellTimeout
        )

        #if os(macOS)
        let runner = AgentRunner()
        let capturedCommand = command
        do {
            let output = try await Task.detached(priority: .userInitiated) {
                try runner.shell(
                    "/bin/zsh",
                    ["-c", capturedCommand],
                    timeout: timeout,
                    includeStderrOnSuccess: true,
                    scrubSecretEnvironment: true
                )
            }.value
            return ToolResult(toolName: "shell", output: cap(output.isEmpty ? "(no output)" : output))
        } catch {
            return .failure("shell", cap(error.localizedDescription))
        }
        #else
        return .failure("shell", "The shell tool is only available on macOS.")
        #endif
    }

    // MARK: - read_file

    private func readFile(input: JSONValue) -> ToolResult {
        guard let path = input["path"]?.stringValue else {
            return .failure("read_file", "read_file: missing required field 'path'.")
        }
        let url: URL
        switch guardPath(path, roots: readRoots) {
        case .refused(let reason):
            return .failure("read_file", reason)
        case .allowed(let resolved):
            url = resolved
        }

        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return .failure("read_file", "Could not read \(displayPath(url)) as UTF-8 text (missing file or binary content).")
        }

        let offset = max(1, input["offset"]?.intValue ?? 1)
        let limit = min(max(1, input["limit"]?.intValue ?? 500), 2_000)
        let lines = text.components(separatedBy: "\n")
        guard offset <= lines.count else {
            return .failure("read_file", "offset \(offset) is past the end of the file (\(lines.count) lines).")
        }

        var rendered: [String] = []
        var charBudget = 100_000
        // Per-line cap: one pathologically long line (a minified bundle, a
        // base64 blob) must not blow the whole budget in a single entry or
        // stream megabytes back to the model.
        let maxLineLength = 4_000
        var nextOffset: Int?
        var lineNumber = offset
        for line in lines[(offset - 1)...] {
            if rendered.count >= limit || charBudget <= 0 {
                nextOffset = lineNumber
                break
            }
            let clipped = line.count > maxLineLength
                ? String(line.prefix(maxLineLength)) + "… [line truncated at \(maxLineLength) characters]"
                : line
            let entry = "\(lineNumber)|\(clipped)"
            rendered.append(entry)
            charBudget -= entry.count + 1
            lineNumber += 1
        }

        var output = rendered.joined(separator: "\n")
        if let nextOffset {
            output += "\n… truncated; continue with offset=\(nextOffset)."
        }
        return ToolResult(toolName: "read_file", output: output)
    }

    // MARK: - search_files

    private func searchFiles(input: JSONValue) -> ToolResult {
        guard let pattern = input["pattern"]?.stringValue, !pattern.isEmpty else {
            return .failure("search_files", "search_files: missing required field 'pattern'.")
        }
        guard let path = input["path"]?.stringValue else {
            return .failure("search_files", "search_files: missing required field 'path'.")
        }
        let root: URL
        switch guardPath(path, roots: readRoots) {
        case .refused(let reason):
            return .failure("search_files", reason)
        case .allowed(let resolved):
            root = resolved
        }

        let target = input["target"]?.stringValue ?? "content"
        let limit = min(max(1, input["limit"]?.intValue ?? 50), 500)

        switch target {
        case "files":
            let hits = fileNameSearch(glob: pattern, under: root, limit: limit)
            return ToolResult(
                toolName: "search_files",
                output: hits.isEmpty ? "No files matched '\(pattern)'." : hits.joined(separator: "\n")
            )
        case "content":
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                return .failure("search_files", "'\(pattern)' is not a valid regular expression.")
            }
            let glob = input["file_glob"]?.stringValue
            let hits = contentSearch(regex: regex, under: root, fileGlob: glob, limit: limit)
            return ToolResult(
                toolName: "search_files",
                output: hits.isEmpty ? "No matches for /\(pattern)/." : hits.joined(separator: "\n")
            )
        default:
            return .failure("search_files", "target must be 'content' or 'files'.")
        }
    }

    private func searchableFiles(under root: URL) -> [URL] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory) else { return [] }
        guard isDirectory.boolValue else { return [root] }

        let skippedDirectories: Set<String> = [".git", "node_modules", ".build", "DerivedData"]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsPackageDescendants]
        ) else { return [] }

        var files: [URL] = []
        for case let file as URL in enumerator {
            let name = file.lastPathComponent
            if skippedDirectories.contains(name),
               (try? file.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                enumerator.skipDescendants()
                continue
            }
            let lowered = name.lowercased()
            if lowered == ".env" || lowered.hasPrefix(".env.") || lowered == "auth.json" { continue }
            guard (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            files.append(file)
        }
        return files
    }

    private func fileNameSearch(glob: String, under root: URL, limit: Int) -> [String] {
        guard let regex = Self.regexFromGlob(glob) else { return [] }
        let matches = searchableFiles(under: root)
            .filter { file in
                let name = file.lastPathComponent
                let range = NSRange(name.startIndex..., in: name)
                return regex.firstMatch(in: name, options: [], range: range) != nil
            }
            .sorted { lhs, rhs in
                let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return lhsDate > rhsDate
            }
        return matches.prefix(limit).map { displayPath($0) }
    }

    private func contentSearch(regex: NSRegularExpression, under root: URL, fileGlob: String?, limit: Int) -> [String] {
        let globRegex = fileGlob.flatMap { Self.regexFromGlob($0) }
        var results: [String] = []
        for file in searchableFiles(under: root) {
            if results.count >= limit { break }
            if let globRegex {
                let name = file.lastPathComponent
                let range = NSRange(name.startIndex..., in: name)
                guard globRegex.firstMatch(in: name, options: [], range: range) != nil else { continue }
            }
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            guard size <= 2_000_000 else { continue }
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            var lineNumber = 0
            for line in text.components(separatedBy: "\n") {
                lineNumber += 1
                guard results.count < limit else { break }
                let range = NSRange(line.startIndex..., in: line)
                if regex.firstMatch(in: line, options: [], range: range) != nil {
                    results.append("\(displayPath(file)):\(lineNumber): \(line.prefix(400))")
                }
            }
        }
        return results
    }

    static func regexFromGlob(_ glob: String) -> NSRegularExpression? {
        var pattern = "^"
        for character in glob {
            switch character {
            case "*": pattern += "[^/]*"
            case "?": pattern += "."
            default: pattern += NSRegularExpression.escapedPattern(for: String(character))
            }
        }
        pattern += "$"
        return try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    // MARK: - write_file

    private func writeFile(input: JSONValue) async -> ToolResult {
        guard let path = input["path"]?.stringValue else {
            return .failure("write_file", "write_file: missing required field 'path'.")
        }
        guard let content = input["content"]?.stringValue else {
            return .failure("write_file", "write_file: missing required field 'content'.")
        }
        let url: URL
        switch guardPath(path, roots: writeRoots) {
        case .refused(let reason):
            return .failure("write_file", reason)
        case .allowed(let resolved):
            url = resolved
        }

        // ALL writes are proposals — no decision branch skips the card.
        guard case .requiresApproval(let reason, let patternIds) =
            approvals.decision(toolName: "write_file", payload: url.path) else {
            return .failure("write_file", "The bouncer refused to classify this write; nothing was written.")
        }
        let request = ToolApprovalRequest(
            toolName: "write_file",
            summary: displayPath(url),
            reason: reason,
            patternIds: patternIds,
            detail: String(content.prefix(2_000))
        )
        let resolution = await approvals.awaitDecision(request)
        guard resolution == .approved else {
            return .failure("write_file", "Adam denied this write to \(displayPath(url)). Nothing was written.")
        }

        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try content.write(to: url, atomically: true, encoding: .utf8)
            return ToolResult(
                toolName: "write_file",
                output: "Wrote \(content.utf8.count) bytes to \(displayPath(url)). This write is complete and the file now holds exactly that content — do not call write_file again for this path unless you are changing it."
            )
        } catch {
            return .failure("write_file", "Write failed: \(error.localizedDescription)")
        }
    }

    // MARK: - memory

    private func stageMemory(input: JSONValue) -> ToolResult {
        guard let content = input["content"]?.stringValue,
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure("memory", "memory: missing required field 'content'.")
        }
        let evidence = input["evidence"]?.stringValue ?? content
        let source = input["source"]?.stringValue ?? "harness-tool:memory"
        let candidate = MemoryCandidate(
            id: "cand-mem-\(UUID().uuidString.prefix(8).lowercased())",
            runId: "tool-memory",
            sourceRunIds: [],
            evidenceText: evidence,
            proposedClaim: content,
            proposedGraph: nil,
            status: .candidate,
            validationResult: nil,
            evidenceNote: evidence,
            sourceRef: source
        )
        do {
            try memoryStager.stageMemoryCandidate(candidate)
            return ToolResult(
                toolName: "memory",
                output: "Staged for Adam's review queue as \(candidate.id). Nothing enters memory until Adam approves it — do not treat this as saved."
            )
        } catch {
            return .failure("memory", "Could not stage the memory candidate: \(error.localizedDescription)")
        }
    }

    // MARK: - skills

    private func availableSkills() -> [HarnessCapability] {
        HarnessCapabilityRegistry.vaultPreferred(
            capabilitiesProvider().filter { $0.kind == .skill && $0.matchesCurrentPlatform }
        )
    }

    private func skillsList(input: JSONValue) -> ToolResult {
        var skills = availableSkills()
        if let category = input["category"]?.stringValue, !category.isEmpty {
            skills = skills.filter { $0.category.localizedCaseInsensitiveCompare(category) == .orderedSame }
        }
        guard !skills.isEmpty else {
            return ToolResult(toolName: "skills_list", output: "No skills found.")
        }
        let lines = skills
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .map { skill in
                skill.description.isEmpty
                    ? "- \(skill.name) [\(skill.category)]"
                    : "- \(skill.name) [\(skill.category)]: \(skill.description)"
            }
        return ToolResult(toolName: "skills_list", output: lines.joined(separator: "\n"))
    }

    private func skillView(input: JSONValue) -> ToolResult {
        guard let name = input["name"]?.stringValue, !name.isEmpty else {
            return .failure("skill_view", "skill_view: missing required field 'name'.")
        }
        guard let skill = availableSkills().first(where: {
            $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame
        }) else {
            return .failure("skill_view", "No skill named '\(name)'. Use skills_list to see available skills.")
        }
        // Adam's exact-words law: the skill file is returned WHOLE and
        // VERBATIM — no character cap, no trimming, no paraphrase.
        guard let content = try? String(contentsOf: skill.path, encoding: .utf8) else {
            return .failure("skill_view", "Could not read the skill file at \(displayPath(skill.path)).")
        }
        return ToolResult(toolName: "skill_view", output: content)
    }

    // MARK: - session_search

    private func sessionSearch(input: JSONValue) async -> ToolResult {
        guard let searcher = sessionSearcher else {
            return .failure("session_search", "Session search is not available in this run.")
        }
        guard let query = input["query"]?.stringValue, !query.isEmpty else {
            return .failure("session_search", "session_search: missing required field 'query'.")
        }
        let limit = min(max(1, input["limit"]?.intValue ?? 20), 100)
        do {
            let hits = try await searcher.searchSessions(query: query, limit: limit)
            guard !hits.isEmpty else {
                return ToolResult(toolName: "session_search", output: "No past-session matches for '\(query)'.")
            }
            let lines = hits.map { "- [\($0.sessionId)] \($0.title): \($0.snippet)" }
            return ToolResult(toolName: "session_search", output: lines.joined(separator: "\n"))
        } catch {
            return .failure("session_search", "Session search failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Helpers

    private func cap(_ text: String) -> String {
        guard text.count > configuration.outputCap else { return text }
        return String(text.prefix(configuration.outputCap))
            + "\n… [output truncated at \(configuration.outputCap) characters]"
    }
}
