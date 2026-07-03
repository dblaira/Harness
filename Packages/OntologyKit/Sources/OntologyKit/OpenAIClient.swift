import Foundation

public struct OpenAIClient: Sendable {
    public enum OpenAIError: Error, LocalizedError {
        case noKey, badResponse(String)

        public var errorDescription: String? {
            switch self {
            case .noKey:
                return "OpenAI API key required."
            case .badResponse(let message):
                return message
            }
        }
    }

    public var apiKey: String
    public var model: String

    public init(apiKey: String? = nil, model: String = "gpt-4.1") {
        self.apiKey = apiKey ?? ProcessInfo.processInfo.environment["OPENAI_API_KEY"] ?? ""
        self.model = model
    }

    public func send(messages: [(role: String, text: String)], system: String) async throws -> String {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OpenAIError.noKey
        }

        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "max_output_tokens": 1024,
            "input": [["role": "system", "content": system]] + messages.map {
                ["role": $0.role, "content": $0.text]
            }
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OpenAIError.badResponse("Unparseable OpenAI response")
        }

        if let text = json["output_text"] as? String, !text.isEmpty {
            return text
        }
        if let text = Self.extractOutputText(from: json), !text.isEmpty {
            return text
        }
        if let error = json["error"] as? [String: Any] {
            let message = error["message"] as? String ?? "Unknown OpenAI API error"
            if let statusCode {
                throw OpenAIError.badResponse("OpenAI API \(statusCode): \(message)")
            }
            throw OpenAIError.badResponse(message)
        }
        return String(data: data, encoding: .utf8) ?? "(empty)"
    }

    private static func extractOutputText(from json: [String: Any]) -> String? {
        guard let output = json["output"] as? [[String: Any]] else { return nil }
        let fragments = output.flatMap { item -> [String] in
            guard let content = item["content"] as? [[String: Any]] else { return [] }
            return content.compactMap { contentItem in
                contentItem["text"] as? String
            }
        }
        return fragments.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
