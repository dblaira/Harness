import Foundation

public enum SuiteCaptureInboxError: Error, LocalizedError, Sendable, Equatable {
    case sourceChangedBeforeArchive(String)

    public var errorDescription: String? {
        switch self {
        case .sourceChangedBeforeArchive(let path):
            return "Capture changed after Harness retained it, so the newer file was left pending: \(path)"
        }
    }
}

public struct SuiteCaptureInboxSource: Sendable, Equatable {
    public let trustedSource: TrustedSuiteCaptureSource
    public let root: URL

    public init(trustedSource: TrustedSuiteCaptureSource, root: URL) {
        self.trustedSource = trustedSource
        self.root = root
    }
}

public struct SuiteCaptureInboxReport: Sendable, Equatable {
    public let storedCaptureIDs: [String]
    public let duplicateCaptureIDs: [String]
    public let conflictCaptureIDs: [String]
    public let quarantinedCaptureIDs: [String]
    public let archivedFiles: [String]
    public let retainedFiles: [String]
    public let invalidFiles: [String: String]
    public let missingRootPaths: [String]
    public let inaccessibleRootPaths: [String]

    public init(
        storedCaptureIDs: [String] = [],
        duplicateCaptureIDs: [String] = [],
        conflictCaptureIDs: [String] = [],
        quarantinedCaptureIDs: [String] = [],
        archivedFiles: [String] = [],
        retainedFiles: [String] = [],
        invalidFiles: [String: String] = [:],
        missingRootPaths: [String] = [],
        inaccessibleRootPaths: [String] = []
    ) {
        self.storedCaptureIDs = storedCaptureIDs
        self.duplicateCaptureIDs = duplicateCaptureIDs
        self.conflictCaptureIDs = conflictCaptureIDs
        self.quarantinedCaptureIDs = quarantinedCaptureIDs
        self.archivedFiles = archivedFiles
        self.retainedFiles = retainedFiles
        self.invalidFiles = invalidFiles
        self.missingRootPaths = missingRootPaths
        self.inaccessibleRootPaths = inaccessibleRootPaths
    }
}

/// Receives every local suite capture without touching the review queue or the
/// accepted graph. A producer file moves to Archive only after the receipt
/// store has durably retained its bytes. Candidate-shaped files from the old
/// contract are preserved as opaque legacy capture payloads.
public struct LocalSuiteCaptureInboxImporter: @unchecked Sendable {
    private let sources: [SuiteCaptureInboxSource]
    private let receiptStore: SuiteCaptureReceiptStore
    private let fileManager: FileManager
    private let materializeUbiquitousItem: (URL) -> Void
    private let beforeArchive: (URL) -> Void

    public init(
        sources: [SuiteCaptureInboxSource],
        receiptStore: SuiteCaptureReceiptStore,
        fileManager: FileManager = .default
    ) {
        self.sources = sources
        self.receiptStore = receiptStore
        self.fileManager = fileManager
        self.materializeUbiquitousItem = { url in
            try? fileManager.startDownloadingUbiquitousItem(at: url)
        }
        self.beforeArchive = { _ in }
    }

    init(
        sources: [SuiteCaptureInboxSource],
        receiptStore: SuiteCaptureReceiptStore,
        fileManager: FileManager = .default,
        materializeUbiquitousItem: @escaping (URL) -> Void,
        beforeArchive: @escaping (URL) -> Void = { _ in }
    ) {
        self.sources = sources
        self.receiptStore = receiptStore
        self.fileManager = fileManager
        self.materializeUbiquitousItem = materializeUbiquitousItem
        self.beforeArchive = beforeArchive
    }

