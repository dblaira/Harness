import Foundation
import Testing
import OntologyKit
@testable import Harness

@Test func appCanLoadOntology() async throws {
    let onto = OntologyLoader.load()
    #expect(!onto.connections.isEmpty)
    #expect(!onto.axioms.isEmpty)
    #expect(onto.pattern.count == 8)
}

@Test func compactInspectorRailListsEverySectionWithCandidatesVisible() {
    let railOrder = WorkbenchInspectorTab.compactRailOrder

    #expect(railOrder == [
        .authority,
        .route,
        .memory,
        .candidates,
        .connectors,
        .skills,
        .trace
    ])
    #expect(railOrder.contains(.candidates))
    #expect(Set(railOrder) == Set(WorkbenchInspectorTab.allCases))
}

@Test func notebookLMComposerReferenceMarksSupportingContextOnly() {
    let source = NotebookLMSourceFile(
        url: URL(fileURLWithPath: "/Users/adamblair/Documents/Harness/NotebookLM/Market Research.md"),
        rootTitle: "NotebookLM",
        modifiedAt: .distantPast
    )
    let reference = MacWorkbenchModel.notebookLMReferenceText(for: source)

    #expect(reference.contains("[NotebookLM: Market Research]"))
    #expect(reference.contains("supporting research context only"))
    #expect(reference.contains("not accepted authority"))
}

@Test func notebookLMPowerPointImportCreatesSearchableIndexNote() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("HarnessNotebookLMImportTests-\(UUID().uuidString)", isDirectory: true)
    let downloads = root.appendingPathComponent("Downloads", isDirectory: true)
    let imports = root.appendingPathComponent("NotebookLM", isDirectory: true)
    try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: imports, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let source = downloads.appendingPathComponent("NotebookLM Strategy Deck.pptx")
    try Data([0x50, 0x4B, 0x03, 0x04]).write(to: source)

    let copied = try MacWorkbenchModel.copyFileIfNeeded(source, to: imports, fileManager: .default)
    let optionalIndex = try MacWorkbenchModel.createNotebookLMIndexIfNeeded(
        for: copied,
        originalURL: source,
        fileManager: .default
    )
    let index = try #require(optionalIndex)

    #expect(copied.deletingLastPathComponent() == imports)
    #expect(copied.lastPathComponent == "NotebookLM Strategy Deck.pptx")
    #expect(index.lastPathComponent == "NotebookLM Strategy Deck.harness.md")
    let indexText = try String(contentsOf: index, encoding: .utf8)
    #expect(indexText.contains("source-class: notebooklm-export"))
    #expect(indexText.contains("file-type: pptx"))
}

@Test func workbenchContextToolsIncludeNotebookLM() {
    let tools = WorkbenchToolGroup.defaults.flatMap(\.tools)

    #expect(tools.contains { $0.title == "NotebookLM" })
}

@Test func codexWorkbenchToolMatchesSessionProxyBackendMetadata() throws {
    let tools = WorkbenchToolGroup.defaults.flatMap(\.tools)
    let codex = try #require(tools.first { $0.title == "Codex" })

    #expect(codex.detail == "ChatGPT session")
    #expect(codex.summary == "Routes model packets through the ChatGPT session proxy.")
    #expect(codex.permission == "Uses the existing ChatGPT authorization from Codex.")
    #expect(codex.provenance == "Backend metadata records \(Backend.codex.invocationMethod) invocation.")
}

@Test func communicationWorkbenchToolsSurfaceAdamSkills() {
    let capabilities = HarnessCapabilityRegistry.defaultCapabilities()
    let group = WorkbenchToolGroup.communicationSkills(from: capabilities)

    #expect(group.title == "Communication")
    #expect(group.tools.count == HarnessCapabilityRegistry.adamCommunicationSkillNames.count)
    #expect(group.tools.contains { $0.title == "Pyramid chapters" && $0.skillName == "articulate-leadership-communication" })
    #expect(group.tools.contains { $0.title == "Adam's words" && $0.skillName == "adams-words" })
}

