import CryptoKit
import Foundation

/// Identity is assigned by Harness configuration (the watched inbox or the
/// authenticated bridge), never trusted from the capture payload itself.
public struct TrustedSuiteCaptureSource: Sendable, Equatable {
    public let id: String
    public let displayName: String

    public init(id: String, displayName: String) {
        self.id = id
        self.displayName = displayName
    }
}

public enum SuiteCaptureProvenance {
    /// Multiple trusted transports may belong to one producer during legacy
    /// recovery. Collapse only those explicitly named transports; never infer
    /// producer identity from a payload-controlled source_app field.
    public static func canonicalProducerID(for trustedSourceID: String) -> String {
        switch trustedSourceID {
        case "news-calm", "news-calm-legacy", "news-calm-legacy-queue":
            return "news-calm"
        case "recall", "recall-legacy", "recall-legacy-queue":
            return "recall"
        case "understood", "understood-legacy", "understood-legacy-queue":
            return "understood"
        default:
            return trustedSourceID
        }
    }
}

/// The neutral handoff contract for suite apps. It contains what happened,
/// not a candidate/no-candidate decision and not ontology interpretation.
public struct SuiteCaptureEnvelope: Codable, Sendable, Equatable {
    public let schemaVersion: String
    public let captureID: String
    public let sourceRecordID: String?
    /// Descriptive producer label only. Harness derives trusted identity from
    /// the configured inbox or authenticated bridge instead of this value.
    public let sourceApp: String?
    public let capturedAt: String
    public let captureKind: String
    public let payload: JSONValue
    public let artifactRefs: [String]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case captureID = "capture_id"
        case sourceRecordID = "source_record_id"
        case sourceApp = "source_app"
        case capturedAt = "captured_at"
        case captureKind = "capture_kind"
        case legacyKind = "kind"
        case payload
        case artifactRefs = "artifact_refs"
    }

    public init(
        schemaVersion: String = "suite_capture.v1",
        captureID: String,
        sourceRecordID: String? = nil,
        sourceApp: String? = nil,
        capturedAt: String,
        captureKind: String,
        payload: JSONValue,
        artifactRefs: [String] = []
    ) {
        self.schemaVersion = schemaVersion
        self.captureID = captureID
        self.sourceRecordID = sourceRecordID
        self.sourceApp = sourceApp
        self.capturedAt = capturedAt
        self.captureKind = captureKind
        self.payload = payload
        self.artifactRefs = artifactRefs
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let version = try? container.decode(String.self, forKey: .schemaVersion) {
            schemaVersion = version
        } else if (try? container.decode(Int.self, forKey: .schemaVersion)) == 1 {
            schemaVersion = "suite_capture.v1"
        } else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: container,
                debugDescription: "Unsupported capture schema version"
            )
        }
        captureID = try container.decode(String.self, forKey: .captureID)
        sourceRecordID = try container.decodeIfPresent(String.self, forKey: .sourceRecordID)
        sourceApp = try container.decodeIfPresent(String.self, forKey: .sourceApp)
        capturedAt = try container.decode(String.self, forKey: .capturedAt)
        captureKind = try container.decodeIfPresent(String.self, forKey: .captureKind)
            ?? container.decode(String.self, forKey: .legacyKind)
        payload = try container.decode(JSONValue.self, forKey: .payload)
        artifactRefs = try container.decodeIfPresent([String].self, forKey: .artifactRefs) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(captureID, forKey: .captureID)
        try container.encodeIfPresent(sourceRecordID, forKey: .sourceRecordID)
        try container.encodeIfPresent(sourceApp, forKey: .sourceApp)
        try container.encode(capturedAt, forKey: .capturedAt)
        try container.encode(captureKind, forKey: .captureKind)
        try container.encode(payload, forKey: .payload)
        if !artifactRefs.isEmpty {
            try container.encode(artifactRefs, forKey: .artifactRefs)
        }
    }
}