    public func importAll(now: Date = Date()) async -> SuiteCaptureInboxReport {
        var stored: [String] = []
        var duplicates: [String] = []
        var conflicts: [String] = []
        var quarantined: [String] = []
        var archived: [String] = []
        var retained: [String] = []
        var invalid: [String: String] = [:]
        var missingRoots: [String] = []
        var inaccessibleRoots: [String] = []

        for source in sources {
            guard fileManager.fileExists(atPath: source.root.path) else {
                missingRoots.append(source.root.path)
                continue
            }
            do {
                _ = try fileManager.contentsOfDirectory(
                    at: source.root,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles]
                )
            } catch {
                inaccessibleRoots.append(source.root.path)
                continue
            }

            for file in captureFiles(in: source.root) {
                let key = file.path
                do {
                    let data = try Data(contentsOf: file)
                    let disposition: SuiteCaptureIngestDisposition
                    do {
                        disposition = try await receiptStore.ingest(
                            data: data,
                            from: source.trustedSource,
                            now: now
                        )
                    } catch {
                        guard Self.looksLikeLegacyCandidate(data) else { throw error }
                        let values = try? file.resourceValues(forKeys: [.contentModificationDateKey])
                        disposition = try await receiptStore.ingestLegacyCandidate(
                            data: data,
                            from: source.trustedSource,
                            capturedAt: values?.contentModificationDate ?? now,
                            now: now
                        )
                    }

                    let receipt = disposition.receipt
                    switch disposition {
                    case .stored:
                        stored.append(receipt.capture.captureID)
                    case .duplicate:
                        duplicates.append(receipt.capture.captureID)
                    case .conflict:
                        conflicts.append(receipt.capture.captureID)
                    }
                    if receipt.state == .quarantined {
                        quarantined.append(receipt.capture.captureID)
                    }
                    do {
                        beforeArchive(file)
                        try archive(file: file, under: source.root, expectedData: data)
                        archived.append(file.lastPathComponent)
                    } catch {
                        invalid[key] = (error as? LocalizedError)?.errorDescription
                            ?? error.localizedDescription
                        retained.append(file.lastPathComponent)
                    }
                } catch {
                    invalid[key] = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    retained.append(file.lastPathComponent)
                }
            }
        }

        return SuiteCaptureInboxReport(
            storedCaptureIDs: stored,
            duplicateCaptureIDs: duplicates,
            conflictCaptureIDs: conflicts,
            quarantinedCaptureIDs: quarantined,
            archivedFiles: archived,
            retainedFiles: retained,
            invalidFiles: invalid,
            missingRootPaths: missingRoots,
            inaccessibleRootPaths: inaccessibleRoots
        )
    }

    private func captureFiles(in root: URL) -> [URL] {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [
                .isDirectoryKey,
                .isRegularFileKey,
                .ubiquitousItemDownloadingStatusKey,
            ],
            options: [.skipsPackageDescendants]
        ) else { return [] }

        var files: [URL] = []
        for case let file as URL in enumerator {
            let components = file.pathComponents.map { $0.lowercased() }
            let values = try? file.resourceValues(forKeys: [
                .isDirectoryKey,
                .isRegularFileKey,
                .ubiquitousItemDownloadingStatusKey,
            ])
            if components.contains("archive") || components.contains("rejected") {
                if values?.isDirectory == true { enumerator.skipDescendants() }
                continue
            }
            if file.pathExtension.lowercased() == "icloud"
                || values?.ubiquitousItemDownloadingStatus == .notDownloaded {
                materializeUbiquitousItem(file)
                continue
            }
            if file.lastPathComponent.hasPrefix(".") {
                if values?.isDirectory == true { enumerator.skipDescendants() }
                continue
            }
            guard file.pathExtension.lowercased() == "json",
                  values?.isRegularFile == true else { continue }
            files.append(file)
        }
        return files.sorted { $0.path < $1.path }
    }

    private func archive(file: URL, under root: URL, expectedData: Data) throws {
        let directory = root.appendingPathComponent("Archive", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var archiveResult: Result<Void, Error>?
        coordinator.coordinate(
            writingItemAt: file,
            options: .forMoving,
            error: &coordinationError
        ) { coordinatedFile in
            archiveResult = Result {
                guard try Data(contentsOf: coordinatedFile) == expectedData else {
                    throw SuiteCaptureInboxError.sourceChangedBeforeArchive(file.path)
                }
                var destination = directory.appendingPathComponent(file.lastPathComponent)
                if fileManager.fileExists(atPath: destination.path) {
                    let stem = file.deletingPathExtension().lastPathComponent
                    let ext = file.pathExtension
                    var suffix = 2
                    repeat {
                        destination = directory.appendingPathComponent(
                            ext.isEmpty ? "\(stem)-\(suffix)" : "\(stem)-\(suffix).\(ext)"
                        )
                        suffix += 1
                    } while fileManager.fileExists(atPath: destination.path)
                }
                try fileManager.moveItem(at: coordinatedFile, to: destination)
            }
        }
        if let coordinationError { throw coordinationError }
        guard let archiveResult else { throw CocoaError(.fileWriteUnknown) }
        try archiveResult.get()
    }

    private static func looksLikeLegacyCandidate(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        let fields = Set(object.keys)
        return fields.isSuperset(of: ["id", "plain", "evidence", "status"])
    }
}
