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
    @Published var chatThread: [ConversationTurn] = []
    @Published var draft = "" {
        didSet { refreshRoutePlan() }
    }
    @Published var composerAttachments: [ComposerAttachment] = []
    @Published var composerIntent = ComposerIntent()
    @Published var backend: Backend = .harnessDefault {
        didSet {
            guard backend != oldValue else { return }
            loadAPIKey(for: backend)
            refreshReadiness(for: backend)
        }
    }
    @Published var apiKey = ""
    @Published var hasSavedAPIKey = false
    @Published var backendReadiness: [Backend: BackendReadiness] = [:]
    @Published var firecrawlAPIKey = ""
    @Published var hasFirecrawlAPIKey = false
    @Published var isRunning = false
    @Published var status = "Ledger ready"
    @Published var searchText = ""
    @Published var chatSessions: [ChatSession] = []
    @Published var sessionSearchHits: [SessionSearchHit] = []
    @Published var currentSessionId: String?
    @Published var activeToolLoop: ToolLoopMonitor?
    @Published var showApprovalToast = false
    @Published var selectedTool: WorkbenchTool?
    @Published var reviewQueueCandidates: [MemoryCandidate] = []
    @Published var opportunityBoardRows: [OpportunityBoardRow] = []
    @Published var opportunityBoardLoadIssue: String?
    @Published var connectors: [HarnessConnector] = HarnessConnectorRegistry.defaultConnectors()
    @Published var capabilities: [HarnessCapability] = HarnessCapabilityRegistry.defaultCapabilities()
    @Published var routePlan = HarnessExecutionRoutePlan(prompt: "", steps: [])
    @Published var routeExecutionResult: HarnessRouteExecutionResult?
    @Published var delegationAgentWatchlistEnabled = MacWorkbenchModel.loadDelegationAgentWatchlistEnabled() {
        didSet { Self.saveDelegationAgentWatchlistEnabled(delegationAgentWatchlistEnabled) }
    }
    @Published var delegationAgentPerRunCreditLimit = MacWorkbenchModel.loadDelegationAgentPerRunCreditLimit() {
        didSet { Self.saveDelegationAgentPerRunCreditLimit(delegationAgentPerRunCreditLimit) }
    }
    @Published var delegationAgentDailyCreditLimit = MacWorkbenchModel.loadDelegationAgentDailyCreditLimit() {
        didSet { Self.saveDelegationAgentDailyCreditLimit(delegationAgentDailyCreditLimit) }
    }
    var toolGroups: [WorkbenchToolGroup] {
        WorkbenchToolGroup.defaults + [WorkbenchToolGroup.communicationSkills(from: capabilities)]
    }

    /// The bouncer's queue, observed directly by the approval cards in the
    /// chat transcript. "Agents propose. The bouncer checks. You decide."
    let toolApprovals = ToolApprovalStore()

    private let ledger: RunLedgerStore
    private let service: HarnessRunService
    private let reviewQueue: ReviewQueueStore
    private let sessions: SessionStore
    private var runTask: Task<Void, Never>?
    private var approvalToastTask: Task<Void, Never>?

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
        self.sessions = SessionStore(ledger: store)
        self.hasFirecrawlAPIKey = Self.loadFirecrawlAPIKey() != nil
        loadAPIKey(for: backend)
        refreshReadiness(for: backend)
        Task {
            await refreshRuns()
            await restoreMostRecentSession()
            await refreshSessions()
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
        chatThread = []
        currentSessionId = nil
        sessionSearchHits = []
        draft = ""
        composerAttachments = []
        composerIntent = ComposerIntent()
        searchText = ""
        status = "New session"
    }

    // MARK: Sessions (WS-A4 SessionStore)

    func refreshSessions() async {
        do {
            chatSessions = try await sessions.listSessions()
        } catch {
            status = "Sessions unavailable: \(error.localizedDescription)"
        }
    }

    /// Launch restore: reopen the most recently touched session so the
    /// conversation survives relaunch.
    func restoreMostRecentSession() async {
        do {
            guard let session = try await sessions.mostRecentSession() else { return }
            await loadSession(session)
        } catch {
            status = "Session restore failed: \(error.localizedDescription)"
        }
    }

    func selectSession(_ session: ChatSession) {
        Task { await loadSession(session) }
    }

    func selectSessionSearchHit(_ hit: SessionSearchHit) {
        Task {
            do {
                guard let session = try await sessions.session(id: hit.sessionId) else {
                    status = "Session no longer exists."
                    return
                }
                await loadSession(session)
            } catch {
                status = error.localizedDescription
            }
        }
    }

    private func loadSession(_ session: ChatSession) async {
        do {
            let messages = try await sessions.thread(sessionId: session.id)
            currentSessionId = session.id
            chatThread = messages
                .filter { $0.role == .user || $0.role == .assistant }
                .map { ConversationTurn(id: $0.id, role: $0.role, text: $0.text) }
            if let lastRunId = messages.last(where: { $0.runId != nil })?.runId {
                selectedDetail = try? await ledger.runDetail(id: lastRunId)
            }
            status = "Session restored: \(session.title)"
        } catch {
            status = "Session load failed: \(error.localizedDescription)"
        }
    }

    /// Episodic search over persisted sessions (FTS5 when available,
    /// LIKE fallback otherwise). Feeds the sidebar SESSIONS list.
    func searchSessions() async {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            sessionSearchHits = []
            return
        }
        do {
            let hits = try await sessions.searchSessions(query: query, limit: 20)
            // Drop results for a query the user has since edited past — an
            // out-of-order completion must not show hits for stale text.
            guard searchText.trimmingCharacters(in: .whitespacesAndNewlines) == query else { return }
            sessionSearchHits = hits
        } catch {
            guard searchText.trimmingCharacters(in: .whitespacesAndNewlines) == query else { return }
            sessionSearchHits = []
            status = "Session search failed: \(error.localizedDescription)"
        }
    }

    nonisolated static func sessionTitle(from prompt: String, maxLength: Int = 48) -> String {
        let firstLine = prompt
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first
            .map(String.init) ?? prompt
        let trimmed = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "New session" }
        guard trimmed.count > maxLength else { return trimmed }
        return String(trimmed.prefix(maxLength - 1)) + "…"
    }

    // MARK: Bouncer decisions (ToolApprovalStore)

    /// Adam approves a proposed tool call. `always: true` also persists the
    /// fired pattern ids to the allowlist. Mutations never execute silently —
    /// this is the one place a suspended call gets unblocked.
    func approveToolRequest(_ request: ToolApprovalRequest, always: Bool = false) {
        toolApprovals.approve(id: request.id, always: always)
        status = always
            ? "\(request.toolName) approved; pattern allowlisted"
            : "\(request.toolName) approved"
        flashApprovalToast()
    }

    /// Adam denies a proposed tool call. The agent receives the refusal as an
    /// error tool result and the loop continues.
    func denyToolRequest(_ request: ToolApprovalRequest) {
        toolApprovals.deny(id: request.id)
        status = "\(request.toolName) denied; the agent was told no"
    }

    private func flashApprovalToast() {
        approvalToastTask?.cancel()
        showApprovalToast = true
        approvalToastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            guard !Task.isCancelled else { return }
            self?.showApprovalToast = false
        }
    }

    func mutateComposerIntent(_ body: (inout ComposerIntent) -> Void) {
        var copy = composerIntent
        body(&copy)
        composerIntent = copy
    }

    func selectTool(_ tool: WorkbenchTool) {
        selectedTool = tool
        if let skillName = tool.skillName,
           let capability = capabilities.first(where: { $0.name == skillName && $0.kind == .skill }) {
            insertCapabilityReference(capability)
            return
        }
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
            .appendingPathComponent("Delegations", isDirectory: true)
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
                    self?.status = "\(action.label) recorded for \(records.count) delegation item\(records.count == 1 ? "" : "s")."
                }
            } catch {
                await MainActor.run {
                    self?.status = "\(action.label) failed: \(error.localizedDescription)"
                }
            }
        }
    }

    func runDelegationAgent() {
        guard !isRunning else { return }
        guard let firecrawlKey = Self.loadFirecrawlAPIKey() else {
            status = "Firecrawl key required before running an agent."
            return
        }

        let prompt = draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? DelegationAgentRunner.defaultPrompt
            : draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let ontology = ontology
        let ledger = ledger
        let outputDirectory = Self.defaultOpportunityBoardDirectory()
        let backend = backend
        let apiKey = apiKey
        let killSwitch = DelegationAgentKillSwitch(
            watchlistEnabled: delegationAgentWatchlistEnabled,
            perRunCreditLimit: delegationAgentPerRunCreditLimit,
            perDayCreditLimit: delegationAgentDailyCreditLimit,
            creditsUsedToday: Self.delegationAgentCreditsUsedToday()
        )
        isRunning = true
        status = "Running agent"

        Task { [weak self] in
            do {
                let authorityHits = try await OntologyAuthorityRetriever().retrieve(
                    prompt: prompt,
                    ontology: ontology,
                    limit: 8
                )
                let client = FirecrawlClient(apiKey: firecrawlKey)
                let result = try await DelegationAgentRunner(
                    search: { query, limit in
                        try await client.search(query: query, limit: limit)
                    },
                    scrape: { url in
                        try await client.scrape(url: url)
                    },
                    triage: { request in
                        let text = try await AgentRunner().run(
                            backend: backend,
                            system: DelegationAgentRunner.triageSystemPrompt(),
                            user: DelegationAgentRunner.triageUserPrompt(request),
                            apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : apiKey
                        )
                        return DelegationAgentRunner.parseTriageJSON(text)
                    }
                ).run(
                    prompt: prompt,
                    authorityHits: authorityHits,
                    outputDirectory: outputDirectory,
                    killSwitch: killSwitch
                )
                try await ledger.save(result.detail)
                await MainActor.run {
                    Self.recordDelegationAgentCreditsUsed(result.creditsUsed)
                    self?.isRunning = false
                    self?.selectedDetail = result.detail
                    self?.refreshOpportunityBoard()
                    self?.refreshConnectors()
                    self?.status = result.detail.run.finalAnswer
                }
                await self?.refreshRuns()
            } catch {
                await MainActor.run {
                    self?.isRunning = false
                    self?.status = "Agent run failed: \(error.localizedDescription)"
                }
            }
        }
    }

    func setDelegationAgentWatchlistEnabled(_ enabled: Bool) {
        delegationAgentWatchlistEnabled = enabled
    }

    func setDelegationAgentPerRunCreditLimit(_ value: Int) {
        delegationAgentPerRunCreditLimit = max(1, value)
    }

    func setDelegationAgentDailyCreditLimit(_ value: Int) {
        delegationAgentDailyCreditLimit = max(1, value)
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
        let prompt = composedDraftPrompt
        routePlan = HarnessExecutionRouter.plan(
            prompt: prompt,
            connectors: connectors,
            capabilities: capabilities
        )
        routeExecutionResult = nil
    }

    /// Attach a skill to the draft. Skills load their FULL file content
    /// verbatim (Adam's exact-words law: rules travel as written, never as a
    /// bare `[Skill: name]` marker the model cannot read). Plugins and
    /// unreadable files fall back to the reference marker.
    func insertCapabilityReference(_ capability: HarnessCapability) {
        if capability.kind == .skill,
           let content = Self.loadSkillContent(at: capability.path) {
            guard !composerAttachments.contains(where: { $0.localPath == capability.path.path }) else {
                status = "\(capability.name) is already attached."
                return
            }
            composerAttachments.append(ComposerAttachment(
                kind: .file,
                title: "Skill: \(capability.name)",
                localPath: capability.path.path,
                excerpt: content
            ))
            refreshRoutePlan()
            status = "\(capability.name) skill loaded verbatim into the draft."
            return
        }

        let label = capability.kind == .plugin ? "Plugin" : "Skill"
        let insertion = "[\(label): \(capability.name)]"
        if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            draft = "\(insertion) "
        } else if !draft.contains(insertion) {
            draft += "\n\(insertion) "
        }
        status = "\(capability.name) added to draft."
    }

    /// Reads the skill file as-is at attach time. Only a length cap is
    /// applied (same limit as file attachments); the retained prefix is
    /// byte-for-byte Adam's words.
    nonisolated static func loadSkillContent(
        at url: URL,
        maxLength: Int = ComposerAttachmentStore.maxTextExcerptLength
    ) -> String? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.count > maxLength else { return trimmed }
        return String(trimmed.prefix(maxLength)) + "\n...(truncated)"
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

    func removeComposerAttachment(_ attachment: ComposerAttachment) {
        composerAttachments.removeAll { $0.id == attachment.id }
        refreshRoutePlan()
        status = "\(attachment.title) removed."
    }

    func addComposerLink(_ raw: String) {
        guard let attachment = ComposerAttachment.parseLinkInput(raw) else {
            status = "Paste a valid URL or owner/repo."
            return
        }
        guard !composerAttachments.contains(where: { $0.remoteURL == attachment.remoteURL && $0.kind == .link }) else {
            status = "\(attachment.title) is already attached."
            return
        }
        composerAttachments.append(attachment)
        refreshRoutePlan()
        status = "\(attachment.title) attached."
    }

    func chooseComposerPhotos() {
        presentComposerImportPanel(
            title: "Add Photos",
            prompt: "Attach",
            allowedTypes: [.image, .jpeg, .png, .heic, .gif, .tiff] + [UTType(filenameExtension: "webp")].compactMap { $0 },
            allowsMultipleSelection: true
        ) { urls in
            self.importComposerFiles(urls, kind: .photo)
        }
    }

    func chooseComposerFiles() {
        presentComposerImportPanel(
            title: "Add Files",
            prompt: "Attach",
            allowedTypes: [.item, .pdf, .plainText, .json, .commaSeparatedText, .data],
            allowsMultipleSelection: true
        ) { urls in
            self.importComposerFiles(urls, kind: .file)
        }
    }

    private func importComposerFiles(_ urls: [URL], kind: ComposerAttachmentKind) {
        var added = 0
        for url in urls {
            do {
                let attachment = try ComposerAttachmentStore.importFile(from: url, kind: kind)
                guard !composerAttachments.contains(where: { $0.localPath == attachment.localPath }) else { continue }
                composerAttachments.append(attachment)
                added += 1
            } catch {
                status = "Attach failed: \(error.localizedDescription)"
                return
            }
        }
        if added > 0 {
            refreshRoutePlan()
            let noun = kind == .photo ? "photo" : "file"
            status = added == 1 ? "1 \(noun) attached." : "\(added) \(noun)s attached."
        }
    }

    private func presentComposerImportPanel(
        title: String,
        prompt: String,
        allowedTypes: [UTType],
        allowsMultipleSelection: Bool,
        onImport: @escaping ([URL]) -> Void
    ) {
        let panel = NSOpenPanel()
        panel.title = title
        panel.prompt = prompt
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = allowsMultipleSelection
        panel.allowedContentTypes = allowedTypes
        guard panel.runModal() == .OK else { return }
        onImport(panel.urls)
    }

    private var composedDraftPrompt: String {
        ComposerIntent.composedPrompt(
            userText: draft,
            attachments: composerAttachments,
            intent: composerIntent
        )
    }

    var canSendComposer: Bool {
        ComposerAttachment.canSend(userText: draft, attachments: composerAttachments) && !isRunning
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
        let selectedBackend = backend
        let trimmedKey = Self.usesAPIKey(selectedBackend) ? apiKey.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        let routeAPIKey = trimmedKey.isEmpty ? nil : trimmedKey
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
                            backend: selectedBackend,
                            system: request.adapter.systemInstruction,
                            user: request.routePrompt,
                            apiKey: routeAPIKey
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

    /// Environment variable wins for one-off overrides; the Keychain is the
    /// durable store. Each backend has its own Keychain account so a key can
    /// never be sent to the wrong vendor.
    func loadAPIKey(for backend: Backend) {
        apiKey = Self.initialAPIKey(for: backend)
        hasSavedAPIKey = !apiKey.isEmpty
    }

    /// Probe the backend and publish its readiness — "live", "pending",
    /// or "failed (message)" — using SAVY's status vocabulary. When
    /// something is waiting on one action, the status line names it.
    func refreshReadiness(for backend: Backend) {
        backendReadiness[backend] = .checking
        let key = Self.usesAPIKey(backend) ? apiKey.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        Task { [weak self] in
            let readiness = await AgentRunner().preflight(
                backend: backend,
                apiKey: key.isEmpty ? nil : key
            )
            await MainActor.run {
                guard let self else { return }
                self.backendReadiness[backend] = readiness
                if let action = readiness.actionNeeded {
                    self.status = "\(backend.rawValue): \(action)"
                } else if case .failed(let message) = readiness {
                    self.status = "\(backend.rawValue) failed: \(message)"
                }
            }
        }
    }

    /// Cancel the in-flight run: abort the tool loop (which kills CLI/shell
    /// subprocesses), kill any CLI child, and restore the UI. A call already
    /// suspended on an approval card stays pending — the queue is never
    /// silently drained; Adam decides it from the card.
    func cancelRun() {
        guard isRunning else { return }
        activeToolLoop?.cancel()
        // Drop the monitor so the run's own completion handler sees it is no
        // longer the active run and skips clobbering fresh UI state.
        activeToolLoop = nil
        AgentRunner.terminateRunningProcesses()
        runTask?.cancel()
        runTask = nil
        isRunning = false
        status = toolApprovals.pendingSnapshot().isEmpty
            ? "Cancelled"
            : "Cancelled; pending proposals still need your decision"
    }

    func saveAPIKey() {
        guard Self.usesAPIKey(backend) else {
            status = "\(backend.rawValue) uses ChatGPT authorization through Codex."
            refreshReadiness(for: backend)
            return
        }
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            status = "Paste an API key first."
            return
        }
        do {
            try APIKeyStore.saveKey(trimmed, for: backend)
            hasSavedAPIKey = true
            status = "\(backend.rawValue) key saved in Keychain."
            refreshReadiness(for: backend)
        } catch {
            status = "Key save failed: \(error.localizedDescription)"
        }
    }

    func deleteAPIKey() {
        guard Self.usesAPIKey(backend) else {
            apiKey = ""
            hasSavedAPIKey = false
            status = "\(backend.rawValue) has no API key to remove."
            refreshReadiness(for: backend)
            return
        }
        do {
            try APIKeyStore.deleteKey(for: backend)
            apiKey = ""
            hasSavedAPIKey = false
            status = "\(backend.rawValue) key removed."
            refreshReadiness(for: backend)
        } catch {
            status = "Key removal failed: \(error.localizedDescription)"
        }
    }

    nonisolated static func initialAPIKey(
        for backend: Backend,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        keychainKey: (Backend) -> String? = { APIKeyStore.loadKey(for: $0) }
    ) -> String {
        let environmentName: String?
        switch backend {
        case .codex: environmentName = "OPENAI_API_KEY"  // env only — never keychain
        case .grok: environmentName = "XAI_API_KEY"
        case .claude: environmentName = "ANTHROPIC_API_KEY"
        case .hermes: environmentName = nil
        }
        if let environmentName,
           let value = environment[environmentName]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !value.isEmpty {
            return value
        }
        guard usesAPIKey(backend) else { return "" }
        return keychainKey(backend) ?? ""
    }

    nonisolated static func usesAPIKey(_ backend: Backend) -> Bool {
        switch backend {
        case .grok, .claude:
            return true
        case .codex, .hermes:
            // Codex runs its tool loop off the ChatGPT `codex login` session —
            // no keychain key, so selecting it never triggers a keychain
            // prompt. (An OpenAI API key can still be supplied via the
            // OPENAI_API_KEY environment variable for anyone who wants it.)
            return false
        }
    }

    func authorizeCodexAccount() {
        guard backend == .codex else { return }
        #if os(macOS)
        guard let codex = Self.codexExecutablePath() else {
            status = BackendReadiness.codexAuthorizationAction
            refreshReadiness(for: .codex)
            return
        }
        openTerminalLogin(command: "\(Self.shellQuote(codex)) login --device-auth", backend: .codex)
        #else
        status = "Codex authorization requires the Codex CLI on macOS."
        #endif
    }

    func authorizeGrokAccount() {
        guard backend == .grok else { return }
        #if os(macOS)
        guard let grok = Self.grokExecutablePath() else {
            status = BackendReadiness.grokAuthorizationAction
            refreshReadiness(for: .grok)
            return
        }
        openTerminalLogin(command: "\(Self.shellQuote(grok)) login", backend: .grok)
        #else
        status = "Grok authorization requires the Grok CLI on macOS."
        #endif
    }

    #if os(macOS)
    private func openTerminalLogin(command: String, backend: Backend) {
        let appleScript = """
        tell application "Terminal"
            activate
            do script "\(command.replacingOccurrences(of: "\"", with: "\\\""))"
        end tell
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", appleScript]
        do {
            try process.run()
            status = "\(backend.rawValue) authorization opened in Terminal."
        } catch {
            status = "\(backend.rawValue) authorization failed: \(error.localizedDescription)"
        }
        refreshReadiness(for: backend)
    }
    #endif

    nonisolated private static func codexExecutablePath() -> String? {
        let candidates = [
            "/Applications/Codex.app/Contents/Resources/codex",
            "\(NSHomeDirectory())/.local/bin/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex"
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    nonisolated private static func grokExecutablePath() -> String? {
        let candidates = [
            "\(NSHomeDirectory())/.grok/bin/grok",
            "\(NSHomeDirectory())/.local/bin/grok",
            "/opt/homebrew/bin/grok",
            "/usr/local/bin/grok"
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    nonisolated private static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
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

    func captureEvidence() {
        status = "Capturing Supabase evidence"
        Task {
            do {
                let output = try await Task.detached(priority: .userInitiated) {
                    try Self.runEvidenceIngest()
                }.value
                reviewQueueCandidates = try await reviewQueue.loadPendingClaims()
                status = output
            } catch {
                status = "Evidence capture failed: \(error.localizedDescription)"
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
        let prompt = composedDraftPrompt
        let attachmentsSnapshot = composerAttachments
        guard ComposerAttachment.canSend(userText: draft, attachments: attachmentsSnapshot), !isRunning else { return }
        // Send-time hook: a Due date or Nudge time also registers a oneshot
        // routine with the scheduler, and the returned copy has the schedule
        // signals consumed so a re-send cannot double-register.
        composerIntent = composerIntent.registeringScheduledRoutines(userText: prompt)
        refreshRoutePlan()
        let plannedRoute = routePlan
        draft = ""
        composerAttachments = []
        routePlan = plannedRoute
        isRunning = true
        status = plannedRoute.requiresApproval ? "Route planned; approval-gated steps detected" : "Checking graph authority"
        let selectedBackend = backend
        let trimmedKey = Self.usesAPIKey(selectedBackend) ? apiKey.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        let key = trimmedKey.isEmpty ? nil : trimmedKey
        // Persist a pasted key on first use so it survives relaunch.
        if let key, !hasSavedAPIKey, Self.usesAPIKey(selectedBackend) {
            try? APIKeyStore.saveKey(key, for: selectedBackend)
            hasSavedAPIKey = true
        }

        let service = service
        let ledger = ledger
        let ontology = ontology
        let sessionStore = sessions
        let existingSessionId = currentSessionId

        // One monitor per run: the loop reports progress into it and the
        // Cancel control aborts through it. The executor routes every tool
        // call through the bouncer before anything runs.
        let monitor = ToolLoopMonitor()
        activeToolLoop = monitor
        let executor = ToolExecutor.standard(approvals: toolApprovals, ledger: ledger)

        let historySnapshot = chatThread
        runTask = Task.detached(priority: .userInitiated) {
            let adapter = AgentRunnerBackendAdapter(backend: selectedBackend, apiKey: key)
            do {
                let sessionId: String
                if let existingSessionId {
                    sessionId = existingSessionId
                } else {
                    sessionId = try await sessionStore
                        .createSession(title: Self.sessionTitle(from: prompt))
                        .id
                    await MainActor.run { self.currentSessionId = sessionId }
                }

                let visionImages = try ComposerAttachmentStore.visionImages(from: attachmentsSnapshot)
                let detail = try await service.createRun(
                    prompt: prompt,
                    ontology: ontology,
                    backend: adapter,
                    images: visionImages,
                    conversationHistory: historySnapshot,
                    tools: HarnessToolCatalog.v1,
                    toolExecutor: executor,
                    toolLoop: monitor,
                    sessionId: sessionId
                )
                // Link the run and its transcript into the session so the
                // thread survives relaunch and becomes searchable.
                try? await sessionStore.attachRun(runId: detail.run.id, toSession: sessionId)
                let latestSessions = (try? await sessionStore.listSessions()) ?? []
                let latestRuns = try await ledger.listRuns()
                let answer = detail.messages.last(where: { $0.role == .assistant })?.text ?? detail.run.finalAnswer
                await MainActor.run {
                    // Only the still-active run may commit UI state. If this run
                    // was cancelled or superseded by a newer send, activeToolLoop
                    // no longer points at our monitor — leave the newer run alone.
                    guard self.activeToolLoop === monitor else { return }
                    self.runTask = nil
                    self.activeToolLoop = nil
                    self.isRunning = false
                    self.selectedDetail = detail
                    self.runs = latestRuns
                    if !latestSessions.isEmpty {
                        self.chatSessions = latestSessions
                    }
                    // Append to the visible thread only if the run's own session
                    // is still on screen; if Adam switched sessions mid-run, the
                    // transcript is already persisted and reappears when he
                    // reopens that session.
                    if self.currentSessionId == sessionId {
                        self.chatThread.append(ConversationTurn(role: .user, text: prompt))
                        self.chatThread.append(ConversationTurn(role: .assistant, text: answer))
                        self.status = detail.run.success ? "Trace saved" : "Backend failed; trace saved"
                    } else {
                        self.status = "Background run finished in another session"
                    }
                }
            } catch {
                await MainActor.run {
                    // Same supersession guard: a cancelled/superseded run must
                    // not clobber the newer run's status or isRunning flag.
                    guard self.activeToolLoop === monitor else { return }
                    self.runTask = nil
                    self.activeToolLoop = nil
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
            return "Evidence capture complete: \(count) new candidate\(count == 1 ? "" : "s")."
        }
        return "Evidence capture complete."
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

    private static let delegationAgentWatchlistEnabledKey = "Harness.DelegationAgent.watchlistEnabled"
    private static let delegationAgentPerRunCreditLimitKey = "Harness.DelegationAgent.perRunCreditLimit"
    private static let delegationAgentDailyCreditLimitKey = "Harness.DelegationAgent.dailyCreditLimit"
    private static let delegationAgentDailyCreditDateKey = "Harness.DelegationAgent.dailyCreditDate"
    private static let delegationAgentDailyCreditsUsedKey = "Harness.DelegationAgent.dailyCreditsUsed"

    private static func loadDelegationAgentWatchlistEnabled() -> Bool {
        guard UserDefaults.standard.object(forKey: delegationAgentWatchlistEnabledKey) != nil else {
            return true
        }
        return UserDefaults.standard.bool(forKey: delegationAgentWatchlistEnabledKey)
    }

    private static func saveDelegationAgentWatchlistEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: delegationAgentWatchlistEnabledKey)
    }

    private static func loadDelegationAgentPerRunCreditLimit() -> Int {
        let value = UserDefaults.standard.integer(forKey: delegationAgentPerRunCreditLimitKey)
        return value > 0 ? value : 10
    }

    private static func saveDelegationAgentPerRunCreditLimit(_ value: Int) {
        UserDefaults.standard.set(max(1, value), forKey: delegationAgentPerRunCreditLimitKey)
    }

    private static func loadDelegationAgentDailyCreditLimit() -> Int {
        let value = UserDefaults.standard.integer(forKey: delegationAgentDailyCreditLimitKey)
        return value > 0 ? value : 50
    }

    private static func saveDelegationAgentDailyCreditLimit(_ value: Int) {
        UserDefaults.standard.set(max(1, value), forKey: delegationAgentDailyCreditLimitKey)
    }

    private static func delegationAgentCreditsUsedToday(now: Date = Date()) -> Int {
        resetDelegationAgentDailyCreditsIfNeeded(now: now)
        return UserDefaults.standard.integer(forKey: delegationAgentDailyCreditsUsedKey)
    }

    private static func recordDelegationAgentCreditsUsed(_ count: Int, now: Date = Date()) {
        guard count > 0 else { return }
        resetDelegationAgentDailyCreditsIfNeeded(now: now)
        let current = UserDefaults.standard.integer(forKey: delegationAgentDailyCreditsUsedKey)
        UserDefaults.standard.set(current + count, forKey: delegationAgentDailyCreditsUsedKey)
    }

    private static func resetDelegationAgentDailyCreditsIfNeeded(now: Date = Date()) {
        let today = ISO8601DateFormatter().string(from: Calendar.current.startOfDay(for: now))
        let saved = UserDefaults.standard.string(forKey: delegationAgentDailyCreditDateKey)
        guard saved != today else { return }
        UserDefaults.standard.set(today, forKey: delegationAgentDailyCreditDateKey)
        UserDefaults.standard.set(0, forKey: delegationAgentDailyCreditsUsedKey)
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
                    permission: "Uses ChatGPT authorization from the Codex CLI.",
                    provenance: "Backend metadata records chatgpt-auth-local-cli invocation."
                ),
                WorkbenchTool(
                    title: "Grok",
                    icon: "sparkles",
                    state: .available,
                    detail: "local CLI",
                    summary: "Routes model packets to the local Grok CLI on macOS.",
                    permission: "Uses Grok authorization from the Grok CLI.",
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

    static func communicationSkills(from capabilities: [HarnessCapability]) -> WorkbenchToolGroup {
        let preferredOrder = Array(HarnessCapabilityRegistry.adamCommunicationSkillNames)
        let communication = capabilities.filter {
            $0.kind == .skill && HarnessCapabilityRegistry.adamCommunicationSkillNames.contains($0.name)
        }
        let sourcePriority = ["Agents", "Grok", "Harness", "Vault", "Claude", "Codex", "Hermes"]
        let ordered = preferredOrder.compactMap { name in
            for source in sourcePriority {
                if let match = communication.first(where: { $0.name == name && $0.sourceSystem == source }) {
                    return match
                }
            }
            return communication.first { $0.name == name }
        }
        let tools = ordered.map { capability in
            WorkbenchTool(
                id: "communication-\(capability.name)",
                title: communicationTitle(for: capability.name),
                icon: communicationIcon(for: capability.name),
                state: .available,
                detail: capability.sourceSystem.lowercased(),
                summary: capability.description,
                permission: "Inserts a skill reference into the composer draft.",
                provenance: capability.provenance,
                skillName: capability.name
            )
        }
        return WorkbenchToolGroup(id: "communication", title: "Communication", tools: tools)
    }

    private static func communicationTitle(for name: String) -> String {
        switch name {
        case "articulate-leadership-communication": return "Pyramid chapters"
        case "cognitive-fit": return "Cognitive fit"
        case "no-time-estimates": return "No time estimates"
        case "requirement-is-the-test": return "Requirement is test"
        case "market-inefficiency": return "Market inefficiency"
        case "adams-words": return "Adam's words"
        default: return name.replacingOccurrences(of: "-", with: " ")
        }
    }

    private static func communicationIcon(for name: String) -> String {
        switch name {
        case "articulate-leadership-communication": return "text.alignleft"
        case "cognitive-fit": return "square.grid.3x3"
        case "no-time-estimates": return "clock.badge.xmark"
        case "requirement-is-the-test": return "checkmark.seal"
        case "market-inefficiency": return "chart.line.uptrend.xyaxis"
        case "adams-words": return "quote.opening"
        default: return "sparkles"
        }
    }
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
    let skillName: String?

    init(
        id: String? = nil,
        title: String,
        icon: String,
        state: WorkbenchToolState,
        detail: String,
        summary: String,
        permission: String,
        provenance: String,
        skillName: String? = nil
    ) {
        self.id = id ?? title.lowercased().replacingOccurrences(of: " ", with: "-")
        self.title = title
        self.icon = icon
        self.state = state
        self.detail = detail
        self.summary = summary
        self.permission = permission
        self.provenance = provenance
        self.skillName = skillName
    }
}

enum WorkbenchToolState: String, Equatable {
    case available = "available"
    case readOnly = "read-only"
    case planned = "planned"
}
#endif
