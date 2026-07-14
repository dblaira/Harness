#if os(macOS)
import AppKit
import CryptoKit
import Foundation
import OntologyKit
import OSLog
import Security
import UniformTypeIdentifiers

private let suiteCaptureLogger = Logger(
    subsystem: "com.adamblair.Harness",
    category: "SuiteCapture"
)

@MainActor
final class MacWorkbenchModel: ObservableObject {
    @Published var ontology: Ontology = .empty
    @Published var runs: [HarnessRun] = []
    @Published var selectedDetail: HarnessRunDetail?
    @Published var chatThread: [ConversationTurn] = []
    @Published var draft = "" {
        didSet { refreshRoutePlan() }
    }
    /// WO-J field 2 ("When I am...I like to") -- conn-004 "Delegation is
    /// three sentences." Free text like `draft`, not a ComposerIntent
    /// signal (those are menu/toggle choices, this is Adam's own sentence).
    @Published var preferredApproach = "" {
        didSet { refreshRoutePlan() }
    }
    /// WO-J field 3 ("Done looks like...").
    @Published var doneCondition = "" {
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
    /// Human-readable evidence for the explicit Connections surface. This is
    /// separate from the compact status word so a red dot can never be the
    /// only explanation of what the user should do next.
    @Published private(set) var backendConnectionDetails: [Backend: String] = [:]
    @Published private(set) var backendLastCheckedAt: [Backend: Date] = [:]
    @Published var firecrawlAPIKey = ""
    @Published var hasFirecrawlAPIKey = false
    @Published var isRunning = false
    /// Captured synchronously at the Send boundary so the large answer window
    /// is already visible before routing, retrieval, or provider work begins.
    @Published private(set) var answerWindowPrompt = ""
    @Published private(set) var answerWindowStartTurnIndex = 0
    /// Frozen to the Send that opened the answer window. The popup never
    /// re-queries a mutable session and accidentally displays another chat's
    /// answer after a session switch.
    @Published private(set) var answerWindowAnswer: String?
    @Published var isAnswerWindowPresented = false
    /// WO-Q: a separate flag from isRunning -- a build-and-screenshot
    /// run is not a chat send, and "one builder, no parallelism" only
    /// needs to block a second build, not the whole app.
    @Published private(set) var isCapturingBuildScreenshot = false
    @Published var status = "Ledger ready"
    /// A Delegation-page send is a durable transaction, not a disappearing
    /// chat draft. Receipts are loaded from Harness's app-owned Application
    /// Support folder so relaunch persistence never asks for Documents access.
    @Published private(set) var delegationReceipts: [DelegationReceipt] = []
    @Published private(set) var delegationSubmissionError: String?
    @Published private(set) var activeDelegationReceiptID: String?
    @Published var searchText = ""
    @Published var chatSessions: [ChatSession] = []
    @Published var sessionSearchHits: [SessionSearchHit] = []
    @Published var currentSessionId: String?
    @Published var activeToolLoop: ToolLoopMonitor?
    @Published var showApprovalToast = false
    @Published var selectedTool: WorkbenchTool?
    @Published var reviewQueueCandidates: [MemoryCandidate] = []
    @Published var suiteCaptureReceipts: [SuiteCaptureReceipt] = []
    @Published var suiteCaptureIssues: [String] = []
    /// The Step Rail's gate state. Starts locked before the first check
    /// ever completes -- never assume open. See PatternGateChecker
    /// (fails CLOSED; CLAUDE.md hard rule 1).
    @Published private(set) var patternGateState = PatternGateState.locked(detail: "Not yet checked.")
    @Published var opportunityBoardRows: [OpportunityBoardRow] = []
    @Published var opportunityBoardLoadIssue: String?
    /// WO-N: the unlabeled pool -- .sourceCard rows the delegation board
    /// deliberately excludes (see loadOpportunityBoardRows).
    @Published var sourcePoolCards: [OpportunitySourceCard] = []
    /// WO-I: cards of "concepts currently holding my fascination"
    /// (Adam, design-brief-ios-workbench.md) -- his words or verbatim
    /// quoted sources only, sourced from watched .md files.
    @Published var fascinationCards: [FascinationCard] = []
    @Published private(set) var fascinationLoadIssue: String?
    @Published var connectors: [HarnessConnector] = HarnessConnectorRegistry.defaultConnectors(
        includeProtectedUserFolders: false
    )
    @Published var capabilities: [HarnessCapability] = HarnessCapabilityRegistry.defaultCapabilities(
        includeProtectedUserFolders: false
    )
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

    /// The skills list behind each composer box's plus menu (memo 20:
    /// "even plugins or skills anything like that").
    var workbenchCommunicationSkillTools: [WorkbenchTool] {
        WorkbenchToolGroup.communicationSkills(from: capabilities).tools
    }

    /// The bouncer's queue, observed directly by the approval cards in the
    /// chat transcript. "Agents propose. The bouncer checks. You decide."
    let toolApprovals = ToolApprovalStore()

    private let ledger: RunLedgerStore
    private let service: HarnessRunService
    private let captureAnalysisService: HarnessRunService
    private let reviewQueue: ReviewQueueStore
    private let sessions: SessionStore
    private let suiteCaptureReceiptStore: SuiteCaptureReceiptStore
    private let delegationReceiptStore: DelegationReceiptStore
    private var runTask: Task<Void, Never>?
    private var sendStartupTask: Task<Void, Never>?
    private var pendingSendID: UUID?
    private var responseDeadlineTask: Task<Void, Never>?
    private weak var responseDeadlinePresentedMonitor: ToolLoopMonitor?
    private var approvalToastTask: Task<Void, Never>?
    private let patternEvidenceStore = PatternEvidenceStore()
    private let patternGateChecker = PatternGateChecker()
    /// One ongoing build for v1 -- no build picker exists yet (cut from
    /// v1 scope). Stable across launches so ratings accumulate.
    let patternBuildId = MacWorkbenchModel.loadOrCreatePatternBuildId()
    private let buildScreenshotService = BuildScreenshotService()

    init() {
        let store: RunLedgerStore
        do {
            store = try RunLedgerStore.applicationDefault()
        } catch {
            store = try! RunLedgerStore.inMemory()
        }
        self.ledger = store
        self.service = HarnessRunService(
            ledger: store,
            authorityRetriever: CanonicalAcceptedGraphAuthorityRetriever()
        )
        self.captureAnalysisService = HarnessRunService(
            ledger: store,
            authorityRetriever: CanonicalAcceptedGraphAuthorityRetriever(),
            candidateExtractor: NoopCandidateMemoryExtractor()
        )
        self.reviewQueue = ReviewQueueStore(ledger: store)
        self.sessions = SessionStore(ledger: store)
        self.suiteCaptureReceiptStore = SuiteCaptureReceiptStore(
            root: SuiteCaptureReceiptStore.applicationDefaultRoot()
        )
        let delegationReceiptStore = DelegationReceiptStore(
            directory: Self.defaultOpportunityBoardDirectory()
        )
        self.delegationReceiptStore = delegationReceiptStore
        do {
            self.delegationReceipts = try delegationReceiptStore.load()
        } catch {
            self.delegationSubmissionError = "Saved delegations could not be loaded: \(error.localizedDescription)"
        }
        self.hasFirecrawlAPIKey = Self.loadFirecrawlAPIKey() != nil
        loadAPIKey(for: backend)
        checkAllBackendConnections()
        Task {
            await refreshRuns()
            await restoreMostRecentSession()
            await refreshSessions()
            refreshOpportunityBoard()
            refreshSourcePool()
            refreshConnectors()
            refreshFascinationCards()
            await refreshFleetLedger()
        }

        // Adam's list #7: phone captures land on their own -- re-scan
        // the watched folders every 5 minutes and whenever the app
        // comes back to the front ("It could be something that calls
        // every 30 minutes or every hour" -- 5 keeps it feeling live
        // for a folder scan that costs almost nothing).
        if Self.shouldRunSuiteCaptureBackgroundWork() {
            phoneCaptureTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    self?.refreshOpportunityBoard()
                    self?.refreshSourcePool()
                    self?.refreshSuiteCaptureInbox()
                }
            }
            NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.refreshOpportunityBoard()
                    self?.refreshSourcePool()
                    self?.refreshSuiteCaptureInbox()
                }
            }
        }

        // Re-confirm provider authorization whenever the signed app returns
        // to the foreground. A stale dot is not a connection contract.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.checkAllBackendConnections() }
        }
    }

    private var phoneCaptureTimer: Timer?
    private var phoneCaptureRefreshTask: Task<Void, Never>?
    private var suiteCaptureTask: Task<Void, Never>?

    func updateOntology(_ ontology: Ontology) {
        self.ontology = ontology
        refreshSuiteCaptureInbox()
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
        guard activeToolLoop == nil else {
            status = "Finish or cancel the current response before changing sessions"
            return
        }
        selectedDetail = nil
        chatThread = []
        currentSessionId = nil
        sessionSearchHits = []
        draft = ""
        preferredApproach = ""
        doneCondition = ""
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
        guard activeToolLoop == nil else {
            status = "Finish or cancel the current response before changing sessions"
            return
        }
        Task { await loadSession(session) }
    }

    func selectSessionSearchHit(_ hit: SessionSearchHit) {
        guard activeToolLoop == nil else {
            status = "Finish or cancel the current response before changing sessions"
            return
        }
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
            guard activeToolLoop == nil else { return }
            let messages = try await sessions.thread(sessionId: session.id)
            guard activeToolLoop == nil else { return }
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

    nonisolated static func ontologyDirectoryURLsReferToSameResource(
        _ lhs: URL,
        _ rhs: URL
    ) -> Bool {
        lhs.resolvingSymlinksInPath().standardizedFileURL
            == rhs.resolvingSymlinksInPath().standardizedFileURL
    }

    /// Receive every app capture first, without touching the review queue.
    /// Harness then analyzes one retained receipt at a time and is the only
    /// component allowed to form a proposal for Adam's review.
    func refreshSuiteCaptureInbox() {
        guard Self.shouldRunSuiteCaptureBackgroundWork() else { return }
        // Shared iCloud/Documents capture folders are an installed-app
        // capability. An ad-hoc copy launched from /tmp or DerivedData must
        // never touch them: macOS quite correctly turns that copy into a new
        // Documents-permission prompt. The signed installed app is the only
        // runtime allowed to poll the suite inbox.
        guard Self.canAccessExternalSuiteCaptureDirectories() else {
            suiteCaptureLogger.info("Suite capture refresh skipped for an untrusted app copy.")
            return
        }
        guard suiteCaptureTask == nil else { return }
        let receiptStore = suiteCaptureReceiptStore
        let sources = Self.defaultSuiteCaptureInboxSources()
        let importer = LocalSuiteCaptureInboxImporter(
            sources: sources,
            receiptStore: receiptStore
        )
        let analysisService = captureAnalysisService
        let ontologySnapshot = ontology
        let selectedBackend = backend
        let trimmedKey = Self.usesAPIKey(selectedBackend)
            ? apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            : ""
        let key = trimmedKey.isEmpty ? nil : trimmedKey
        let reviewQueue = reviewQueue
        let ledger = ledger
        let understoodBridgePoller = UnderstoodHarnessBridgeConfiguration().map {
            UnderstoodHarnessBridgePoller(
                client: UnderstoodHarnessBridgeClient(configuration: $0),
                receiptStore: receiptStore
            )
        }

        suiteCaptureLogger.info("Suite capture refresh started with \(sources.count) configured roots.")
        suiteCaptureTask = Task { [weak self] in
            guard let self else { return }
            let report = await importer.importAll()
            var analysisSummary: String?
            var candidateQueued = false
            var bridgeIssue: String?
            var migrationIssue: String?
            var reviewStatusIssue: String?
            var corruptReceiptPaths: [String] = []
            var migratedLegacyCandidateIDs: [String] = []

            do {
                migratedLegacyCandidateIDs = try await LegacySuiteCandidateQueueMigrator(
                    receiptStore: receiptStore
                ).migrate()
            } catch {
                migrationIssue = "Legacy proposal recovery failed: \(error.localizedDescription)"
                suiteCaptureLogger.error(
                    "Legacy proposal recovery failed: \(error.localizedDescription, privacy: .public)"
                )
            }

            if let understoodBridgePoller {
                do {
                    let result = try await understoodBridgePoller.poll()
                    if case .storedAndAcknowledged(let captureID) = result {
                        suiteCaptureLogger.info(
                            "Understood raw capture received and acknowledged: \(captureID, privacy: .public)"
                        )
                    }
                } catch {
                    bridgeIssue = "Understood capture bridge failed: \(error.localizedDescription)"
                    suiteCaptureLogger.error(
                        "Understood capture bridge failed: \(error.localizedDescription, privacy: .public)"
                    )
                }
            }

            do {
                var inventory = try await receiptStore.inspectReceipts()
                var receipts = inventory.receipts
                corruptReceiptPaths = inventory.corruptReceiptPaths
                do {
                    let claimStatuses = try await reviewQueue.loadClaimStatuses()
                    receipts = try await receiptStore.reconcileReviewStatuses(claimStatuses)
                } catch {
                    reviewStatusIssue = "Capture review status will retry: \(error.localizedDescription)"
                    suiteCaptureLogger.error(
                        "Capture review status reconciliation failed: \(error.localizedDescription, privacy: .public)"
                    )
                }
                if let pending = receipts.reversed().first(where: {
                    $0.state == .analysisPending || ($0.state == .analysisFailed && $0.analysisAttempts < 3)
                }) {
                    let relatedReceipts = Self.relatedSuiteCaptureReceipts(
                        to: pending,
                        in: receipts
                    )
                    do {
                        let receiptGroup = Self.uniqueSuiteCaptureReceipts(
                            [pending] + relatedReceipts
                        )
                        if let existingClaim = try await Self.existingReviewClaim(
                            for: pending,
                            relatedReceipts: relatedReceipts,
                            reviewQueue: reviewQueue
                        ) {
                            let detail: String
                            switch existingClaim.status {
                            case .pending:
                                detail = "Reconnected to an existing Harness proposal after receipt recovery."
                                candidateQueued = true
                                analysisSummary = "Capture reconnected to its existing Harness proposal."
                            case .accepted:
                                detail = "This producer record is already represented by an accepted Harness decision."
                                analysisSummary = "Capture retained — already represented by accepted authority."
                            case .rejected:
                                detail = "This producer record matches a Harness proposal Adam did not adopt."
                                analysisSummary = "Capture retained — its prior Harness proposal was not adopted."
                            }
                            for receipt in receiptGroup {
                                _ = try await receiptStore.recordExistingReviewClaim(
                                    for: receipt,
                                    candidateID: existingClaim.id,
                                    status: existingClaim.status,
                                    detail: detail
                                )
                            }
                        } else {
                            let adapter = AgentRunnerBackendAdapter(
                                backend: selectedBackend,
                                apiKey: key
                            )
                            let analyzer = SuiteCaptureAnalyzer(
                                runPrompt: { prompt, responseContract in
                                    let detail = try await analysisService.createRun(
                                        prompt: prompt,
                                        ontology: ontologySnapshot,
                                        backend: adapter,
                                        soul: SoulLoader.load(),
                                        responseContract: responseContract,
                                        tools: [],
                                        sessionId: "suite-capture-consolidation"
                                    )
                                    guard !SuiteCaptureAnalyzer.containsValidDecision(detail.run.finalAnswer),
                                          AgentRunner().supportsToolLoop(
                                            backend: selectedBackend,
                                            apiKey: key
                                          ) else {
                                        return detail
                                    }
                                    return try await Self.captureDecisionToolRun(
                                        prompt: prompt,
                                        backend: selectedBackend,
                                        apiKey: key,
                                        authorityHits: detail.authorityHits,
                                        memoryHits: detail.memoryHits,
                                        ledger: ledger
                                    )
                                },
                                candidateStager: CoordinatedReviewQueueMemoryStager()
                            )
                            let outcome = try await analyzer.analyze(
                                pending,
                                relatedReceipts: relatedReceipts
                            )
                            switch outcome {
                            case .notCandidate(let runID, let reason):
                                for receipt in receiptGroup {
                                    _ = try await receiptStore.recordAnalysis(
                                        for: receipt,
                                        state: .notCandidate,
                                        runID: runID,
                                        detail: reason
                                    )
                                }
                                analysisSummary = "Harness retained \(receiptGroup.count) capture\(receiptGroup.count == 1 ? "" : "s") — no candidate."
                            case .candidateQueued(let runID, let candidate):
                                for receipt in receiptGroup {
                                    _ = try await receiptStore.recordAnalysis(
                                        for: receipt,
                                        state: .candidateQueued,
                                        runID: runID,
                                        candidateIDs: [candidate.id],
                                        detail: "Harness formed a proposal for Adam's review."
                                    )
                                }
                                candidateQueued = true
                                analysisSummary = "Harness formed one proposal from \(pending.trustedSourceName)."
                            }
                        }
                    } catch {
                        for receipt in Self.uniqueSuiteCaptureReceipts([pending] + relatedReceipts) {
                            do {
                                _ = try await receiptStore.recordAnalysis(
                                    for: receipt,
                                    state: .analysisFailed,
                                    runID: nil,
                                    detail: error.localizedDescription
                                )
                            } catch {
                                suiteCaptureLogger.error(
                                    "Stale analysis result could not replace receipt state: \(error.localizedDescription, privacy: .public)"
                                )
                            }
                        }
                        analysisSummary = "Capture retained; Harness analysis will retry: \(error.localizedDescription)"
                        suiteCaptureLogger.error(
                            "Capture analysis failed: \(error.localizedDescription, privacy: .public)"
                        )
                    }
                    inventory = try await receiptStore.inspectReceipts()
                    receipts = inventory.receipts
                    corruptReceiptPaths = inventory.corruptReceiptPaths
                    do {
                        let claimStatuses = try await reviewQueue.loadClaimStatuses()
                        receipts = try await receiptStore.reconcileReviewStatuses(claimStatuses)
                    } catch {
                        reviewStatusIssue = "Capture review status will retry: \(error.localizedDescription)"
                    }
                }
                self.suiteCaptureReceipts = receipts
            } catch {
                analysisSummary = "Capture receipts unavailable: \(error.localizedDescription)"
                suiteCaptureLogger.error(
                    "Capture receipt refresh failed: \(error.localizedDescription, privacy: .public)"
                )
            }

            var issues: [String] = []
            if let bridgeIssue { issues.append(bridgeIssue) }
            if let migrationIssue { issues.append(migrationIssue) }
            if let reviewStatusIssue { issues.append(reviewStatusIssue) }
            issues += corruptReceiptPaths.map {
                "Unreadable capture receipt metadata retained for inspection: \($0)"
            }
            issues += report.missingRootPaths.map { path in
                if let source = sources.first(where: { $0.root.path == path }) {
                    return "Waiting for first \(source.trustedSource.displayName) capture."
                }
                return "Capture inbox not present: \(path)"
            }
            issues += report.inaccessibleRootPaths.map { "Capture inbox inaccessible: \($0)" }
            issues += report.invalidFiles.map { "Invalid capture retained at \($0.key): \($0.value)" }
            if !report.conflictCaptureIDs.isEmpty {
                issues.append("Capture ID conflicts preserved: \(report.conflictCaptureIDs.joined(separator: ", "))")
            }
            if !report.quarantinedCaptureIDs.isEmpty {
                issues.append("Credential-shaped captures retained locally and withheld from analysis: \(report.quarantinedCaptureIDs.joined(separator: ", "))")
            }
            self.suiteCaptureIssues = issues

            if candidateQueued || !migratedLegacyCandidateIDs.isEmpty {
                do {
                    self.reviewQueueCandidates = try await reviewQueue.loadPendingClaims()
                } catch {
                    issues.append("Proposal queued, but review cards could not reload: \(error.localizedDescription)")
                    self.suiteCaptureIssues = issues
                }
            }

            if let analysisSummary {
                self.status = analysisSummary
            } else if !migratedLegacyCandidateIDs.isEmpty {
                self.status = "Recovered \(migratedLegacyCandidateIDs.count) producer proposal\(migratedLegacyCandidateIDs.count == 1 ? "" : "s") as raw captures for Harness analysis."
            } else if !report.storedCaptureIDs.isEmpty {
                self.status = "Received \(report.storedCaptureIDs.count) raw app capture\(report.storedCaptureIDs.count == 1 ? "" : "s")."
            } else if !report.retainedFiles.isEmpty {
                self.status = "Capture received; producer archive will retry."
            }
            suiteCaptureLogger.info(
                "Suite capture refresh stored=\(report.storedCaptureIDs.count), duplicates=\(report.duplicateCaptureIDs.count), conflicts=\(report.conflictCaptureIDs.count)."
            )
            self.suiteCaptureTask = nil
        }
    }

    nonisolated static func shouldRunSuiteCaptureBackgroundWork(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        xctestRuntimePresent: Bool = NSClassFromString("XCTestCase") != nil
            || NSClassFromString("XCTest.XCTestCase") != nil
    ) -> Bool {
        guard environment["XCTestConfigurationFilePath"] == nil,
              environment["XCTestBundlePath"] == nil,
              environment["SWIFT_TESTING_ENABLED"] == nil else { return false }
        return !xctestRuntimePresent
    }

    nonisolated static func defaultSuiteCaptureInboxSources(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [SuiteCaptureInboxSource] {
        let mobileDocuments = homeDirectory
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Mobile Documents", isDirectory: true)
        let harnessDocuments = mobileDocuments
            .appendingPathComponent("iCloud~com~adamblair~harness", isDirectory: true)
            .appendingPathComponent("Documents", isDirectory: true)
        let recallDocuments = mobileDocuments
            .appendingPathComponent("iCloud~app~understood~recall", isDirectory: true)
            .appendingPathComponent("Documents", isDirectory: true)
        let newsCalmDocuments = mobileDocuments
            .appendingPathComponent("iCloud~com~newscalm~app", isDirectory: true)
            .appendingPathComponent("Documents", isDirectory: true)
        return [
            SuiteCaptureInboxSource(
                trustedSource: TrustedSuiteCaptureSource(id: "understood", displayName: "Understood"),
                root: harnessDocuments.appendingPathComponent("Harness Captures/Understood/Pending", isDirectory: true)
            ),
            SuiteCaptureInboxSource(
                trustedSource: TrustedSuiteCaptureSource(id: "recall", displayName: "Re_Call"),
                root: recallDocuments.appendingPathComponent("Harness Captures/Pending", isDirectory: true)
            ),
            SuiteCaptureInboxSource(
                trustedSource: TrustedSuiteCaptureSource(id: "news-calm", displayName: "News Calm"),
                root: newsCalmDocuments.appendingPathComponent("Harness Captures/Pending", isDirectory: true)
            ),
            SuiteCaptureInboxSource(
                trustedSource: TrustedSuiteCaptureSource(id: "recall-legacy", displayName: "Re_Call (legacy)"),
                root: recallDocuments.appendingPathComponent("Harness Candidates/Pending", isDirectory: true)
            ),
            SuiteCaptureInboxSource(
                trustedSource: TrustedSuiteCaptureSource(id: "news-calm-legacy", displayName: "News Calm (legacy)"),
                root: newsCalmDocuments.appendingPathComponent("Harness Candidates/Pending", isDirectory: true)
            ),
        ]
    }

    nonisolated static func relatedSuiteCaptureReceipts(
        to receipt: SuiteCaptureReceipt,
        in receipts: [SuiteCaptureReceipt]
    ) -> [SuiteCaptureReceipt] {
        guard receipt.capture.captureKind == "legacy_candidate_envelope",
              let plain = receipt.capture.payload["plain"]?.stringValue,
              !plain.isEmpty else { return [] }
        let producerID = SuiteCaptureProvenance.canonicalProducerID(
            for: receipt.trustedSourceID
        )
        let producerSource = receipt.capture.payload["source"]?.stringValue
        return receipts.filter {
            $0.id != receipt.id
                && SuiteCaptureProvenance.canonicalProducerID(for: $0.trustedSourceID) == producerID
                && $0.capture.captureKind == "legacy_candidate_envelope"
                && $0.capture.payload["plain"]?.stringValue == plain
                && $0.capture.payload["source"]?.stringValue == producerSource
                && ($0.state == .analysisPending
                    || ($0.state == .analysisFailed && $0.analysisAttempts < 3))
        }
    }

    nonisolated static func existingReviewClaim(
        for receipt: SuiteCaptureReceipt,
        relatedReceipts: [SuiteCaptureReceipt],
        reviewQueue: ReviewQueueStore
    ) async throws -> ReviewQueueClaimSnapshot? {
        let producerID = SuiteCaptureProvenance.canonicalProducerID(
            for: receipt.trustedSourceID
        )
        let captureIDs = Set(([receipt] + relatedReceipts).map(\.capture.captureID)).sorted()
        if let exact = try await reviewQueue.findClaim(
            sourceCaptureIDs: captureIDs,
            canonicalProducerID: producerID
        ) {
            return exact
        }
        guard receipt.capture.captureKind == "legacy_candidate_envelope",
              let plain = receipt.capture.payload["plain"]?.stringValue else {
            return nil
        }
        return try await reviewQueue.findLegacyClaim(
            normalizedPlainText: plain,
            canonicalProducerID: producerID
        )
    }

    nonisolated static func uniqueSuiteCaptureReceipts(
        _ receipts: [SuiteCaptureReceipt]
    ) -> [SuiteCaptureReceipt] {
        var seen: Set<String> = []
        return receipts.filter { seen.insert($0.id).inserted }
    }

    /// Subscription-backed Grok/Codex sessions can emit a conversational
    /// preamble instead of the requested JSON in a plain completion. Retry
    /// through a required structured tool call, then persist that decision as
    /// an ordinary Harness run before the analyzer stages anything.
    nonisolated static func captureDecisionToolRun(
        prompt: String,
        backend: Backend,
        apiKey: String?,
        authorityHits: [GraphAuthorityHit],
        memoryHits: [MemoryHit],
        ledger: RunLedgerStore
    ) async throws -> HarnessRunDetail {
        let start = Date()
        let acceptedContext = authorityHits.isEmpty
            ? "No matching accepted authority was retrieved."
            : authorityHits.map {
                "- \($0.subject) \($0.predicate) \($0.object) [\($0.source)]"
            }.joined(separator: "\n")
        let groundedPrompt = """
        \(prompt)

        ACCEPTED GRAPH AUTHORITY ALREADY RETRIEVED
        \(acceptedContext)

        If this capture is already represented by accepted authority, submit not_candidate and say that it is already accepted. Do not create a duplicate proposal.
        """
        let response = try await AgentRunner().runWithTools(
            backend: backend,
            system: "You are Harness's capture consolidation gate. Accepted graph authority outranks raw captures. You must call submit_capture_decision exactly once. Do not answer with prose.",
            user: groundedPrompt,
            apiKey: apiKey,
            tools: [SuiteCaptureAnalyzer.decisionTool],
            toolTranscript: []
        )
        let answer = try SuiteCaptureAnalyzer.decisionJSON(from: response)
        let runID = UUID().uuidString
        let redactor = SecretRedactor()
        let redactedPrompt = redactor.redact(groundedPrompt)
        let redactedAnswer = redactor.redact(answer)
        let packetHash = SHA256.hash(data: Data(redactedPrompt.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        let run = HarnessRun(
            id: runID,
            prompt: redactedPrompt,
            backend: backend.rawValue,
            modelName: backend.defaultModelName,
            invocationMethod: "capture-decision-tool",
            promptPacketHash: packetHash,
            success: true,
            duration: Date().timeIntervalSince(start),
            tokenCount: response.tokenCount,
            cost: response.cost,
            finalAnswer: redactedAnswer,
            deviceName: DeviceIdentity.currentName()
        )
        let detail = HarnessRunDetail(
            run: run,
            messages: [
                HarnessMessage(runId: runID, role: .user, text: redactedPrompt),
                HarnessMessage(runId: runID, role: .assistant, text: redactedAnswer),
            ],
            authorityHits: authorityHits.map { $0.attached(to: runID) },
            memoryHits: memoryHits.map { $0.attached(to: runID) },
            traceEvents: [
                TraceEvent(
                    runId: runID,
                    stage: .modelExecution,
                    message: "Captured one structured Harness consolidation decision."
                ),
            ],
            evalResults: [],
            memoryCandidates: [],
            validationResults: []
        )
        try await ledger.save(detail)
        return detail
    }

    /// Phone captures, kept OUT of the board/map -- Adam: "that map ...
    /// That's where I go to take an idea I want to really think about
    /// ... some of those ideas might not be that big deal ... I just
    /// needed to capture it in the moment and then I come back when
    /// I'm calm." They land on the left, below the pool jumble, until
    /// he works them or archives them.
    @Published private(set) var phoneArrivals: [OpportunityBoardRow] = []

    func refreshOpportunityBoard() {
        let directory = Self.authorizedOpportunityBoardDirectory()
        do {
            opportunityBoardRows = try Self.loadOpportunityBoardRows(from: directory)
            opportunityBoardLoadIssue = nil
        } catch {
            opportunityBoardLoadIssue = error.localizedDescription
        }

        // Keep the app-owned board available in every build, but do not
        // resolve the shared iCloud/Documents phone-drop container from an
        // ad-hoc test copy.
        guard Self.canAccessExternalSuiteCaptureDirectories() else { return }

        // Ubiquity container resolution, directory creation, and placeholder
        // materialization can all block on file-provider I/O. Never perform
        // them on the main actor: a disconnected provider previously froze
        // the entire Harness window in mkdirat during startup.
        guard phoneCaptureRefreshTask == nil else { return }
        phoneCaptureRefreshTask = Task { [weak self] in
            let rows = await Task.detached(priority: .utility) {
                Self.loadPhoneArrivalRows()
            }.value
            guard let self else { return }
            self.phoneArrivals = rows
            self.phoneCaptureRefreshTask = nil
        }
    }

    /// Archive, never delete: the file moves to Archive/ inside the
    /// shared pocket and the card leaves the arrivals stack.
    func archivePhoneArrival(_ row: OpportunityBoardRow) {
        let path = row.card.envelope.source
        Task { [weak self] in
            let didArchive = await Task.detached(priority: .utility) {
                guard FileManager.default.fileExists(atPath: path),
                      let dir = Self.phoneCaptureDelegationsDirectory() else { return false }
                let archive = dir.appendingPathComponent("Archive", isDirectory: true)
                do {
                    try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
                    let destination = archive.appendingPathComponent(URL(fileURLWithPath: path).lastPathComponent)
                    try FileManager.default.moveItem(at: URL(fileURLWithPath: path), to: destination)
                    return true
                } catch {
                    return false
                }
            }.value
            if didArchive {
                self?.refreshOpportunityBoard()
            }
        }
    }

    /// Documents/Delegations inside the suite's shared iCloud container.
    /// Resolved once by the background phone-capture loader (the first
    /// ubiquity lookup can touch disk); nil when iCloud is signed out or
    /// the entitlement isn't provisioned -- callers treat that as "no
    /// phone drops".
    nonisolated private static let phoneCaptureContainerURL: URL? = {
        FileManager.default.url(forUbiquityContainerIdentifier: "iCloud.com.adamblair.harness")
    }()

    /// Returns true only for the signed Harness runtime that owns the
    /// iCloud entitlement. Temporary ad-hoc copies share the bundle ID but do
    /// not carry a team identifier, and must not trigger a Documents prompt.
    nonisolated static func canAccessExternalSuiteCaptureDirectories() -> Bool {
        #if os(macOS)
        var code: SecStaticCode?
        let bundleURL = Bundle.main.bundleURL as CFURL
        guard SecStaticCodeCreateWithPath(bundleURL, SecCSFlags(), &code) == errSecSuccess,
              let code else { return false }
        var signingInformation: CFDictionary?
        guard SecCodeCopySigningInformation(
            code,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &signingInformation
        ) == errSecSuccess,
              let signingInformation,
              let values = signingInformation as? [String: Any],
              let teamIdentifier = values[kSecCodeInfoTeamIdentifier as String] as? String
        else { return false }
        return teamIdentifier == "7FKUS5M5QS"
        #else
        return false
        #endif
    }

    nonisolated static func phoneCaptureDelegationsDirectory() -> URL? {
        guard canAccessExternalSuiteCaptureDirectories() else { return nil }
        guard let container = phoneCaptureContainerURL else { return nil }
        let dir = container
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent("Delegations", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    nonisolated static func loadPhoneArrivalRows(from directory: URL? = nil) -> [OpportunityBoardRow] {
        guard let phoneDrop = directory ?? phoneCaptureDelegationsDirectory() else { return [] }
        downloadUbiquitousFiles(in: phoneDrop)
        let rows = (try? loadOpportunityBoardRows(from: phoneDrop)) ?? []
        // The recursive loader also walks Archive/ -- archived captures
        // stay stored ("I don't delete it. I just archive it") but leave
        // the canvas.
        return rows.filter { !$0.card.envelope.source.contains("/Archive/") }
    }

    /// iCloud placeholders (.icloud stubs) don't parse -- ask the daemon
    /// to materialize anything not yet local. Best effort, non-blocking.
    nonisolated static func downloadUbiquitousFiles(in directory: URL) {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.ubiquitousItemDownloadingStatusKey],
            options: [.skipsPackageDescendants]
        ) else { return }
        for case let file as URL in enumerator {
            let status = try? file.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]).ubiquitousItemDownloadingStatus
            if status == .notDownloaded {
                try? FileManager.default.startDownloadingUbiquitousItem(at: file)
            }
        }
    }

    nonisolated static func defaultOpportunityBoardDirectory() -> URL {
        let directory = defaultHarnessDocumentsDirectory()
            .appendingPathComponent("Delegations", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func authorizedOpportunityBoardDirectory() -> URL {
        defaultOpportunityBoardDirectory()
    }

    nonisolated static func loadOpportunityBoardRows(
        from directory: URL,
        fileManager: FileManager = .default
    ) throws -> [OpportunityBoardRow] {
        _ = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            throw CocoaError(.fileReadUnknown)
        }

        let parser = OpportunityCardParser()
        let validator = OpportunityCardValidator()
        var cards: [OpportunityCard] = []
        var readableMarkdownCount = 0
        var firstMarkdownReadError: Error?

        for case let file as URL in enumerator {
            guard file.pathExtension.lowercased() == "md" else { continue }
            let isRegularFile: Bool
            do {
                isRegularFile = try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true
            } catch {
                firstMarkdownReadError = firstMarkdownReadError ?? error
                continue
            }
            guard isRegularFile else { continue }
            let markdown: String
            do {
                markdown = try String(contentsOf: file, encoding: .utf8)
                readableMarkdownCount += 1
            } catch {
                firstMarkdownReadError = firstMarkdownReadError ?? error
                continue
            }
            guard case let .opportunity(card) = try? parser.parse(markdown: markdown, source: file.path),
                  validator.validate(card).passed
            else { continue }
            cards.append(card)
        }

        if readableMarkdownCount == 0, let firstMarkdownReadError {
            throw firstMarkdownReadError
        }

        return OpportunityBoardDeduper().deduplicate(cards)
    }

    // MARK: - Sources pool (WO-N)

    func refreshSourcePool() {
        do {
            sourcePoolCards = try Self.loadSourcePoolCards(from: Self.authorizedOpportunityBoardDirectory())
        } catch {}
    }

    /// WO-N: "Stop discarding .sourceCard rows" -- loadOpportunityBoardRows
    /// above deliberately keeps ONLY .opportunity (source files must not
    /// become delegation items, per its own test). This is the mirror:
    /// same watched folder, same parser, keeps ONLY .sourceCard.
    nonisolated static func loadSourcePoolCards(
        from directory: URL,
        fileManager: FileManager = .default
    ) throws -> [OpportunitySourceCard] {
        _ = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { throw CocoaError(.fileReadUnknown) }

        let parser = OpportunityCardParser()
        let validator = OpportunityCardValidator()
        var cards: [OpportunitySourceCard] = []
        var readableMarkdownCount = 0
        var firstMarkdownReadError: Error?

        for case let file as URL in enumerator {
            guard file.pathExtension.lowercased() == "md" else { continue }
            let isRegularFile: Bool
            do {
                isRegularFile = try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true
            } catch {
                firstMarkdownReadError = firstMarkdownReadError ?? error
                continue
            }
            guard isRegularFile else { continue }
            let markdown: String
            do {
                markdown = try String(contentsOf: file, encoding: .utf8)
                readableMarkdownCount += 1
            } catch {
                firstMarkdownReadError = firstMarkdownReadError ?? error
                continue
            }
            guard case let .sourceCard(card) = try? parser.parse(markdown: markdown, source: file.path),
                  validator.validate(card).passed
            else { continue }
            cards.append(card)
        }

        if readableMarkdownCount == 0, let firstMarkdownReadError {
            throw firstMarkdownReadError
        }

        return cards
    }

    /// Paste or drop a link into the pool -- writes a new source_card
    /// .md file into the same watched Delegations folder the scout
    /// already writes to, so it appears through the normal load path.
    /// No title, no folder picker: recognition-only capture.
    func captureSourcePoolLink(_ url: URL) {
        writeSourcePoolCard(resource: url.absoluteString, retrievedBy: "adam-paste")
    }

    /// Adam's list, item 3 (2026-07-09 voice memo): "I can click inside
    /// it and change the wording of it if I want." Rewrites the card
    /// file's title frontmatter with HIS words, verbatim, and reloads
    /// the pool. envelope.source is the file's own path (set by the
    /// parser at load).
    func updateSourcePoolCardTitle(_ card: OpportunitySourceCard, title: String) {
        let path = card.envelope.source
        guard FileManager.default.fileExists(atPath: path),
              var text = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        let escaped = title.replacingOccurrences(of: "\"", with: "\\\"")
        let titleLine = "title: \"\(escaped)\""
        if let range = text.range(of: #"(?m)^title:.*$"#, options: .regularExpression) {
            text.replaceSubrange(range, with: titleLine)
        } else if let range = text.range(of: #"(?m)^type:.*$"#, options: .regularExpression) {
            text.replaceSubrange(range, with: text[range] + "\n" + titleLine)
        } else {
            return
        }
        try? text.write(toFile: path, atomically: true, encoding: .utf8)
        refreshSourcePool()
    }

    /// Drop a local file (an image dragged from Finder, etc.) -- copies
    /// it into a pool-assets folder next to the watched Delegations
    /// folder so the capture survives even if the original moves, then
    /// writes the source_card pointing at the copy.
    func captureSourcePoolFile(_ localURL: URL) {
        let assetsDirectory = Self.authorizedOpportunityBoardDirectory().appendingPathComponent("pool-assets", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: assetsDirectory, withIntermediateDirectories: true)
            let ext = localURL.pathExtension.isEmpty ? "bin" : localURL.pathExtension
            let destination = assetsDirectory.appendingPathComponent("\(UUID().uuidString).\(ext)")
            try FileManager.default.copyItem(at: localURL, to: destination)
            writeSourcePoolCard(resource: destination.absoluteString, retrievedBy: "adam-drop")
        } catch {
            status = "Couldn't capture dropped file: \(error.localizedDescription)"
        }
    }

    private func writeSourcePoolCard(resource: String, retrievedBy: String) {
        let directory = Self.authorizedOpportunityBoardDirectory()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let contentHash = Self.sha256Hex(resource)
            let markdown = """
            ---
            type: source_card
            resource: \(resource)
            retrieved_by: \(retrievedBy)
            content_hash: \(contentHash)
            ---

            """
            let destination = directory.appendingPathComponent("pool-\(contentHash.prefix(12)).md")
            try markdown.write(to: destination, atomically: true, encoding: .utf8)
            refreshSourcePool()
            status = "Captured into the sources pool."
        } catch {
            status = "Couldn't capture into the sources pool: \(error.localizedDescription)"
        }
    }

    nonisolated private static func sha256Hex(_ text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - FASCINATION carousel (WO-I)

    func refreshFascinationCards() {
        let directory = Self.authorizedFascinationsDirectory()
        do {
            let cards = try Self.loadFascinationCards(from: directory)
            fascinationCards = cards
            fascinationLoadIssue = nil
        } catch {
            fascinationLoadIssue = error.localizedDescription
        }
    }

    nonisolated static func harnessDocumentsDirectoryURLsReferToSameResource(
        _ lhs: URL,
        _ rhs: URL
    ) -> Bool {
        lhs.resolvingSymlinksInPath().standardizedFileURL
            == rhs.resolvingSymlinksInPath().standardizedFileURL
    }

    nonisolated static func defaultHarnessDocumentsDirectory() -> URL {
        let root = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
            .appendingPathComponent("Harness", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    nonisolated static func defaultFascinationsDirectory() -> URL {
        let directory = defaultHarnessDocumentsDirectory()
            .appendingPathComponent("Fascinations", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func authorizedFascinationsDirectory() -> URL {
        defaultFascinationsDirectory()
    }

    /// Same watched-folder pattern as loadOpportunityBoardRows, kept as
    /// its own small parser rather than reusing OpportunityCardParser --
    /// a fascination card is just a verbatim quote + attribution + date,
    /// not the delegation-linked OpportunitySourceCard schema (WO-N).
    nonisolated static func loadFascinationCards(
        from directory: URL,
        fileManager: FileManager = .default
    ) throws -> [FascinationCard] {
        // FileManager.enumerator can return a non-nil enumerator that yields
        // no files when macOS denies Documents access. Force a throwing read
        // first so permission loss cannot masquerade as an empty carousel.
        _ = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { throw CocoaError(.fileReadUnknown) }

        var cards: [FascinationCard] = []
        var readableMarkdownCount = 0
        var firstMarkdownReadError: Error?
        for case let file as URL in enumerator {
            guard file.pathExtension.lowercased() == "md" else { continue }
            let isRegularFile: Bool
            do {
                isRegularFile = try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true
            } catch {
                firstMarkdownReadError = firstMarkdownReadError ?? error
                continue
            }
            guard isRegularFile else { continue }
            let markdown: String
            do {
                markdown = try String(contentsOf: file, encoding: .utf8)
                readableMarkdownCount += 1
            } catch {
                firstMarkdownReadError = firstMarkdownReadError ?? error
                continue
            }
            let (frontmatter, body) = Self.splitFrontmatter(markdown)
            let quote = body.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !quote.isEmpty else { continue }

            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
            let date = frontmatter["date"].flatMap(Self.fascinationDateFormatter.date(from:)) ?? modified
            let attribution = frontmatter["attribution"]?.trimmingCharacters(in: .whitespacesAndNewlines)
            cards.append(FascinationCard(
                id: file.path,
                quote: quote,
                attribution: (attribution?.isEmpty == false ? attribution! : nil) ?? "ADAM",
                date: date
            ))
        }
        if readableMarkdownCount == 0, let firstMarkdownReadError {
            throw firstMarkdownReadError
        }
        return cards.sorted { $0.date > $1.date }
    }

    /// Frontmatter is optional -- a card with none is still valid, its
    /// whole body is the quote and it's attributed to ADAM by default
    /// (recognition-only capture, no required fields to fill in first).
    nonisolated private static func splitFrontmatter(_ markdown: String) -> (frontmatter: [String: String], body: String) {
        let lines = markdown.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let closingIndex = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" })
        else {
            return ([:], markdown)
        }
        var frontmatter: [String: String] = [:]
        for line in lines[1..<closingIndex] {
            guard let colonIndex = line.firstIndex(of: ":") else { continue }
            let key = line[line.startIndex..<colonIndex].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colonIndex)...].trimmingCharacters(in: .whitespaces)
            frontmatter[key] = value
        }
        let body = lines[(closingIndex + 1)...].joined(separator: "\n")
        return (frontmatter, body)
    }

    nonisolated private static let fascinationDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

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
                if action == .pursue {
                    await self?.refreshFleetLedger()
                }
            } catch {
                await MainActor.run {
                    self?.status = "\(action.label) failed: \(error.localizedDescription)"
                }
            }
        }
    }

    // MARK: - Fleet ledger (WO-M)

    /// WO-M: "shipped this week" seeded from Pursue ledger actions --
    /// a v1 approximation (Pursue means "started," not "shipped"; there
    /// is no dedicated shipped event yet) named explicitly as a stand-in
    /// by the plan, not a claim of literal completion.
    @Published private(set) var fleetLedgerShippedThisWeek = 0
    @Published private(set) var delegationAgentDailySpend = MacWorkbenchModel.delegationAgentCreditsUsedToday()

    func refreshFleetLedger() async {
        delegationAgentDailySpend = Self.delegationAgentCreditsUsedToday()
        do {
            let records = try await ledger.listOpportunityBoardActions(limit: 500)
            let weekAgo = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? .distantPast
            fleetLedgerShippedThisWeek = records.filter { $0.action == .pursue && $0.createdAt >= weekAgo }.count
        } catch {
            fleetLedgerShippedThisWeek = 0
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
        let outputDirectory = Self.authorizedOpportunityBoardDirectory()
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
                await self?.refreshFleetLedger()
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
        connectors = HarnessConnectorRegistry.defaultConnectors(
            environment: Self.connectorEnvironment(),
            includeProtectedUserFolders: false
        )
        capabilities = HarnessCapabilityRegistry.defaultCapabilities(
            includeProtectedUserFolders: false
        )
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

    /// Adam's memo 20: "I should be able to add files separate files to
    /// each one of these chats ... there's some reference material that
    /// could be useful there." Keyed by the box's own label; rides into
    /// the composed prompt as reference lines under that box's words.
    @Published var composerFieldAttachments: [String: [ComposerFieldAttachment]] = [:]

    func addFieldAttachment(_ attachment: ComposerFieldAttachment, to field: String) {
        composerFieldAttachments[field, default: []].append(attachment)
    }

    func removeFieldAttachment(_ attachment: ComposerFieldAttachment, from field: String) {
        composerFieldAttachments[field]?.removeAll { $0.id == attachment.id }
    }

    private var fieldAttachmentLines: String {
        let ordered = ["WHAT DO I WANT?", "WHEN I AM...I LIKE TO", "DONE LOOKS LIKE..."]
        let lines = ordered.flatMap { field -> [String] in
            (composerFieldAttachments[field] ?? []).map { "Reference for \(field): \($0.promptLine)" }
        }
        return lines.isEmpty ? "" : "\n\n" + lines.joined(separator: "\n")
    }

    private var composedDraftPrompt: String {
        ComposerIntent.composedPrompt(
            userText: draft,
            attachments: composerAttachments,
            intent: composerIntent,
            preferredApproach: preferredApproach,
            doneCondition: doneCondition
        ) + fieldAttachmentLines
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

    /// Confirm the backend and publish its readiness — "live", "pending",
    /// or "failed (message)" — using SAVY's status vocabulary. API-backed
    /// providers receive a tiny authenticated connection request; Codex and
    /// Hermes use their authorization/health checks.
    func refreshReadiness(for backend: Backend) {
        backendReadiness[backend] = .checking
        backendConnectionDetails[backend] = "Checking authorization and connection…"
        let key = Self.usesAPIKey(backend) ? apiKey.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        Task { [weak self] in
            let readiness = await AgentRunner().checkConnection(
                backend: backend,
                apiKey: key.isEmpty ? nil : key
            )
            await MainActor.run {
                guard let self else { return }
                self.backendReadiness[backend] = readiness
                self.backendLastCheckedAt[backend] = Date()
                self.backendConnectionDetails[backend] = Self.connectionDetail(for: readiness)
                if let action = readiness.actionNeeded {
                    self.status = "\(backend.rawValue): \(action)"
                } else if case .failed(let message) = readiness {
                    self.status = "\(backend.rawValue) failed: \(message)"
                }
            }
        }
    }

    /// Run the same explicit check for every selectable model when the app
    /// opens or returns to the foreground. The selected backend is not the
    /// only one that matters: this makes switching models predictable.
    func checkAllBackendConnections() {
        for backend in Backend.allCases {
            refreshReadiness(for: backend)
        }
        status = "Checking model connections…"
    }

    nonisolated private static func connectionDetail(for readiness: BackendReadiness) -> String {
        switch readiness {
        case .checking:
            return "Checking authorization and connection…"
        case .live:
            return "Connection confirmed."
        case .pending(let action):
            return "Action needed: " + action + "."
        case .failed(let message):
            return message
        }
    }

    /// Cancel the in-flight run: abort the tool loop (which kills CLI/shell
    /// subprocesses), remove any pending approval from this stopped task, and
    /// restore the UI. A stale later approval can never execute cancelled work.
    func cancelRun() {
        guard isRunning else { return }
        sendStartupTask?.cancel()
        sendStartupTask = nil
        pendingSendID = nil
        responseDeadlineTask?.cancel()
        responseDeadlineTask = nil
        responseDeadlinePresentedMonitor = nil
        activeToolLoop?.cancel()
        // Drop the monitor so the run's own completion handler sees it is no
        // longer the active run and skips clobbering fresh UI state.
        activeToolLoop = nil
        AgentRunner.terminateRunningProcesses()
        runTask?.cancel()
        runTask = nil
        isRunning = false
        status = "Cancelled"
        let cancellationAnswer = InteractiveChatPolicy.cancelledAnswer()
        answerWindowAnswer = cancellationAnswer
        if let receiptID = activeDelegationReceiptID {
            finishDelegationReceipt(
                id: receiptID,
                state: .cancelled,
                result: cancellationAnswer
            )
            activeDelegationReceiptID = nil
        }
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
        case .codex: environmentName = nil
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
            // no API key or keychain account is loaded when it is selected.
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
        openTerminalLogin(command: "\(Self.shellQuote(grok)) login --oauth", backend: .grok)
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

    // MARK: - Build-and-screenshot spike (WO-Q)

    /// "One builder, one screen, no parallelism" -- this guard is that
    /// rule, not just a spinner.
    func captureBuildScreenshot() {
        guard !isCapturingBuildScreenshot else { return }
        isCapturingBuildScreenshot = true
        status = "Building and capturing a simulator screenshot — this can take a few minutes."
        let service = buildScreenshotService
        let outputDirectory = Self.defaultBuildEvidenceDirectory()
        let ledger = ledger
        Task { [weak self] in
            let detail = await Task.detached(priority: .userInitiated) {
                service.run(outputDirectory: outputDirectory)
            }.value
            try? await ledger.save(detail)
            await MainActor.run {
                guard let self else { return }
                self.isCapturingBuildScreenshot = false
                self.selectedDetail = detail
                self.status = detail.evalResults.first?.detail ?? detail.run.finalAnswer
            }
            await self?.refreshRuns()
        }
    }

    nonisolated static func defaultBuildEvidenceDirectory() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent("Harness", isDirectory: true)
            .appendingPathComponent("BuildEvidence", isDirectory: true)
    }

    func decideReviewQueueCandidate(_ candidate: MemoryCandidate, decision: ReviewQueueDecision) {
        let reviewQueue = reviewQueue
        let receiptStore = suiteCaptureReceiptStore
        Task {
            do {
                let outcome = try await reviewQueue.decide(claimId: candidate.id, decision: decision)
                var receiptUpdateIssue: String?
                if outcome.blockedReason == nil {
                    let detail: String
                    switch decision {
                    case .yes:
                        detail = "Adam accepted this Harness proposal as usually true."
                    case .sometimes:
                        detail = "Adam accepted this Harness proposal as sometimes true."
                    case .no:
                        detail = "Adam did not adopt this Harness proposal."
                    }
                    do {
                        _ = try await receiptStore.recordReviewOutcome(
                            candidateID: candidate.id,
                            accepted: outcome.accepted,
                            detail: detail
                        )
                    } catch {
                        receiptUpdateIssue = error.localizedDescription
                        suiteCaptureLogger.error(
                            "Review succeeded but capture receipt update failed: \(error.localizedDescription, privacy: .public)"
                        )
                    }
                }
                let pending = try await reviewQueue.loadPendingClaims()
                let receipts = (try? await receiptStore.listReceipts()) ?? self.suiteCaptureReceipts
                await MainActor.run {
                    self.reviewQueueCandidates = pending
                    self.suiteCaptureReceipts = receipts
                    if let blocked = outcome.blockedReason {
                        self.status = blocked
                    } else if let receiptUpdateIssue {
                        self.status = "Decision recorded. Capture History will reconcile: \(receiptUpdateIssue)"
                    } else {
                        self.status = "\(pending.count) candidate\(pending.count == 1 ? "" : "s") waiting"
                    }
                }
                self.refreshSuiteCaptureInbox()
            } catch {
                await MainActor.run {
                    self.status = error.localizedDescription
                }
            }
        }
    }

    /// Re-reads the gate. Fuseki unreachable AND no local accepted graph
    /// -> stays locked; this is the only path callers should trust for
    /// "is execution unlocked" (never infer it from ratings directly).
    func refreshPatternGate() async {
        patternGateState = await patternGateChecker.checkGate(buildId: patternBuildId)
    }

    func submitPatternRating(step: Int, rating: Int, evidenceNote: String) {
        let store = patternEvidenceStore
        let buildId = patternBuildId
        Task {
            do {
                try await store.record(
                    StepEvidenceRating(buildId: buildId, step: step, rating: rating, evidenceNote: evidenceNote)
                )
                await MainActor.run {
                    self.status = "Step \(step) rated \(rating)."
                }
            } catch {
                await MainActor.run {
                    self.status = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                }
            }
            await refreshPatternGate()
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

    /// Delegation owns a receipt-first transaction. The exact three fields are
    /// atomically written before this method is allowed to clear any of them.
    /// Chat continues to call `send()` and does not create a delegation file.
    func sendDelegation() {
        let attachmentsSnapshot = composerAttachments
        guard ComposerAttachment.canSend(userText: draft, attachments: attachmentsSnapshot), !isRunning else { return }

        let prompt = composedDraftPrompt
        let receipt = DelegationReceipt(
            intent: draft,
            preferredApproach: preferredApproach,
            doneCondition: doneCondition,
            state: .submitted
        )
        let sendID = presentAnswerWindow(prompt: prompt, status: "Saving delegation")

        // Give SwiftUI a render turn before any receipt or scheduler disk I/O.
        // The durable receipt still completes before the composer is cleared.
        sendStartupTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(16))
            guard let self,
                  !Task.isCancelled,
                  self.isRunning,
                  self.pendingSendID == sendID
            else { return }
            do {
                try self.delegationReceiptStore.save(receipt)
                self.delegationReceipts.removeAll { $0.id == receipt.id }
                self.delegationReceipts.insert(receipt, at: 0)
                self.delegationSubmissionError = nil
                self.activeDelegationReceiptID = receipt.id
                self.status = "Saved · Working"
                self.startSend(
                    id: sendID,
                    prompt: prompt,
                    attachmentsSnapshot: attachmentsSnapshot,
                    persistedDelegationReceiptID: receipt.id
                )
            } catch {
                // The draft remains untouched. A failed persistence attempt
                // may never look like a successful send.
                let message = "Delegation was not saved: \(error.localizedDescription)"
                self.pendingSendID = nil
                self.sendStartupTask = nil
                self.delegationSubmissionError = message
                self.status = message
                self.isRunning = false
                self.answerWindowAnswer = InteractiveChatPolicy.failureAnswer(message)
            }
        }
    }

    func send() {
        let prompt = composedDraftPrompt
        let attachmentsSnapshot = composerAttachments
        guard ComposerAttachment.canSend(userText: draft, attachments: attachmentsSnapshot), !isRunning else { return }
        let sendID = presentAnswerWindow(prompt: prompt, status: "Request received. Starting now.")

        // A render turn is a functional requirement: visible feedback must be
        // on screen before route registration, Keychain, retrieval, or model
        // setup can do synchronous work on the main actor.
        sendStartupTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(16))
            guard let self,
                  !Task.isCancelled,
                  self.isRunning,
                  self.pendingSendID == sendID
            else { return }
            self.startSend(
                id: sendID,
                prompt: prompt,
                attachmentsSnapshot: attachmentsSnapshot,
                persistedDelegationReceiptID: nil
            )
        }
    }

    @discardableResult
    private func presentAnswerWindow(prompt: String, status: String) -> UUID {
        let sendID = UUID()
        answerWindowPrompt = prompt
        answerWindowStartTurnIndex = chatThread.count
        answerWindowAnswer = nil
        isAnswerWindowPresented = true
        isRunning = true
        self.status = status
        pendingSendID = sendID
        return sendID
    }

    private func startSend(
        id sendID: UUID,
        prompt: String,
        attachmentsSnapshot: [ComposerAttachment],
        persistedDelegationReceiptID: String?
    ) {
        guard isRunning, pendingSendID == sendID else { return }
        pendingSendID = nil
        sendStartupTask = nil
        // Send-time hook: a Due date or Nudge time also registers a oneshot
        // routine with the scheduler, and the returned copy has the schedule
        // signals consumed so a re-send cannot double-register.
        composerIntent = composerIntent.registeringScheduledRoutines(userText: prompt)
        refreshRoutePlan()
        let plannedRoute = routePlan
        draft = ""
        preferredApproach = ""
        doneCondition = ""
        composerAttachments = []
        routePlan = plannedRoute
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
        responseDeadlinePresentedMonitor = nil
        let chatMode = InteractiveChatPolicy.mode(prompt: prompt, routePlan: plannedRoute)
        let acceptedAuthorityOnly = InteractiveChatPolicy.requestsAcceptedAuthorityOnly(prompt)
            && chatMode == .singleShot
        let productHelpAnswer = InteractiveChatPolicy.productHelpAnswer(for: prompt)
        let chatTools = InteractiveChatPolicy.tools(prompt: prompt, routePlan: plannedRoute)
        let maxToolIterations = InteractiveChatPolicy.maxToolIterations(
            prompt: prompt,
            routePlan: plannedRoute
        )
        let executor = chatTools.isEmpty
            ? nil
            : ToolExecutor.standard(approvals: toolApprovals, ledger: ledger)
        let interactiveDeadline = ContinuousClock().now.advanced(
            by: .seconds(InteractiveChatPolicy.watchdogBudgetSeconds)
        )

        let historySnapshot = chatThread
        // The submitted question is visible immediately. It must never vanish
        // merely because the provider stalls or Adam cancels the run.
        chatThread.append(ConversationTurn(role: .user, text: prompt))

        responseDeadlineTask?.cancel()
        responseDeadlineTask = Task { @MainActor [weak self] in
            while true {
                do {
                    try await Task.sleep(
                        for: .seconds(InteractiveChatPolicy.watchdogBudgetSeconds)
                    )
                } catch {
                    return
                }
                guard let self,
                      self.isRunning,
                      self.activeToolLoop === monitor
                else { return }

                // Human review is not provider latency. Keep the bouncer card
                // live for as long as Adam needs, then start a fresh response
                // budget after the decision is made.
                if !self.toolApprovals.pendingSnapshot().isEmpty {
                    self.status = "Waiting for your decision"
                    repeat {
                        do {
                            try await Task.sleep(for: .milliseconds(200))
                        } catch {
                            return
                        }
                        guard self.isRunning, self.activeToolLoop === monitor else { return }
                    } while !self.toolApprovals.pendingSnapshot().isEmpty
                    self.status = "Continuing after your decision"
                    continue
                }
                break
            }

            guard let self,
                  self.isRunning,
                  self.activeToolLoop === monitor
            else { return }

            let progress = monitor.progressSnapshot()
            let rawVisibleAnswer = progress.completedAnswer ?? InteractiveChatPolicy.deadlineFallback(
                backendName: selectedBackend.rawValue,
                acceptedEvidence: progress.acceptedEvidence,
                supportingEvidence: progress.supportingEvidence,
                toolEvidence: progress.toolEvidence
            )
            let visibleAnswer = InteractiveChatPolicy
                .enforceArticulateLeadershipFormat(rawVisibleAnswer)

            // Publish first, then tear down the losing provider/tool work. The
            // visible response contract never awaits a cancellation-ignoring
            // child task.
            self.answerWindowAnswer = visibleAnswer
            self.chatThread.append(ConversationTurn(role: .assistant, text: visibleAnswer))
            if let receiptID = persistedDelegationReceiptID {
                self.finishDelegationReceipt(id: receiptID, state: .failed, result: visibleAnswer)
                self.activeDelegationReceiptID = nil
            }
            self.status = "Response ceiling reached; showing retrieved evidence"
            self.isRunning = false
            self.responseDeadlinePresentedMonitor = monitor
            monitor.exceedDeadline()
            self.responseDeadlineTask = nil
            Task { @MainActor [weak self] in
                // Cooperative backends normally return immediately after the
                // monitor cancels them. If one ignores cancellation, release
                // the session/UI lock anyway; its eventual ledger result can
                // still attach without touching the visible thread.
                try? await Task.sleep(for: .seconds(1))
                guard let self,
                      !self.isRunning,
                      self.activeToolLoop === monitor
                else { return }
                self.activeToolLoop = nil
                self.responseDeadlinePresentedMonitor = nil
                self.runTask = nil
            }
        }

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
                    await MainActor.run {
                        guard self.activeToolLoop === monitor else { return }
                        self.currentSessionId = sessionId
                    }
                }

                let visionImages = try ComposerAttachmentStore.visionImages(from: attachmentsSnapshot)
                let detail = try await service.createRun(
                    prompt: prompt,
                    ontology: ontology,
                    backend: adapter,
                    images: visionImages,
                    conversationHistory: historySnapshot,
                    localAnswer: productHelpAnswer,
                    includeSupportingMemory: productHelpAnswer == nil && !acceptedAuthorityOnly,
                    answerFromAcceptedAuthority: acceptedAuthorityOnly,
                    tools: chatTools,
                    toolExecutor: executor,
                    toolLoop: monitor,
                    maxToolIterations: maxToolIterations,
                    // The UI watchdog pauses while a bouncer approval card is
                    // waiting. An absolute service deadline would count Adam's
                    // decision time as provider latency and expire immediately
                    // after approval, so tool turns use the pausable UI guard.
                    interactiveDeadline: chatTools.isEmpty ? interactiveDeadline : nil,
                    sessionId: sessionId
                )
                let rawAnswer = detail.messages.last(where: { $0.role == .assistant })?.text ?? detail.run.finalAnswer
                let answer = InteractiveChatPolicy
                    .enforceArticulateLeadershipFormat(rawAnswer)
                await MainActor.run {
                    // Only the still-active run may commit UI state. If this run
                    // was cancelled or superseded by a newer send, activeToolLoop
                    // no longer points at our monitor — leave the newer run alone.
                    guard self.activeToolLoop === monitor else { return }
                    let deadlineAlreadyPresented = self.responseDeadlinePresentedMonitor === monitor
                    self.responseDeadlineTask?.cancel()
                    self.responseDeadlineTask = nil
                    self.responseDeadlinePresentedMonitor = nil
                    self.runTask = nil
                    self.activeToolLoop = nil
                    self.isRunning = false
                    self.selectedDetail = detail
                    if !deadlineAlreadyPresented {
                        self.answerWindowAnswer = answer
                    }
                    if self.currentSessionId == sessionId {
                        if !deadlineAlreadyPresented {
                            self.chatThread.append(ConversationTurn(role: .assistant, text: answer))
                            if let receiptID = persistedDelegationReceiptID {
                                self.finishDelegationReceipt(
                                    id: receiptID,
                                    state: detail.run.success ? .completed : .failed,
                                    result: answer
                                )
                                self.activeDelegationReceiptID = nil
                            }
                        }
                        self.status = deadlineAlreadyPresented || answer.contains("Harness stopped waiting for")
                            ? "Response ceiling reached; showing retrieved evidence"
                            : (detail.run.success ? "Trace saved" : "Backend failed; trace saved")
                    } else {
                        self.status = "Background run finished in another session"
                    }
                }

                // The answer is already on screen. Session linking and list
                // refreshes are housekeeping and must not delay it. Even a
                // superseded run is linked so deadline fallbacks survive a
                // relaunch instead of becoming an orphaned visible bubble.
                try? await sessionStore.attachRun(runId: detail.run.id, toSession: sessionId)
                let latestSessions = (try? await sessionStore.listSessions()) ?? []
                let latestRuns = (try? await ledger.listRuns()) ?? []
                await MainActor.run {
                    self.runs = latestRuns
                    if !latestSessions.isEmpty {
                        self.chatSessions = latestSessions
                    }
                }
            } catch {
                await MainActor.run {
                    // Same supersession guard: a cancelled/superseded run must
                    // not clobber the newer run's status or isRunning flag.
                    guard self.activeToolLoop === monitor else { return }
                    let deadlineAlreadyPresented = self.responseDeadlinePresentedMonitor === monitor
                    self.responseDeadlineTask?.cancel()
                    self.responseDeadlineTask = nil
                    self.responseDeadlinePresentedMonitor = nil
                    self.runTask = nil
                    self.activeToolLoop = nil
                    self.status = deadlineAlreadyPresented
                        ? "Response ceiling reached; showing retrieved evidence"
                        : error.localizedDescription
                    self.isRunning = false
                    if !deadlineAlreadyPresented {
                        let failureAnswer = InteractiveChatPolicy.failureAnswer(
                            "Harness could not complete this request: \(error.localizedDescription)"
                        )
                        self.answerWindowAnswer = failureAnswer
                        self.chatThread.append(ConversationTurn(role: .assistant, text: failureAnswer))
                        if let receiptID = persistedDelegationReceiptID {
                            self.finishDelegationReceipt(
                                id: receiptID,
                                state: .failed,
                                result: failureAnswer
                            )
                            self.activeDelegationReceiptID = nil
                        }
                    }
                }
            }
        }
    }

    private func finishDelegationReceipt(
        id: String,
        state: DelegationReceiptState,
        result: String
    ) {
        guard let index = delegationReceipts.firstIndex(where: { $0.id == id }) else { return }
        var updated = delegationReceipts[index]
        updated.state = state
        updated.result = result
        updated.updatedAt = Date()
        delegationReceipts[index] = updated

        do {
            try delegationReceiptStore.save(updated)
            delegationSubmissionError = nil
        } catch {
            let message = "Delegation result is visible but was not saved: \(error.localizedDescription)"
            delegationSubmissionError = message
            status = message
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

    nonisolated private static func evidenceIngestScriptURL() -> URL? {
        let fileManager = FileManager.default
        var roots: [URL] = []
        let environment = ProcessInfo.processInfo.environment
        if let repoRoot = environment["HARNESS_REPO_ROOT"], !repoRoot.isEmpty {
            roots.append(URL(fileURLWithPath: repoRoot, isDirectory: true))
        }
        roots.append(fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Developer/GitHub/Harness"))
        if let user = environment["USER"], !user.isEmpty {
            roots.append(URL(fileURLWithPath: "/Users/\(user)/Developer/GitHub/Harness", isDirectory: true))
        }
        return roots
            .map { $0.appendingPathComponent("scripts/ingest_evidence.py") }
            .first { fileManager.fileExists(atPath: $0.path) }
    }

    nonisolated private static func runEvidenceIngest() throws -> String {
        guard let scriptURL = evidenceIngestScriptURL() else {
            throw NSError(
                domain: "HarnessEvidenceIngest",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "scripts/ingest_evidence.py was not found. Set HARNESS_REPO_ROOT to the repo checkout."]
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

        // Drain both pipes while the process runs; reading after
        // waitUntilExit() deadlocks once a pipe fills (the WO-1 class).
        let outputHandle = outputPipe.fileHandleForReading
        let errorHandle = errorPipe.fileHandleForReading
        var outputData = Data()
        var errorData = Data()
        let drainGroup = DispatchGroup()
        drainGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            outputData = outputHandle.readDataToEndOfFile()
            drainGroup.leave()
        }
        drainGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            errorData = errorHandle.readDataToEndOfFile()
            drainGroup.leave()
        }
        process.waitUntilExit()
        drainGroup.wait()

        let output = String(data: outputData, encoding: .utf8) ?? ""
        let error = String(data: errorData, encoding: .utf8) ?? ""

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

    private static let patternBuildIdKey = "Harness.patternBuildId"

    private static func loadOrCreatePatternBuildId() -> String {
        let defaults = UserDefaults.standard
        if let existing = defaults.string(forKey: patternBuildIdKey), !existing.isEmpty {
            return existing
        }
        let created = UUID().uuidString
        defaults.set(created, forKey: patternBuildIdKey)
        return created
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

/// WO-I: one card of "concepts currently holding my fascination"
/// (Adam, verbatim). `quote` is the .md file's body, untouched --
/// content obeys the note rule, his words or verbatim quoted sources
/// only. `attribution` defaults to "ADAM" for his own captured
/// observations; an external source (a book, a paper) names itself.
/// One thing Adam stuffed into a composer box: a file, an image, or a
/// skill (memo 20: "different files even plugins or skills anything
/// like that").
struct ComposerFieldAttachment: Identifiable, Equatable {
    enum Kind { case file, image, skill }
    let id = UUID()
    let kind: Kind
    let label: String
    let url: URL?

    var promptLine: String {
        switch kind {
        case .skill: return "[skill: \(label)]"
        case .file, .image: return "\(label) — \(url?.path ?? "")"
        }
    }
}

struct FascinationCard: Identifiable, Equatable {
    let id: String
    let quote: String
    let attribution: String
    let date: Date
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
                    detail: "ChatGPT session",
                    summary: "Routes model packets through the ChatGPT session proxy.",
                    permission: "Uses the existing ChatGPT authorization from Codex.",
                    provenance: "Backend metadata records chatgpt-session-proxy invocation."
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

enum DelegationReceiptState: String, Codable, Sendable, Equatable {
    case submitted
    case completed
    case failed
    case cancelled

    var label: String {
        switch self {
        case .submitted: return "SAVED"
        case .completed: return "COMPLETED"
        case .failed: return "FAILED"
        case .cancelled: return "CANCELLED"
        }
    }
}

struct DelegationReceipt: Identifiable, Codable, Sendable, Equatable {
    let id: String
    let intent: String
    let preferredApproach: String
    let doneCondition: String
    var state: DelegationReceiptState
    var result: String?
    let createdAt: Date
    var updatedAt: Date

    init(
        id: String = UUID().uuidString,
        intent: String,
        preferredApproach: String,
        doneCondition: String,
        state: DelegationReceiptState = .submitted,
        result: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.intent = intent
        self.preferredApproach = preferredApproach
        self.doneCondition = doneCondition
        self.state = state
        self.result = result
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
    }
}

enum DelegationReceiptStoreError: Error, LocalizedError, Equatable {
    case readbackMismatch

    var errorDescription: String? {
        switch self {
        case .readbackMismatch:
            return "The delegation receipt did not match after atomic write."
        }
    }
}

/// One JSON artifact per Delegation-page submission. `Data.write(.atomic)`
/// creates and renames a complete temporary file, so fields never clear on a
/// partial or failed write. The dedicated prefix keeps these receipts separate
/// from the existing markdown Opportunity Board parser in the same folder.
struct DelegationReceiptStore: Sendable {
    static let filenamePrefix = "DELEGATION-RECEIPT-"

    let directory: URL

    init(directory: URL) {
        self.directory = directory
    }

    func save(_ receipt: DelegationReceipt) throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(receipt)
        let destination = fileURL(for: receipt.id)
        try data.write(to: destination, options: .atomic)

        // The return code is not the acceptance test. Read the exact three
        // fields back before the caller is allowed to clear the composer.
        let saved = try decode(Data(contentsOf: destination))
        guard saved.id == receipt.id,
              saved.intent == receipt.intent,
              saved.preferredApproach == receipt.preferredApproach,
              saved.doneCondition == receipt.doneCondition,
              saved.state == receipt.state,
              saved.result == receipt.result
        else {
            throw DelegationReceiptStoreError.readbackMismatch
        }
    }

    func load() throws -> [DelegationReceipt] {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: directory.path) else { return [] }
        let files = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        return try files
            .filter {
                $0.lastPathComponent.hasPrefix(Self.filenamePrefix)
                    && $0.pathExtension.lowercased() == "json"
            }
            .map { try decode(Data(contentsOf: $0)) }
            .sorted {
                if $0.createdAt == $1.createdAt { return $0.id > $1.id }
                return $0.createdAt > $1.createdAt
            }
    }

    func fileURL(for receiptID: String) -> URL {
        directory.appendingPathComponent("\(Self.filenamePrefix)\(receiptID).json")
    }

    private func decode(_ data: Data) throws -> DelegationReceipt {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(DelegationReceipt.self, from: data)
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
