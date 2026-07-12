import Foundation
import Testing
@testable import OntologyKit

private func captureTestDirectory(_ name: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func captureData(
    id: String = "capture-news-calm-001",
    payload: [String: Any] = ["text": "Adam tapped useful"]
) throws -> Data {
    try JSONSerialization.data(
        withJSONObject: [
            "schema_version": "suite_capture.v1",
            "capture_id": id,
            "source_app": "payload-can-say-anything",
            "source_record_id": "row-7",
            "captured_at": "2026-07-11T19:00:00Z",
            "capture_kind": "rating_recorded",
            "payload": payload,
            "artifact_refs": ["news-calm://rating/7"],
        ],
        options: [.sortedKeys]
    )
}

@Test func neutralCaptureIsDurableBeforeAnyAnalysis() async throws {
    let root = try captureTestDirectory("suite-capture-store")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SuiteCaptureReceiptStore(root: root)
    let source = TrustedSuiteCaptureSource(id: "news-calm", displayName: "News Calm")
    let bytes = try captureData()

    let disposition = try await store.ingest(
        data: bytes,
        from: source,
        now: Date(timeIntervalSince1970: 1_752_260_400)
    )
    let receipt = disposition.receipt

    if case .stored = disposition {} else { Issue.record("Expected a newly stored receipt") }
    #expect(receipt.state == .analysisPending)
    #expect(receipt.trustedSourceID == "news-calm")
    #expect(receipt.trustedSourceName == "News Calm")
    #expect(receipt.capture.sourceApp == "payload-can-say-anything")
    #expect(try Data(contentsOf: URL(fileURLWithPath: receipt.rawCapturePath)) == bytes)
    #expect(try await store.listReceipts() == [receipt])
}

@Test func duplicateIsIdempotentAndChangedBytesBecomeAConflict() async throws {
    let root = try captureTestDirectory("suite-capture-conflict")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SuiteCaptureReceiptStore(root: root)
    let source = TrustedSuiteCaptureSource(id: "understood", displayName: "Understood")
    let first = try captureData(id: "capture-understood-001", payload: ["text": "first"])
    let changed = try captureData(id: "capture-understood-001", payload: ["text": "changed"])

    _ = try await store.ingest(data: first, from: source)
    let duplicate = try await store.ingest(data: first, from: source)
    let conflict = try await store.ingest(data: changed, from: source)

    if case .duplicate = duplicate {} else { Issue.record("Expected an idempotent duplicate") }
    if case .conflict = conflict {} else { Issue.record("Expected a preserved conflict") }
    #expect(conflict.receipt.state == .conflict)
    #expect(conflict.receipt.conflictOfReceiptPath != nil)
    #expect(try await store.listReceipts().count == 2)
    #expect(try Data(contentsOf: URL(fileURLWithPath: conflict.receipt.rawCapturePath)) == changed)
}

@Test func corruptReceiptMetadataKeepsRawEvidenceVisibleAndQuarantined() async throws {
    let root = try captureTestDirectory("suite-capture-corrupt-receipt")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SuiteCaptureReceiptStore(root: root)
    let bytes = try captureData(id: "capture-news-calm-corrupt-receipt")
    let receipt = try await store.ingest(
        data: bytes,
        from: .init(id: "news-calm", displayName: "News Calm")
    ).receipt
    let receiptURL = URL(fileURLWithPath: receipt.rawCapturePath)
        .deletingLastPathComponent()
        .appendingPathComponent("receipt.json")
    try Data("{not valid receipt json".utf8).write(to: receiptURL, options: .atomic)

    let inventory = try await store.inspectReceipts()
    let visible = try #require(inventory.receipts.first)

    #expect(inventory.corruptReceiptPaths.count == 1)
    #expect(
        inventory.corruptReceiptPaths.first.map {
            URL(fileURLWithPath: $0).resolvingSymlinksInPath()
        } == receiptURL.resolvingSymlinksInPath()
    )
    #expect(visible.state == .quarantined)
    #expect(visible.capture.captureID == "capture-news-calm-corrupt-receipt")
    #expect(visible.analysisDetail?.contains("unreadable") == true)
    #expect(try Data(contentsOf: URL(fileURLWithPath: visible.rawCapturePath)) == bytes)
}