public enum SuiteCaptureReceiptState: String, Codable, Sendable, Equatable {
    case analysisPending = "analysis_pending"
    case notCandidate = "not_candidate"
    case candidateQueued = "candidate_queued"
    case candidateAccepted = "candidate_accepted"
    case candidateRejected = "candidate_rejected"
    case analysisFailed = "analysis_failed"
    case quarantined
    case conflict
}

/// Durable receipt written before any model call or review-queue mutation.
/// The exact received bytes live next to this record at `rawCapturePath`.
public struct SuiteCaptureReceipt: Codable, Sendable, Equatable, Identifiable {
    public var id: String { "\(trustedSourceID):\(capture.captureID):\(rawSHA256)" }
    public let trustedSourceID: String
    public let trustedSourceName: String
    public let capture: SuiteCaptureEnvelope
    public let rawSHA256: String
    public let rawCapturePath: String
    public let receivedAt: String
    public var updatedAt: String
    public var state: SuiteCaptureReceiptState
    public var analysisRunID: String?
    public var candidateIDs: [String]
    public var analysisDetail: String?
    public var analysisAttempts: Int
    public var conflictOfReceiptPath: String?

    public init(
        trustedSourceID: String,
        trustedSourceName: String,
        capture: SuiteCaptureEnvelope,
        rawSHA256: String,
        rawCapturePath: String,
        receivedAt: String,
        updatedAt: String,
        state: SuiteCaptureReceiptState,
        analysisRunID: String? = nil,
        candidateIDs: [String] = [],
        analysisDetail: String? = nil,
        analysisAttempts: Int = 0,
        conflictOfReceiptPath: String? = nil
    ) {
        self.trustedSourceID = trustedSourceID
        self.trustedSourceName = trustedSourceName
        self.capture = capture
        self.rawSHA256 = rawSHA256
        self.rawCapturePath = rawCapturePath
        self.receivedAt = receivedAt
        self.updatedAt = updatedAt
        self.state = state
        self.analysisRunID = analysisRunID
        self.candidateIDs = candidateIDs
        self.analysisDetail = analysisDetail
        self.analysisAttempts = analysisAttempts
        self.conflictOfReceiptPath = conflictOfReceiptPath
    }
}

public struct SuiteCaptureReceiptInventory: Sendable, Equatable {
    public let receipts: [SuiteCaptureReceipt]
    public let corruptReceiptPaths: [String]

    public init(
        receipts: [SuiteCaptureReceipt],
        corruptReceiptPaths: [String]
    ) {
        self.receipts = receipts
        self.corruptReceiptPaths = corruptReceiptPaths
    }
}

public enum SuiteCaptureIngestDisposition: Sendable, Equatable {
    case stored(SuiteCaptureReceipt)
    case duplicate(SuiteCaptureReceipt)
    case conflict(SuiteCaptureReceipt)

    public var receipt: SuiteCaptureReceipt {
        switch self {
        case .stored(let receipt), .duplicate(let receipt), .conflict(let receipt):
            return receipt
        }
    }
}

public enum SuiteCaptureError: Error, LocalizedError, Sendable, Equatable {
    case invalidSourceID
    case tooLarge
    case invalidJSON
    case unsupportedFields([String])
    case missingFields([String])
    case invalidField(String)
    case receiptMissing(String)

    public var errorDescription: String? {
        switch self {
        case .invalidSourceID:
            return "Trusted capture source id is invalid."
        case .tooLarge:
            return "Capture exceeds Harness's maximum receipt size."
        case .invalidJSON:
            return "Capture must contain one valid JSON object."
        case .unsupportedFields(let fields):
            return "Capture contains unsupported fields: \(fields.joined(separator: ", "))."
        case .missingFields(let fields):
            return "Capture is missing fields: \(fields.joined(separator: ", "))."
        case .invalidField(let detail):
            return detail
        case .receiptMissing(let path):
            return "Capture receipt is missing: \(path)"
        }
    }
}

