import CryptoKit
import Foundation

public enum SuiteCaptureAnalysisError: Error, LocalizedError, Sendable, Equatable {
    case backendFailed(String)
    case invalidDecision(String)
    case unsafeCandidate(String)

    public var errorDescription: String? {
        switch self {
        case .backendFailed(let detail):
            return "Harness capture analysis failed: \(detail)"
        case .invalidDecision(let detail):
            return "Harness capture analysis returned an invalid decision: \(detail)"
        case .unsafeCandidate(let detail):
            return "Harness refused an unsafe capture candidate: \(detail)"
        }
    }
}

public enum SuiteCaptureAnalysisOutcome: Sendable, Equatable {
    case notCandidate(runID: String, reason: String)
    case candidateQueued(runID: String, candidate: MemoryCandidate)

    public var runID: String {
        switch self {
        case .notCandidate(let runID, _), .candidateQueued(let runID, _):
            return runID
        }
    }
}

/// Harness's consolidation gate for neutral suite captures. Producers provide
/// facts; this analyzer asks Harness's configured model whether the retained
/// fact warrants a review proposal, then Harness itself constructs and stages
/// that proposal. A model response never enters accepted truth directly.
public struct SuiteCaptureAnalyzer: Sendable {
    public static let analyzerVersion = "suite-capture-consolidation-v2"
    public static let decisionTool = ToolSpec(
        name: "submit_capture_decision",
        description: "Required final response for Harness capture consolidation. Call exactly once. This records only Harness's candidate-or-not analysis; it never accepts memory or changes the graph.",
        inputSchema: [
            "type": "object",
            "properties": [
                "decision": [
                    "type": "string",
                    "enum": ["candidate", "not_candidate"],
                ],
                "reason": ["type": "string"],
                "claim": ["type": "string"],
                "evidence": ["type": "string"],
                "domain_a": ["type": "string"],
                "domain_b": ["type": "string"],
                "strength": ["type": "number"],
                "connection_type": ["type": "string"],
            ],
            "required": ["decision"],
        ]
    )

    private let runPrompt: @Sendable (String) async throws -> HarnessRunDetail
    private let candidateStager: any MemoryCandidateStaging

    public init(
        runPrompt: @escaping @Sendable (String) async throws -> HarnessRunDetail,
        candidateStager: any MemoryCandidateStaging = CoordinatedReviewQueueMemoryStager()
    ) {
        self.runPrompt = runPrompt
        self.candidateStager = candidateStager
    }

    public func analyze(
        _ receipt: SuiteCaptureReceipt,
        relatedReceipts: [SuiteCaptureReceipt] = []
    ) async throws -> SuiteCaptureAnalysisOutcome {
        let receipts = Self.uniqueReceipts([receipt] + relatedReceipts)
        let producerIDs = Set(receipts.map {
            SuiteCaptureProvenance.canonicalProducerID(for: $0.trustedSourceID)
        })
        guard producerIDs.count == 1 else {
            throw SuiteCaptureAnalysisError.invalidDecision(
                "related captures must belong to the same trusted producer"
            )
        }
        if receipts.count > 1 {
            guard Self.areDuplicateLegacyDeliveries(receipts) else {
                throw SuiteCaptureAnalysisError.invalidDecision(
                    "related captures must be duplicate deliveries of one legacy producer record"
                )
            }
        }
        for item in receipts where item.state != .analysisPending && item.state != .analysisFailed {
            throw SuiteCaptureAnalysisError.invalidDecision(
                "receipt state \(item.state.rawValue) is not eligible for analysis"
            )
        }

        let representative = receipts.max { lhs, rhs in
            let lhsSize = lhs.capture.payload.jsonString.utf8.count
            let rhsSize = rhs.capture.payload.jsonString.utf8.count
            if lhsSize == rhsSize { return lhs.receivedAt < rhs.receivedAt }
            return lhsSize < rhsSize
        } ?? receipt
        let duplicateReceipts = receipts.filter { $0.id != representative.id }
        let detail = try await runPrompt(Self.prompt(
            for: representative,
            relatedReceipts: duplicateReceipts
        ))
        guard detail.run.success else {
            throw SuiteCaptureAnalysisError.backendFailed(detail.run.finalAnswer)
        }
        let decision = try Self.parseDecision(detail.run.finalAnswer)
        switch decision {
        case .notCandidate(let reason):
            return .notCandidate(runID: detail.run.id, reason: reason)
        case .candidate(let draft):
            let candidate = try Self.makeCandidate(
                draft: draft,
                receipts: receipts,
                runID: detail.run.id
            )
            try candidateStager.stageMemoryCandidate(candidate)
            return .candidateQueued(runID: detail.run.id, candidate: candidate)
        }
    }