@Test func producerCandidateFieldsAreNotAcceptedAsCaptureAuthority() async throws {
    let root = try captureTestDirectory("suite-capture-legacy")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SuiteCaptureReceiptStore(root: root)
    let source = TrustedSuiteCaptureSource(id: "news-calm", displayName: "News Calm")
    let legacy = try JSONSerialization.data(
        withJSONObject: [
            "id": "cand-news-calm-old",
            "status": "pending",
            "plain": "AGENT PROPOSAL: upstream decision",
            "evidence": "old aggregate",
            "domain_a": "learning",
            "domain_b": "affect",
            "strength": 0.9,
            "connection_type": "stated_news_preference",
        ],
        options: [.prettyPrinted, .sortedKeys]
    )

    await #expect(throws: SuiteCaptureError.self) {
        try await store.ingest(data: legacy, from: source)
    }
    let migrated = try await store.ingestLegacyCandidate(
        data: legacy,
        from: source,
        capturedAt: Date(timeIntervalSince1970: 1_752_260_400)
    ).receipt

    #expect(migrated.capture.captureKind == "legacy_candidate_envelope")
    #expect(migrated.capture.sourceRecordID == "cand-news-calm-old")
    #expect(migrated.state == .analysisPending)
    #expect(try Data(contentsOf: URL(fileURLWithPath: migrated.rawCapturePath)) == legacy)
}

@Test func inboxArchivesOnlyAfterReceiptAndReportsMissingRoots() async throws {
    let fixture = try captureTestDirectory("suite-capture-inbox")
    defer { try? FileManager.default.removeItem(at: fixture) }
    let inbox = fixture.appendingPathComponent("Pending", isDirectory: true)
    let missing = fixture.appendingPathComponent("Missing", isDirectory: true)
    let receipts = fixture.appendingPathComponent("Receipts", isDirectory: true)
    try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
    let incoming = inbox.appendingPathComponent("capture.json")
    try captureData().write(to: incoming)

    let store = SuiteCaptureReceiptStore(root: receipts)
    let source = TrustedSuiteCaptureSource(id: "news-calm", displayName: "News Calm")
    let importer = LocalSuiteCaptureInboxImporter(
        sources: [
            SuiteCaptureInboxSource(trustedSource: source, root: inbox),
            SuiteCaptureInboxSource(
                trustedSource: TrustedSuiteCaptureSource(id: "recall", displayName: "Re_Call"),
                root: missing
            ),
        ],
        receiptStore: store
    )

    let report = await importer.importAll()

    #expect(report.storedCaptureIDs == ["capture-news-calm-001"])
    #expect(report.archivedFiles == ["capture.json"])
    #expect(report.missingRootPaths == [missing.path])
    #expect(!FileManager.default.fileExists(atPath: incoming.path))
    #expect(FileManager.default.fileExists(atPath: inbox.appendingPathComponent("Archive/capture.json").path))
    #expect(try await store.listReceipts().count == 1)
}

@Test func inboxNeverArchivesBytesThatChangedAfterTheDurableReceipt() async throws {
    let fixture = try captureTestDirectory("suite-capture-inbox-race")
    defer { try? FileManager.default.removeItem(at: fixture) }
    let inbox = fixture.appendingPathComponent("Pending", isDirectory: true)
    let receipts = fixture.appendingPathComponent("Receipts", isDirectory: true)
    try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
    let incoming = inbox.appendingPathComponent("capture.json")
    let original = try captureData(id: "capture-news-calm-race", payload: ["text": "first"])
    let changed = try captureData(id: "capture-news-calm-race", payload: ["text": "changed"])
    try original.write(to: incoming)
    let store = SuiteCaptureReceiptStore(root: receipts)
    let importer = LocalSuiteCaptureInboxImporter(
        sources: [SuiteCaptureInboxSource(
            trustedSource: .init(id: "news-calm", displayName: "News Calm"),
            root: inbox
        )],
        receiptStore: store,
        materializeUbiquitousItem: { _ in },
        beforeArchive: { _ in try? changed.write(to: incoming, options: .atomic) }
    )

    let report = await importer.importAll()
    let receipt = try #require(try await store.listReceipts().first)

    #expect(report.archivedFiles.isEmpty)
    #expect(report.retainedFiles == ["capture.json"])
    #expect(report.invalidFiles.values.contains {
        $0.contains("changed after Harness retained")
    })
    #expect(try Data(contentsOf: incoming) == changed)
    #expect(try Data(contentsOf: URL(fileURLWithPath: receipt.rawCapturePath)) == original)
}

