import Foundation
#if os(macOS)
import Darwin
#endif

public enum Backend: String, CaseIterable, Identifiable, Sendable, Codable {
    case codex   = "Codex"      // ChatGPT-authorized Codex CLI
    case grok    = "Grok"       // macOS CLI or xAI API
    case claude  = "Claude API" // direct API key (optional)
    case hermes  = "Hermes local" // local Ollama model, no subscription or key
    public var id: String { rawValue }

    /// Backend Harness selects on launch and for synthesis delegates.
    public static let harnessDefault: Backend = .grok
}

/// Backend readiness, shown with the SAVY content-status vocabulary:
/// "live", "pending", "failed (message)", "Checking gateway…".
/// See Docs/design-vocabulary.md — no other status words are used.
public enum BackendReadiness: Equatable, Sendable {
    case checking
    case live
    case pending(action: String)
    case failed(message: String)

    public static let codexAuthorizationAction = "install codex CLI and run codex login --device-auth"
    public static let grokAuthorizationAction = "run grok login"

    /// The status word, verbatim from SAVY's content status band.
    public var statusWord: String {
        switch self {
        case .checking: return "Checking gateway…"
        case .live: return "live"
        case .pending: return "pending"
        case .failed(let message): return "failed (\(message))"
        }
    }

    /// The one named action when something is waiting, else nil.
    public var actionNeeded: String? {
        if case .pending(let action) = self { return action }
        return nil
    }

    /// Pure state mapping so readiness is unit-testable without probing.
    /// `keyPresent` — an API key is available for this backend.
    /// `cliFound` — the backend's CLI binary exists on disk (macOS only).
    /// `cliProbe` — result of a fast version probe, nil if not attempted.
    /// `localServerReachable` — Ollama answered (Hermes only).
    public static func evaluate(
        backend: Backend,
        keyPresent: Bool,
        cliFound: Bool,
        cliProbe: Result<Void, Error>?,
        localServerReachable: Bool
    ) -> BackendReadiness {
        switch backend {
        case .claude:
            return keyPresent ? .live : .pending(action: "paste Claude API key")
        case .hermes:
            return localServerReachable ? .live : .pending(action: "run ollama serve")
        case .codex:
            guard cliFound else {
                return .pending(action: Self.codexAuthorizationAction)
            }
            switch cliProbe {
            case .success, nil:
                return .live
            case .failure(let error):
                return .failed(message: error.localizedDescription)
            }
        case .grok:
            if keyPresent { return .live }
            guard cliFound else {
                return .pending(action: "install grok CLI or paste xAI API key")
            }
            switch cliProbe {
            case .success, nil:
                return .live
            case .failure(let error):
                return .failed(message: error.localizedDescription)
            }
        }
    }
}

public struct AgentRunner: Sendable {
    public init() {}

    /// Resolve a CLI on disk (apps don't inherit the shell PATH).
    private func resolve(_ candidates: [String]) -> String? {
        for p in candidates where FileManager.default.isExecutableFile(atPath: p) { return p }
        return nil
    }

    private var codexPath: String? {
        resolve(["/Applications/Codex.app/Contents/Resources/codex",
                 "\(NSHomeDirectory())/.local/bin/codex", "/opt/homebrew/bin/codex", "/usr/local/bin/codex"])
    }
    private var grokPath: String? {
        resolve(["\(NSHomeDirectory())/.grok/bin/grok",
                 "\(NSHomeDirectory())/.local/bin/grok", "/opt/homebrew/bin/grok", "/usr/local/bin/grok"])
    }

