import Foundation

/// The one coordinated append path for model-created review candidates.
///
/// `Data.write(.atomic)` protects a file from partial bytes, but it does not
/// protect a read/append/write transaction from another Harness process or
/// Mac updating the queue between the read and write. This stager re-reads the
/// coordinated file, compares it with the caller's snapshot, and retries from
/// fresh bytes on contention. A stable candidate ID already owned by the same
/// canonical producer is idempotent even if a later analysis chose different
/// wording. Existing review state and content always win; only capture IDs may
/// be unioned while the row is still pending.
public struct CoordinatedReviewQueueMemoryStager: MemoryCandidateStaging, @unchecked Sendable {
    private let ontologyRoot: URL
    private let fileManager: FileManager
    private let maxCommitAttempts: Int

    public init(
        ontologyRoot: URL = ReviewQueueStore.defaultOntologyRoot(),
        fileManager: FileManager = .default,
        maxCommitAttempts: Int = 3
    ) {
        self.ontologyRoot = ontologyRoot
        self.fileManager = fileManager
        self.maxCommitAttempts = max(1, maxCommitAttempts)
    }

    public func stageMemoryCandidate(_ candidate: MemoryCandidate) throws {
        let encodedCandidate = try candidateRow(candidate)
        let candidatesURL = ontologyRoot.appendingPathComponent("candidates", isDirectory: true)
        let queueURL = candidatesURL.appendingPathComponent("queue.json")
        try fileManager.createDirectory(at: candidatesURL, withIntermediateDirectories: true)
        if !fileManager.fileExists(atPath: queueURL.path) {
            do {
                try Data("[]".utf8).write(to: queueURL, options: .withoutOverwriting)
            } catch {
                // Another Harness process may have created the queue between
                // the existence check and this write. Keep its file.
                guard fileManager.fileExists(atPath: queueURL.path) else { throw error }
            }
        }

        for attempt in 0..<maxCommitAttempts {
            let expected = try ReviewQueueFileCoordinator.read(queueURL: queueURL)
            let queue = try decodeQueue(expected)
            if let index = queue.firstIndex(where: { ($0["id"] as? String) == candidate.id }) {
                let existing = queue[index]
                if NSDictionary(dictionary: existing).isEqual(to: encodedCandidate) {
                    return
                }
                guard sameCanonicalProducer(existing: existing, incoming: encodedCandidate) else {
                    throw ToolExecutorError.staging(
                        "Candidate id \(candidate.id) already exists with different content."
                    )
                }

                // A review may have completed between capture analysis and
                // this replay. Never rewrite a terminal row back to pending or
                // replace Adam's reviewed wording.
                guard existing["status"] as? String == "pending" else { return }
                let existingCaptureIDs = existing["source_capture_ids"] as? [String] ?? []
                let incomingCaptureIDs = encodedCandidate["source_capture_ids"] as? [String] ?? []
                let mergedCaptureIDs = Set(existingCaptureIDs + incomingCaptureIDs).sorted()
                guard mergedCaptureIDs != existingCaptureIDs.sorted() else { return }

                var replacementQueue = queue
                var preserved = existing
                preserved["source_capture_ids"] = mergedCaptureIDs
                replacementQueue[index] = preserved
                let replacement = try JSONSerialization.data(
                    withJSONObject: replacementQueue,
                    options: [.prettyPrinted, .sortedKeys]
                )
                do {
                    guard try ReviewQueueFileCoordinator.compareAndSwap(
                        queueURL: queueURL,
                        expected: expected,
                        replacement: replacement
                    ) else {
                        throw ReviewQueueMemoryStagingError.queueChanged
                    }
                    return
                } catch ReviewQueueMemoryStagingError.queueChanged {
                    if attempt + 1 < maxCommitAttempts { continue }
                    break
                }
            }

            let replacement = try JSONSerialization.data(
                withJSONObject: queue + [encodedCandidate],
                options: [.prettyPrinted, .sortedKeys]
            )
            do {
                guard try ReviewQueueFileCoordinator.compareAndSwap(
                    queueURL: queueURL,
                    expected: expected,
                    replacement: replacement
                ) else {
                    throw ReviewQueueMemoryStagingError.queueChanged
                }
                return
            } catch ReviewQueueMemoryStagingError.queueChanged {
                if attempt + 1 < maxCommitAttempts { continue }
                break
            }
        }
        throw ToolExecutorError.staging(
            "The review queue kept changing while Harness staged a candidate; the proposal was not lost and can be retried."
        )
    }

    private func candidateRow(_ candidate: MemoryCandidate) throws -> [String: Any] {
        guard ReviewQueueCandidateID.isSafe(candidate.id) else {
            throw ToolExecutorError.staging("Candidate id contains unsafe characters.")
        }
        let claim = candidate.proposedClaim.trimmingCharacters(in: .whitespacesAndNewlines)
        let evidence = candidate.evidenceNote.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = candidate.sourceRef.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !claim.isEmpty else {
            throw ToolExecutorError.staging("Candidate claim is empty.")
        }
        guard !evidence.isEmpty, !source.isEmpty else {
            throw ToolExecutorError.staging("Candidate evidence and source are required.")
        }
        let candidateText = [claim, evidence, source].joined(separator: "\n")
        guard SecretRedactor().redact(candidateText) == candidateText else {
            throw ToolExecutorError.staging("Candidate contains credential-shaped text.")
        }

        var row: [String: Any] = [
            "id": candidate.id,
            "status": "pending",
            "plain": claim,
            "evidence": evidence,
            "source": source,
            "domain_a": candidate.domainA ?? "",
            "domain_b": candidate.domainB ?? "",
            "connection_type": candidate.connectionType ?? "memory-note",
        ]
        if let strength = candidate.strength {
            guard (0...1).contains(strength) else {
                throw ToolExecutorError.staging("Candidate strength must be between 0 and 1.")
            }
            row["strength"] = strength
        }
        if let sourceCaptureIDs = candidate.sourceCaptureIDs, !sourceCaptureIDs.isEmpty {
            row["source_capture_ids"] = sourceCaptureIDs
        }
        if let trustedSource = candidate.trustedSource {
            row["trusted_source"] = trustedSource
        }
        if let sourceCapturedAt = candidate.sourceCapturedAt {
            row["source_captured_at"] = sourceCapturedAt.timeIntervalSinceReferenceDate
        }
        if let analyzerVersion = candidate.analyzerVersion {
            row["analyzer_version"] = analyzerVersion
        }
        return row
    }

    private func decodeQueue(_ data: Data) throws -> [[String: Any]] {
        do {
            guard let queue = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                throw ToolExecutorError.staging("queue.json is not a JSON array; refusing to overwrite it")
            }
            return queue
        } catch let error as ToolExecutorError {
            throw error
        } catch {
            throw ToolExecutorError.staging("queue.json is invalid JSON; refusing to overwrite it")
        }
    }

    private func sameCanonicalProducer(
        existing: [String: Any],
        incoming: [String: Any]
    ) -> Bool {
        guard let existingValue = existing["trusted_source"] as? String,
              let incomingValue = incoming["trusted_source"] as? String else { return false }
        let existingSource = existingValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let incomingSource = incomingValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !existingSource.isEmpty, !incomingSource.isEmpty else { return false }
        return SuiteCaptureProvenance.canonicalProducerID(for: existingSource)
            == SuiteCaptureProvenance.canonicalProducerID(for: incomingSource)
    }
}

private enum ReviewQueueMemoryStagingError: Error {
    case queueChanged
}
