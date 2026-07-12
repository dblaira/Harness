import Foundation

/// Splits assistant transcript text into visible body and trailing eval markers.
enum TranscriptAssistantTurn {
    struct Parsed: Equatable {
        let displayBody: String
        let isBackendFailure: Bool
        let rule: String?
        let patternStep: String?

        var showsMetadataFooter: Bool {
            !isBackendFailure && (rule != nil || patternStep != nil)
        }
    }

    static func parse(_ text: String) -> Parsed {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var rule: String?
        var patternStep: String?

        while true {
            while lines.last?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
                lines.removeLast()
            }
            guard let last = lines.last?.trimmingCharacters(in: .whitespacesAndNewlines), !last.isEmpty else {
                break
            }
            if let value = matchRule(last) {
                rule = value
                lines.removeLast()
                continue
            }
            if let value = matchPatternStep(last) {
                patternStep = value
                lines.removeLast()
                continue
            }
            break
        }

        let body = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return Parsed(
            displayBody: body,
            isBackendFailure: body.hasPrefix("Backend failed:")
                || body.contains("Harness status: backend failure"),
            rule: rule,
            patternStep: patternStep
        )
    }

    static func suggestsReauthorization(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("login")
            || lower.contains("expired")
            || lower.contains("authorization")
            || lower.contains("http 400")
            || lower.contains("http 401")
            || lower.contains("session")
    }

    private static func matchRule(_ line: String) -> String? {
        guard let range = line.range(of: #"^Rule:\s*(.+)$"#, options: .regularExpression) else {
            return nil
        }
        return String(line[range]).replacingOccurrences(of: "Rule:", with: "").trimmingCharacters(in: .whitespaces)
    }

    private static func matchPatternStep(_ line: String) -> String? {
        guard let range = line.range(of: #"^Adam Pattern Step:\s*(.+)$"#, options: [.regularExpression, .caseInsensitive]) else {
            return nil
        }
        return String(line[range])
            .replacingOccurrences(of: "Adam Pattern Step:", with: "", options: .caseInsensitive)
            .trimmingCharacters(in: .whitespaces)
    }
}
