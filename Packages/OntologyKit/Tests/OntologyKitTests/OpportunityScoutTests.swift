import Foundation
import Testing
@testable import OntologyKit

@Test func delegationFixtureParsesValidatesAndComputesPriority() throws {
    let markdown = try fixtureText("OPP-0001.md")
    let parsed = try OpportunityCardParser().parse(markdown: markdown, source: "Tests/fixtures/OPP-0001.md")
    let delegation = try #require(parsed.opportunity)

    #expect(delegation.envelope.type == "delegation")
    #expect(delegation.envelope.title == "Journaling app sunsets exports Aug 1 - migration vacuum")
    #expect(delegation.envelope.tags == ["platform-watch", "migration"])
    #expect(delegation.envelope.resource == "https://example-journal.app/blog/sunset-notice")
    #expect(delegation.envelope.declaredTrustLevel == "supporting_memory")
    #expect(delegation.envelope.authorityLevel == .supporting)
    #expect(delegation.envelope.trustNote == nil)
    #expect(delegation.oppID == "DELEGATION-0001")
    #expect(delegation.fit == 0.91)
    #expect(delegation.rulesHit == ["R-01", "R-02", "R-07"])
    #expect(delegation.app == .understood)
    #expect(delegation.windowDays == 27)
    #expect(delegation.effort == .fits)
    #expect(delegation.dollarOrder == "100K")
    #expect(delegation.attention == 143)
    #expect(delegation.timesSeen == 5)
    #expect(delegation.sources == 9)
    #expect(delegation.scoutID == "agent-platform")
    #expect(delegation.body.contains("plain-English case"))
    #expect(abs(delegation.priority - 3.25) < 0.0001)

    let validation = OpportunityCardValidator().validate(delegation)
    #expect(validation.passed)
    #expect(validation.reason == "Delegation file passed typed validation.")
}

@Test func sourceFileFixtureParsesAndRequiresRetrievalMetadata() throws {
    let markdown = try fixtureText("OPP-0001-source.md")
    let parsed = try OpportunityCardParser().parse(markdown: markdown, source: "Tests/fixtures/OPP-0001-source.md")
    let sourceCard = try #require(parsed.sourceCard)

    #expect(sourceCard.envelope.type == "source_card")
    #expect(sourceCard.envelope.title == "Sunset notice - Example Journal blog")
    #expect(sourceCard.envelope.resource == "https://example-journal.app/blog/sunset-notice")
    #expect(sourceCard.retrievedBy == "firecrawl-scrape")
    #expect(sourceCard.contentHash == "sha256:9f2c...")
    #expect(sourceCard.linkedOpportunities == ["DELEGATION-0001"])
    #expect(sourceCard.envelope.authorityLevel == .supporting)

    let validation = OpportunityCardValidator().validate(sourceCard)
    #expect(validation.passed)
    #expect(validation.reason == "Source file passed typed validation.")
}

@Test func delegationTrustLevelCannotSelfPromote() throws {
    let markdown = """
    ---
    type: delegation
    title: Self promoting delegation
    resource: https://example.com/self-promote
    timestamp: 2026-07-04T10:00:00Z
    trust_level: accepted
    opp_id: DELEGATION-9999
    fit: 0.7
    rules_hit: [R-01]
    app: Understood
    effort: in
    sources: 1
    ---
    An agent claim that should stay supporting memory.
    """

    let parsed = try OpportunityCardParser().parse(markdown: markdown, source: "self-promote.md")
    let delegation = try #require(parsed.opportunity)

    #expect(delegation.envelope.declaredTrustLevel == "accepted")
    #expect(delegation.envelope.authorityLevel == .supporting)
    #expect(delegation.envelope.trustNote == "Self-declared trust_level accepted ignored; connector ceiling is supporting.")
}

@Test func delegationCaseAgainstParsesWhenPresentAndIsNilWhenAbsent() throws {
    let withDissent = """
    ---
    type: delegation
    title: Has dissent
    resource: https://example.com/has-dissent
    fit: 0.7
    rules_hit: [R-01]
    app: Understood
    effort: in
    sources: 1
    case_against: "Still Step 1 -- only one source seen so far, no pattern confirmed yet."
    ---
    Body text.
    """
    let withDissentParsed = try #require(try OpportunityCardParser().parse(markdown: withDissent, source: "a.md").opportunity)
    #expect(withDissentParsed.caseAgainst == "Still Step 1 -- only one source seen so far, no pattern confirmed yet.")

    let withoutDissent = """
    ---
    type: delegation
    title: No dissent field
    resource: https://example.com/no-dissent
    fit: 0.7
    rules_hit: [R-01]
    app: Understood
    effort: in
    sources: 1
    ---
    Body text.
    """
    let withoutDissentParsed = try #require(try OpportunityCardParser().parse(markdown: withoutDissent, source: "b.md").opportunity)
    #expect(withoutDissentParsed.caseAgainst == nil)
}

@Test func malformedDelegationIsBlockedWithPlainEnglishReasons() throws {
    let markdown = """
    ---
    type: delegation
    title: Missing rules and bad fit
    resource: https://example.com/bad
    fit: 1.4
    app: Atlantis
    sources: 0
    ---
    This should not reach the queue.
    """

    let parsed = try OpportunityCardParser().parse(markdown: markdown, source: "bad.md")
    let delegation = try #require(parsed.opportunity)
    let validation = OpportunityCardValidator().validate(delegation)

    #expect(!validation.passed)
    #expect(validation.reason.contains("rules_hit must include at least one accepted rule ID."))
    #expect(validation.reason.contains("fit must be between 0 and 1."))
    #expect(validation.reason.contains("app must be News Calm, Notorious Recall, Understood, or SAVY."))
    #expect(validation.reason.contains("sources must be at least 1."))
}

