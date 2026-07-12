import Foundation
import Testing
@testable import OntologyKit

@Test func captureAnalyzerRetainsNoCandidateWithHarnessReason() async throws {
    let stager = AnalyzerRecordingStager()
    let analyzer = SuiteCaptureAnalyzer(
        runPrompt: { _ in analyzerRun(
            answer: #"{"decision":"not_candidate","reason":"A one-off completion is task progress, not a stable pattern."}"#
        ) },
        candidateStager: stager
    )

    let outcome = try await analyzer.analyze(analyzerReceipt())

    #expect(outcome == .notCandidate(
        runID: "capture-analysis-run",
        reason: "A one-off completion is task progress, not a stable pattern."
    ))
    #expect(stager.snapshot().isEmpty)
}

@Test func captureAnalyzerStagesHarnessOwnedCandidateWithTrustedProvenance() async throws {
    let stager = AnalyzerRecordingStager()
    let analyzer = SuiteCaptureAnalyzer(
        runPrompt: { prompt in
            #expect(prompt.contains("Its arrival is evidence only; it is not a candidate"))
            return analyzerRun(answer: """
            ```json
            {"decision":"candidate","claim":"Adam prefers brief news summaries.","evidence":"The retained settings choose the brief tone.","domain_a":"learning","domain_b":"affect","strength":0.8,"connection_type":"stated_news_preference"}
            ```
            """)
        },
        candidateStager: stager
    )

    let outcome = try await analyzer.analyze(analyzerReceipt())
    let candidate: MemoryCandidate
    switch outcome {
    case .candidateQueued(let runID, let queued):
        #expect(runID == "capture-analysis-run")
        candidate = queued
    case .notCandidate:
        Issue.record("Expected a Harness candidate")
        return
    }

    #expect(candidate.id.hasPrefix("cand-capture-"))
    #expect(candidate.plainEnglish == "Adam prefers brief news summaries.")
    #expect(candidate.trustedSource == "news-calm")
    #expect(candidate.sourceCaptureIDs == ["capture-news-calm-abc123"])
    #expect(candidate.domainA == "learning")
    #expect(candidate.domainB == "affect")
    #expect(candidate.connectionType == "stated_news_preference")
    #expect(candidate.analyzerVersion == SuiteCaptureAnalyzer.analyzerVersion)
    #expect(stager.snapshot() == [candidate])
}

@Test func captureAnalyzerNeverStagesAResponseFromAFailedHarnessRun() async {
    let stager = AnalyzerRecordingStager()
    let analyzer = SuiteCaptureAnalyzer(
        runPrompt: { _ in analyzerRun(
            answer: #"{"decision":"candidate","claim":"Wrong","evidence":"Wrong","domain_a":"work","domain_b":"work","connection_type":"wrong"}"#,
            success: false
        ) },
        candidateStager: stager
    )

    await #expect(throws: SuiteCaptureAnalysisError.self) {
        try await analyzer.analyze(analyzerReceipt())
    }
    #expect(stager.snapshot().isEmpty)
}

@Test func captureAnalyzerRefusesRelatedReceiptsFromAnotherTrustedSource() async {
    let stager = AnalyzerRecordingStager()
    let analyzer = SuiteCaptureAnalyzer(
        runPrompt: { _ in
            Issue.record("Cross-source receipts must be rejected before model analysis")
            return analyzerRun(answer: #"{"decision":"not_candidate","reason":"unused"}"#)
        },
        candidateStager: stager
    )
    let foreignReceipt = analyzerReceipt(
        captureID: "capture-recall-abc123",
        trustedSourceID: "recall",
        trustedSourceName: "Re_Call"
    )

    await #expect(throws: SuiteCaptureAnalysisError.self) {
        try await analyzer.analyze(
            analyzerReceipt(),
            relatedReceipts: [foreignReceipt]
        )
    }
    #expect(stager.snapshot().isEmpty)
}