    public static func prompt(
        for receipt: SuiteCaptureReceipt,
        relatedReceipts: [SuiteCaptureReceipt] = []
    ) -> String {
        let duplicateIDs = relatedReceipts.map(\.capture.captureID).sorted()
        return """
        HARNESS CAPTURE CONSOLIDATION GATE

        This is a raw capture from \(receipt.trustedSourceName). Its arrival is evidence only; it is not a candidate and not authority.

        Decide whether the capture contains a stable preference, correction, personal fact, or repeated high-signal behavioral pattern worth Adam's review. Do not propose transient state, ordinary task progress, one-off events, raw dumps, credentials, or a rule inferred from insufficient evidence. Favor data, not rules. Preserve every named entity exactly as it appears in the capture; if uncertain, omit it rather than respelling it. Adam alone will decide Yes, Sometimes, or No later.

        Return exactly one JSON object and no Markdown.

        If it is not worth review:
        {"decision":"not_candidate","reason":"plain explanation"}

        If it is worth review:
        {"decision":"candidate","claim":"one precise claim in plain language","evidence":"what in the capture supports it","domain_a":"one allowed domain","domain_b":"one allowed domain","strength":0.0,"connection_type":"short descriptive relationship"}

        Allowed domains: affect, ambition, belief, entertainment, exercise, health, insight, learning, nutrition, purchase, sleep, social, work.

        Trusted source: \(receipt.trustedSourceName)
        Capture id: \(receipt.capture.captureID)
        Capture kind: \(receipt.capture.captureKind)
        Captured at: \(receipt.capture.capturedAt)
        Source record id: \(receipt.capture.sourceRecordID ?? "none")
        Payload: \(receipt.capture.payload.jsonString)
        Artifact references: \(receipt.capture.artifactRefs.joined(separator: ", "))
        Duplicate delivery receipts: \(duplicateIDs.isEmpty ? "none" : duplicateIDs.joined(separator: ", "))
        Duplicate delivery receipts are retained for provenance only. They are not independent observations and must not increase confidence or be cited as additional behavioral evidence.
        """
    }

    public static func containsValidDecision(_ response: String) -> Bool {
        (try? parseDecision(response)) != nil
    }

    public static func decisionJSON(from response: BackendResponse) throws -> String {
        guard let call = response.toolCalls.first(where: { $0.name == decisionTool.name }) else {
            throw SuiteCaptureAnalysisError.invalidDecision(
                "the backend did not submit the required capture decision"
            )
        }
        let json = call.input.jsonString
        _ = try parseDecision(json)
        return json
    }

    private enum ParsedDecision: Equatable {
        case notCandidate(String)
        case candidate(CandidateDraft)
    }

    private struct CandidateDraft: Decodable, Equatable {
        let claim: String
        let evidence: String
        let domainA: String
        let domainB: String
        let strength: Double?
        let connectionType: String

        enum CodingKeys: String, CodingKey {
            case claim, evidence, strength
            case domainA = "domain_a"
            case domainB = "domain_b"
            case connectionType = "connection_type"
        }
    }

    private struct WireDecision: Decodable {
        let decision: String
        let reason: String?
        let claim: String?
        let evidence: String?
        let domainA: String?
        let domainB: String?
        let strength: Double?
        let connectionType: String?

        enum CodingKeys: String, CodingKey {
            case decision, reason, claim, evidence, strength
            case domainA = "domain_a"
            case domainB = "domain_b"
            case connectionType = "connection_type"
        }
    }

