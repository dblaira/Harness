import CryptoKit
import Foundation

public struct DelegationAgentRunResult: Sendable, Equatable {
    public let detail: HarnessRunDetail
    public let delegationFiles: [URL]
    public let sourceFiles: [URL]
    public let creditsUsed: Int
    public let haltedByKillSwitch: Bool

    public init(
        detail: HarnessRunDetail,
        delegationFiles: [URL],
        sourceFiles: [URL],
        creditsUsed: Int,
        haltedByKillSwitch: Bool
    ) {
        self.detail = detail
        self.delegationFiles = delegationFiles
        self.sourceFiles = sourceFiles
        self.creditsUsed = creditsUsed
        self.haltedByKillSwitch = haltedByKillSwitch
    }
}

public struct DelegationAgentKillSwitch: Sendable, Equatable {
    public let watchlistEnabled: Bool
    public let perRunCreditLimit: Int
    public let perDayCreditLimit: Int
    public let creditsUsedToday: Int

    public init(
        watchlistEnabled: Bool = true,
        perRunCreditLimit: Int = 10,
        perDayCreditLimit: Int = 50,
        creditsUsedToday: Int = 0
    ) {
        self.watchlistEnabled = watchlistEnabled
        self.perRunCreditLimit = max(1, perRunCreditLimit)
        self.perDayCreditLimit = max(1, perDayCreditLimit)
        self.creditsUsedToday = max(0, creditsUsedToday)
    }

    public static let standard = DelegationAgentKillSwitch()

    public var dayRemaining: Int {
        max(0, perDayCreditLimit - creditsUsedToday)
    }

    public func allowsStart() -> Bool {
        watchlistEnabled && dayRemaining > 0
    }

    public func breached(runCredits: Int) -> Bool {
        runCredits > perRunCreditLimit || creditsUsedToday + runCredits > perDayCreditLimit
    }

    public func breachReason(runCredits: Int) -> String? {
        if !watchlistEnabled {
            return "Watchlist is off."
        }
        if creditsUsedToday >= perDayCreditLimit {
            return "Day credits reached."
        }
        if runCredits > perRunCreditLimit {
            return "Run credits reached."
        }
        if creditsUsedToday + runCredits > perDayCreditLimit {
            return "Day credits reached."
        }
        return nil
    }
}

public struct DelegationAgentRuleReference: Sendable, Equatable {
    public let id: String
    public let subject: String
    public let object: String
    public let source: String

    public init(id: String, subject: String, object: String, source: String) {
        self.id = id
        self.subject = subject
        self.object = object
        self.source = source
    }
}

public struct DelegationAgentTriageRequest: Sendable, Equatable {
    public let prompt: String
    public let result: FirecrawlSearchResult
    public let rules: [DelegationAgentRuleReference]

    public init(prompt: String, result: FirecrawlSearchResult, rules: [DelegationAgentRuleReference]) {
        self.prompt = prompt
        self.result = result
        self.rules = rules
    }
}

public struct DelegationAgentTriage: Sendable, Equatable {
    public let title: String?
    public let description: String?
    public let app: OpportunityApp?
    public let fit: Double?
    public let windowDays: Int?
    public let effort: OpportunityEffort?
    public let dollarOrder: String?
    public let attention: Int?
    public let rationale: String?
    /// WO-L: the dissent -- "an agent argues why this is still Step 1."
    /// Agent speech by design, unlike title/description above.
    public let caseAgainst: String?

    public init(
        title: String? = nil,
        description: String? = nil,
        app: OpportunityApp? = nil,
        fit: Double? = nil,
        windowDays: Int? = nil,
        effort: OpportunityEffort? = nil,
        dollarOrder: String? = nil,
        attention: Int? = nil,
        rationale: String? = nil,
        caseAgainst: String? = nil
    ) {
        self.title = title
        self.description = description
        self.app = app
        self.fit = fit
        self.windowDays = windowDays
        self.effort = effort
        self.dollarOrder = dollarOrder
        self.attention = attention
        self.rationale = rationale
        self.caseAgainst = caseAgainst
    }
}