@Test func delegationQueueLoadsMarkdownFilesFromDirectory() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("HarnessDelegationQueueTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    try """
    ---
    type: delegation
    title: NotebookLM handoff scouts
    resource: https://example.com/notebooklm
    timestamp: 2026-07-04T10:00:00Z
    trust_level: accepted
    opp_id: DELEGATION-NOTEBOOKLM
    fit: 0.9
    rules_hit: [R-01, R-07]
    app: Understood
    window_days: 5
    effort: in
    attention: 40
    times_seen: 1
    sources: 2
    scout_id: agent-context
    ---
    Turn NotebookLM exports into reviewable sources.
    """.write(to: root.appendingPathComponent("DELEGATION-NOTEBOOKLM.md"), atomically: true, encoding: .utf8)

    try """
    ---
    type: source_card
    title: Supporting source
    resource: https://example.com/source
    retrieved_by: firecrawl-scrape
    content_hash: sha256:test
    linked_opportunities: [DELEGATION-NOTEBOOKLM]
    ---
    Source files should not become delegation items.
    """.write(to: root.appendingPathComponent("source.md"), atomically: true, encoding: .utf8)

    let rows = try MacWorkbenchModel.loadOpportunityBoardRows(from: root)

    #expect(rows.map(\.id) == ["DELEGATION-NOTEBOOKLM"])
    #expect(rows.first?.card.envelope.authorityLevel == .supporting)
    #expect(rows.first?.card.envelope.trustNote == "Self-declared trust_level accepted ignored; connector ceiling is supporting.")

    // WO-N: the mirror image of the assertion above -- the pool keeps
    // ONLY the source card, the delegation board keeps ONLY the
    // opportunity. Same directory, same files, opposite filter.
    let poolCards = try MacWorkbenchModel.loadSourcePoolCards(from: root)
    #expect(poolCards.map(\.envelope.resource) == ["https://example.com/source"])
    #expect(poolCards.first?.retrievedBy == "firecrawl-scrape")
}

@Test func workbenchCenterViewsAreExactlyDelegationThenChat() {
    // Adam's language, verbatim (2026-07-09): "2 pages the first one
    // is delegate with all of that beautiful design on it ... and then
    // chat would be ... just open chat box." Cockpit: "There's no such
    // thing as cockpit."
    #expect(WorkbenchCenterView.allCases.map(\.rawValue) == ["delegation", "chat"])
    #expect(WorkbenchCenterView.delegation.label == "Delegation")
    #expect(WorkbenchCenterView.chat.label == "Chat")
}

@Test func phoneArrivalLoaderKeepsArchivedCapturesOffTheCanvas() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let archive = root.appendingPathComponent("Archive", isDirectory: true)
    try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    try """
    ---
    type: opportunity
    opp_id: PHONE-ACTIVE
    title: Active phone capture
    resource: https://example.com/active
    fit: 0.9
    rules_hit: [R-01]
    app: Understood
    sources: 1
    ---
    Active phone capture.
    """.write(to: root.appendingPathComponent("PHONE-ACTIVE.md"), atomically: true, encoding: .utf8)

    try """
    ---
    type: opportunity
    opp_id: PHONE-ARCHIVED
    title: Archived phone capture
    resource: https://example.com/archived
    fit: 0.9
    rules_hit: [R-01]
    app: Understood
    sources: 1
    ---
    Archived phone capture.
    """.write(to: archive.appendingPathComponent("PHONE-ARCHIVED.md"), atomically: true, encoding: .utf8)

    let rows = MacWorkbenchModel.loadPhoneArrivalRows(from: root)

    #expect(rows.map(\.id) == ["PHONE-ACTIVE"])
}

@Test func suiteCaptureInboxRootsCoverEveryRuntimeProducerAndLegacyHandoff() {
    let sources = MacWorkbenchModel.defaultSuiteCaptureInboxSources(
        homeDirectory: URL(fileURLWithPath: "/Users/tester", isDirectory: true)
    )
    let roots = sources.map(\.root.path)

    #expect(roots == [
        "/Users/tester/Library/Mobile Documents/iCloud~com~adamblair~harness/Documents/Harness Captures/Understood/Pending",
        "/Users/tester/Library/Mobile Documents/iCloud~app~understood~recall/Documents/Harness Captures/Pending",
        "/Users/tester/Library/Mobile Documents/iCloud~com~newscalm~app/Documents/Harness Captures/Pending",
        "/Users/tester/Library/Mobile Documents/iCloud~app~understood~recall/Documents/Harness Candidates/Pending",
        "/Users/tester/Library/Mobile Documents/iCloud~com~newscalm~app/Documents/Harness Candidates/Pending",
    ])
    #expect(sources.map(\.trustedSource.id) == [
        "understood", "recall", "news-calm", "recall-legacy", "news-calm-legacy",
    ])
}

@Test func ontologyBookmarkRestoreAcceptsAnICloudSymlinkAlias() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("harness-bookmark-alias-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let canonical = root.appendingPathComponent("canonical/Ontology", isDirectory: true)
    let alias = root.appendingPathComponent("alias-Ontology", isDirectory: true)
    try FileManager.default.createDirectory(at: canonical, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: canonical)

    #expect(alias.standardizedFileURL != canonical.standardizedFileURL)
    #expect(MacWorkbenchModel.ontologyDirectoryURLsReferToSameResource(alias, canonical))
}

@Test func legacyProposalReceiptsGroupOnlyWithinTheSameTrustedProducer() {
    func receipt(
        _ id: String,
        plain: String,
        trustedSourceID: String = "news-calm-legacy",
        trustedSourceName: String = "News Calm (legacy)",
        producerSource: String = "News Calm — news-calm:preferences-feedback:adam"
    ) -> SuiteCaptureReceipt {
        SuiteCaptureReceipt(
            trustedSourceID: trustedSourceID,
            trustedSourceName: trustedSourceName,
            capture: SuiteCaptureEnvelope(
                captureID: id,
                capturedAt: "2026-07-11T20:00:00Z",
                captureKind: "legacy_candidate_envelope",
                payload: .object([
                    "plain": .string(plain),
                    "source": .string(producerSource),
                ])
            ),
            rawSHA256: String(repeating: "a", count: 64),
            rawCapturePath: "/tmp/\(id).json",
            receivedAt: "2026-07-11T20:00:00Z",
            updatedAt: "2026-07-11T20:00:00Z",
            state: .analysisPending
        )
    }
    let first = receipt("capture-legacy-one", plain: "AGENT PROPOSAL: same wording")
    let duplicate = receipt("capture-legacy-two", plain: "AGENT PROPOSAL: same wording")
    let duplicateQueueTransport = receipt(
        "capture-legacy-queue",
        plain: "AGENT PROPOSAL: same wording",
        trustedSourceID: "news-calm-legacy-queue",
        trustedSourceName: "News Calm (legacy queue)"
    )
    let different = receipt("capture-legacy-three", plain: "AGENT PROPOSAL: different")
    let differentProducerRecord = receipt(
        "capture-legacy-other-record",
        plain: "AGENT PROPOSAL: same wording",
        producerSource: "News Calm — news-calm:preferences-feedback:someone-else"
    )
    let foreignSource = receipt(
        "capture-legacy-four",
        plain: "AGENT PROPOSAL: same wording",
        trustedSourceID: "recall-legacy",
        trustedSourceName: "Re_Call (legacy)"
    )

    #expect(MacWorkbenchModel.relatedSuiteCaptureReceipts(
        to: first,
        in: [
            first, duplicate, duplicateQueueTransport, different,
            differentProducerRecord, foreignSource,
        ]
    ).map(\.capture.captureID) == [
        "capture-legacy-two", "capture-legacy-queue",
    ])
}

@Test func xctestNeverStartsTheLiveSuiteCaptureWorker() {
    #expect(!MacWorkbenchModel.shouldRunSuiteCaptureBackgroundWork(environment: [
        "XCTestConfigurationFilePath": "/tmp/HarnessTests.xctestconfiguration",
    ], xctestRuntimePresent: false))
    #expect(!MacWorkbenchModel.shouldRunSuiteCaptureBackgroundWork(
        environment: [:],
        xctestRuntimePresent: true
    ))
    #expect(MacWorkbenchModel.shouldRunSuiteCaptureBackgroundWork(
        environment: [:],
        xctestRuntimePresent: false
    ))
}

@Test func captureRecoveryFindsExistingLegacyDecisionBeforeModelAnalysis() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("harness-capture-recovery-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let candidates = root.appendingPathComponent("candidates", isDirectory: true)
    try FileManager.default.createDirectory(at: candidates, withIntermediateDirectories: true)
    try """
    [
      {
        "id": "cand-news-calm-already-reviewed",
        "status": "accepted",
        "plain": "AGENT PROPOSAL: Adam prefers brief news.",
        "evidence": "Legacy evidence.",
        "source": "News Calm",
        "domain_a": "learning",
        "domain_b": "affect",
        "connection_type": "stated_news_preference"
      }
    ]
    """.write(
        to: candidates.appendingPathComponent("queue.json"),
        atomically: true,
        encoding: .utf8
    )
    let reviewQueue = ReviewQueueStore(
        ontologyRoot: root,
        ledger: try RunLedgerStore.inMemory()
    )
    let receipt = SuiteCaptureReceipt(
        trustedSourceID: "news-calm-legacy-queue",
        trustedSourceName: "News Calm (legacy queue)",
        capture: SuiteCaptureEnvelope(
            captureID: "capture-legacy-recovery",
            capturedAt: "2026-07-11T20:00:00Z",
            captureKind: "legacy_candidate_envelope",
            payload: .object([
                "plain": .string("AGENT PROPOSAL: Adam prefers brief news."),
                "source": .string("News Calm"),
            ])
        ),
        rawSHA256: String(repeating: "c", count: 64),
        rawCapturePath: "/tmp/capture-legacy-recovery/raw-capture.json",
        receivedAt: "2026-07-11T20:00:00Z",
        updatedAt: "2026-07-11T20:00:00Z",
        state: .analysisPending
    )

    let existing = try await MacWorkbenchModel.existingReviewClaim(
        for: receipt,
        relatedReceipts: [],
        reviewQueue: reviewQueue
    )

    #expect(existing == ReviewQueueClaimSnapshot(
        id: "cand-news-calm-already-reviewed",
        status: .accepted
    ))
}

@Test func delegationQueueActionRecordsShareBatchForMultiSelect() {
    let rows = [
        opportunityBoardRow(id: "DELEGATION-ONE", resource: "https://example.com/one"),
        opportunityBoardRow(id: "DELEGATION-TWO", resource: "https://example.com/two")
    ]
    let records = MacWorkbenchModel.opportunityBoardActionRecords(
        action: .pass,
        rows: rows,
        batchID: "batch-one",
        createdAt: Date(timeIntervalSince1970: 100)
    )

    #expect(records.map(\.opportunityID) == ["DELEGATION-ONE", "DELEGATION-TWO"])
    #expect(Set(records.map(\.batchID)) == ["batch-one"])
    #expect(records.allSatisfy { $0.action == .pass })
}

@Test func delegationReceiptPersistsExactThreeFieldsAndReloads() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("harness-delegation-receipt-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = DelegationReceiptStore(directory: root.appendingPathComponent("Delegations", isDirectory: true))
    let receipt = DelegationReceipt(
        id: "receipt-exact-words",
        intent: "I want proof the harness app works.",
        preferredApproach: "make my intentions clear, so the app can use it’s own system",
        doneCondition: "A response that shows personalization about me,\ndone within 15 seconds.",
        state: .submitted,
        createdAt: Date(timeIntervalSince1970: 1_000)
    )

    try store.save(receipt)

    let artifact = store.fileURL(for: receipt.id)
    #expect(FileManager.default.fileExists(atPath: artifact.path))
    let reloaded = try DelegationReceiptStore(directory: store.directory).load()
    #expect(reloaded.count == 1)
    #expect(reloaded.first?.id == receipt.id)
    #expect(reloaded.first?.intent == receipt.intent)
    #expect(reloaded.first?.preferredApproach == receipt.preferredApproach)
    #expect(reloaded.first?.doneCondition == receipt.doneCondition)
    #expect(reloaded.first?.state == .submitted)
}

@Test func delegationReceiptResultAtomicallyReplacesSubmittedState() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("harness-delegation-result-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = DelegationReceiptStore(directory: root)
    var receipt = DelegationReceipt(
        id: "receipt-result",
        intent: "Do the work",
        preferredApproach: "Use Harness",
        doneCondition: "The result is visible",
        state: .submitted,
        createdAt: Date(timeIntervalSince1970: 2_000)
    )
    try store.save(receipt)

    receipt.state = .completed
    receipt.result = "Visible result"
    receipt.updatedAt = Date(timeIntervalSince1970: 2_001)
    try store.save(receipt)

    let reloaded = try store.load()
    #expect(reloaded.count == 1)
    #expect(reloaded.first?.state == .completed)
    #expect(reloaded.first?.result == "Visible result")
}

@Test func delegationReceiptSaveFailureProducesNoFalseArtifact() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("harness-delegation-blocked-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    try Data("not a directory".utf8).write(to: root)
    let store = DelegationReceiptStore(directory: root)
    let receipt = DelegationReceipt(
        intent: "Keep this draft",
        preferredApproach: "Do not clear it",
        doneCondition: "A visible save error",
        state: .submitted
    )

    #expect(throws: (any Error).self) {
        try store.save(receipt)
    }
    #expect(!FileManager.default.fileExists(atPath: store.fileURL(for: receipt.id).path))
}

@Test func harnessInternalStorageNeverRequiresDocumentsFolderAccess() {
    let root = MacWorkbenchModel.defaultHarnessDocumentsDirectory().standardizedFileURL.path
    let delegations = MacWorkbenchModel.defaultOpportunityBoardDirectory().standardizedFileURL.path
    let fascinations = MacWorkbenchModel.defaultFascinationsDirectory().standardizedFileURL.path

    #expect(root.contains("/Library/Application Support/Harness"))
    #expect(!root.contains("/Documents/Harness"))
    #expect(delegations.hasPrefix(root))
    #expect(fascinations.hasPrefix(root))
}

@Test func answerWindowMakesTheAnswerAPrimaryReadingSurface() {
    #expect(HarnessAnswerWindowLayout.minimumWidth >= 900)
    #expect(HarnessAnswerWindowLayout.minimumHeight >= 650)
    #expect(HarnessAnswerWindowLayout.minimumReadingFraction >= 0.60)
    #expect(HarnessAnswerWindowLayout.answerBodyPointSize >= 17)

    let compactWindow = CGSize(width: 560, height: 680)
    let fitted = HarnessAnswerWindowLayout.fittedSize(in: compactWindow)
    #expect(fitted.width <= compactWindow.width)
    #expect(fitted.height <= compactWindow.height)
    #expect(fitted == CGSize(width: 520, height: 640))
}

@Test @MainActor func chatSendPresentsTheAnswerWindowBeforeBackendWorkCompletes() {
    let model = MacWorkbenchModel()
    model.chatThread = []
    model.draft = "How do I add a new belief?"

    model.send()

    #expect(model.isAnswerWindowPresented)
    #expect(model.answerWindowPrompt == "How do I add a new belief?")
    #expect(model.answerWindowStartTurnIndex == 0)
    #expect(model.isRunning)
    #expect(model.activeToolLoop == nil)

    model.cancelRun()
    #expect(model.answerWindowAnswer == InteractiveChatPolicy.cancelledAnswer())
    #expect(!model.isRunning)
    model.isAnswerWindowPresented = false
}

@Test @MainActor func delegationSendPresentsTheAnswerWindowBeforeReceiptWorkBegins() {
    let model = MacWorkbenchModel()
    model.chatThread = []
    model.draft = "Turn this intent into a completed delegation."
    model.preferredApproach = "Keep the work visible while it runs."
    model.doneCondition = "A readable answer appears in Harness."

    model.sendDelegation()

    #expect(model.isAnswerWindowPresented)
    #expect(model.answerWindowPrompt.contains("Turn this intent into a completed delegation."))
    #expect(model.isRunning)
    #expect(model.activeToolLoop == nil)

    model.cancelRun()
    #expect(model.answerWindowAnswer == InteractiveChatPolicy.cancelledAnswer())
    model.isAnswerWindowPresented = false
}

private func opportunityBoardRow(id: String, resource: String) -> OpportunityBoardRow {
    let envelope = OpportunityCardEnvelope(
        source: "\(id).md",
        type: "opportunity",
        title: id,
        resource: resource,
        authorityLevel: .supporting
    )
    let card = OpportunityCard(
        envelope: envelope,
        oppID: id,
        fit: 0.8,
        rulesHit: ["R-01"],
        app: .understood,
        windowDays: 5,
        effort: .fits,
        sources: 1
    )
    return OpportunityBoardRow(canonicalResource: resource, card: card, history: [card])
}
