import Foundation
import Testing
@testable import OntologyKit

@Test func opportunityFixtureParsesValidatesAndComputesPriority() throws {
    let markdown = try fixtureText("OPP-0001.md")
    let parsed = try OpportunityCardParser().parse(markdown: markdown, source: "Tests/fixtures/OPP-0001.md")
    let opportunity = try #require(parsed.opportunity)

    #expect(opportunity.envelope.type == "opportunity")
    #expect(opportunity.envelope.title == "Journaling app sunsets exports Aug 1 — migration vacuum")
    #expect(opportunity.envelope.tags == ["platform-watch", "migration"])
    #expect(opportunity.envelope.resource == "https://example-journal.app/blog/sunset-notice")
    #expect(opportunity.envelope.declaredTrustLevel == "supporting_memory")
    #expect(opportunity.envelope.authorityLevel == .supporting)
    #expect(opportunity.envelope.trustNote == nil)
    #expect(opportunity.oppID == "OPP-0001")
    #expect(opportunity.fit == 0.91)
    #expect(opportunity.rulesHit == ["R-01", "R-02", "R-07"])
    #expect(opportunity.band == .now)
    #expect(opportunity.windowDays == 27)
    #expect(opportunity.effort == .inBand)
    #expect(opportunity.dollarOrder == "100K")
    #expect(opportunity.attention == 143)
    #expect(opportunity.timesSeen == 5)
    #expect(opportunity.sources == 9)
    #expect(opportunity.scoutID == "scout-platform")
    #expect(opportunity.body.contains("plain-English case"))
    #expect(abs(opportunity.priority - 3.25) < 0.0001)

    let validation = OpportunityCardValidator().validate(opportunity)
    #expect(validation.passed)
    #expect(validation.reason == "Opportunity envelope passed typed validation.")
}

@Test func sourceCardFixtureParsesAndRequiresRetrievalMetadata() throws {
    let markdown = try fixtureText("OPP-0001-source.md")
    let parsed = try OpportunityCardParser().parse(markdown: markdown, source: "Tests/fixtures/OPP-0001-source.md")
    let sourceCard = try #require(parsed.sourceCard)

    #expect(sourceCard.envelope.type == "source_card")
    #expect(sourceCard.envelope.title == "Sunset notice — Example Journal blog")
    #expect(sourceCard.envelope.resource == "https://example-journal.app/blog/sunset-notice")
    #expect(sourceCard.retrievedBy == "firecrawl-scrape")
    #expect(sourceCard.contentHash == "sha256:9f2c…")
    #expect(sourceCard.linkedOpportunities == ["OPP-0001"])
    #expect(sourceCard.envelope.authorityLevel == .supporting)

    let validation = OpportunityCardValidator().validate(sourceCard)
    #expect(validation.passed)
    #expect(validation.reason == "Source card envelope passed typed validation.")
}

@Test func opportunityTrustLevelCannotSelfPromote() throws {
    let markdown = """
    ---
    type: opportunity
    title: Self promoting opportunity
    resource: https://example.com/self-promote
    timestamp: 2026-07-04T10:00:00Z
    trust_level: accepted
    opp_id: OPP-9999
    fit: 0.7
    rules_hit: [R-01]
    band: Now
    effort: in
    sources: 1
    ---
    A scout claim that should stay supporting memory.
    """

    let parsed = try OpportunityCardParser().parse(markdown: markdown, source: "self-promote.md")
    let opportunity = try #require(parsed.opportunity)

    #expect(opportunity.envelope.declaredTrustLevel == "accepted")
    #expect(opportunity.envelope.authorityLevel == .supporting)
    #expect(opportunity.envelope.trustNote == "Self-declared trust_level accepted ignored; connector ceiling is supporting.")
}

@Test func malformedOpportunityIsBlockedWithPlainEnglishReasons() throws {
    let markdown = """
    ---
    type: opportunity
    title: Missing rules and bad fit
    resource: https://example.com/bad
    fit: 1.4
    band: Soon
    sources: 0
    ---
    This should not reach the Board.
    """

    let parsed = try OpportunityCardParser().parse(markdown: markdown, source: "bad.md")
    let opportunity = try #require(parsed.opportunity)
    let validation = OpportunityCardValidator().validate(opportunity)

    #expect(!validation.passed)
    #expect(validation.reason.contains("rules_hit must include at least one accepted rule ID."))
    #expect(validation.reason.contains("fit must be between 0 and 1."))
    #expect(validation.reason.contains("band must be Now, Hold, or Out."))
    #expect(validation.reason.contains("sources must be at least 1."))
}

