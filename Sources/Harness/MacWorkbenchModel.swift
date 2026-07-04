#if os(macOS)
import AppKit
import Foundation
import OntologyKit
import UniformTypeIdentifiers

@MainActor
final class MacWorkbenchModel: ObservableObject {
    @Published var ontology: Ontology = .empty
    @Published var runs: [HarnessRun] = []
    @Published var selectedDetail: HarnessRunDetail?
    @Published var draft = "" {
        didSet { refreshRoutePlan() }
    }
    @Published var backend: Backend = .codex
    @Published var apiKey = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] ?? ""
    @Published var firecrawlAPIKey = ""
    @Published var hasFirecrawlAPIKey = false
    @Published var isRunning = false
    @Published var status = "Ledger ready"
    @Published var searchText = ""
    @Published var selectedTool: WorkbenchTool?
    @Published var reviewQueueCandidates: [MemoryCandidate] = []
    @Published var opportunityBoardRows: [OpportunityBoardRow] = []
    @Published var opportunityBoardLoadIssue: String?
    @Published var connectors: [HarnessConnector] = HarnessConnectorRegistry.defaultConnectors()
    @Published var capabilities: [HarnessCapability] = HarnessCapabilityRegistry.defaultCapabilities()
    @Published var routePlan = HarnessExecutionRoutePlan(prompt: "", steps: [])
    @Published var routeExecutionResult: HarnessRouteExecutionResult?
    let toolGroups = WorkbenchToolGroup.defaults

    private let ledger: RunLedgerStore
    private let service: HarnessRunService
    private let reviewQueue: ReviewQueueStore

    init() {
        let store: RunLedgerStore
        do {
            store = try RunLedgerStore.applicationDefault()
        } catch {
            store = try! RunLedgerStore.inMemory()
        }
        self.ledger = store
        self.service = HarnessRunService(ledger: store)
        self.reviewQueue = ReviewQueueStore(ledger: store)
        self.hasFirecrawlAPIKey = Self.loadFirecrawlAPIKey() != nil
        Task {
            await refreshRuns()
            await refreshReviewQueue()
            refreshOpportunityBoard()
            refreshConnectors()
        }
    }

    func updateOntology(_ ontology: Ontology) {
        self.ontology = ontology
    }

    func refreshRuns() async {
        do {
            runs = try await ledger.listRuns()
            if selectedDetail == nil, let first = runs.first {
                selectedDetail = try await ledger.runDetail(id: first.id)
            }
        } catch {
            status = error.localizedDescription
        }
    }

    func searchRuns() async {
        do {
            runs = try await ledger.searchRuns(searchText)
        } catch {
            status = error.localizedDescription
        }
    }

    func selectRun(_ run: HarnessRun) async {
        do {
            selectedDetail = try await ledger.runDetail(id: run.id)
        } catch {
            status = error.localizedDescription
        }
    }

    func newSession() {
        selectedDetail = nil
        draft = ""
        searchText = ""
        status = "New session"
    }

    func selectTool(_ tool: WorkbenchTool) {
        selectedTool = tool
        status = "\(tool.title): \(tool.state.rawValue)"
    }

    func refreshReviewQueue() async {
        do {
            reviewQueueCandidates = try await reviewQueue.loadPendingClaims()
            status = "\(reviewQueueCandidates.count) candidate\(reviewQueueCandidates.count == 1 ? "" : "s") waiting"
        } catch {
            reviewQueueCandidates = []
            status = "Candidates unavailable: \(error.localizedDescription)"
        }
    }

    func refreshOpportunityBoard() {
        do {
            opportunityBoardRows = try Self.loadOpportunityBoardRows(from: Self.defaultOpportunityBoardDirectory())
            opportunityBoardLoadIssue = nil
        } catch {
            opportunityBoardRows = []
            opportunityBoardLoadIssue = error.localizedDescription
        }
    }

    nonisolated static func defaultOpportunityBoardDirectory() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent("Harness", isDirectory: true)
            .appendingPathComponent("Opportunities", isDirectory: true)
    }

    nonisolated static func loadOpportunityBoardRows(
        from directory: URL,
        fileManager: FileManager = .default
    ) throws -> [OpportunityBoardRow] {
        guard fileManager.fileExists(atPath: directory.path) else {
            return []
        }
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }

        let parser = OpportunityCardParser()
        let validator = OpportunityCardValidator()
        var cards: [OpportunityCard] = []

        for case let file as URL in enumerator {
            guard file.pathExtension.lowercased() == "md" else { continue }
            guard (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            let markdown = try String(contentsOf: file, encoding: .utf8)
            guard case let .opportunity(card) = try? parser.parse(markdown: markdown, source: file.path),
                  validator.validate(card).passed
            else { continue }
            cards.append(card)
        }

        return OpportunityBoardDeduper().deduplicate(cards)
    }

    func recordOpportunityBoardAction(_ action: OpportunityBoardAction, rows: [OpportunityBoardRow]) {
        let records = Self.opportunityBoardActionRecords(action: action, rows: rows)
        guard !records.isEmpty else { return }

        let ledger = ledger
        Task { [weak self] in
            do {
                try await ledger.recordOpportunityBoardActions(records)
                await MainActor.run {
                    self?.status = "\(action.label) recorded for \(records.count) opportunity row\(records.count == 1 ? "" : "s")."
                }
            } catch {
                await MainActor.run {
                    self?.status = "\(action.label) failed: \(error.localizedDescription)"
                }
            }
        }
    }

    nonisolated static func opportunityBoardActionRecords(
        action: OpportunityBoardAction,
        rows: [OpportunityBoardRow],
        batchID: String = UUID().uuidString,
        createdAt: Date = Date()
    ) -> [OpportunityBoardActionRecord] {
        rows.map { row in
            OpportunityBoardActionRecord(
                batchID: batchID,
                opportunityID: row.id,
                canonicalResource: row.canonicalResource,
                action: action,
                createdAt: createdAt
            )
        }
    }

    func refreshConnectors() {
        connectors = HarnessConnectorRegistry.defaultConnectors(environment: Self.connectorEnvironment())
        capabilities = HarnessCapabilityRegistry.defaultCapabilities()
        refreshRoutePlan()
    }

    func refreshRoutePlan() {
        let prompt = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        routePlan = HarnessExecutionRouter.plan(
            prompt: prompt,
            connectors: connectors,
            capabilities: capabilities
        )
        routeExecutionResult = nil
    }

    func insertCapabilityReference(_ capability: HarnessCapability) {
        let label = capability.kind == .plugin ? "Plugin" : "Skill"
        let insertion = "[\(label): \(capability.name)]"
        if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            draft = "\(insertion) "
        } else if !draft.contains(insertion) {
            draft += "\n\(insertion) "
        }
        status = "\(capability.name) added to draft."
    }

    func notebookLMSourceFiles(limit: Int = 20) -> [NotebookLMSourceFile] {
        let fileManager = FileManager.default
        let roots = connectors
            .filter { $0.kind == .notebookLM }
            .map(\.root)
        let extensions = LocalMemorySourceRegistry.notebookLMExtensions()

        var files: [NotebookLMSourceFile] = []
        for root in roots {
            guard files.count < limit * 2,
                  fileManager.fileExists(atPath: root.path),
                  let enumerator = fileManager.enumerator(
                    at: root,
                    includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                  )
            else { continue }

            for case let file as URL in enumerator {
                guard extensions.contains(file.pathExtension.lowercased()) else { continue }
                guard !file.lastPathComponent.hasSuffix(".harness.md") else { continue }
                guard (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
                let modifiedAt = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                files.append(NotebookLMSourceFile(
                    url: file,
                    rootTitle: root.lastPathComponent.isEmpty ? "NotebookLM" : root.lastPathComponent,
                    modifiedAt: modifiedAt ?? .distantPast
                ))
            }
        }

        return Array(files
            .sorted {
                if $0.modifiedAt == $1.modifiedAt {
                    return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
                }
                return $0.modifiedAt > $1.modifiedAt
            }
            .prefix(limit))
    }

    func insertNotebookLMSourceReference(_ source: NotebookLMSourceFile) {
        let insertion = Self.notebookLMReferenceText(for: source)
        if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            draft = insertion
        } else if !draft.contains(source.url.path) {
            draft += "\n\n\(insertion)"
        }
        status = "\(source.title) added from NotebookLM."
    }

    func importNotebookLMSourceFromDownloads() {
        let downloads = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Downloads", isDirectory: true)
        presentNotebookLMImportPanel(
            startingDirectory: downloads,
            title: "Import NotebookLM Download"
        )
    }

    func chooseNotebookLMSource() {
        presentNotebookLMImportPanel(
            startingDirectory: ensureNotebookLMDirectory(),
            title: "Choose NotebookLM Export"
        )
    }

    private func presentNotebookLMImportPanel(startingDirectory: URL, title: String) {
        let panel = NSOpenPanel()
        panel.title = title
        panel.prompt = "Import"
        panel.directoryURL = startingDirectory
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = LocalMemorySourceRegistry.notebookLMExtensions()
            .compactMap { UTType(filenameExtension: $0) }

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        do {
            let imported = try importNotebookLMFile(url)
            insertNotebookLMSourceReference(imported)
            refreshConnectors()
        } catch {
            status = "NotebookLM import failed: \(error.localizedDescription)"
        }
    }

    func openNotebookLMFolder() {
        let directory = ensureNotebookLMDirectory()
        NSWorkspace.shared.open(directory)
        refreshConnectors()
        status = "NotebookLM folder opened."
    }

    nonisolated static func notebookLMReferenceText(for source: NotebookLMSourceFile) -> String {
        var parts = [
            """
        [NotebookLM: \(source.title)]
        Source: \(source.url.path)
        """
        ]
        if let indexURL = source.indexURL {
            parts.append("Index: \(indexURL.path)")
        }
        parts.append(
            """
        Use as supporting research context only; not accepted authority unless promoted through review.
        """
        )
        return parts.joined(separator: "\n")
    }

    func importNotebookLMFile(_ sourceURL: URL) throws -> NotebookLMSourceFile {
        let destinationDirectory = ensureNotebookLMDirectory()
        let destinationURL = try Self.copyFileIfNeeded(
            sourceURL,
            to: destinationDirectory,
            fileManager: .default
        )
        let indexURL = try Self.createNotebookLMIndexIfNeeded(
            for: destinationURL,
            originalURL: sourceURL,
            fileManager: .default
        )
        let modifiedAt = (try? destinationURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
        return NotebookLMSourceFile(
            url: destinationURL,
            rootTitle: destinationDirectory.lastPathComponent.isEmpty ? "NotebookLM" : destinationDirectory.lastPathComponent,
            modifiedAt: modifiedAt,
            indexURL: indexURL
        )
    }

    nonisolated static func copyFileIfNeeded(
        _ sourceURL: URL,
        to directory: URL,
        fileManager: FileManager
    ) throws -> URL {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let standardizedSource = sourceURL.standardizedFileURL
        if standardizedSource.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL {
            return standardizedSource
        }

        let destination = uniqueDestinationURL(
            for: sourceURL.lastPathComponent,
            in: directory,
            fileManager: fileManager
        )
        try fileManager.copyItem(at: sourceURL, to: destination)
        return destination
    }

    nonisolated static func createNotebookLMIndexIfNeeded(
        for importedURL: URL,
        originalURL: URL,
        fileManager: FileManager
    ) throws -> URL? {
        let textExtensions = LocalMemorySourceRegistry.noteExtensions()
        guard !textExtensions.contains(importedURL.pathExtension.lowercased()) else {
            return nil
        }

        let indexURL = importedURL
            .deletingPathExtension()
            .appendingPathExtension("harness")
            .appendingPathExtension("md")
        let body = """
        # NotebookLM Import: \(importedURL.deletingPathExtension().lastPathComponent)

        source-class: notebooklm-export
        imported-file: \(importedURL.path)
        original-file: \(originalURL.path)
        file-type: \(importedURL.pathExtension.lowercased())

        This file was imported from a NotebookLM-created document. Treat it as synthesized research context, like web evidence, unless the user explicitly marks it as personal-data or direct-thought.
        """
        try body.write(to: indexURL, atomically: true, encoding: .utf8)
        return indexURL
    }

    nonisolated static func uniqueDestinationURL(
        for fileName: String,
        in directory: URL,
        fileManager: FileManager
    ) -> URL {
        let original = directory.appendingPathComponent(fileName)
        guard fileManager.fileExists(atPath: original.path) else { return original }

        let stem = original.deletingPathExtension().lastPathComponent
        let fileExtension = original.pathExtension
        for index in 2...999 {
            let candidateName = fileExtension.isEmpty
                ? "\(stem)-\(index)"
                : "\(stem)-\(index).\(fileExtension)"
            let candidate = directory.appendingPathComponent(candidateName)
            if !fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return directory.appendingPathComponent("\(UUID().uuidString)-\(fileName)")
    }

    func runReadOnlyRoute() {
        let plan = routePlan
        guard !plan.steps.isEmpty else {
            status = "No route to run."
            return
        }
        status = "Running read-only route"
        let connectors = connectors
        let capabilities = capabilities
        Task {
            do {
                let result = try await HarnessRouteExecutor(
                    connectors: connectors,
                    capabilities: capabilities
                ).executeReadOnly(plan)
                await MainActor.run {
                    self.routeExecutionResult = result
                    self.status = result.summary
                }
            } catch {
                await MainActor.run {
                    self.status = "Route run failed: \(error.localizedDescription)"
                }
            }
        }
    }

    func approveAndRunRouteStep(_ step: HarnessExecutionRouteStep) {
        let plan = routePlan
        guard plan.steps.contains(where: { $0.id == step.id }) else {
            status = "Route step is no longer current."
            return
        }
        guard step.guardrail == .approvalRequired else {
            status = "Only approval-gated steps need this action."
            return
        }

        status = "Running approved step"
        let connectors = connectors
        let capabilities = capabilities
        let firecrawlKey = Self.loadFirecrawlAPIKey()
        Task {
            do {
                let result = try await HarnessRouteExecutor(
                    connectors: connectors,
                    capabilities: capabilities
                ).executeApproved(
                    plan,
                    approvedStepIDs: [step.id],
                    externalResearchDelegate: { request in
                        switch request.adapter.executionKind {
                        case .firecrawlSearch:
                            guard let firecrawlKey else { throw FirecrawlClient.FirecrawlError.noKey }
                            let response = try await FirecrawlClient(apiKey: firecrawlKey)
                                .search(query: request.userPrompt, limit: 5)
                            let mcpConfig = HarnessMCPServerConfiguration.firecrawlLocal(apiKey: firecrawlKey)
                            return response.formattedBrief(for: request.userPrompt)
                                + "\n\nMCP runtime: \(mcpConfig.redactedSummary)"
                        case .firecrawlScrape:
                            guard let firecrawlKey else { throw FirecrawlClient.FirecrawlError.noKey }
                            guard let url = FirecrawlClient.firstURL(in: request.userPrompt) else {
                                throw FirecrawlClient.FirecrawlError.missingURL
                            }
                            let response = try await FirecrawlClient(apiKey: firecrawlKey).scrape(url: url)
                            let mcpConfig = HarnessMCPServerConfiguration.firecrawlLocal(apiKey: firecrawlKey)
                            return response.formattedBrief(for: request.userPrompt)
                                + "\n\nMCP runtime: \(mcpConfig.redactedSummary)"
                        case .firecrawlMap:
                            guard let firecrawlKey else { throw FirecrawlClient.FirecrawlError.noKey }
                            guard let url = FirecrawlClient.firstURL(in: request.userPrompt) else {
                                throw FirecrawlClient.FirecrawlError.missingURL
                            }
                            let response = try await FirecrawlClient(apiKey: firecrawlKey).map(url: url, limit: 100)
                            let mcpConfig = HarnessMCPServerConfiguration.firecrawlLocal(apiKey: firecrawlKey)
                            return response.formattedBrief(for: request.userPrompt)
                                + "\n\nMCP runtime: \(mcpConfig.redactedSummary)"
                        case .agentSynthesis:
                            break
                        }
                        return try await AgentRunner().run(
                            backend: .codex,
                            system: request.adapter.systemInstruction,
                            user: request.routePrompt
                        )
                    }
                )
                await MainActor.run {
                    self.refreshConnectors()
                    self.routeExecutionResult = result
                    self.status = result.summary
                }
            } catch {
                await MainActor.run {
                    self.refreshConnectors()
                    self.status = "Approved step failed: \(error.localizedDescription)"
                }
            }
        }
    }

    func saveFirecrawlAPIKey() {
        let trimmed = firecrawlAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            status = "Paste a Firecrawl API key first."
            return
        }
        do {
            try APIKeyStore.saveFirecrawlKey(trimmed)
            firecrawlAPIKey = ""
            hasFirecrawlAPIKey = true
            refreshConnectors()
            status = "Firecrawl key saved in Keychain."
        } catch {
            status = "Firecrawl key save failed: \(error.localizedDescription)"
        }
    }

    func deleteFirecrawlAPIKey() {
        do {
            try APIKeyStore.deleteFirecrawlKey()
            firecrawlAPIKey = ""
            hasFirecrawlAPIKey = Self.loadFirecrawlAPIKey() != nil
            refreshConnectors()
            status = "Firecrawl key removed."
        } catch {
            status = "Firecrawl key removal failed: \(error.localizedDescription)"
        }
    }

    func syncAppleNotes() {
        status = "Syncing Apple Notes"
        let exporter = AppleNotesExporter()
        Task.detached(priority: .userInitiated) {
            do {
                let result = try await exporter.export()
                await MainActor.run {
                    self.refreshConnectors()
                    self.status = "Apple Notes synced: \(result.exportedCount) note\(result.exportedCount == 1 ? "" : "s")."
                }
            } catch {
                await MainActor.run {
                    self.refreshConnectors()
                    self.status = "Apple Notes sync failed: \(error.localizedDescription)"
                }
            }
        }
    }

    func scanForNewPatterns() {
        status = "Scanning Supabase evidence"
        Task {
            do {
                let output = try await Task.detached(priority: .userInitiated) {
                    try Self.runEvidenceIngest()
                }.value
                reviewQueueCandidates = try await reviewQueue.loadPendingClaims()
                status = output
            } catch {
                status = "Evidence scan failed: \(error.localizedDescription)"
            }
        }
    }

    func decideReviewQueueCandidate(_ candidate: MemoryCandidate, decision: ReviewQueueDecision) {
        let reviewQueue = reviewQueue
        Task {
            do {
                let outcome = try await reviewQueue.decide(claimId: candidate.id, decision: decision)
                let pending = try await reviewQueue.loadPendingClaims()
                await MainActor.run {
                    self.reviewQueueCandidates = pending
                    if let blocked = outcome.blockedReason {
                        self.status = blocked
                    } else {
                        self.status = "\(pending.count) candidate\(pending.count == 1 ? "" : "s") waiting"
                    }
                }
            } catch {
                await MainActor.run {
                    self.status = error.localizedDescription
                }
            }
        }
    }

    func markCandidate(_ candidate: MemoryCandidate, as status: CandidateState) {
        guard [.suggested, .candidate, .rejected].contains(status) else {
            self.status = "Candidate review cannot accept graph authority."
            return
        }
        let selectedRunId = selectedDetail?.run.id
        let ledger = ledger

        Task {
            do {
                try await ledger.updateCandidateStatus(
                    id: candidate.id,
                    status: status,
                    validationResult: Self.reviewMessage(for: status)
                )
                let detail: HarnessRunDetail?
                if let selectedRunId {
                    detail = try await ledger.runDetail(id: selectedRunId)
                } else {
                    detail = nil
                }
                await MainActor.run {
                    if let detail {
                        self.selectedDetail = detail
                    }
                    self.status = Self.reviewMessage(for: status)
                }
            } catch {
                await MainActor.run {
                    self.status = error.localizedDescription
                }
            }
        }
    }

    func prepareCandidateForGraphReview(_ candidate: MemoryCandidate) {
        let proposedGraph = CandidateGraphDraftBuilder().draft(for: candidate)
        let draftCandidate = MemoryCandidate(
            id: candidate.id,
            runId: candidate.runId,
            sourceRunIds: candidate.sourceRunIds,
            evidenceText: candidate.evidenceText,
            proposedClaim: candidate.proposedClaim,
            proposedGraph: proposedGraph,
            status: .candidate,
            validationResult: candidate.validationResult,
            createdAt: candidate.createdAt
        )
        let validation = TurtleCandidateValidator().validate(candidate: draftCandidate)
        guard validation.passed else {
            status = validation.detail
            return
        }

        let selectedRunId = selectedDetail?.run.id
        let ledger = ledger
        Task {
            do {
                try await ledger.updateCandidateReview(
                    id: candidate.id,
                    status: .validated,
                    proposedGraph: proposedGraph,
                    validationResult: "Ready for graph review. Not accepted authority."
                )
                let detail: HarnessRunDetail?
                if let selectedRunId {
                    detail = try await ledger.runDetail(id: selectedRunId)
                } else {
                    detail = nil
                }
                await MainActor.run {
                    if let detail {
                        self.selectedDetail = detail
                    }
                    self.status = "Candidate ready for graph review."
                }
            } catch {
                await MainActor.run {
                    self.status = error.localizedDescription
                }
            }
        }
    }

    func send() {
        let prompt = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !isRunning else { return }
        refreshRoutePlan()
        let plannedRoute = routePlan
        draft = ""
        routePlan = plannedRoute
        isRunning = true
        status = plannedRoute.requiresApproval ? "Route planned; approval-gated steps detected" : "Checking graph authority"
        let selectedBackend = backend
        let key = apiKey.isEmpty ? nil : apiKey

        let service = service
        let ledger = ledger
        let ontology = ontology

        Task.detached(priority: .userInitiated) {
            let adapter = AgentRunnerBackendAdapter(backend: selectedBackend, apiKey: key)
            do {
                let detail = try await service.createRun(
                    prompt: prompt,
                    ontology: ontology,
                    backend: adapter
                )
                let latestRuns = try await ledger.listRuns()
                await MainActor.run {
                    self.selectedDetail = detail
                    self.runs = latestRuns
                    self.status = detail.run.success ? "Trace saved" : "Backend failed; trace saved"
                    self.isRunning = false
                }
            } catch {
                await MainActor.run {
                    self.status = error.localizedDescription
                    self.isRunning = false
                }
            }
        }
    }

    private static func reviewMessage(for status: CandidateState) -> String {
        switch status {
        case .suggested:
            return "Candidate returned to suggested."
        case .candidate:
            return "Candidate marked for review."
        case .rejected:
            return "Candidate rejected."
        case .validated:
            return "Candidate validation is not wired here."
        case .accepted:
            return "Candidate review cannot accept graph authority."
        }
    }

    nonisolated private static func runEvidenceIngest() throws -> String {
        let scriptURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Developer/GitHub/Harness/scripts/ingest_evidence.py")
        guard FileManager.default.fileExists(atPath: scriptURL.path) else {
            throw NSError(
                domain: "HarnessEvidenceIngest",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "scripts/ingest_evidence.py was not found."]
            )
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [scriptURL.path]
        process.currentDirectoryURL = scriptURL.deletingLastPathComponent().deletingLastPathComponent()

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        let output = String(
            data: outputPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        let error = String(
            data: errorPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""

        guard process.terminationStatus == 0 else {
            let message = error.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? output
                : error
            throw NSError(
                domain: "HarnessEvidenceIngest",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: message.trimmingCharacters(in: .whitespacesAndNewlines)]
            )
        }

        if let data = output.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let count = json["candidates_created"] as? Int {
            return "Evidence scan complete: \(count) new candidate\(count == 1 ? "" : "s")."
        }
        return "Evidence scan complete."
    }

    private static func connectorEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        if loadFirecrawlAPIKey() != nil {
            environment["FIRECRAWL_API_KEY"] = "[configured]"
        }
        return environment
    }

    private func ensureNotebookLMDirectory() -> URL {
        let preferred = connectors.first { $0.kind == .notebookLM && $0.state == .available }?.root
            ?? connectors.first { $0.kind == .notebookLM }?.root
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Documents/Harness/NotebookLM", isDirectory: true)
        try? FileManager.default.createDirectory(at: preferred, withIntermediateDirectories: true)
        return preferred
    }

    private static func loadFirecrawlAPIKey() -> String? {
        let environmentKey = ProcessInfo.processInfo.environment["FIRECRAWL_API_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let environmentKey, !environmentKey.isEmpty {
            return environmentKey
        }
        return APIKeyStore.loadFirecrawlKey()
    }
}