    private static func parseDecision(_ response: String) throws -> ParsedDecision {
        let data = try decisionData(from: response)
        let wire: WireDecision
        do {
            wire = try JSONDecoder().decode(WireDecision.self, from: data)
        } catch {
            throw SuiteCaptureAnalysisError.invalidDecision("response was not the required JSON object")
        }

        switch wire.decision.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "not_candidate", "retained":
            let reason = wire.reason?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !reason.isEmpty else {
                throw SuiteCaptureAnalysisError.invalidDecision("a no-candidate decision requires a reason")
            }
            return .notCandidate(reason)
        case "candidate":
            guard let claim = wire.claim,
                  let evidence = wire.evidence,
                  let domainA = wire.domainA,
                  let domainB = wire.domainB,
                  let connectionType = wire.connectionType else {
                throw SuiteCaptureAnalysisError.invalidDecision("a candidate decision is missing required fields")
            }
            return .candidate(CandidateDraft(
                claim: claim,
                evidence: evidence,
                domainA: domainA,
                domainB: domainB,
                strength: wire.strength,
                connectionType: connectionType
            ))
        default:
            throw SuiteCaptureAnalysisError.invalidDecision("decision must be candidate or not_candidate")
        }
    }

    private static func decisionData(from response: String) throws -> Data {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = trimmed.data(using: .utf8),
           (try? JSONSerialization.jsonObject(with: data)) is [String: Any] {
            return data
        }
        guard let start = trimmed.firstIndex(of: "{"),
              let end = trimmed.lastIndex(of: "}"),
              start <= end,
              let data = String(trimmed[start...end]).data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else {
            throw SuiteCaptureAnalysisError.invalidDecision("no JSON object was found")
        }
        return data
    }

    private static func makeCandidate(
        draft: CandidateDraft,
        receipts: [SuiteCaptureReceipt],
        runID: String
    ) throws -> MemoryCandidate {
        guard let receipt = receipts.first else {
            throw SuiteCaptureAnalysisError.invalidDecision("no receipt was supplied")
        }
        let claim = draft.claim.trimmingCharacters(in: .whitespacesAndNewlines)
        let evidence = draft.evidence.trimmingCharacters(in: .whitespacesAndNewlines)
        let domainA = draft.domainA.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let domainB = draft.domainB.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let connectionType = draft.connectionType.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowedDomains: Set<String> = [
            "affect", "ambition", "belief", "entertainment", "exercise",
            "health", "insight", "learning", "nutrition", "purchase", "sleep",
            "social", "work",
        ]
        guard !claim.isEmpty, claim.utf8.count <= 2_000 else {
            throw SuiteCaptureAnalysisError.unsafeCandidate("claim is empty or too long")
        }
        guard !evidence.isEmpty, evidence.utf8.count <= 4_000 else {
            throw SuiteCaptureAnalysisError.unsafeCandidate("evidence is empty or too long")
        }
        guard allowedDomains.contains(domainA), allowedDomains.contains(domainB) else {
            throw SuiteCaptureAnalysisError.unsafeCandidate("candidate uses an unknown life domain")
        }
        guard !connectionType.isEmpty, connectionType.utf8.count <= 120 else {
            throw SuiteCaptureAnalysisError.unsafeCandidate("connection type is empty or too long")
        }
        if let strength = draft.strength, !(0...1).contains(strength) {
            throw SuiteCaptureAnalysisError.unsafeCandidate("strength must be between 0 and 1")
        }
        let candidateText = [claim, evidence, connectionType].joined(separator: "\n")
        guard SecretRedactor().redact(candidateText) == candidateText else {
            throw SuiteCaptureAnalysisError.unsafeCandidate("candidate contains credential-shaped text")
        }

        let producerIDs = Set(receipts.map {
            SuiteCaptureProvenance.canonicalProducerID(for: $0.trustedSourceID)
        }).sorted()
        let captureIDs = Set(receipts.map(\.capture.captureID)).sorted()
        let digestInput = [
            producerIDs.joined(separator: ","),
            Self.logicalRecordIdentities(for: receipts).joined(separator: ","),
        ].joined(separator: "|")
        let digest = SHA256.hash(data: Data(digestInput.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        let candidateID = "cand-capture-\(digest.prefix(20))"
        let capturedAt = parseTimestamp(receipt.capture.capturedAt)
        let rawPaths = receipts.map(\.rawCapturePath).sorted().joined(separator: ", ")
        let source = "Harness proposal from \(receipt.trustedSourceName) · captures \(captureIDs.joined(separator: ", ")) · raw \(rawPaths)"
        let evidenceNote = "\(evidence)\nSource captures: \(captureIDs.joined(separator: ", "))"

        return MemoryCandidate(
            id: candidateID,
            runId: runID,
            sourceRunIds: [runID],
            evidenceText: evidenceNote,
            proposedClaim: claim,
            proposedGraph: nil,
            status: .candidate,
            validationResult: "Harness proposal. Not accepted graph authority until Adam approves it.",
            plainEnglish: claim,
            evidenceNote: evidenceNote,
            sourceRef: source,
            strength: draft.strength,
            sourceCaptureIDs: captureIDs,
            trustedSource: producerIDs.first,
            sourceCapturedAt: capturedAt,
            analyzerVersion: analyzerVersion,
            domainA: domainA,
            domainB: domainB,
            connectionType: connectionType
        )
    }

    private static func parseTimestamp(_ value: String) -> Date? {
        let standard = ISO8601DateFormatter()
        if let date = standard.date(from: value) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value)
    }

    private static func uniqueReceipts(_ receipts: [SuiteCaptureReceipt]) -> [SuiteCaptureReceipt] {
        var seen: Set<String> = []
        return receipts.filter { seen.insert($0.id).inserted }
    }

    private static func areDuplicateLegacyDeliveries(
        _ receipts: [SuiteCaptureReceipt]
    ) -> Bool {
        guard let first = receipts.first,
              first.capture.captureKind == "legacy_candidate_envelope",
              let plain = first.capture.payload["plain"]?.stringValue,
              !plain.isEmpty else { return false }
        let producerSource = first.capture.payload["source"]?.stringValue
        return receipts.dropFirst().allSatisfy {
            $0.capture.captureKind == "legacy_candidate_envelope"
                && $0.capture.payload["plain"]?.stringValue == plain
                && $0.capture.payload["source"]?.stringValue == producerSource
        }
    }

    private static func logicalRecordIdentities(
        for receipts: [SuiteCaptureReceipt]
    ) -> [String] {
        Set(receipts.map { receipt in
            if receipt.capture.captureKind == "legacy_candidate_envelope",
               let source = receipt.capture.payload["source"]?.stringValue,
               let plain = receipt.capture.payload["plain"]?.stringValue {
                return "legacy:\(source)|\(normalizedIdentityText(plain))"
            }
            if let sourceRecordID = receipt.capture.sourceRecordID,
               !sourceRecordID.isEmpty {
                return "record:\(sourceRecordID)"
            }
            return "capture:\(receipt.capture.captureID)"
        }).sorted()
    }

    private static func normalizedIdentityText(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
}