@Test func opportunityDedupMergesByCanonicalResourceAndPreservesHistory() throws {
    let first = try #require(try OpportunityCardParser().parse(markdown: """
    ---
    type: opportunity
    title: First title
    resource: https://Example-Journal.app/blog/sunset-notice?utm_source=newsletter
    timestamp: 2026-07-01T10:00:00Z
    opp_id: OPP-0001
    fit: 0.8
    rules_hit: [R-01]
    band: Now
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
    type: opportunity
    title: Later title
    resource: https://example-journal.app/blog/sunset-notice
    timestamp: 2026-07-04T10:00:00Z
    opp_id: OPP-0002
    fit: 0.7
    rules_hit: [R-02]
    band: Hold
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
    #expect(row.card.oppID == "OPP-0001")
    #expect(row.card.envelope.resource == "https://example-journal.app/blog/sunset-notice")
    #expect(row.card.envelope.timestamp == "2026-07-04T10:00:00Z")
    #expect(row.card.attention == 42)
    #expect(row.card.timesSeen == 2)
    #expect(row.history.map(\.oppID) == ["OPP-0001", "OPP-0002"])
}

@Test func opportunityBoardProjectionSupportsScanNowAndBandViews() throws {
    let now = try opportunityCard(
        id: "OPP-NOW",
        resource: "https://example.com/now",
        fit: 0.8,
        band: "Now",
        windowDays: 3,
        rules: ["R-01"],
        attention: 20
    )
    let hold = try opportunityCard(
        id: "OPP-HOLD",
        resource: "https://example.com/hold",
        fit: 0.65,
        band: "Hold",
        windowDays: 20,
        rules: ["R-02"],
        attention: 10
    )
    let out = try opportunityCard(
        id: "OPP-OUT",
        resource: "https://example.com/out",
        fit: 0.2,
        band: "Out",
        windowDays: 120,
        rules: ["R-03"],
        attention: 5
    )

    let rows = OpportunityBoardDeduper().deduplicate([hold, out, now])
    let board = OpportunityBoardProjection(rows: rows)

    #expect(board.rows(for: .scan).map(\.id) == ["OPP-NOW", "OPP-HOLD", "OPP-OUT"])
    #expect(board.rows(for: .nowOnly).map(\.id) == ["OPP-NOW"])
    #expect(board.groupsByBand().map(\.band) == [.now, .hold, .out])
    #expect(board.groupsByBand().flatMap(\.rows).map(\.id) == ["OPP-NOW", "OPP-HOLD", "OPP-OUT"])
}

@Test func opportunityBoardViewModeRawValuesAreStableForPersistence() {
    #expect(OpportunityBoardViewMode.scan.rawValue == "scan")
    #expect(OpportunityBoardViewMode.nowOnly.rawValue == "now_only")
    #expect(OpportunityBoardViewMode.byBand.rawValue == "by_band")
    #expect(OpportunityBoardViewMode(rawValue: "missing") == nil)
}

@Test func opportunityBoardActionsPersistWithBatchTags() async throws {
    let ledger = try RunLedgerStore.inMemory()
    let batchID = "batch-test"
    let records = [
        OpportunityBoardActionRecord(
            id: "action-1",
            batchID: batchID,
            opportunityID: "OPP-001",
            canonicalResource: "https://example.com/one",
            action: .pass,
            createdAt: Date(timeIntervalSince1970: 10)
        ),
        OpportunityBoardActionRecord(
            id: "action-2",
            batchID: batchID,
            opportunityID: "OPP-002",
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

private func opportunityCard(
    id: String,
    resource: String,
    fit: Double,
    band: String,
    windowDays: Int,
    rules: [String],
    attention: Int
) throws -> OpportunityCard {
    let rulesText = rules.joined(separator: ", ")
    let parsed = try OpportunityCardParser().parse(markdown: """
    ---
    type: opportunity
    title: \(id)
    resource: \(resource)
    timestamp: 2026-07-04T10:00:00Z
    opp_id: \(id)
    fit: \(fit)
    rules_hit: [\(rulesText)]
    band: \(band)
    window_days: \(windowDays)
    effort: in
    attention: \(attention)
    times_seen: 1
    sources: 1
    scout_id: scout-test
    ---
    \(id) body.
    """, source: "\(id).md")
    return try #require(parsed.opportunity)
}