public struct DelegationAgentRunner: Sendable {
    public typealias Search = @Sendable (_ query: String, _ limit: Int) async throws -> FirecrawlSearchResponse
    public typealias Scrape = @Sendable (_ url: URL) async throws -> FirecrawlScrapeResponse
    public typealias Triage = @Sendable (_ request: DelegationAgentTriageRequest) async throws -> DelegationAgentTriage?

    private let search: Search
    private let scrape: Scrape?
    private let triage: Triage?
    private let now: @Sendable () -> Date
    private let deviceName: String

    public init(
        search: @escaping Search,
        scrape: Scrape? = nil,
        triage: Triage? = nil,
        now: @escaping @Sendable () -> Date = { Date() },
        deviceName: String = DeviceIdentity.currentName()
    ) {
        self.search = search
        self.scrape = scrape
        self.triage = triage
        self.now = now
        self.deviceName = deviceName
    }

    public func run(
        prompt: String,
        authorityHits: [GraphAuthorityHit],
        outputDirectory: URL,
        searchLimit: Int = 5,
        killSwitch: DelegationAgentKillSwitch = .standard,
        fileManager: FileManager = .default
    ) async throws -> DelegationAgentRunResult {
        let start = now()
        let runID = UUID().uuidString
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let query = trimmedPrompt.isEmpty ? Self.defaultPrompt : trimmedPrompt
        let attachedAuthority = authorityHits
            .filter { $0.authorityLevel == .accepted }
            .map { $0.attached(to: runID) }
        var traceEvents: [TraceEvent] = [
            TraceEvent(runId: runID, stage: .createRun, message: "Created manual agent run for Delegation Queue.", createdAt: start),
            TraceEvent(runId: runID, stage: .authorityRetrieval, message: "Accepted rule hits available: \(attachedAuthority.count).", createdAt: start)
        ]

        guard killSwitch.allowsStart() else {
            let reason = killSwitch.breachReason(runCredits: 0) ?? "Kill Switch blocked this run."
            let detail = Self.detail(
                runID: runID,
                prompt: query,
                start: start,
                end: now(),
                success: false,
                finalAnswer: "Kill Switch halted the agent: \(reason)",
                authorityHits: attachedAuthority,
                traceEvents: traceEvents + [
                    TraceEvent(runId: runID, stage: .evaluation, message: "Kill Switch halted before Firecrawl: \(reason)", createdAt: now()),
                    TraceEvent(runId: runID, stage: .traceSaved, message: "No Firecrawl request was made.", createdAt: now())
                ],
                evalResults: [
                    EvalResult(runId: runID, checkName: "kill-switch-halt", passed: true, detail: reason),
                    EvalResult(runId: runID, checkName: "no-external-actions", passed: true, detail: "The agent halted before Search, Scrape, or Triage.")
                ],
                deviceName: deviceName
            )
            return DelegationAgentRunResult(
                detail: detail,
                delegationFiles: [],
                sourceFiles: [],
                creditsUsed: 0,
                haltedByKillSwitch: true
            )
        }

        guard !attachedAuthority.isEmpty else {
            let detail = Self.detail(
                runID: runID,
                prompt: query,
                start: start,
                end: now(),
                success: false,
                finalAnswer: "No delegations emitted because no accepted rules were available.",
                authorityHits: attachedAuthority,
                traceEvents: traceEvents + [
                    TraceEvent(runId: runID, stage: .traceSaved, message: "Agent run halted before Firecrawl; every delegation must cite at least one accepted rule.", createdAt: now())
                ],
                evalResults: [
                    EvalResult(runId: runID, checkName: "no-rule-no-file", passed: true, detail: "The agent emitted zero files because accepted rules were missing.")
                ],
                deviceName: deviceName
            )
            return DelegationAgentRunResult(
                detail: detail,
                delegationFiles: [],
                sourceFiles: [],
                creditsUsed: 0,
                haltedByKillSwitch: false
            )
        }

        let response: FirecrawlSearchResponse
        var creditsUsed = 0
        var haltedByKillSwitch = false
        var partialReason: String?
        do {
            response = try await search(query, max(1, min(searchLimit, 10)))
            creditsUsed += response.creditsUsed ?? 1
        } catch {
            let end = now()
            traceEvents.append(TraceEvent(runId: runID, stage: .supportingRetrieval, message: "Firecrawl Search failed: \(error.localizedDescription)", createdAt: end))
            let detail = Self.detail(
                runID: runID,
                prompt: query,
                start: start,
                end: end,
                success: false,
                finalAnswer: "Firecrawl Search failed: \(error.localizedDescription)",
                authorityHits: attachedAuthority,
                traceEvents: traceEvents + [
                    TraceEvent(runId: runID, stage: .traceSaved, message: "Failure saved to Trace; no delegation files written.", createdAt: end)
                ],
                evalResults: [
                    EvalResult(runId: runID, checkName: "failure-saved", passed: true, detail: "The failed Firecrawl run was represented as a saved trace.")
                ],
                deviceName: deviceName
            )
            return DelegationAgentRunResult(
                detail: detail,
                delegationFiles: [],
                sourceFiles: [],
                creditsUsed: creditsUsed,
                haltedByKillSwitch: false
            )
        }

        traceEvents.append(TraceEvent(
            runId: runID,
            stage: .supportingRetrieval,
            message: "Firecrawl returned \(response.results.count) source\(response.results.count == 1 ? "" : "s"); credits used: \(response.creditsUsed.map(String.init) ?? "unknown").",
            createdAt: now()
        ))
        if let reason = killSwitch.breachReason(runCredits: creditsUsed) {
            haltedByKillSwitch = true
            partialReason = reason
            traceEvents.append(TraceEvent(
                runId: runID,
                stage: .evaluation,
                message: "Kill Switch halted additional Firecrawl requests after Search: \(reason)",
                createdAt: now()
            ))
        }

        var scrapedByURL: [String: FirecrawlScrapeResponse] = [:]
        var scrapeFailures = 0
        if let scrape, !haltedByKillSwitch {
            for result in response.results.prefix(min(2, max(1, searchLimit))) {
                guard let url = URL(string: result.url) else {
                    scrapeFailures += 1
                    continue
                }
                do {
                    let scrapeResponse = try await scrape(url)
                    creditsUsed += scrapeResponse.creditsUsed ?? 1
                    scrapedByURL[result.url] = scrapeResponse
                    if let reason = killSwitch.breachReason(runCredits: creditsUsed) {
                        haltedByKillSwitch = true
                        partialReason = reason
                        break
                    }
                } catch {
                    scrapeFailures += 1
                }
            }
            traceEvents.append(TraceEvent(
                runId: runID,
                stage: .supportingRetrieval,
                message: "Scraped \(scrapedByURL.count) shortlisted source\(scrapedByURL.count == 1 ? "" : "s"); scrape failures: \(scrapeFailures).",
                createdAt: now()
            ))
            if let partialReason {
                traceEvents.append(TraceEvent(
                    runId: runID,
                    stage: .evaluation,
                    message: "Kill Switch halted remaining Firecrawl requests: \(partialReason)",
                    createdAt: now()
                ))
            }
        }

        try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let parser = OpportunityCardParser()
        let validator = OpportunityCardValidator()
        let ruleRefs = Self.ruleReferences(from: attachedAuthority)
        let publicRuleRefs = ruleRefs.map { rule in
            DelegationAgentRuleReference(
                id: rule.id,
                subject: rule.hit.subject,
                object: rule.hit.object,
                source: rule.hit.source
            )
        }
        var delegationFiles: [URL] = []
        var sourceFiles: [URL] = []
        var skipped = 0
        var triaged = 0
        var triageFailures = 0

        for (index, result) in response.results.prefix(searchLimit).enumerated() {
            guard let sourceURL = URL(string: result.url), !result.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                skipped += 1
                continue
            }
            let evidence = Self.evidenceResult(searchResult: result, scrapeResponse: scrapedByURL[result.url])
            var triageResult: DelegationAgentTriage?
            if let triage, scrapedByURL[result.url] != nil {
                do {
                    triageResult = try await triage(DelegationAgentTriageRequest(
                        prompt: query,
                        result: evidence,
                        rules: publicRuleRefs
                    ))
                    if triageResult != nil {
                        triaged += 1
                    } else {
                        triageFailures += 1
                    }
                } catch {
                    triageFailures += 1
                }
            }

            let id = Self.delegationID(date: start, index: index)
            let markdown = Self.delegationMarkdown(
                id: id,
                result: evidence,
                date: start,
                ruleRefs: ruleRefs,
                triage: triageResult,
                index: index,
                adamPrompt: query
            )
            guard case let .opportunity(card) = try parser.parse(markdown: markdown, source: id),
                  validator.validate(card).passed
            else {
                skipped += 1
                continue
            }

            let sourceMarkdown = Self.sourceMarkdown(
                id: id,
                result: evidence,
                sourceURL: sourceURL,
                date: start,
                delegationMarkdown: markdown
            )
            guard case let .sourceCard(sourceCard) = try parser.parse(markdown: sourceMarkdown, source: "\(id)-source"),
                  validator.validate(sourceCard).passed
            else {
                skipped += 1
                continue
            }

            let delegationURL = outputDirectory.appendingPathComponent("\(id).md")
            let sourceFileURL = outputDirectory.appendingPathComponent("\(id)-source.md")
            try markdown.write(to: delegationURL, atomically: true, encoding: .utf8)
            try sourceMarkdown.write(to: sourceFileURL, atomically: true, encoding: .utf8)
            delegationFiles.append(delegationURL)
            sourceFiles.append(sourceFileURL)
        }