    /// Probe whether a backend can answer right now, without sending a real
    /// prompt. Fast: CLI backends get a 5-second version probe; Hermes gets
    /// a local HTTP check; API backends only need a key.
    public func preflight(backend: Backend, apiKey: String? = nil) async -> BackendReadiness {
        let keyPresent = !(apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty

        switch backend {
        case .claude:
            let envKey = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] ?? ""
            return BackendReadiness.evaluate(
                backend: backend,
                keyPresent: keyPresent || !envKey.isEmpty,
                cliFound: false,
                cliProbe: nil,
                localServerReachable: false
            )
        case .hermes:
            return BackendReadiness.evaluate(
                backend: backend,
                keyPresent: false,
                cliFound: false,
                cliProbe: nil,
                localServerReachable: await hermesReachable()
            )
        case .codex:
            let openAIEnvKey = ProcessInfo.processInfo.environment["OPENAI_API_KEY"] ?? ""
            if keyPresent || !openAIEnvKey.isEmpty {
                return .live
            }
            #if os(macOS)
            guard let binary = codexPath else {
                return BackendReadiness.evaluate(
                    backend: backend,
                    keyPresent: false,
                    cliFound: false,
                    cliProbe: nil,
                    localServerReachable: false
                )
            }
            let runner = self
            return await Task.detached(priority: .userInitiated) {
                runner.codexAccountReadiness(binary: binary)
            }.value
            #else
            return BackendReadiness.evaluate(
                backend: backend,
                keyPresent: false,
                cliFound: false,
                cliProbe: nil,
                localServerReachable: false
            )
            #endif
        case .grok:
            #if os(macOS)
            if keyPresent {
                return BackendReadiness.evaluate(
                    backend: backend,
                    keyPresent: true,
                    cliFound: grokPath != nil,
                    cliProbe: nil,
                    localServerReachable: false
                )
            }
            return grokAccountReadiness(binary: grokPath)
            #else
            return BackendReadiness.evaluate(
                backend: backend,
                keyPresent: keyPresent,
                cliFound: false,
                cliProbe: nil,
                localServerReachable: false
            )
            #endif
        }
    }

    #if os(macOS)
    private func codexAccountReadiness(binary: String) -> BackendReadiness {
        do {
            let output = try shell(binary, ["login", "status"], timeout: 5, includeStderrOnSuccess: true)
            if output.localizedCaseInsensitiveContains("chatgpt") {
                return .live
            }
            return .pending(action: "run codex login --device-auth")
        } catch {
            let message = error.localizedDescription
            if message.localizedCaseInsensitiveContains("not logged")
                || message.localizedCaseInsensitiveContains("login") {
                return .pending(action: "run codex login --device-auth")
            }
            return .failed(message: message)
        }
    }

    private func grokAccountReadiness(binary: String?) -> BackendReadiness {
        switch GrokSessionClient.sessionStatus() {
        case .valid:
            return .live
        case .expired:
            return .pending(action: BackendReadiness.grokAuthorizationAction)
        case .missing:
            guard binary != nil else {
                return .pending(action: "install grok CLI or paste xAI API key")
            }
            return .pending(action: BackendReadiness.grokAuthorizationAction)
        }
    }
    #endif

    private func hermesReachable() async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:11434/api/tags") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    /// Send a prompt (ontology + SOUL already in `system`) to the chosen backend.
    public func run(
        backend: Backend,
        system: String,
        user: String,
        conversationHistory: [ConversationTurn] = [],
        images: [ModelImageAttachment] = [],
        apiKey: String? = nil
    ) async throws -> String {
        let history = ConversationTurn.cappedHistory(conversationHistory)
        let transcriptPrompt = Self.transcriptPrompt(system: system, history: history, user: user)
        switch backend {
        case .codex:
            // ChatGPT via the OpenAI API when a key is present; else the
            // existing ChatGPT session / CLI path. Options stay open.
            let codexKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let hasOpenAIKey = !codexKey.isEmpty
                || !(ProcessInfo.processInfo.environment["OPENAI_API_KEY"] ?? "").isEmpty
            if hasOpenAIKey {
                return try await OpenAIClient(apiKey: codexKey.isEmpty ? nil : codexKey).send(
                    messages: Self.openAIMessages(history: history, user: user, images: images),
                    system: system
                )
            }
            if CodexSessionClient.loadSessionToken() != nil {
                return try await CodexSessionClient().send(
                    messages: Self.codexMessages(history: history, user: user, images: images),
                    system: system
                )
            }
            #if os(macOS)
            guard let bin = codexPath else { throw RunError.notFound("codex CLI") }
            return try shell(
                bin,
                ["exec", "--skip-git-repo-check", "--ignore-user-config", "--ephemeral", transcriptPrompt],
                timeout: 300
            )
            #else
            throw RunError.notFound("codex CLI")
            #endif
        case .grok:
            let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !key.isEmpty {
                return try await XAIClient(apiKey: key).send(
                    messages: Self.xaiMessages(history: history, user: user, images: images),
                    system: system
                )
            }
            if GrokSessionClient.loadSessionToken() != nil {
                return try await GrokSessionClient().send(
                    messages: Self.grokMessages(history: history, user: user, images: images),
                    system: system
                )
            }
            #if os(macOS)
            guard let bin = grokPath else { throw RunError.notFound("grok CLI") }
            return try shell(
                bin,
                [
                    "-p", transcriptPrompt,
                    "--output-format", "json",
                    "--max-turns", "1",
                    "--disable-web-search",
                    "--no-subagents",
                    "--disallowed-tools", "run_terminal_cmd,grep,web_search,web_fetch,Agent,list_dir,read_file,search_replace,write",
                ],
                timeout: 300
            )
            #else
            throw RunError.notFound("xAI API key")
            #endif
        case .claude:
            let c = ClaudeClient(apiKey: apiKey)
            return try await c.send(
                messages: Self.claudeMessages(history: history, user: user),
                system: system
            )
        case .hermes:
            return try await runHermesLocal(system: system, history: history, user: user)
        }
    }