@Test func legacyTransportDuplicatesAreOneProducerRecordNotExtraEvidence() async throws {
    let stager = AnalyzerRecordingStager()
    let analyzer = SuiteCaptureAnalyzer(
        runPrompt: { prompt in
            #expect(prompt.contains("Duplicate delivery receipts are retained for provenance only"))
            #expect(prompt.contains("not independent observations"))
            return analyzerRun(answer: #"{"decision":"candidate","claim":"Adam prefers brief news.","evidence":"The producer record says brief.","domain_a":"learning","domain_b":"affect","connection_type":"stated_news_preference"}"#)
        },
        candidateStager: stager
    )
    let primary = legacyAnalyzerReceipt(
        captureID: "capture-news-calm-legacy-one",
        trustedSourceID: "news-calm-legacy"
    )
    let duplicateTransport = legacyAnalyzerReceipt(
        captureID: "capture-news-calm-legacy-two",
        trustedSourceID: "news-calm-legacy-queue"
    )

    let outcome = try await analyzer.analyze(
        primary,
        relatedReceipts: [duplicateTransport]
    )

    guard case .candidateQueued(_, let candidate) = outcome else {
        Issue.record("Expected one candidate for the producer record")
        return
    }
    #expect(candidate.trustedSource == "news-calm")
    #expect(candidate.sourceCaptureIDs == [
        "capture-news-calm-legacy-one",
        "capture-news-calm-legacy-two",
    ])
    #expect(stager.snapshot().count == 1)
}

