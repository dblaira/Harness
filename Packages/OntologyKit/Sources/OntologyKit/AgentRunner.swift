import Foundation

/// BORROW layer (conn-006: compute over cleverness).
/// Instead of copying expiring OAuth tokens, shell out to the CLIs Adam already
/// pays for (Codex = ChatGPT sub, Grok = xAI sub). They manage their own auth +
/// refresh, so the app never has to re-authenticate or store a secret.
public enum Backend: String, CaseIterable, Identifiable, Sendable {
    case codex   = "Codex"      // ChatGPT subscription
    case grok    = "Grok"       // xAI subscription
    case claude  = "Claude API" // direct API key (optional)
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
            #if os(macOS)
            guard let bin = codexPath else { throw RunError.notFound("codex CLI") }
            return try shell(bin, ["exec", "--skip-git-repo-check", fullPrompt])
            #else
            throw RunError.notFound("codex CLI (desktop only)")
            #endif
        case .grok:
            #if os(macOS)
            guard let bin = grokPath else { throw RunError.notFound("grok CLI") }
            return try shell(bin, [fullPrompt, "--output-format", "json"])
            #else
            throw RunError.notFound("grok CLI (desktop only)")
            #endif
        case .claude:
            let c = ClaudeClient(apiKey: apiKey)
            return try await c.send(messages: [(role: "user", text: user)], system: system)
        }
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
    #if os(macOS)
    private func shell(_ launchPath: String, _ args: [String]) throws -> String {
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
        try proc.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        let text = String(data: data, encoding: .utf8) ?? ""
        if proc.terminationStatus != 0 && text.isEmpty {
            let e = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "exit \(proc.terminationStatus)"
            throw RunError.failed(e)
        }
        return cleanup(text)
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