struct NotebookLMSourceFile: Identifiable, Equatable {
    let url: URL
    let rootTitle: String
    let modifiedAt: Date
    let indexURL: URL?

    init(url: URL, rootTitle: String, modifiedAt: Date) {
        self.init(url: url, rootTitle: rootTitle, modifiedAt: modifiedAt, indexURL: nil)
    }

    init(url: URL, rootTitle: String, modifiedAt: Date, indexURL: URL?) {
        self.url = url
        self.rootTitle = rootTitle
        self.modifiedAt = modifiedAt
        self.indexURL = indexURL
    }

    var id: String { url.path }
    var title: String { url.deletingPathExtension().lastPathComponent }

    var menuTitle: String {
        let base = title.isEmpty ? url.lastPathComponent : title
        guard base.count > 36 else { return base }
        return String(base.prefix(33)) + "..."
    }
}

enum WorkbenchInspectorTab: String, CaseIterable, Identifiable {
    case authority = "Authority"
    case route = "Route"
    case memory = "Memory"
    case connectors = "Connections"
    case skills = "Skills"
    case trace = "Trace"
    case candidates = "Candidates"

    var id: String { rawValue }

    static let compactRailOrder: [WorkbenchInspectorTab] = [
        .authority,
        .route,
        .memory,
        .candidates,
        .connectors,
        .skills,
        .trace
    ]
}

