import Foundation
import Testing
@testable import OntologyKit

@Test func delegationAgentWritesRuleCitedDelegationFiles() async throws {
    let fixedDate = try #require(ISO8601DateFormatter().date(from: "2026-07-05T12:00:00Z"))
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("delegation-agent-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let runner = DelegationAgentRunner(
        search: { query, limit in
            #expect(query.contains("export"))
            #expect(limit == 5)
            return FirecrawlSearchResponse(
                results: [
                    FirecrawlSearchResult(
                        title: "Journal app export API shutdown",
                        url: "https://example.com/export-shutdown",
                        description: "A journaling app changes export API access and pricing.",
                        markdown: "The app is changing export behavior."
                    )
                ],
                creditsUsed: 2
            )
        },
        scrape: { url in
            #expect(url.absoluteString == "https://example.com/export-shutdown")
            return FirecrawlScrapeResponse(
                title: "Scraped journal export API shutdown",
                url: url.absoluteString,
                description: "Scraped description about export migration.",
                markdown: "Scraped evidence has the details the Queue should preserve.",
                creditsUsed: 1
            )
        },
        triage: { request in
            #expect(request.rules.map(\.id) == ["R-01"])
            return DelegationAgentRunner.parseTriageJSON("""
            {
              "title": "Triage title for export change",
              "description": "LLM says this belongs in Notorious Recall.",
              "app": "Notorious Recall",
              "fit": 0.88,
              "window_days": 9,
              "effort": "in",
              "dollar_order": "100K",
              "attention": 77,
              "rationale": "Fits R-01 because the target is explicit."
            }
            """)
        },
        now: { fixedDate },
        deviceName: "Test Mac"
    )

    let result = try await runner.run(
        prompt: "export shutdown journaling",
        authorityHits: [
            GraphAuthorityHit(
                subject: "understood:adam-pattern/step-4",
                predicate: "understood:description",
                object: "Choose Success: target must be explicit.",
                source: "Fuseki /accepted named graph",
                queryTrace: "SPARQL query: SELECT ?s ?p ?o WHERE { ?s ?p ?o }",
                authorityLevel: .accepted,
                score: 0.9
            )
        ],
        outputDirectory: directory
    )

    #expect(result.delegationFiles.count == 1)
    #expect(result.sourceFiles.count == 1)
    #expect(result.creditsUsed == 3)
    #expect(result.detail.run.success)
    #expect(result.detail.traceEvents.map(\.stage).contains(.supportingRetrieval))
    #expect(result.detail.traceEvents.contains { $0.message.contains("Scraped 1 shortlisted source") })
    #expect(result.detail.traceEvents.contains { $0.message.contains("LLM triage applied to 1 delegation") })

    let markdown = try String(contentsOf: try #require(result.delegationFiles.first), encoding: .utf8)
    #expect(markdown.contains("type: delegation"))
    #expect(markdown.contains("Triage title for export change"))
    #expect(markdown.contains("Scraped evidence has the details"))
    #expect(markdown.contains("rules_hit: [R-01]"))
    #expect(markdown.contains("app: Notorious Recall"))
    #expect(markdown.contains("fit: 0.88"))
    #expect(markdown.contains("window_days: 9"))
    #expect(markdown.contains("dollar_order: 100K"))
    #expect(markdown.contains("attention: 77"))
    #expect(markdown.contains("Fits R-01"))
    #expect(markdown.contains("trust_level: supporting_memory"))

    let parsed = try OpportunityCardParser().parse(markdown: markdown, source: "agent.md")
    let delegation = try #require(parsed.opportunity)
    #expect(OpportunityCardValidator().validate(delegation).passed)
    #expect(delegation.envelope.authorityLevel == .supporting)
}

@Test func delegationAgentHaltsBeforeFirecrawlWithoutAcceptedRules() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("delegation-agent-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let runner = DelegationAgentRunner(
        search: { _, _ in
            Issue.record("Firecrawl Search should not run without accepted rules.")
            return FirecrawlSearchResponse(results: [])
        },
        now: { Date(timeIntervalSince1970: 0) },
        deviceName: "Test Mac"
    )

    let result = try await runner.run(
        prompt: "anything",
        authorityHits: [],
        outputDirectory: directory
    )

    #expect(!result.detail.run.success)
    #expect(result.delegationFiles.isEmpty)
    #expect(result.detail.run.finalAnswer == "No delegations emitted because no accepted rules were available.")
}

@Test func delegationAgentKillSwitchStopsBeforeFirecrawlWhenWatchlistIsOff() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("delegation-agent-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let runner = DelegationAgentRunner(
        search: { _, _ in
            Issue.record("Search should not run when Watchlist is off.")
            return FirecrawlSearchResponse(results: [])
        },
        scrape: { _ in
            Issue.record("Scrape should not run when Watchlist is off.")
            return FirecrawlScrapeResponse(title: "", url: "", description: "", markdown: "")
        },
        triage: { _ in
            Issue.record("Triage should not run when Watchlist is off.")
            return nil
        },
        now: { Date(timeIntervalSince1970: 20) },
        deviceName: "Test Mac"
    )

    let result = try await runner.run(
        prompt: "export",
        authorityHits: [acceptedRule()],
        outputDirectory: directory,
        killSwitch: DelegationAgentKillSwitch(watchlistEnabled: false)
    )

    #expect(result.haltedByKillSwitch)
    #expect(result.creditsUsed == 0)
    #expect(result.delegationFiles.isEmpty)
    #expect(result.detail.run.finalAnswer.contains("Watchlist is off"))
}

