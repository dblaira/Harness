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
        let candidateAsAuthority = trimmed.localizedCaseInsensitiveContains("candidate memory is accepted")
            || trimmed.localizedCaseInsensitiveContains("suggested memory is accepted")

        return [
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
    }
}

public struct TurtleCandidateValidator: Sendable {
    public init() {}

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

        let hasTerminator = graph.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix(".")
        let hasPredicateShape = graph.contains(" ")
        return ValidationResult(
            runId: candidate.runId,
            candidateId: candidate.id,
            kind: "turtle",
            passed: hasTerminator && hasPredicateShape,
            detail: hasTerminator && hasPredicateShape ? "Lightweight Turtle shape passed." : "Turtle must include a statement ending in a period."
        )
    }
}
