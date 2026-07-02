import Foundation

public protocol AnswerEvaluating: Sendable {
    func evaluate(answer: String, authorityHits: [GraphAuthorityHit], memoryHits: [MemoryHit], runId: String) -> [EvalResult]
}

public struct DeterministicAnswerEvaluator: AnswerEvaluating {
    public init() {}

    public func evaluate(answer: String, authorityHits: [GraphAuthorityHit], memoryHits: [MemoryHit], runId: String) -> [EvalResult] {
        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        let firstLine = trimmed.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? ""
        let namesRule = trimmed.range(of: #"Rule:\s*(conn-\d+|[A-Za-z0-9_\-]+|none)"#, options: .regularExpression) != nil
        let patternStep = Self.patternStep(in: trimmed)
        let candidateAsAuthority = trimmed.localizedCaseInsensitiveContains("candidate memory is accepted")
            || trimmed.localizedCaseInsensitiveContains("suggested memory is accepted")

        var results = [
            EvalResult(
                runId: runId,
                checkName: "plain-answer-first",
                passed: !firstLine.isEmpty && !firstLine.lowercased().hasPrefix("rule:"),
                detail: firstLine.isEmpty ? "Answer is empty." : "First line: \(firstLine)"
            ),
            EvalResult(
                runId: runId,
                checkName: "rule-named-or-none",
                passed: namesRule,
                detail: namesRule ? "Rule marker found." : "Answer must include Rule: <id> or Rule: none."
            ),
            EvalResult(
                runId: runId,
                checkName: "pattern-step-named",
                passed: patternStep != nil || trimmed.range(of: #"(?i)Adam Pattern Step:\s*none"#, options: .regularExpression) != nil,
                detail: patternStep.map { "Adam Pattern step \($0) named." } ?? "Answer must include Adam Pattern Step: 1-8 or Adam Pattern Step: none."
            ),
            EvalResult(
                runId: runId,
                checkName: "authority-memory-separated",
                passed: !candidateAsAuthority && memoryHits.allSatisfy { $0.authorityLevel == .supporting } && authorityHits.allSatisfy { $0.authorityLevel == .accepted },
                detail: "Accepted authority hits: \(authorityHits.count); supporting memory hits: \(memoryHits.count)."
            ),
            EvalResult(
                runId: runId,
                checkName: "secret-redaction-ready",
                passed: !SecretRedactor().redact(answer).contains("sk-ant-"),
                detail: "Answer can be persisted after redaction."
            )
        ]
        if let patternStep, patternStep >= 5 {
            let observationalEvidence = Self.hasObservationalEvidence(answer: trimmed, authorityHits: authorityHits, memoryHits: memoryHits)
            results.append(
                EvalResult(
                    runId: runId,
                    checkName: "observational-zone-before-execution",
                    passed: observationalEvidence,
                    detail: observationalEvidence
                        ? "Execution step has observational context."
                        : "Warning: observational zone incomplete before execution step \(patternStep)."
                )
            )
        }
        return results
    }

    private static func patternStep(in text: String) -> Int? {
        let patterns = [
            #"(?i)Adam Pattern Step:\s*([1-8])"#,
            #"(?i)Pattern Step:\s*([1-8])"#,
            #"(?i)Step\s*([1-8])"#
        ]
        for pattern in patterns {
            guard let re = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(text.startIndex..., in: text)
            guard let match = re.firstMatch(in: text, range: range),
                  match.numberOfRanges > 1,
                  let matchRange = Range(match.range(at: 1), in: text),
                  let step = Int(text[matchRange])
            else { continue }
            return step
        }
        return nil
    }

    private static func hasObservationalEvidence(answer: String, authorityHits: [GraphAuthorityHit], memoryHits: [MemoryHit]) -> Bool {
        let context = ([answer] + authorityHits.map { "\($0.subject) \($0.object)" } + memoryHits.map(\.excerpt))
            .joined(separator: "\n")
            .lowercased()
        let markers = [
            "step 1", "step 2", "step 3", "step 4",
            "context", "circle", "close the gap", "choose success",
            "accept reality", "watch before moving", "specific gap", "measurable target"
        ]
        return markers.contains { context.contains($0) }
    }
}

public struct TurtleCandidateValidator: Sendable {
    private let turtleParser: any TurtleParsing

    public init(turtleParser: any TurtleParsing = PythonSHACLConnectionValidator()) {
        self.turtleParser = turtleParser
    }

    public func validate(candidate: MemoryCandidate) -> ValidationResult {
        guard let graph = candidate.proposedGraph, !graph.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ValidationResult(
                runId: candidate.runId,
                candidateId: candidate.id,
                kind: "turtle",
                passed: false,
                detail: "No Turtle proposed yet."
            )
        }

        do {
            try turtleParser.parse(Self.prefixes + graph)
        } catch {
            let message: String
            if let localized = error as? LocalizedError, let description = localized.errorDescription {
                message = description
            } else {
                message = error.localizedDescription
            }
            return ValidationResult(
                runId: candidate.runId,
                candidateId: candidate.id,
                kind: "shacl",
                passed: false,
                detail: "Blocked: \(message)"
            )
        }

        return ValidationResult(
            runId: candidate.runId,
            candidateId: candidate.id,
            kind: "shacl",
            passed: true,
            detail: "SHACL validation passed."
        )
    }

    private static let prefixes = """
    @prefix understood: <https://understood.app/ontology#> .
    @prefix xsd: <http://www.w3.org/2001/XMLSchema#> .

    """
}

public struct CandidateGraphDraftBuilder: Sendable {
    public init() {}

    public func draft(for candidate: MemoryCandidate) -> String {
        let escapedClaim = Self.escapeLiteral(candidate.proposedClaim)
        let escapedEvidence = Self.escapeLiteral(candidate.evidenceText)
        return """
        <urn:harness:candidate:\(candidate.id)> <urn:harness:proposedClaim> "\(escapedClaim)" .
        <urn:harness:candidate:\(candidate.id)> <urn:harness:evidenceText> "\(escapedEvidence)" .
        <urn:harness:candidate:\(candidate.id)> <urn:harness:sourceRunId> "\(candidate.runId)" .
        """
    }

    private static func escapeLiteral(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
    }
}
