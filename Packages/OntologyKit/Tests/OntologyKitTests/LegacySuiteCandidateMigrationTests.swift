import Foundation
import Testing
@testable import OntologyKit

@Test func legacyProducerProposalBecomesRawReceiptBeforeLeavingReviewQueue() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("legacy-suite-migration-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let queueURL = root.appendingPathComponent("ontology/candidates/queue.json")
    let acceptedURL = root.appendingPathComponent("ontology/accepted/accepted-graph.ttl")
    try FileManager.default.createDirectory(
        at: queueURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
        at: acceptedURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    let accepted = Data("accepted graph must not change".utf8)
    try accepted.write(to: acceptedURL)
    let queue: [[String: Any]] = [
        [
            "id": "cand-news-calm-old",
            "status": "pending",
            "plain": "AGENT PROPOSAL: producer judgment",
            "evidence": "raw settings",
            "source": "News Calm",
            "domain_a": "learning",
            "domain_b": "affect",
            "connection_type": "producer_decision",
        ],
        [
            "id": "cand-harness-real",
            "status": "pending",
            "plain": "Harness-owned proposal",
            "evidence": "retained",
            "source": "Harness",
            "domain_a": "work",
            "domain_b": "work",
            "connection_type": "memory-note",
        ],
    ]
    try JSONSerialization.data(withJSONObject: queue, options: [.prettyPrinted, .sortedKeys])
        .write(to: queueURL)
    let store = SuiteCaptureReceiptStore(root: root.appendingPathComponent("receipts"))
    let migrator = LegacySuiteCandidateQueueMigrator(
        ontologyRoot: root.appendingPathComponent("ontology"),
        receiptStore: store
    )

    let migrated = try await migrator.migrate(now: Date(timeIntervalSince1970: 1_752_260_400))
    let remaining = try #require(
        JSONSerialization.jsonObject(with: Data(contentsOf: queueURL)) as? [[String: Any]]
    )
    let receipts = try await store.listReceipts()

    #expect(migrated == ["cand-news-calm-old"])
    #expect(remaining.compactMap { $0["id"] as? String } == ["cand-harness-real"])
    #expect(receipts.count == 1)
    #expect(receipts[0].capture.captureKind == "legacy_candidate_envelope")
    #expect(receipts[0].capture.sourceRecordID == "cand-news-calm-old")
    #expect(receipts[0].state == .analysisPending)
    #expect(try Data(contentsOf: acceptedURL) == accepted)
}