    /// Whether the backend can run the native tool loop right now.
    /// Claude and Grok via their HTTPS APIs (Anthropic tool_use / OpenAI-
    /// compatible tool_calls). The Grok session proxy uses the same tool-call
    /// shape with `grok login` auth. The grok CLI and Codex CLI stay
    /// single-shot — their tool-disabling safety flags are deliberately
    /// untouched.
    public func supportsToolLoop(backend: Backend, apiKey: String? = nil) -> Bool {
        let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch backend {
        case .claude:
            let envKey = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] ?? ""
            return !key.isEmpty || !envKey.isEmpty
        case .grok:
            let envKey = ProcessInfo.processInfo.environment["XAI_API_KEY"] ?? ""
            return !key.isEmpty || !envKey.isEmpty || GrokSessionClient.sessionStatus() == .valid
        case .codex:
            // ChatGPT is tool-capable through the OpenAI API when a key exists.
            let envKey = ProcessInfo.processInfo.environment["OPENAI_API_KEY"] ?? ""
            return !key.isEmpty || !envKey.isEmpty
        case .hermes:
            return false
        }
    }

    /// One tool-loop step: send prompt + prior loop turns + the tool catalog
    /// to a tool-capable API backend. Throws for backends without native
    /// tool support — callers should check `supportsToolLoop` and degrade to
    /// `run(backend:...)` single-shot instead.
    public func runWithTools(
        backend: Backend,
        system: String,
        user: String,
        conversationHistory: [ConversationTurn] = [],
        images: [ModelImageAttachment] = [],
        apiKey: String? = nil,
        tools: [ToolSpec],
        toolTranscript: [ToolLoopTurn]
    ) async throws -> BackendResponse {
        let history = ConversationTurn.cappedHistory(conversationHistory)
        // Empty strings fall back to the environment key, matching how the
        // clients' initializers treat nil.
        let trimmedKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveKey = (trimmedKey?.isEmpty == false) ? trimmedKey : nil
        switch backend {
        case .claude:
            return try await ClaudeClient(apiKey: effectiveKey).send(
                messages: Self.claudeMessages(history: history, user: user),
                system: system,
                tools: tools,
                toolTranscript: toolTranscript
            )
        case .grok:
            if let effectiveKey {
                return try await XAIClient(apiKey: effectiveKey).send(
                    messages: Self.xaiMessages(history: history, user: user, images: images),
                    system: system,
                    tools: tools,
                    toolTranscript: toolTranscript
                )
            }
            return try await GrokSessionClient().send(
                messages: Self.grokMessages(history: history, user: user, images: images),
                system: system,
                tools: tools,
                toolTranscript: toolTranscript
            )
        case .codex:
            throw RunError.failed("\(backend.rawValue) has no native tool support; run it single-shot instead.")
        case .hermes:
            throw RunError.failed("\(backend.rawValue) has no native tool support; run it single-shot instead.")
        }
    }

    private static func transcriptPrompt(system: String, history: [ConversationTurn], user: String) -> String {
        var transcript = system + "\n\n---\n"
        for turn in history {
            let speaker = turn.role == .user ? "User" : "Assistant"
            transcript += "\(speaker): \(turn.text)\n\n"
        }
        transcript += "User: \(user)"
        return transcript
    }

    private static func codexMessages(
        history: [ConversationTurn],
        user: String,
        images: [ModelImageAttachment]
    ) -> [CodexSessionClient.Message] {
        var messages = history.map {
            CodexSessionClient.Message(role: $0.role.rawValue, text: $0.text)
        }
        messages.append(CodexSessionClient.Message(role: "user", text: user, images: images))
        return messages
    }

    private static func openAIMessages(
        history: [ConversationTurn],
        user: String,
        images: [ModelImageAttachment]
    ) -> [OpenAIClient.Message] {
        var messages = history.map {
            OpenAIClient.Message(role: $0.role.rawValue, text: $0.text)
        }
        messages.append(OpenAIClient.Message(role: "user", text: user, images: images))
        return messages
    }

    private static func grokMessages(
        history: [ConversationTurn],
        user: String,
        images: [ModelImageAttachment]
    ) -> [GrokSessionClient.Message] {
        var messages = history.map {
            GrokSessionClient.Message(role: $0.role.rawValue, text: $0.text)
        }
        messages.append(GrokSessionClient.Message(role: "user", text: user, images: images))
        return messages
    }

    private static func xaiMessages(
        history: [ConversationTurn],
        user: String,
        images: [ModelImageAttachment]
    ) -> [XAIClient.Message] {
        var messages = history.map {
            XAIClient.Message(role: $0.role.rawValue, text: $0.text)
        }
        messages.append(XAIClient.Message(role: "user", text: user, images: images))
        return messages
    }

    private static func claudeMessages(history: [ConversationTurn], user: String) -> [(role: String, text: String)] {
        var messages = history.map { (role: $0.role.rawValue, text: $0.text) }
        messages.append((role: "user", text: user))
        return messages
    }

    /// Local Ollama server, no network egress, no subscription or key.
    private func runHermesLocal(system: String, history: [ConversationTurn], user: String) async throws -> String {
        guard let url = URL(string: "http://127.0.0.1:11434/api/generate") else {
            throw RunError.notFound("Ollama endpoint")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": "hermes3:8b",
            "prompt": Self.transcriptPrompt(system: system, history: history, user: user),
            "stream": false,
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw RunError.failed("Ollama not reachable on 127.0.0.1:11434. Is `ollama serve` running?")
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = obj["response"] as? String else {
            throw RunError.failed("Unexpected Ollama response shape.")
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public enum RunError: Error, LocalizedError {
        case notFound(String), failed(String)
        public var errorDescription: String? {
            switch self {
            case .notFound(let s): return "\(s) not found on disk."
            case .failed(let s):   return s
            }
        }
    }

    #if os(macOS)
    /// Live registry of child processes so a user Cancel can kill them.
    private static let runningProcesses = RunningProcessRegistry()

    /// Cancel: terminate every CLI child currently running. The in-flight
    /// `shell` call then throws and the caller's error path restores the UI.
    public static func terminateRunningProcesses() {
        runningProcesses.terminateAll()
    }

    private final class RunningProcessRegistry: @unchecked Sendable {
        private let lock = NSLock()
        private var processes: [ObjectIdentifier: Process] = [:]

        func register(_ process: Process) {
            lock.lock(); defer { lock.unlock() }
            processes[ObjectIdentifier(process)] = process
        }

        func unregister(_ process: Process) {
            lock.lock(); defer { lock.unlock() }
            processes.removeValue(forKey: ObjectIdentifier(process))
        }

        func terminateAll() {
            lock.lock()
            let current = Array(processes.values)
            lock.unlock()
            for process in current where process.isRunning {
                process.terminate()
            }
        }
    }
    #endif

    /// Remove credential-shaped variables from an environment dictionary.
    /// Broad on purpose: over-removing a variable only affects one shell call,
    /// while under-removing leaks a secret. Explicitly covers the app's own
    /// keys (ANTHROPIC_API_KEY, XAI_API_KEY) plus anything named like a token,
    /// secret, password, or key.
    static func scrubbingSecretEnvironment(_ env: [String: String]) -> [String: String] {
        env.filter { name, _ in !isSecretEnvironmentName(name) }
    }

    static func isSecretEnvironmentName(_ name: String) -> Bool {
        let upper = name.uppercased()
        let needles = [
            "API_KEY", "APIKEY", "SECRET", "TOKEN", "PASSWORD", "PASSWD",
            "CREDENTIAL", "ACCESS_KEY", "PRIVATE_KEY", "SIGNING_KEY",
            "_KEY", "KEY_", "AUTH_TOKEN", "BEARER", "SESSION_KEY",
        ]
        if needles.contains(where: { upper.contains($0) }) { return true }
        let exact: Set<String> = [
            "ANTHROPIC_API_KEY", "XAI_API_KEY", "OPENAI_API_KEY",
            "GITHUB_TOKEN", "GH_TOKEN", "AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY",
        ]
        return exact.contains(upper)
    }

    /// Run a CLI to completion, capturing stdout. Uses a PTY-free pipe.
    ///
    /// Output is drained WHILE the process runs. A macOS pipe buffer holds
    /// 64 KB; waiting for exit before reading deadlocks any child that
    /// writes more than that — the child blocks on write, we block on wait,
    /// and the timeout fires every time.
    #if os(macOS)
    func shell(
        _ launchPath: String,
        _ args: [String],
        timeout: TimeInterval = 90,
        includeStderrOnSuccess: Bool = false,
        scrubSecretEnvironment: Bool = false
    ) throws -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: launchPath)
        proc.arguments = args
        // Give the child the user's real PATH so nested tools resolve.
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "\(NSHomeDirectory())/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        // Agent-invoked shell: strip the app's own API keys (and any other
        // credential-shaped var) so `echo $XAI_API_KEY` / `env` can't
        // exfiltrate them. No pattern matcher can catch every way to read an
        // env var, so the only robust defence is to remove the value.
        if scrubSecretEnvironment {
            env = Self.scrubbingSecretEnvironment(env)
        }
        proc.environment = env
        let out = Pipe(); let err = Pipe()
        proc.standardOutput = out
        proc.standardError = err
        // Close our copy of the child's stdin so CLIs that wait for input exit instead of hanging.
        proc.standardInput = FileHandle.nullDevice

        // Incremental blocking reads on background threads keep the pipes
        // empty while the child runs AND preserve whatever already arrived
        // if we have to kill it — a single read-to-EOF would surrender the
        // partial output whenever a grandchild keeps the pipe open.
        let collector = PipeCollector()
        try proc.run()
        Self.runningProcesses.register(proc)
        defer { Self.runningProcesses.unregister(proc) }

        let drained = DispatchGroup()
        drained.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            let handle = out.fileHandleForReading
            while let chunk = try? handle.read(upToCount: 65_536), !chunk.isEmpty {
                collector.appendOut(chunk)
            }
            drained.leave()
        }
        drained.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            let handle = err.fileHandleForReading
            while let chunk = try? handle.read(upToCount: 65_536), !chunk.isEmpty {
                collector.appendErr(chunk)
            }
            drained.leave()
        }

        let completion = DispatchSemaphore(value: 0)
        proc.terminationHandler = { _ in completion.signal() }
        if completion.wait(timeout: .now() + timeout) == .timedOut {
            proc.terminate()
            if completion.wait(timeout: .now() + 3) == .timedOut {
                kill(proc.processIdentifier, SIGKILL)
            }
            _ = drained.wait(timeout: .now() + 2)
            let partial = collector.snapshot()
            var message = "\(URL(fileURLWithPath: launchPath).lastPathComponent) timed out after \(Int(timeout)) seconds."
            if !partial.combinedTail.isEmpty {
                message += " Partial output: \(partial.combinedTail)"
            }
            throw RunError.failed(message)
        }
        // Process exited; wait for the readers to hit EOF.
        _ = drained.wait(timeout: .now() + 5)

        let output = collector.snapshot()
        let text = output.stdoutText
        if proc.terminationStatus != 0 && text.isEmpty {
            let e = output.stderrText.isEmpty ? "exit \(proc.terminationStatus)" : output.stderrText
            throw RunError.failed(e)
        }
        if includeStderrOnSuccess && text.isEmpty {
            return cleanup(output.stderrText)
        }
        return cleanup(text)
    }
    #endif

    /// Thread-safe accumulator for concurrent pipe drains.
    #if os(macOS)
    private final class PipeCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var stdoutData = Data()
        private var stderrData = Data()

        func appendOut(_ data: Data) {
            guard !data.isEmpty else { return }
            lock.lock(); defer { lock.unlock() }
            stdoutData.append(data)
        }

        func appendErr(_ data: Data) {
            guard !data.isEmpty else { return }
            lock.lock(); defer { lock.unlock() }
            stderrData.append(data)
        }

        struct Snapshot {
            let stdoutText: String
            let stderrText: String

            /// Last ~500 characters of whatever the child said, for timeout errors.
            var combinedTail: String {
                let combined = [stdoutText, stderrText]
                    .filter { !$0.isEmpty }
                    .joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard combined.count > 500 else { return combined }
                return "..." + String(combined.suffix(500))
            }
        }

        func snapshot() -> Snapshot {
            lock.lock(); defer { lock.unlock() }
            return Snapshot(
                stdoutText: String(data: stdoutData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                stderrText: String(data: stderrData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            )
        }
    }
    #endif

    /// Strip CLI chrome / JSON wrapping to the model's actual text.
    private func cleanup(_ raw: String) -> String {
        // Grok JSON: {"type":"result","result":"..."} style — try to extract.
        if let data = raw.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for key in ["result", "text", "response", "content"] {
                if let s = obj[key] as? String { return s.trimmingCharacters(in: .whitespacesAndNewlines) }
            }
        }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