/// Local-first receipt store. Ingestion builds the raw bytes and metadata in a
/// staging directory and atomically moves that complete directory into place.
/// A source file or remote bridge can be archived/acknowledged only after this
/// method returns.
public actor SuiteCaptureReceiptStore {
    public static let maximumRawCaptureBytes = 2_097_152

    private static let requiredFields: Set<String> = [
        "schema_version", "capture_id", "captured_at", "payload",
    ]
    private static let optionalFields: Set<String> = [
        "source_record_id", "source_app", "capture_kind", "kind", "artifact_refs",
    ]

    private let root: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(root: URL, fileManager: FileManager = .default) {
        self.root = root
        self.fileManager = fileManager
        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.decoder = JSONDecoder()
    }

    public static func applicationDefaultRoot(
        fileManager: FileManager = .default
    ) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base
            .appendingPathComponent("Harness", isDirectory: true)
            .appendingPathComponent("Capture Receipts", isDirectory: true)
    }

    public func ingest(
        data: Data,
        from source: TrustedSuiteCaptureSource,
        now: Date = Date()
    ) throws -> SuiteCaptureIngestDisposition {
        guard Self.isSafePathComponent(source.id) else {
            throw SuiteCaptureError.invalidSourceID
        }
        guard data.count <= Self.maximumRawCaptureBytes else {
            throw SuiteCaptureError.tooLarge
        }
        let capture = try Self.decodeAndValidate(data)
        return try ingestValidated(data: data, capture: capture, from: source, now: now)
    }

    /// Migration seam for the candidate-shaped files emitted before the
    /// capture boundary was corrected. Their exact bytes are retained as the
    /// raw artifact; every former candidate field is merely payload data.
    public func ingestLegacyCandidate(
        data: Data,
        from source: TrustedSuiteCaptureSource,
        capturedAt: Date,
        now: Date = Date()
    ) throws -> SuiteCaptureIngestDisposition {
        guard Self.isSafePathComponent(source.id) else {
            throw SuiteCaptureError.invalidSourceID
        }
        guard data.count <= Self.maximumRawCaptureBytes else {
            throw SuiteCaptureError.tooLarge
        }
        let payload: JSONValue
        do {
            payload = try JSONDecoder().decode(JSONValue.self, from: data)
        } catch {
            throw SuiteCaptureError.invalidJSON
        }
        guard case .object(let object) = payload,
              let legacyID = object["id"]?.stringValue,
              object["plain"] != nil || object["evidence"] != nil else {
            throw SuiteCaptureError.invalidJSON
        }
        let hash = Self.sha256Hex(data)
        let capture = SuiteCaptureEnvelope(
            captureID: "capture-legacy-\(hash.prefix(24))",
            sourceRecordID: legacyID,
            sourceApp: source.displayName,
            capturedAt: Self.timestamp(capturedAt),
            captureKind: "legacy_candidate_envelope",
            payload: payload
        )
        return try ingestValidated(data: data, capture: capture, from: source, now: now)
    }

    public func listReceipts() throws -> [SuiteCaptureReceipt] {
        try inspectReceipts().receipts
    }

    /// Corrupt metadata must not make already-acknowledged raw bytes vanish
    /// from Capture History. Return a quarantined in-memory placeholder next
    /// to an explicit issue path; never repair or overwrite the evidence here.
    public func inspectReceipts() throws -> SuiteCaptureReceiptInventory {
        guard fileManager.fileExists(atPath: root.path) else {
            return SuiteCaptureReceiptInventory(receipts: [], corruptReceiptPaths: [])
        }
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return SuiteCaptureReceiptInventory(receipts: [], corruptReceiptPaths: []) }
        var receipts: [SuiteCaptureReceipt] = []
        var corruptReceiptPaths: [String] = []
        for case let file as URL in enumerator where file.lastPathComponent == "receipt.json" {
            do {
                let receipt = try loadReceipt(at: file)
                receipts.append(receipt)
            } catch {
                corruptReceiptPaths.append(file.path)
                receipts.append(syntheticCorruptReceipt(for: file))
            }
        }
        let sorted = receipts.sorted {
            if $0.receivedAt == $1.receivedAt { return $0.id < $1.id }
            return $0.receivedAt > $1.receivedAt
        }
        return SuiteCaptureReceiptInventory(
            receipts: sorted,
            corruptReceiptPaths: corruptReceiptPaths.sorted()
        )
    }

    private func ingestValidated(
        data: Data,
        capture: SuiteCaptureEnvelope,
        from source: TrustedSuiteCaptureSource,
        now: Date
    ) throws -> SuiteCaptureIngestDisposition {
        let hash = Self.sha256Hex(data)
        let sourceDirectory = root.appendingPathComponent(source.id, isDirectory: true)
        let primaryDirectory = sourceDirectory.appendingPathComponent(capture.captureID, isDirectory: true)
        try fileManager.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)

        if fileManager.fileExists(atPath: primaryDirectory.path) {
            let existing = try loadReceipt(in: primaryDirectory)
            if existing.rawSHA256 == hash {
                return .duplicate(existing)
            }
            let conflictDirectory = sourceDirectory.appendingPathComponent(
                "\(capture.captureID)-conflict-\(hash.prefix(12))",
                isDirectory: true
            )
            if fileManager.fileExists(atPath: conflictDirectory.path) {
                return .conflict(try loadReceipt(in: conflictDirectory))
            }
            let receipt = try writeCompleteReceipt(
                data: data,
                capture: capture,
                hash: hash,
                source: source,
                destination: conflictDirectory,
                state: .conflict,
                detail: "The same trusted source and capture id arrived with different bytes; both versions were preserved.",
                conflictOfReceiptPath: receiptURL(in: primaryDirectory).path,
                now: now
            )
            return .conflict(receipt)
        }

        let rawText = String(data: data, encoding: .utf8) ?? ""
        let containsCredential = SecretRedactor().redact(rawText) != rawText
            || Self.containsCredential(in: capture)
        let receipt = try writeCompleteReceipt(
            data: data,
            capture: capture,
            hash: hash,
            source: source,
            destination: primaryDirectory,
            state: containsCredential ? .quarantined : .analysisPending,
            detail: containsCredential
                ? "Credential-shaped text was preserved locally but withheld from model analysis."
                : nil,
            conflictOfReceiptPath: nil,
            now: now
        )
        return .stored(receipt)
    }

    public func recordAnalysis(
        for receipt: SuiteCaptureReceipt,
        state: SuiteCaptureReceiptState,
        runID: String?,
        candidateIDs: [String] = [],
        detail: String,
        now: Date = Date()
    ) throws -> SuiteCaptureReceipt {
        guard [.notCandidate, .candidateQueued, .analysisFailed].contains(state) else {
            throw SuiteCaptureError.invalidField("Analysis may record only a candidate, no-candidate, or failed outcome.")
        }
        var updated = try loadReceipt(at: receiptURL(for: receipt))
        if updated.state == state,
           state != .analysisFailed,
           updated.analysisRunID == runID,
           updated.candidateIDs == candidateIDs,
           updated.analysisDetail == detail {
            return updated
        }
        guard updated.state == .analysisPending || updated.state == .analysisFailed else {
            throw SuiteCaptureError.invalidField(
                "Capture analysis cannot replace existing state \(updated.state.rawValue)."
            )
        }
        updated.state = state
        updated.analysisRunID = runID
        updated.candidateIDs = candidateIDs
        updated.analysisDetail = detail
        updated.analysisAttempts += 1
        updated.updatedAt = Self.timestamp(now)
        try encoder.encode(updated).write(to: receiptURL(for: updated), options: .atomic)
        return updated
    }

    /// Bind a pending receipt to a queue row that already represents the same
    /// producer record. This closes the crash window where the queue append
    /// succeeded but receipt metadata had not yet been written.
    public func recordExistingReviewClaim(
        for receipt: SuiteCaptureReceipt,
        candidateID: String,
        status: ReviewQueueClaimStatus,
        detail: String,
        now: Date = Date()
    ) throws -> SuiteCaptureReceipt {
        var updated = try loadReceipt(at: receiptURL(for: receipt))
        let targetState: SuiteCaptureReceiptState
        switch status {
        case .pending: targetState = .candidateQueued
        case .accepted: targetState = .candidateAccepted
        case .rejected: targetState = .candidateRejected
        }
        if updated.state == targetState, updated.candidateIDs.contains(candidateID) {
            return updated
        }
        guard updated.state == .analysisPending || updated.state == .analysisFailed else {
            throw SuiteCaptureError.invalidField(
                "Existing review claim cannot replace receipt state \(updated.state.rawValue)."
            )
        }
        updated.state = targetState
        updated.analysisRunID = nil
        updated.candidateIDs = [candidateID]
        updated.analysisDetail = detail
        updated.updatedAt = Self.timestamp(now)
        try encoder.encode(updated).write(to: receiptURL(for: updated), options: .atomic)
        return updated
    }

    /// Record the outcome of Adam's Harness review on every raw capture that
    /// contributed to the proposal. This is receipt metadata only: accepted
    /// graph authority continues to be written exclusively by ReviewQueueStore.
    public func recordReviewOutcome(
        candidateID: String,
        accepted: Bool,
        detail: String,
        now: Date = Date()
    ) throws -> [SuiteCaptureReceipt] {
        try updateReviewOutcome(
            candidateID: candidateID,
            state: accepted ? .candidateAccepted : .candidateRejected,
            detail: detail,
            now: now
        )
    }

    /// Reconciles receipts created before outcome tracking existed. The queue
    /// remains the source of truth; this method only mirrors a terminal status
    /// onto retained receipt metadata.
    public func reconcileReviewStatuses(
        _ statuses: [String: ReviewQueueClaimStatus],
        now: Date = Date()
    ) throws -> [SuiteCaptureReceipt] {
        for (candidateID, status) in statuses {
            switch status {
            case .accepted:
                _ = try updateReviewOutcome(
                    candidateID: candidateID,
                    state: .candidateAccepted,
                    detail: "Adam accepted this Harness proposal.",
                    now: now
                )
            case .rejected:
                _ = try updateReviewOutcome(
                    candidateID: candidateID,
                    state: .candidateRejected,
                    detail: "Adam did not adopt this Harness proposal.",
                    now: now
                )
            case .pending:
                continue
            }
        }
        return try listReceipts()
    }

    public func loadReceipt(sourceID: String, captureID: String) throws -> SuiteCaptureReceipt {
        let directory = root
            .appendingPathComponent(sourceID, isDirectory: true)
            .appendingPathComponent(captureID, isDirectory: true)
        return try loadReceipt(in: directory)
    }

    private func updateReviewOutcome(
        candidateID: String,
        state: SuiteCaptureReceiptState,
        detail: String,
        now: Date
    ) throws -> [SuiteCaptureReceipt] {
        guard [.candidateAccepted, .candidateRejected].contains(state) else {
            throw SuiteCaptureError.invalidField("Review outcome must be accepted or rejected.")
        }
        var updatedReceipts: [SuiteCaptureReceipt] = []
        for receipt in try listReceipts() where receipt.candidateIDs.contains(candidateID) {
            guard receipt.state == .candidateQueued else { continue }
            var updated = try loadReceipt(at: receiptURL(for: receipt))
            updated.state = state
            updated.analysisDetail = detail
            updated.updatedAt = Self.timestamp(now)
            try encoder.encode(updated).write(to: receiptURL(for: updated), options: .atomic)
            updatedReceipts.append(updated)
        }
        return updatedReceipts
    }

    private func writeCompleteReceipt(
        data: Data,
        capture: SuiteCaptureEnvelope,
        hash: String,
        source: TrustedSuiteCaptureSource,
        destination: URL,
        state: SuiteCaptureReceiptState,
        detail: String?,
        conflictOfReceiptPath: String?,
        now: Date
    ) throws -> SuiteCaptureReceipt {
        let staging = destination.deletingLastPathComponent()
            .appendingPathComponent(".receipt-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: staging) }

        let finalRawURL = destination.appendingPathComponent("raw-capture.json")
        let receipt = SuiteCaptureReceipt(
            trustedSourceID: source.id,
            trustedSourceName: source.displayName,
            capture: capture,
            rawSHA256: hash,
            rawCapturePath: finalRawURL.path,
            receivedAt: Self.timestamp(now),
            updatedAt: Self.timestamp(now),
            state: state,
            analysisDetail: detail,
            conflictOfReceiptPath: conflictOfReceiptPath
        )
        try data.write(to: staging.appendingPathComponent("raw-capture.json"), options: .atomic)
        try encoder.encode(receipt).write(
            to: staging.appendingPathComponent("receipt.json"),
            options: .atomic
        )
        try fileManager.moveItem(at: staging, to: destination)
        return receipt
    }

    private func loadReceipt(in directory: URL) throws -> SuiteCaptureReceipt {
        try loadReceipt(at: receiptURL(in: directory))
    }

    private func loadReceipt(at url: URL) throws -> SuiteCaptureReceipt {
        guard fileManager.fileExists(atPath: url.path) else {
            throw SuiteCaptureError.receiptMissing(url.path)
        }
        return try decoder.decode(SuiteCaptureReceipt.self, from: Data(contentsOf: url))
    }

    private func syntheticCorruptReceipt(for receiptURL: URL) -> SuiteCaptureReceipt {
        let directory = receiptURL.deletingLastPathComponent()
        let rawURL = directory.appendingPathComponent("raw-capture.json")
        let rawData = (try? Data(contentsOf: rawURL)) ?? Data()
        let hash = Self.sha256Hex(rawData)
        let sourceID = directory
            .pathComponents
            .dropFirst(root.pathComponents.count)
            .first ?? "unknown-source"
        let directoryCaptureID = directory.lastPathComponent
        let fallbackID = Self.isSafePathComponent(
            directoryCaptureID,
            requiredPrefixes: ["capture-", "cap-"]
        ) ? directoryCaptureID : "capture-corrupt-\(hash.prefix(24))"
        let capture = (try? Self.decodeAndValidate(rawData)) ?? SuiteCaptureEnvelope(
            captureID: fallbackID,
            sourceApp: sourceID,
            capturedAt: Self.timestamp(
                (try? rawURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                    ?? Date(timeIntervalSince1970: 0)
            ),
            captureKind: "corrupt_receipt_metadata",
            payload: (try? JSONDecoder().decode(JSONValue.self, from: rawData))
                ?? .object(["receipt_path": .string(receiptURL.path)])
        )
        let timestamp = Self.timestamp(
            (try? receiptURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                ?? Date(timeIntervalSince1970: 0)
        )
        return SuiteCaptureReceipt(
            trustedSourceID: sourceID,
            trustedSourceName: sourceID,
            capture: capture,
            rawSHA256: hash,
            rawCapturePath: fileManager.fileExists(atPath: rawURL.path) ? rawURL.path : receiptURL.path,
            receivedAt: timestamp,
            updatedAt: timestamp,
            state: .quarantined,
            analysisDetail: "Receipt metadata is unreadable. Raw evidence remains retained locally and withheld from analysis."
        )
    }

    private func receiptURL(for receipt: SuiteCaptureReceipt) -> URL {
        URL(fileURLWithPath: receipt.rawCapturePath)
            .deletingLastPathComponent()
            .appendingPathComponent("receipt.json")
    }

    private func receiptURL(in directory: URL) -> URL {
        directory.appendingPathComponent("receipt.json")
    }

    private static func decodeAndValidate(_ data: Data) throws -> SuiteCaptureEnvelope {
        let object: [String: Any]
        do {
            guard let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw SuiteCaptureError.invalidJSON
            }
            object = decoded
        } catch let error as SuiteCaptureError {
            throw error
        } catch {
            throw SuiteCaptureError.invalidJSON
        }

        let fields = Set(object.keys)
        let missing = requiredFields.subtracting(fields).sorted()
        let unsupported = fields.subtracting(requiredFields).subtracting(optionalFields).sorted()
        guard missing.isEmpty else { throw SuiteCaptureError.missingFields(missing) }
        guard unsupported.isEmpty else { throw SuiteCaptureError.unsupportedFields(unsupported) }

        let envelope: SuiteCaptureEnvelope
        do {
            envelope = try JSONDecoder().decode(SuiteCaptureEnvelope.self, from: data)
        } catch {
            throw SuiteCaptureError.invalidField("Capture fields have invalid types.")
        }
        guard fields.contains("capture_kind") || fields.contains("kind") else {
            throw SuiteCaptureError.missingFields(["capture_kind"])
        }
        guard envelope.schemaVersion == "suite_capture.v1" else {
            throw SuiteCaptureError.invalidField("Capture schema_version must be suite_capture.v1.")
        }
        guard isSafePathComponent(envelope.captureID, requiredPrefixes: ["capture-", "cap-"]) else {
            throw SuiteCaptureError.invalidField(
                "capture_id must use lowercase ASCII letters, digits, periods, underscores, or hyphens and start with capture-."
            )
        }
        guard !envelope.captureKind.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              envelope.captureKind.utf8.count <= 120 else {
            throw SuiteCaptureError.invalidField("Capture kind must be non-empty text of at most 120 bytes.")
        }
        guard parseTimestamp(envelope.capturedAt) != nil else {
            throw SuiteCaptureError.invalidField("captured_at must be an ISO-8601 timestamp.")
        }
        guard envelope.artifactRefs.count <= 20,
              envelope.artifactRefs.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 2_048 }) else {
            throw SuiteCaptureError.invalidField("artifact_refs may contain at most 20 non-empty references.")
        }
        if let sourceRecordID = envelope.sourceRecordID,
           sourceRecordID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw SuiteCaptureError.invalidField("source_record_id cannot be empty when present.")
        }
        return envelope
    }

    private static func isSafePathComponent(
        _ value: String,
        requiredPrefixes: [String] = []
    ) -> Bool {
        guard value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              (1...160).contains(value.utf8.count),
              requiredPrefixes.isEmpty || requiredPrefixes.contains(where: value.hasPrefix)
        else { return false }
        return value.utf8.allSatisfy { byte in
            (97...122).contains(byte)
                || (48...57).contains(byte)
                || byte == 45
                || byte == 46
                || byte == 95
        }
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Inspect the decoded JSON tree as well as the original bytes. JSON key
    /// quoting, Unicode escapes, or a non-UTF-8 JSON encoding must not let a
    /// credential-shaped field reach a model prompt.
    private static func containsCredential(in capture: SuiteCaptureEnvelope) -> Bool {
        let decodedText = [
            capture.sourceRecordID,
            capture.sourceApp,
            capture.captureKind,
            capture.artifactRefs.joined(separator: "\n"),
            capture.payload.jsonString,
        ].compactMap { $0 }.joined(separator: "\n")
        return SecretRedactor().redact(decodedText) != decodedText
            || containsCredential(in: capture.payload)
    }

    private static func containsCredential(in value: JSONValue) -> Bool {
        switch value {
        case .null, .bool, .number:
            return false
        case .string(let text):
            return SecretRedactor().redact(text) != text
        case .array(let values):
            return values.contains(where: containsCredential)
        case .object(let object):
            return object.contains { key, nested in
                isSensitiveKey(key) || containsCredential(in: nested)
            }
        }
    }

    private static func isSensitiveKey(_ key: String) -> Bool {
        let normalized = key
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
        let exact: Set<String> = [
            "api_key", "apikey", "token", "access_token", "refresh_token",
            "auth_token", "bearer_token", "id_token", "secret",
            "client_secret", "password", "passwd", "authorization",
            "credential", "credentials", "private_key", "access_key",
            "access_key_id", "secret_access_key",
        ]
        return exact.contains(normalized)
            || normalized.hasSuffix("_token")
            || normalized.hasSuffix("_secret")
            || normalized.hasSuffix("_password")
            || normalized.hasSuffix("_credential")
            || normalized.hasSuffix("_credentials")
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    private static func parseTimestamp(_ value: String) -> Date? {
        let standard = ISO8601DateFormatter()
        if let date = standard.date(from: value) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value)
    }
}