@Test func delegationAgentKillSwitchStopsScrapeButKeepsSearchResults() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("delegation-agent-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let runner = DelegationAgentRunner(
        search: { _, _ in
            FirecrawlSearchResponse(
                results: [
                    FirecrawlSearchResult(
                        title: "Search-only result",
                        url: "https://example.com/search-only",
                        description: "An export change found before credits stopped the run."
                    )
                ],
                creditsUsed: 3
            )
        },
        scrape: { _ in
            Issue.record("Scrape should not run after run credits are reached.")
            return FirecrawlScrapeResponse(title: "", url: "", description: "", markdown: "")
        },
        now: { Date(timeIntervalSince1970: 30) },
        deviceName: "Test Mac"
    )

    let result = try await runner.run(
        prompt: "export",
        authorityHits: [acceptedRule()],
        outputDirectory: directory,
        killSwitch: DelegationAgentKillSwitch(perRunCreditLimit: 2)
    )

    #expect(result.haltedByKillSwitch)
    #expect(result.creditsUsed == 3)
    #expect(result.delegationFiles.count == 1)
    #expect(result.detail.run.finalAnswer.contains("Kill Switch halted after partial evidence"))
    #expect(result.detail.traceEvents.contains { $0.message.contains("halted additional Firecrawl requests") })
}

@Test func delegationAgentRunUsesOnlyApprovedResearchTriageFilesAndTrace() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("delegation-agent-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let callLog = CallLog()
    let runner = DelegationAgentRunner(
        search: { _, _ in
            await callLog.append("search")
            return FirecrawlSearchResponse(
                results: [
                    FirecrawlSearchResult(
                        title: "Safe result",
                        url: "https://example.com/safe",
                        description: "Safe source."
                    )
                ],
                creditsUsed: 1
            )
        },
        scrape: { url in
            await callLog.append("scrape:\(url.absoluteString)")
            return FirecrawlScrapeResponse(
                title: "Safe scrape",
                url: url.absoluteString,
                description: "Safe scrape.",
                markdown: "Safe markdown.",
                creditsUsed: 1
            )
        },
        triage: { _ in
            await callLog.append("triage")
            return DelegationAgentTriage(rationale: "Cites R-01.")
        },
        now: { Date(timeIntervalSince1970: 40) },
        deviceName: "Test Mac"
    )

    let result = try await runner.run(
        prompt: "export",
        authorityHits: [acceptedRule()],
        outputDirectory: directory
    )

    #expect(await callLog.values == ["search", "scrape:https://example.com/safe", "triage"])
    #expect(result.detail.evalResults.contains {
        $0.checkName == "no-external-actions" && $0.passed
    })
}

@Test func delegationAgentSavesFirecrawlFailureTraceWithoutFiles() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("delegation-agent-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let runner = DelegationAgentRunner(
        search: { _, _ in
            throw FirecrawlClient.FirecrawlError.badResponse("Timed out")
        },
        now: { Date(timeIntervalSince1970: 10) },
        deviceName: "Test Mac"
    )

    let result = try await runner.run(
        prompt: "export",
        authorityHits: [
            GraphAuthorityHit(
                subject: "rule",
                predicate: "label",
                object: "Rule",
                source: "accepted",
                queryTrace: "SPARQL",
                authorityLevel: .accepted,
                score: 1
            )
        ],
        outputDirectory: directory
    )

    #expect(!result.detail.run.success)
    #expect(result.delegationFiles.isEmpty)
    #expect(result.detail.traceEvents.contains { $0.message.contains("Timed out") })
    #expect(result.detail.traceEvents.contains { $0.message.contains("no delegation files written") })
}

@Test func triagePromptsRequireVerbatimSourceWords() {
    let system = DelegationAgentRunner.triageSystemPrompt()
    #expect(system.contains("Quote, never restate."))
    #expect(system.contains("When you use your own words or add words to it, it loses all its meaning."))

    let user = DelegationAgentRunner.triageUserPrompt(
        DelegationAgentTriageRequest(
            prompt: "export shutdown journaling",
            result: FirecrawlSearchResult(
                title: "Journal app export API shutdown",
                url: "https://example.com/export-shutdown",
                description: "A journaling app changes export API access and pricing.",
                markdown: "The app is changing export behavior."
            ),
            rules: []
        )
    )
    #expect(user.contains("copied word-for-word from the source or the Adam prompt"))
    #expect(!user.contains("one plain sentence"))
}

private func acceptedRule() -> GraphAuthorityHit {
    GraphAuthorityHit(
        subject: "understood:adam-pattern/step-4",
        predicate: "understood:description",
        object: "Choose Success: target must be explicit.",
        source: "Fuseki /accepted named graph",
        queryTrace: "SPARQL query",
        authorityLevel: .accepted,
        score: 1
    )
}

private actor CallLog {
    private var items: [String] = []

    func append(_ item: String) {
        items.append(item)
    }

    var values: [String] {
        items
    }
}
