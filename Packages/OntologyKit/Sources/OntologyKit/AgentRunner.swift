import Foundation
#if os(macOS)
import Darwin
#endif

public enum Backend: String, CaseIterable, Identifiable, Sendable, Codable {
    case codex   = "Codex"      // macOS CLI or OpenAI API
    case grok    = "Grok"       // macOS CLI or xAI API
    case claude  = "Claude API" // direct API key (optional)
    case hermes  = "Hermes local" // local Ollama model, no subscription or key
    public var id: String { rawValue }
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
        resolve(["\(NSHomeDirectory())/.local/bin/grok", "/opt/homebrew/bin/grok", "/usr/local/bin/grok"])
    }

    /// Send a single-turn prompt (already prefixed with the ontology system prompt)
    /// to the chosen backend and return its text reply.
    public func run(backend: Backend, system: String, user: String, apiKey: String? = nil) async throws -> String {
        let fullPrompt = system + "\n\n---\nUser: " + user
        switch backend {
        case .codex:
            let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !key.isEmpty {
                return try await OpenAIClient(apiKey: key).send(messages: [(role: "user", text: user)], system: system)
            }
            #if os(macOS)
            guard let bin = codexPath else { throw RunError.notFound("codex CLI") }
            return try shell(bin, ["exec", "--skip-git-repo-check", fullPrompt])
            #else
            throw RunError.notFound("OpenAI API key")
            #endif
        case .grok:
            let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !key.isEmpty {
                return try await XAIClient(apiKey: key).send(messages: [(role: "user", text: user)], system: system)
            }
            #if os(macOS)
            guard let bin = grokPath else { throw RunError.notFound("grok CLI") }
            // -p/--prompt forces single-shot, non-interactive mode; a bare
            // positional argument can open an interactive session that never
            // exits and always hits the timeout.
            return try shell(bin, ["-p", fullPrompt, "--output-format", "json"])
            #else
            throw RunError.notFound("xAI API key")
            #endif
        case .claude:
            let c = ClaudeClient(apiKey: apiKey)
            return try await c.send(messages: [(role: "user", text: user)], system: system)
        case .hermes:
            return try await runHermesLocal(system: system, user: user)
        }
    }

    /// Local Ollama server, no network egress, no subscription or key.
    private func runHermesLocal(system: String, user: String) async throws -> String {
        guard let url = URL(string: "http://127.0.0.1:11434/api/generate") else {
            throw RunError.notFound("Ollama endpoint")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": "hermes3:8b",
            "prompt": system + "\n\n---\nUser: " + user,
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

    /// Run a CLI to completion, capturing stdout. Uses a PTY-free pipe.
    ///
    /// Output is drained WHILE the process runs. A macOS pipe buffer holds
    /// 64 KB; waiting for exit before reading deadlocks any child that
    /// writes more than that — the child blocks on write, we block on wait,
    /// and the timeout fires every time.
    #if os(macOS)
    func shell(_ launchPath: String, _ args: [String], timeout: TimeInterval = 90) throws -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: launchPath)
        proc.arguments = args
        // Give the child the user's real PATH so nested tools resolve.
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "\(NSHomeDirectory())/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
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
