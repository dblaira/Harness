import Foundation

/// BORROW layer (conn-019): commodity model call over URLSession.
/// The BUILD part is what we feed it — Adam's ontology as the system prompt.
public struct ClaudeClient {

    public enum ClaudeError: Error, LocalizedError {
        case noKey, badResponse(String)
        public var errorDescription: String? {
            switch self {
            case .noKey: return "No API key. Set ANTHROPIC_API_KEY in the scheme's environment, or paste a key in Settings."
            case .badResponse(let s): return s
            }
        }
    }

    public var apiKey: String
    public var model: String

    public init(apiKey: String? = nil, model: String = "claude-sonnet-4-20250514") {
        self.apiKey = apiKey ?? ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] ?? ""
        self.model = model
    }

    /// Build the system prompt that constrains the model with Adam's confirmed graph.
    /// This is the harness: the LLM must reason inside these rules and name the one it used.
    public static func systemPrompt(from onto: Ontology) -> String {
        var s = """
        You are Adam Blair's personal agent, constrained by his confirmed personal ontology.
        Reason INSIDE these rules. When a rule shapes your answer, NAME it (e.g. "Rule: conn-019").
        When no confirmed rule applies, say so plainly — never present unsupported personal inference as fact.
        Keep answers short; lead with the answer; cover his vocabulary gap for him (judgment-over-vocab).

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

    public func send(messages: [(role: String, text: String)], system: String) async throws -> String {
        guard !apiKey.isEmpty else { throw ClaudeError.noKey }
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "content-type")

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 1024,
            "system": system,
            "messages": messages.map { ["role": $0.role, "content": $0.text] }
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await URLSession.shared.data(for: req)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClaudeError.badResponse("Unparseable response")
        }
        if let content = json["content"] as? [[String: Any]],
           let text = content.first?["text"] as? String {
            return text
        }
        if let err = json["error"] as? [String: Any], let msg = err["message"] as? String {
            throw ClaudeError.badResponse(msg)
        }
        return String(data: data, encoding: .utf8) ?? "(empty)"
    }
}