@Test func candidateIDIsStableAcrossModelWordingForTheSameCapture() async throws {
    let first = SuiteCaptureAnalyzer(
        runPrompt: { _ in analyzerRun(answer: #"{"decision":"candidate","claim":"Adam prefers brief news.","evidence":"Brief was selected.","domain_a":"learning","domain_b":"affect","connection_type":"preference"}"#) },
        candidateStager: AnalyzerRecordingStager()
    )
    let second = SuiteCaptureAnalyzer(
        runPrompt: { _ in analyzerRun(answer: #"{"decision":"candidate","claim":"Brief news is Adam's preference.","evidence":"The tone setting is brief.","domain_a":"learning","domain_b":"affect","connection_type":"preference"}"#) },
        candidateStager: AnalyzerRecordingStager()
    )

    let firstOutcome = try await first.analyze(analyzerReceipt())
    let secondOutcome = try await second.analyze(analyzerReceipt())
    guard case .candidateQueued(_, let firstCandidate) = firstOutcome,
          case .candidateQueued(_, let secondCandidate) = secondOutcome else {
        Issue.record("Expected two candidate analyses")
        return
    }

    #expect(firstCandidate.id == secondCandidate.id)
}

@Test func lateDuplicateTransportDoesNotChangeCandidateIdentity() async throws {
    let answer = #"{"decision":"candidate","claim":"Adam prefers brief news.","evidence":"The producer record says brief.","domain_a":"learning","domain_b":"affect","connection_type":"preference"}"#
    let singleAnalyzer = SuiteCaptureAnalyzer(
        runPrompt: { _ in analyzerRun(answer: answer) },
        candidateStager: AnalyzerRecordingStager()
    )
    let groupedAnalyzer = SuiteCaptureAnalyzer(
        runPrompt: { _ in analyzerRun(answer: answer) },
        candidateStager: AnalyzerRecordingStager()
    )
    let primary = legacyAnalyzerReceipt(
        captureID: "capture-news-calm-first-delivery",
        trustedSourceID: "news-calm-legacy"
    )
    let lateDuplicate = legacyAnalyzerReceipt(
        captureID: "capture-news-calm-late-delivery",
        trustedSourceID: "news-calm-legacy-queue"
    )

    let single = try await singleAnalyzer.analyze(primary)
    let grouped = try await groupedAnalyzer.analyze(
        primary,
        relatedReceipts: [lateDuplicate]
    )
    guard case .candidateQueued(_, let singleCandidate) = single,
          case .candidateQueued(_, let groupedCandidate) = grouped else {
        Issue.record("Expected candidate outcomes")
        return
    }

    #expect(singleCandidate.id == groupedCandidate.id)
    #expect(groupedCandidate.sourceCaptureIDs?.count == 2)
}

@Test func captureDecisionToolRequiresAndValidatesStructuredSubmission() throws {
    let response = BackendResponse(
        text: "I will submit the decision.",
        tokenCount: 10,
        cost: nil,
        toolCalls: [
            ToolCallRequest(
                id: "decision-1",
                name: SuiteCaptureAnalyzer.decisionTool.name,
                input: .object([
                    "decision": .string("not_candidate"),
                    "reason": .string("One event is not a stable pattern."),
                ])
            ),
        ]
    )

    let json = try SuiteCaptureAnalyzer.decisionJSON(from: response)

    #expect(SuiteCaptureAnalyzer.containsValidDecision(json))
    #expect(JSONValue.parse(json)?["decision"]?.stringValue == "not_candidate")
}

private final class AnalyzerRecordingStager: MemoryCandidateStaging, @unchecked Sendable {
    private let lock = NSLock()
    private var candidates: [MemoryCandidate] = []

    func stageMemoryCandidate(_ candidate: MemoryCandidate) throws {
        lock.lock()
        candidates.append(candidate)
        lock.unlock()
    }

    func snapshot() -> [MemoryCandidate] {
        lock.lock()
        defer { lock.unlock() }
        return candidates
    }
}

private func analyzerReceipt(
    captureID: String = "capture-news-calm-abc123",
    trustedSourceID: String = "news-calm",
    trustedSourceName: String = "News Calm"
) -> SuiteCaptureReceipt {
    SuiteCaptureReceipt(
        trustedSourceID: trustedSourceID,
        trustedSourceName: trustedSourceName,
        capture: SuiteCaptureEnvelope(
            captureID: captureID,
            sourceRecordID: "news-calm:preferences-feedback:adam",
            sourceApp: "news_calm",
            capturedAt: "2026-07-11T20:00:00Z",
            captureKind: "news_preferences_snapshot",
            payload: .object(["tone_choice": .string("brief")])
        ),
        rawSHA256: String(repeating: "a", count: 64),
        rawCapturePath: "/tmp/\(captureID)/raw-capture.json",
        receivedAt: "2026-07-11T20:00:01Z",
        updatedAt: "2026-07-11T20:00:01Z",
        state: .analysisPending
    )
}

private func legacyAnalyzerReceipt(
    captureID: String,
    trustedSourceID: String
) -> SuiteCaptureReceipt {
    SuiteCaptureReceipt(
        trustedSourceID: trustedSourceID,
        trustedSourceName: "News Calm (legacy)",
        capture: SuiteCaptureEnvelope(
            captureID: captureID,
            capturedAt: "2026-07-11T20:00:00Z",
            captureKind: "legacy_candidate_envelope",
            payload: .object([
                "plain": .string("AGENT PROPOSAL: Adam prefers brief news."),
                "source": .string("News Calm — news-calm:preferences-feedback:adam"),
            ])
        ),
        rawSHA256: String(repeating: "b", count: 64),
        rawCapturePath: "/tmp/\(captureID)/raw-capture.json",
        receivedAt: "2026-07-11T20:00:01Z",
        updatedAt: "2026-07-11T20:00:01Z",
        state: .analysisPending
    )
}

private func analyzerRun(answer: String, success: Bool = true) -> HarnessRunDetail {
    let run = HarnessRun(
        id: "capture-analysis-run",
        prompt: "capture prompt",
        backend: "test",
        modelName: "deterministic",
        invocationMethod: "test",
        promptPacketHash: "hash",
        success: success,
        duration: 0,
        tokenCount: nil,
        cost: nil,
        finalAnswer: answer,
        deviceName: "test"
    )
    return HarnessRunDetail(
        run: run,
        messages: [],
        authorityHits: [],
        memoryHits: [],
        traceEvents: [],
        evalResults: [],
        memoryCandidates: [],
        validationResults: []
    )
}
