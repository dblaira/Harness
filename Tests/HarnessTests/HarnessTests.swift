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

@Test func workbenchCenterViewsIncludeDelegationQueue() {
    // Adam, 2026-07-09: the cockpit canvas IS the chat page (his
    // homepage) -- the separate Blueprint tab is gone for good, and
    // every surviving view keeps its same name.
    #expect(WorkbenchCenterView.allCases.map(\.rawValue) == ["chat", "cockpit", "board"])
    #expect(WorkbenchCenterView.chat.label == "Chat")
    #expect(WorkbenchCenterView.cockpit.label == "Cockpit")
    #expect(WorkbenchCenterView.board.label == "Delegation")
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