@Test func credentialShapedCaptureIsRetainedButNotSentForAnalysis() async throws {
    let root = try captureTestDirectory("suite-capture-quarantine")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SuiteCaptureReceiptStore(root: root)
    let source = TrustedSuiteCaptureSource(id: "recall", displayName: "Re_Call")
    let bytes = try captureData(
        id: "capture-recall-secret",
        payload: ["text": "api_key=should-not-go-to-a-model"]
    )

    let receipt = try await store.ingest(data: bytes, from: source).receipt

    #expect(receipt.state == .quarantined)
    #expect(receipt.analysisDetail?.contains("withheld") == true)
    #expect(try Data(contentsOf: URL(fileURLWithPath: receipt.rawCapturePath)) == bytes)
}

@Test func decodedCredentialKeysAreQuarantinedEvenWhenRawTextEvadesTheRedactor() async throws {
    let root = try captureTestDirectory("suite-capture-decoded-secret")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SuiteCaptureReceiptStore(root: root)
    let source = TrustedSuiteCaptureSource(id: "understood", displayName: "Understood")
    let bytes = Data(#"{"schema_version":"suite_capture.v1","capture_id":"capture-understood-secret-key","captured_at":"2026-07-11T19:00:00Z","capture_kind":"entry_created","payload":{"\u0061pi_key":"ordinary-looking-value"}}"#.utf8)

    let receipt = try await store.ingest(data: bytes, from: source).receipt

    #expect(receipt.state == .quarantined)
    #expect(receipt.analysisDetail?.contains("withheld") == true)
    #expect(try Data(contentsOf: URL(fileURLWithPath: receipt.rawCapturePath)) == bytes)
}

@Test func reviewOutcomeUpdatesReceiptMetadataWithoutChangingRawCapture() async throws {
    let root = try captureTestDirectory("suite-capture-review-outcome")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SuiteCaptureReceiptStore(root: root)
    let source = TrustedSuiteCaptureSource(id: "news-calm", displayName: "News Calm")
    let bytes = try captureData(id: "capture-news-calm-reviewed")
    let stored = try await store.ingest(data: bytes, from: source).receipt
    let queued = try await store.recordAnalysis(
        for: stored,
        state: .candidateQueued,
        runID: "run-capture-review",
        candidateIDs: ["cand-capture-review-001"],
        detail: "Harness formed a proposal for Adam's review."
    )

    let reconciled = try await store.reconcileReviewStatuses([
        "cand-capture-review-001": .accepted,
    ])
    let reviewed = try #require(reconciled.first)

    #expect(reviewed.state == .candidateAccepted)
    #expect(reviewed.analysisDetail == "Adam accepted this Harness proposal.")
    #expect(reviewed.analysisAttempts == queued.analysisAttempts)
    #expect(reviewed.analysisRunID == "run-capture-review")
    #expect(try Data(contentsOf: URL(fileURLWithPath: reviewed.rawCapturePath)) == bytes)

    let idempotent = try await store.reconcileReviewStatuses([
        "cand-capture-review-001": .accepted,
    ])
    #expect(idempotent == reconciled)
}

@Test func existingQueueClaimClosesCrashWindowAndTerminalStateCannotRegress() async throws {
    let root = try captureTestDirectory("suite-capture-existing-claim")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SuiteCaptureReceiptStore(root: root)
    let source = TrustedSuiteCaptureSource(id: "recall", displayName: "Re_Call")
    let bytes = try captureData(id: "capture-recall-existing-claim")
    let stored = try await store.ingest(data: bytes, from: source).receipt

    let bound = try await store.recordExistingReviewClaim(
        for: stored,
        candidateID: "cand-capture-existing-claim",
        status: .accepted,
        detail: "Already represented by an accepted Harness decision."
    )

    #expect(bound.state == .candidateAccepted)
    #expect(bound.candidateIDs == ["cand-capture-existing-claim"])
    #expect(bound.analysisAttempts == 0)
    await #expect(throws: SuiteCaptureError.self) {
        try await store.recordAnalysis(
            for: stored,
            state: .analysisFailed,
            runID: nil,
            detail: "A stale analyzer failed after the review."
        )
    }
    let preserved = try await store.loadReceipt(
        sourceID: "recall",
        captureID: "capture-recall-existing-claim"
    )
    #expect(preserved.state == .candidateAccepted)
    #expect(try Data(contentsOf: URL(fileURLWithPath: preserved.rawCapturePath)) == bytes)
}