        let end = now()
        if triage != nil {
            traceEvents.append(TraceEvent(
                runId: runID,
                stage: .modelExecution,
                message: "LLM triage applied to \(triaged) delegation\(triaged == 1 ? "" : "s"); fallback used \(triageFailures) time\(triageFailures == 1 ? "" : "s").",
                createdAt: end
            ))
        }
        traceEvents.append(TraceEvent(
            runId: runID,
            stage: .modelExecution,
            message: "Emitted \(delegationFiles.count) Delegation file\(delegationFiles.count == 1 ? "" : "s"); skipped \(skipped).",
            createdAt: end
        ))
        traceEvents.append(TraceEvent(
            runId: runID,
            stage: .traceSaved,
            message: "Saved Trace with Firecrawl query, accepted rule citations, and emitted file count.",
            createdAt: end
        ))

        let detail = Self.detail(
            runID: runID,
            prompt: query,
            start: start,
            end: end,
            success: !delegationFiles.isEmpty,
            finalAnswer: delegationFiles.isEmpty
                ? "Agent emitted zero delegations. Check Trace for skipped sources."
                : "\(haltedByKillSwitch ? "Kill Switch halted after partial evidence. " : "")Agent emitted \(delegationFiles.count) delegation\(delegationFiles.count == 1 ? "" : "s") into \(outputDirectory.path).",
            authorityHits: attachedAuthority,
            traceEvents: traceEvents,
            evalResults: [
                EvalResult(runId: runID, checkName: "delegations-cite-rules", passed: !delegationFiles.isEmpty, detail: "Every written Delegation file was validated before writing."),
                EvalResult(runId: runID, checkName: "kill-switch-accounted", passed: !killSwitch.breached(runCredits: creditsUsed) || haltedByKillSwitch, detail: "Credits used: \(creditsUsed). Run limit: \(killSwitch.perRunCreditLimit). Day limit: \(killSwitch.perDayCreditLimit)."),
                EvalResult(runId: runID, checkName: "no-external-actions", passed: true, detail: "The run used Firecrawl Search/Scrape, optional LLM triage, local file writes, and ledger writes only.")
            ],
            deviceName: deviceName
        )
        return DelegationAgentRunResult(
            detail: detail,
            delegationFiles: delegationFiles,
            sourceFiles: sourceFiles,
            creditsUsed: creditsUsed,
            haltedByKillSwitch: haltedByKillSwitch
        )
    }

    public static let defaultPrompt = "personal-data platform export shutdown API pricing journaling health self-tracking migration"

    static func delegationID(date: Date, index: Int) -> String {
        "DELEGATION-\(stamp(for: date))-\(String(format: "%03d", index + 1))"
    }

    static func ruleReferences(from hits: [GraphAuthorityHit]) -> [(id: String, hit: GraphAuthorityHit)] {
        hits.prefix(8).enumerated().map { index, hit in
            (String(format: "R-%02d", index + 1), hit)
        }
    }

    public static func triageSystemPrompt() -> String {
        """
        You triage Firecrawl evidence for the Harness Delegation Queue.
        Return JSON only. No markdown. No extra prose.
        Allowed apps: News Calm, Notorious Recall, Understood, SAVY.
        Allowed effort values: in, above, below.
        Every decision must cite the supplied accepted rules in rationale.
        Never recommend spending, trading, contacting, purchasing, committing, or executing.
        The title is the label Adam scans. It must be Adam's words, copied word-for-word from the \
        Adam prompt — what HE wants, in his phrasing. It's what "I" want, not what "is" wanted. \
        Never write a title in your own words and never use the source's words as the title.
        The description must be copied word-for-word from the source title, description, or excerpt. \
        Do not paraphrase, summarize, or add your own words: "When you use your own words or add \
        words to it, it loses all its meaning."
        Also write case_against: one or two sentences arguing why this might still be Step 1 \
        (Context) or Step 2 (Circle) of the Adam Pattern -- more observation needed -- rather than \
        ready to execute. This is the one field that is explicitly YOUR words, not Adam's; argue \
        the skeptical case honestly, don't just restate the rationale in reverse.
        """
    }

    public static func triageUserPrompt(_ request: DelegationAgentTriageRequest) -> String {
        let rules = request.rules.map { "- \($0.id): \($0.object) [\($0.source)]" }.joined(separator: "\n")
        let markdown = request.result.markdown?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return """
        Adam prompt:
        \(request.prompt)

        Source:
        title: \(request.result.title)
        url: \(request.result.url)
        description: \(request.result.description)
        excerpt: \(String(markdown.prefix(1_800)))

        Accepted rules:
        \(rules)

        Return exactly this JSON shape:
        {
          "title": "a short phrase copied word-for-word from the Adam prompt",
          "description": "one sentence copied word-for-word from the source",
          "app": "News Calm|Notorious Recall|Understood|SAVY",
          "fit": 0.0,
          "window_days": 14,
          "effort": "in|above|below",
          "dollar_order": "unknown|10K|100K|1M",
          "attention": 1,
          "rationale": "why this belongs in the Queue, citing R-IDs",
          "case_against": "one or two sentences arguing why this is still Step 1 or Step 2, not ready to execute"
        }
        """
    }

    public static func parseTriageJSON(_ text: String) -> DelegationAgentTriage? {
        guard let data = jsonObjectSlice(from: text).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        return DelegationAgentTriage(
            title: string(object["title"]),
            description: string(object["description"]),
            app: string(object["app"]).flatMap(parseApp),
            fit: double(object["fit"]),
            windowDays: int(object["window_days"] ?? object["windowDays"]),
            effort: string(object["effort"]).flatMap(parseEffort),
            dollarOrder: string(object["dollar_order"] ?? object["dollarOrder"]),
            attention: int(object["attention"]),
            rationale: string(object["rationale"]),
            caseAgainst: string(object["case_against"] ?? object["caseAgainst"])
        )
    }

    private static func delegationMarkdown(
        id: String,
        result: FirecrawlSearchResult,
        date: Date,
        ruleRefs: [(id: String, hit: GraphAuthorityHit)],
        triage: DelegationAgentTriage?,
        index: Int,
        adamPrompt: String = ""
    ) -> String {
        let text = "\(result.title) \(result.description)".lowercased()
        let app = triage?.app?.rawValue ?? appName(for: text)
        let windowDays = triage?.windowDays ?? windowDays(for: app)
        let fit = triage?.fit.map { min(1, max(0, $0)) }
            ?? min(0.95, 0.56 + Double(min(ruleRefs.count, 6)) * 0.05 + Double(max(0, 5 - index)) * 0.01)
        let attention = triage?.attention.map { min(100, max(1, $0)) }
            ?? min(100, max(1, (result.title.count + result.description.count) / 3))
        // The title is the label Adam scans. It must be his words: the triage title
        // (copied from his prompt) or the prompt itself — never the source's words.
        let trimmedPrompt = adamPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = triage?.title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? triage!.title!
            : (trimmedPrompt.isEmpty ? (result.title.isEmpty ? result.url : result.title) : trimmedPrompt)
        let description = triage?.description?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? triage!.description!
            : result.description
        let effort = triage?.effort?.rawValue ?? OpportunityEffort.fits.rawValue
        let dollarOrder = triage?.dollarOrder?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? triage!.dollarOrder!
            : "unknown"
        let ruleIDs = ruleRefs.map(\.id).joined(separator: ", ")
        let ruleLines = ruleRefs.map { "- \($0.id): \($0.hit.object) (\($0.hit.source))" }.joined(separator: "\n")
        let excerpt = result.markdown?.trimmingCharacters(in: .whitespacesAndNewlines)
        let excerptBlock = excerpt.map { "\n## Firecrawl excerpt\n\(String($0.prefix(900)))\n" } ?? ""
        let triageBlock = triage?.rationale.map { "\n## LLM triage\n\($0)\n" } ?? ""
        // WO-L: the one frontmatter field that's explicitly agent speech,
        // never Adam's words -- the UP NEXT card renders it as SavyDarkCard.
        let caseAgainstLine = triage?.caseAgainst?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? "case_against: \"\(yaml(triage!.caseAgainst!))\"\n"
            : ""

        return """
        ---
        type: delegation
        title: "\(yaml(title))"
        description: "\(yaml(description))"
        tags: [agent-run, firecrawl]
        resource: \(result.url)
        timestamp: \(iso(date))
        trust_level: supporting_memory
        opp_id: \(id)
        fit: \(String(format: "%.2f", fit))
        rules_hit: [\(ruleIDs)]
        app: \(app)
        window_days: \(windowDays)
        effort: \(effort)
        dollar_order: \(dollarOrder)
        attention: \(attention)
        times_seen: 1
        sources: 1
        scout_id: agent-firecrawl-v1
        \(caseAgainstLine)---
        ## Why this is in Harness
        Firecrawl found this source while running the manual agent path for the Delegation Queue.

        ## Source
        \(result.url)

        ## Accepted rules cited
        \(ruleLines)
        \(triageBlock)
        \(excerptBlock)
        """
    }

    private static func evidenceResult(
        searchResult: FirecrawlSearchResult,
        scrapeResponse: FirecrawlScrapeResponse?
    ) -> FirecrawlSearchResult {
        guard let scrapeResponse else { return searchResult }
        let title = scrapeResponse.title.isEmpty ? searchResult.title : scrapeResponse.title
        let url = scrapeResponse.url.isEmpty ? searchResult.url : scrapeResponse.url
        let description = scrapeResponse.description.isEmpty ? searchResult.description : scrapeResponse.description
        let markdown = scrapeResponse.markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? searchResult.markdown
            : scrapeResponse.markdown
        return FirecrawlSearchResult(title: title, url: url, description: description, markdown: markdown)
    }

    private static func sourceMarkdown(
        id: String,
        result: FirecrawlSearchResult,
        sourceURL: URL,
        date: Date,
        delegationMarkdown: String
    ) -> String {
        """
        ---
        type: source_card
        title: "\(yaml(result.title.isEmpty ? sourceURL.absoluteString : result.title))"
        description: "\(yaml(result.description))"
        tags: [firecrawl, source]
        resource: \(sourceURL.absoluteString)
        timestamp: \(iso(date))
        trust_level: supporting_memory
        retrieved_by: firecrawl-search
        content_hash: sha256:\(sha256Hex(delegationMarkdown))
        linked_opportunities: [\(id)]
        ---
        \(result.markdown?.trimmingCharacters(in: .whitespacesAndNewlines) ?? result.description)
        """
    }

    private static func detail(
        runID: String,
        prompt: String,
        start: Date,
        end: Date,
        success: Bool,
        finalAnswer: String,
        authorityHits: [GraphAuthorityHit],
        traceEvents: [TraceEvent],
        evalResults: [EvalResult],
        deviceName: String
    ) -> HarnessRunDetail {
        let run = HarnessRun(
            id: runID,
            prompt: "Run agent: \(prompt)",
            backend: "Harness",
            modelName: "delegation-agent-v1",
            invocationMethod: "firecrawl-search",
            promptPacketHash: "sha256:\(sha256Hex(prompt + authorityHits.map(\.id).joined()))",
            success: success,
            duration: end.timeIntervalSince(start),
            tokenCount: nil,
            cost: nil,
            finalAnswer: finalAnswer,
            deviceName: deviceName,
            createdAt: start
        )
        return HarnessRunDetail(
            run: run,
            messages: [
                HarnessMessage(runId: runID, role: .user, text: prompt, createdAt: start),
                HarnessMessage(runId: runID, role: .assistant, text: finalAnswer, createdAt: end)
            ],
            authorityHits: authorityHits,
            memoryHits: [],
            traceEvents: traceEvents,
            evalResults: evalResults,
            memoryCandidates: [],
            validationResults: []
        )
    }

    private static func appName(for text: String) -> String {
        if text.contains("build") || text.contains("integration") || text.contains("setup") {
            return OpportunityApp.understood.rawValue
        }
        if text.contains("shutdown") || text.contains("sunset") || text.contains("export") || text.contains("migration") || text.contains("api") || text.contains("pricing") {
            return OpportunityApp.notoriousRecall.rawValue
        }
        return OpportunityApp.newsCalm.rawValue
    }

    private static func windowDays(for app: String) -> Int {
        switch app {
        case OpportunityApp.understood.rawValue:
            return 7
        case OpportunityApp.notoriousRecall.rawValue:
            return 14
        default:
            return 30
        }
    }

    private static func iso(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private static func stamp(for date: Date) -> String {
        iso(date)
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: "T", with: "")
            .replacingOccurrences(of: "Z", with: "")
    }

    private static func yaml(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
    }

    private static func sha256Hex(_ text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func jsonObjectSlice(from text: String) -> String {
        guard let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}"),
              start <= end
        else {
            return text
        }
        return String(text[start...end])
    }

    private static func string(_ value: Any?) -> String? {
        guard let value else { return nil }
        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let number = value as? NSNumber {
            return number.stringValue
        }
        return nil
    }

    private static func double(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? Int { return Double(value) }
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = string(value) { return Double(value) }
        return nil
    }

    private static func int(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? Double { return Int(value) }
        if let value = value as? NSNumber { return value.intValue }
        if let value = string(value) { return Int(value) ?? Double(value).map(Int.init) }
        return nil
    }

    private static func parseApp(_ raw: String) -> OpportunityApp? {
        let normalized = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
        switch normalized {
        case "news calm", "boring news":
            return .newsCalm
        case "notorious recall":
            return .notoriousRecall
        case "understood":
            return .understood
        case "savy", "savvy":
            return .savy
        default:
            return nil
        }
    }

    private static func parseEffort(_ raw: String) -> OpportunityEffort? {
        OpportunityEffort.allCases.first { $0.rawValue.lowercased() == raw.lowercased() }
    }
}