@Test func delegationDedupMergesByCanonicalResourceAndPreservesHistory() throws {
    let first = try #require(try OpportunityCardParser().parse(markdown: """
    ---
    type: delegation
    title: First title
    resource: https://Example-Journal.app/blog/sunset-notice?utm_source=newsletter
    timestamp: 2026-07-01T10:00:00Z
    opp_id: DELEGATION-0001
    fit: 0.8
    rules_hit: [R-01]
    app: Understood
    window_days: 10
    effort: in
    attention: 12
    times_seen: 1
    sources: 1
    ---
    First sighting.
    """, source: "first.md").opportunity)
    let duplicate = try #require(try OpportunityCardParser().parse(markdown: """
    ---
    type: delegation
    title: Later title
    resource: https://example-journal.app/blog/sunset-notice
    timestamp: 2026-07-04T10:00:00Z
    opp_id: DELEGATION-0002
    fit: 0.7
    rules_hit: [R-02]
    app: Notorious Recall
    effort: in
    attention: 30
    times_seen: 1
    sources: 2
    ---
    Duplicate sighting.
    """, source: "duplicate.md").opportunity)

    let rows = OpportunityBoardDeduper().deduplicate([first, duplicate])

    let row = try #require(rows.first)
    #expect(rows.count == 1)
    #expect(row.card.oppID == "DELEGATION-0001")
    #expect(row.card.envelope.resource == "https://example-journal.app/blog/sunset-notice")
    #expect(row.card.envelope.timestamp == "2026-07-04T10:00:00Z")
    #expect(row.card.attention == 42)
    #expect(row.card.timesSeen == 2)
    #expect(row.history.map(\.oppID) == ["DELEGATION-0001", "DELEGATION-0002"])
}

@Test func delegationQueueProjectionSupportsAllAndByAppViews() throws {
    let understood = try delegationItem(
        id: "DELEGATION-UNDERSTOOD",
        resource: "https://example.com/understood",
        fit: 0.8,
        app: "Understood",
        windowDays: 3,
        rules: ["R-01"],
        attention: 20
    )
    let notorious = try delegationItem(
        id: "DELEGATION-NOTORIOUS",
        resource: "https://example.com/notorious",
        fit: 0.65,
        app: "Notorious Recall",
        windowDays: 20,
        rules: ["R-02"],
        attention: 10
    )
    let newsCalm = try delegationItem(
        id: "DELEGATION-NEWS",
        resource: "https://example.com/news",
        fit: 0.2,
        app: "News Calm",
        windowDays: 120,
        rules: ["R-03"],
        attention: 5
    )

    let rows = OpportunityBoardDeduper().deduplicate([notorious, newsCalm, understood])
    let queue = OpportunityBoardProjection(rows: rows)

    #expect(queue.rows(for: .all).map(\.id) == ["DELEGATION-UNDERSTOOD", "DELEGATION-NOTORIOUS", "DELEGATION-NEWS"])
    #expect(queue.groupsByApp().map(\.app) == [.newsCalm, .notoriousRecall, .understood])
    #expect(queue.groupsByApp().flatMap(\.rows).map(\.id) == ["DELEGATION-NEWS", "DELEGATION-NOTORIOUS", "DELEGATION-UNDERSTOOD"])
}

@Test func delegationQueueViewModeRawValuesAreStableForPersistence() {
    #expect(OpportunityBoardViewMode.all.rawValue == "all")
    #expect(OpportunityBoardViewMode.byApp.rawValue == "by_app")
    #expect(OpportunityBoardViewMode(rawValue: "missing") == nil)
}

@Test func delegationQueueActionsPersistWithBatchTags() async throws {
    let ledger = try RunLedgerStore.inMemory()
    let batchID = "batch-test"
    let records = [
        OpportunityBoardActionRecord(
            id: "action-1",
            batchID: batchID,
            opportunityID: "DELEGATION-001",
            canonicalResource: "https://example.com/one",
            action: .pass,
            createdAt: Date(timeIntervalSince1970: 10)
        ),
        OpportunityBoardActionRecord(
            id: "action-2",
            batchID: batchID,
            opportunityID: "DELEGATION-002",
            canonicalResource: "https://example.com/two",
            action: .pass,
            createdAt: Date(timeIntervalSince1970: 11)
        )
    ]

    try await ledger.recordOpportunityBoardActions(records)
    let saved = try await ledger.listOpportunityBoardActions()

    #expect(saved.map(\.id) == ["action-2", "action-1"])
    #expect(Set(saved.map(\.batchID)) == [batchID])
    #expect(saved.allSatisfy { $0.action == .pass })
}

private func fixtureText(_ name: String) throws -> String {
    let testFile = URL(fileURLWithPath: #filePath)
    let repoRoot = testFile
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let fixture = repoRoot.appendingPathComponent("Tests/fixtures/\(name)")
    return try String(contentsOf: fixture, encoding: .utf8)
}

private func delegationItem(
    id: String,
    resource: String,
    fit: Double,
    app: String,
    windowDays: Int,
    rules: [String],
    attention: Int
) throws -> OpportunityCard {
    let rulesText = rules.joined(separator: ", ")
    let parsed = try OpportunityCardParser().parse(markdown: """
    ---
    type: delegation
    title: \(id)
    resource: \(resource)
    timestamp: 2026-07-04T10:00:00Z
    opp_id: \(id)
    fit: \(fit)
    rules_hit: [\(rulesText)]
    app: \(app)
    window_days: \(windowDays)
    effort: in
    attention: \(attention)
    sources: 1
    ---
    Queue item.
    """, source: "\(id).md")
    return try #require(parsed.opportunity)
}