@Test func coordinatedCandidateStagerIsIdempotentAndKeepsCaptureProvenance() throws {
    let root = try captureTestDirectory("suite-capture-queue")
    defer { try? FileManager.default.removeItem(at: root) }
    let queueURL = root.appendingPathComponent("candidates/queue.json")
    try FileManager.default.createDirectory(
        at: queueURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try Data("[]".utf8).write(to: queueURL)
    let capturedAt = Date(timeIntervalSince1970: 1_752_260_400)
    let candidate = MemoryCandidate(
        id: "cand-capture-1234567890abcdef",
        runId: "run-capture",
        sourceRunIds: ["run-capture"],
        evidenceText: "Adam rated the story useful.",
        proposedClaim: "Adam prefers useful news without manufactured drama.",
        proposedGraph: nil,
        status: .candidate,
        validationResult: nil,
        evidenceNote: "Adam rated the story useful.",
        sourceRef: "/receipts/news-calm/capture-1/raw-capture.json",
        strength: 0.8,
        sourceCaptureIDs: ["capture-news-calm-001"],
        trustedSource: "news-calm",
        sourceCapturedAt: capturedAt,
        analyzerVersion: "suite-capture-consolidation-v1",
        domainA: "learning",
        domainB: "affect",
        connectionType: "stated_news_preference"
    )
    let stager = CoordinatedReviewQueueMemoryStager(ontologyRoot: root)

    try stager.stageMemoryCandidate(candidate)
    try stager.stageMemoryCandidate(candidate)

    let queue = try #require(
        JSONSerialization.jsonObject(with: Data(contentsOf: queueURL)) as? [[String: Any]]
    )
    #expect(queue.count == 1)
    #expect(queue[0]["source_capture_ids"] as? [String] == ["capture-news-calm-001"])
    #expect(queue[0]["trusted_source"] as? String == "news-calm")
    #expect(queue[0]["domain_a"] as? String == "learning")
    #expect(queue[0]["domain_b"] as? String == "affect")
    #expect(queue[0]["connection_type"] as? String == "stated_news_preference")
    #expect(queue[0]["analyzer_version"] as? String == "suite-capture-consolidation-v1")
    #expect(queue[0]["source_captured_at"] as? Double == capturedAt.timeIntervalSinceReferenceDate)
}