struct WorkbenchToolGroup: Identifiable, Equatable {
    let id: String
    let title: String
    let tools: [WorkbenchTool]

    static let defaults: [WorkbenchToolGroup] = [
        WorkbenchToolGroup(
            id: "authority",
            title: "Authority",
            tools: [
                WorkbenchTool(
                    title: "Ontology steward",
                    icon: "checkmark.seal",
                    state: .available,
                    detail: "accepted graph",
                    summary: "Retrieves accepted ontology facts before model execution.",
                    permission: "Read-only bundled Turtle graph.",
                    provenance: "Authority hits are recorded on each run."
                ),
                WorkbenchTool(
                    title: "Graph trace",
                    icon: "point.3.connected.trianglepath.dotted",
                    state: .available,
                    detail: "query proof",
                    summary: "Shows the local query trace behind accepted graph hits.",
                    permission: "Read-only run inspection.",
                    provenance: "Trace text is saved in the run ledger."
                ),
                WorkbenchTool(
                    title: "Candidate review",
                    icon: "tray.and.arrow.up",
                    state: .readOnly,
                    detail: "no promotion",
                    summary: "Marks suggested memory for review, rejection, or graph-review preparation.",
                    permission: "Can update candidate status; cannot accept graph authority.",
                    provenance: "Candidate status changes persist in the ledger."
                )
            ]
        ),
        WorkbenchToolGroup(
            id: "context",
            title: "Context",
            tools: [
                WorkbenchTool(
                    title: "Vault search",
                    icon: "doc.text.magnifyingglass",
                    state: .readOnly,
                    detail: "supporting memory",
                    summary: "Finds Obsidian and markdown notes as supporting memory after authority retrieval.",
                    permission: "Read-only markdown, text, Turtle, HTML, and RTF files.",
                    provenance: "Memory hits are labeled supporting, not accepted."
                ),
                WorkbenchTool(
                    title: "GitHub repos",
                    icon: "folder",
                    state: .available,
                    detail: "local repos",
                    summary: "Searches local GitHub repositories for code, docs, and product context.",
                    permission: "Read-only filesystem access under configured repo roots.",
                    provenance: "Source file paths are shown in memory cards."
                ),
                WorkbenchTool(
                    title: "Apple Notes",
                    icon: "note.text",
                    state: .available,
                    detail: "local export",
                    summary: "Exports Apple Notes into a local Harness folder, then searches them as supporting memory.",
                    permission: "Requires macOS Automation permission for Notes on first sync.",
                    provenance: "Exported note files are searched as supporting memory, not accepted authority."
                ),
                WorkbenchTool(
                    title: "NotebookLM",
                    icon: "text.book.closed",
                    state: .readOnly,
                    detail: "synthesis context",
                    summary: "Searches exported NotebookLM notebooks, study guides, briefs, and source packs as supporting research context.",
                    permission: "Read-only local exports; no direct NotebookLM account control.",
                    provenance: "Unlabeled NotebookLM files are treated like web synthesis unless marked source-class: personal-data or source-class: direct-thought."
                ),
                WorkbenchTool(
                    title: "Run ledger",
                    icon: "clock.arrow.circlepath",
                    state: .available,
                    detail: "SQLite trace",
                    summary: "Persists prompts, replies, authority, memory, evals, traces, and candidates.",
                    permission: "Writes local Application Support ledger records.",
                    provenance: "Every saved run has a prompt packet hash."
                )
            ]
        ),
        WorkbenchToolGroup(
            id: "backends",
            title: "Backends",
            tools: [
                WorkbenchTool(
                    title: "Codex",
                    icon: "terminal",
                    state: .available,
                    detail: "local CLI",
                    summary: "Routes model packets to the local Codex CLI on macOS.",
                    permission: "Uses existing CLI authentication.",
                    provenance: "Backend metadata records local-cli invocation."
                ),
                WorkbenchTool(
                    title: "Grok",
                    icon: "sparkles",
                    state: .available,
                    detail: "local CLI",
                    summary: "Routes model packets to the local Grok CLI on macOS.",
                    permission: "Uses existing CLI authentication.",
                    provenance: "Backend metadata records local-cli invocation."
                ),
                WorkbenchTool(
                    title: "Claude",
                    icon: "cloud",
                    state: .available,
                    detail: "API key",
                    summary: "Routes model packets to Claude through the configured API key.",
                    permission: "Uses environment or entered Anthropic API key.",
                    provenance: "Backend metadata records https-api invocation."
                ),
                WorkbenchTool(
                    title: "Hermes local",
                    icon: "shippingbox",
                    state: .available,
                    detail: "local model",
                    summary: "Routes model packets to a local Hermes 3 (8B) model via Ollama. No subscription, no API key, no network egress.",
                    permission: "Requires `ollama serve` running locally on 127.0.0.1:11434.",
                    provenance: "Backend metadata records local-http invocation."
                )
            ]
        )
    ]
}

struct WorkbenchTool: Identifiable, Equatable {
    let id: String
    let title: String
    let icon: String
    let state: WorkbenchToolState
    let detail: String
    let summary: String
    let permission: String
    let provenance: String

    init(
        id: String? = nil,
        title: String,
        icon: String,
        state: WorkbenchToolState,
        detail: String,
        summary: String,
        permission: String,
        provenance: String
    ) {
        self.id = id ?? title.lowercased().replacingOccurrences(of: " ", with: "-")
        self.title = title
        self.icon = icon
        self.state = state
        self.detail = detail
        self.summary = summary
        self.permission = permission
        self.provenance = provenance
    }
}

enum WorkbenchToolState: String, Equatable {
    case available = "available"
    case readOnly = "read-only"
    case planned = "planned"
}
#endif
