import Foundation

public struct XAIClient: Sendable {
    public enum XAIError: Error, LocalizedError {
        case noKey, badResponse(String)

        public var errorDescription: String? {
            switch self {
            case .noKey:
                return "xAI API key required."
            case .badResponse(let message):
                return message
            }
        }
    }

    public var apiKey: String
    public var model: String

    public init(apiKey: String? = nil, model: String = "grok-4.3") {
        self.apiKey = apiKey ?? ProcessInfo.processInfo.environment["XAI_API_KEY"] ?? ""
        self.model = model
    }

    public struct Message: Sendable {
        public let role: String
        public let text: String
        public let images: [ModelImageAttachment]

        public init(role: String, text: String, images: [ModelImageAttachment] = []) {
            self.role = role
            self.text = text
            self.images = images
        }
    }

    public func send(messages: [Message], system: String) async throws -> String {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw XAIError.noKey
        }

        var request = URLRequest(url: URL(string: "https://api.x.ai/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "max_tokens": 1024,
            "messages": [["role": "system", "content": system]] + messages.map(Self.payloadMessage)
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw XAIError.badResponse("Unparseable xAI response")
        }

        if let choices = json["choices"] as? [[String: Any]],
           let message = choices.first?["message"] as? [String: Any],
           let content = message["content"] as? String {
            return content
        }
        if let error = json["error"] as? [String: Any] {
            let message = error["message"] as? String ?? "Unknown xAI API error"
            if let statusCode {
                throw XAIError.badResponse("xAI API \(statusCode): \(message)")
            }
            throw XAIError.badResponse(message)
        }
        return String(data: data, encoding: .utf8) ?? "(empty)"
    }

    private static func payloadMessage(for message: Message) -> [String: Any] {
        guard !message.images.isEmpty else {
            return ["role": message.role, "content": message.text]
        }
        var content: [[String: Any]] = [["type": "text", "text": message.text]]
        for image in message.images {
            content.append([
                "type": "image_url",
                "image_url": ["url": image.dataURI, "detail": "high"],
            ])
        }
        return ["role": message.role, "content": content]
    }
}
