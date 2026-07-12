import Foundation

public enum LegacySuiteCandidateMigrationError: Error, LocalizedError, Sendable, Equatable {
    case queueInvalid
    case queueChanged

    public var errorDescription: String? {
        switch self {
        case .queueInvalid:
            return "The review queue is invalid; legacy producer proposals were left untouched."
        case .queueChanged:
            return "The review queue kept changing; legacy producer proposals were retained for retry."
        }
    }
}

/// One-time correction for producer-authored pending rows created before the
/// capture boundary was fixed. Each row becomes a durable opaque capture
/// receipt first; only then is that unreviewed row removed from queue.json.
/// Accepted and rejected rows, decision history, and the accepted graph are
/// never read or written here.
public struct LegacySuiteCandidateQueueMigrator: Sendable {
    private let ontologyRoot: URL
    private let receiptStore: SuiteCaptureReceiptStore
    private let maxAttempts: Int

    public init(
        ontologyRoot: URL = ReviewQueueStore.defaultOntologyRoot(),
        receiptStore: SuiteCaptureReceiptStore,
        maxAttempts: Int = 3
    ) {
        self.ontologyRoot = ontologyRoot
        self.receiptStore = receiptStore
        self.maxAttempts = max(1, maxAttempts)
    }

    public func migrate(now: Date = Date()) async throws -> [String] {
        let queueURL = ontologyRoot
            .appendingPathComponent("candidates", isDirectory: true)
            .appendingPathComponent("queue.json")

        for attempt in 0..<maxAttempts {
            let original = try ReviewQueueFileCoordinator.read(queueURL: queueURL)
            guard let rows = try JSONSerialization.jsonObject(with: original) as? [[String: Any]] else {
                throw LegacySuiteCandidateMigrationError.queueInvalid
            }
            let migrations = rows.compactMap(Self.legacyProducerRow)
            guard !migrations.isEmpty else { return [] }

            for migration in migrations {
                let data = try JSONSerialization.data(
                    withJSONObject: migration.row,
                    options: [.prettyPrinted, .sortedKeys]
                )
                _ = try await receiptStore.ingestLegacyCandidate(
                    data: data,
                    from: migration.source,
                    capturedAt: now,
                    now: now
                )
            }

            let migratedIDs = Set(migrations.map(\.id))
            let replacement = try JSONSerialization.data(
                withJSONObject: rows.filter {
                    guard let id = $0["id"] as? String else { return true }
                    return !migratedIDs.contains(id)
                },
                options: [.prettyPrinted, .sortedKeys]
            )
            do {
                guard try ReviewQueueFileCoordinator.compareAndSwap(
                    queueURL: queueURL,
                    expected: original,
                    replacement: replacement
                ) else {
                    throw LegacySuiteCandidateMigrationError.queueChanged
                }
                return migratedIDs.sorted()
            } catch LegacySuiteCandidateMigrationError.queueChanged where attempt + 1 < maxAttempts {
                continue
            }
        }
        throw LegacySuiteCandidateMigrationError.queueChanged
    }

    private struct Migration {
        let id: String
        let row: [String: Any]
        let source: TrustedSuiteCaptureSource
    }

    private static func legacyProducerRow(_ row: [String: Any]) -> Migration? {
        guard row["status"] as? String == "pending",
              let id = row["id"] as? String,
              let plain = row["plain"] as? String,
              plain.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("AGENT PROPOSAL:")
        else { return nil }

        let source: TrustedSuiteCaptureSource
        if id.hasPrefix("cand-news-calm-") {
            source = .init(id: "news-calm-legacy-queue", displayName: "News Calm (legacy queue)")
        } else if id.hasPrefix("cand-recall-") || id.hasPrefix("cand-re-call-") {
            source = .init(id: "recall-legacy-queue", displayName: "Re_Call (legacy queue)")
        } else if id.hasPrefix("cand-understood-") {
            source = .init(id: "understood-legacy-queue", displayName: "Understood (legacy queue)")
        } else {
            return nil
        }
        return Migration(id: id, row: row, source: source)
    }

}