@Test func sameProducerReplayCannotRegressATerminalQueueClaim() throws {
    let root = try captureTestDirectory("suite-capture-terminal-replay")
    defer { try? FileManager.default.removeItem(at: root) }
    let queueURL = root.appendingPathComponent("candidates/queue.json")
    try FileManager.default.createDirectory(
        at: queueURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    let row: [String: Any] = [
        "id": "cand-capture-stable-record",
        "status": "accepted",
        "plain": "Adam's reviewed wording must remain.",
        "evidence": "Reviewed evidence.",
        "source": "original receipt",
        "domain_a": "learning",
        "domain_b": "affect",
        "connection_type": "reviewed_preference",
        "frequency": "usually",
        "source_capture_ids": ["capture-news-original"],
        "trusted_source": "news-calm-legacy-queue",
    ]
    try JSONSerialization.data(withJSONObject: [row], options: [.prettyPrinted, .sortedKeys])
        .write(to: queueURL)
    let before = try Data(contentsOf: queueURL)
    let replay = replayCandidate(
        id: "cand-capture-stable-record",
        captureIDs: ["capture-news-original", "capture-news-late-copy"],
        trustedSource: "news-calm",
        claim: "A later model chose different wording."
    )

    try CoordinatedReviewQueueMemoryStager(ontologyRoot: root)
        .stageMemoryCandidate(replay)

    #expect(try Data(contentsOf: queueURL) == before)
}

@Test func sameProducerReplayOnlyUnionsProvenanceOnPendingClaim() throws {
    let root = try captureTestDirectory("suite-capture-pending-replay")
    defer { try? FileManager.default.removeItem(at: root) }
    let queueURL = root.appendingPathComponent("candidates/queue.json")
    try FileManager.default.createDirectory(
        at: queueURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    let row: [String: Any] = [
        "id": "cand-capture-stable-pending",
        "status": "pending",
        "plain": "Keep the first proposed wording.",
        "evidence": "Keep the first evidence.",
        "source": "first receipt",
        "domain_a": "learning",
        "domain_b": "affect",
        "connection_type": "first_preference",
        "source_capture_ids": ["capture-news-original"],
        "trusted_source": "news-calm-legacy",
    ]
    try JSONSerialization.data(withJSONObject: [row], options: [.prettyPrinted, .sortedKeys])
        .write(to: queueURL)
    let replay = replayCandidate(
        id: "cand-capture-stable-pending",
        captureIDs: ["capture-news-late-copy", "capture-news-original"],
        trustedSource: "news-calm-legacy-queue",
        claim: "Do not replace the first wording."
    )

    try CoordinatedReviewQueueMemoryStager(ontologyRoot: root)
        .stageMemoryCandidate(replay)

    let rows = try #require(
        JSONSerialization.jsonObject(with: Data(contentsOf: queueURL)) as? [[String: Any]]
    )
    let preserved = try #require(rows.first)
    #expect(rows.count == 1)
    #expect(preserved["status"] as? String == "pending")
    #expect(preserved["plain"] as? String == "Keep the first proposed wording.")
    #expect(preserved["evidence"] as? String == "Keep the first evidence.")
    #expect(preserved["trusted_source"] as? String == "news-calm-legacy")
    #expect(preserved["source_capture_ids"] as? [String] == [
        "capture-news-late-copy",
        "capture-news-original",
    ])
}

@Test func stableIDReplayFromDifferentProducerRemainsACollision() throws {
    let root = try captureTestDirectory("suite-capture-producer-collision")
    defer { try? FileManager.default.removeItem(at: root) }
    let queueURL = root.appendingPathComponent("candidates/queue.json")
    try FileManager.default.createDirectory(
        at: queueURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    let row: [String: Any] = [
        "id": "cand-capture-stable-collision",
        "status": "pending",
        "plain": "News Calm proposal.",
        "evidence": "News Calm evidence.",
        "source": "news receipt",
        "domain_a": "learning",
        "domain_b": "affect",
        "connection_type": "news_preference",
        "source_capture_ids": ["capture-news-original"],
        "trusted_source": "news-calm",
    ]
    try JSONSerialization.data(withJSONObject: [row], options: [.prettyPrinted, .sortedKeys])
        .write(to: queueURL)
    let before = try Data(contentsOf: queueURL)
    let collision = replayCandidate(
        id: "cand-capture-stable-collision",
        captureIDs: ["capture-recall-record"],
        trustedSource: "recall",
        claim: "A different producer cannot claim this stable ID."
    )

    #expect(throws: ToolExecutorError.self) {
        try CoordinatedReviewQueueMemoryStager(ontologyRoot: root)
            .stageMemoryCandidate(collision)
    }
    #expect(try Data(contentsOf: queueURL) == before)
}

private func replayCandidate(
    id: String,
    captureIDs: [String],
    trustedSource: String,
    claim: String
) -> MemoryCandidate {
    MemoryCandidate(
        id: id,
        runId: "run-replay",
        sourceRunIds: ["run-replay"],
        evidenceText: "A later analysis supplied different evidence.",
        proposedClaim: claim,
        proposedGraph: nil,
        status: .candidate,
        validationResult: nil,
        evidenceNote: "A later analysis supplied different evidence.",
        sourceRef: "later receipt",
        sourceCaptureIDs: captureIDs,
        trustedSource: trustedSource,
        domainA: "work",
        domainB: "insight",
        connectionType: "later_wording"
    )
}
