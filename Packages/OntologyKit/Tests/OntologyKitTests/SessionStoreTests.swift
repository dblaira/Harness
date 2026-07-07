import Foundation
import Testing
@testable import OntologyKit

private func makeRun(id: String, prompt: String, answer: String, createdAt: Date = Date()) -> HarnessRun {
    HarnessRun(
        id: id,
        prompt: prompt,
        backend: "grok",
        modelName: "test-grok",
        invocationMethod: "unit-test",
        promptPacketHash: "hash-\(id)",
        success: true,
        duration: 0.5,
        tokenCount: 42,
        cost: nil,
        finalAnswer: answer,
        deviceName: "test-device",
        createdAt: createdAt
    )
}

private func makeDetail(run: HarnessRun, messages: [HarnessMessage]) -> HarnessRunDetail {
    HarnessRunDetail(
        run: run,
        messages: messages,
        authorityHits: [],
        memoryHits: [],
        traceEvents: [],
        evalResults: [],
        memoryCandidates: [],
        validationResults: []
    )
}

@Test func sessionThreadRoundTrips() async throws {
    let ledger = try RunLedgerStore.inMemory()
    let store = SessionStore(ledger: ledger)
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    let session = try await store.createSession(title: "Morning planning", createdAt: t0)
    try await store.appendMessage(sessionId: session.id, role: .user, text: "Draft the Fuseki reload plan", createdAt: t0.addingTimeInterval(1))
    try await store.appendMessage(sessionId: session.id, role: .assistant, text: "Here is the reload plan, step by step.", createdAt: t0.addingTimeInterval(2))

    let run = makeRun(id: "run-1", prompt: "Draft the Fuseki reload plan", answer: "Plan drafted.")
    try await ledger.save(makeDetail(run: run, messages: []))
    try await store.appendMessage(sessionId: session.id, role: .assistant, text: "Logged the run in the ledger.", runId: run.id, createdAt: t0.addingTimeInterval(3))

    let thread = try await store.thread(sessionId: session.id)
    #expect(thread.map(\.text) == [
        "Draft the Fuseki reload plan",
        "Here is the reload plan, step by step.",
        "Logged the run in the ledger."
    ])
    #expect(thread.map(\.role) == [.user, .assistant, .assistant])
    #expect(thread[0].runId == nil)
    #expect(thread[2].runId == "run-1")
    #expect(thread.allSatisfy { $0.sessionId == session.id })
}

@Test func renameAndMostRecentSessionLookup() async throws {
    let ledger = try RunLedgerStore.inMemory()
    let store = SessionStore(ledger: ledger)
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    let older = try await store.createSession(title: "Older session", createdAt: t0)
    let newer = try await store.createSession(title: "Newer session", createdAt: t0.addingTimeInterval(60))
    #expect(try await store.mostRecentSession()?.id == newer.id)

    // Appending to the older session bumps it to most recent.
    try await store.appendMessage(sessionId: older.id, role: .user, text: "back to this one", createdAt: t0.addingTimeInterval(120))
    #expect(try await store.mostRecentSession()?.id == older.id)

    try await store.renameSession(id: older.id, title: "Renamed session", at: t0.addingTimeInterval(180))
    let renamed = try await store.session(id: older.id)
    #expect(renamed?.title == "Renamed session")

    let listed = try await store.listSessions()
    #expect(listed.map(\.id) == [older.id, newer.id])
}

@Test func searchFindsKeywordAcrossSessions() async throws {
    let ledger = try RunLedgerStore.inMemory()
    let store = SessionStore(ledger: ledger)
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    let planning = try await store.createSession(title: "Trip planning", createdAt: t0)
    try await store.appendMessage(sessionId: planning.id, role: .user, text: "Remember the quokka photo permit for Rottnest", createdAt: t0.addingTimeInterval(1))

    let cooking = try await store.createSession(title: "Dinner ideas", createdAt: t0.addingTimeInterval(10))
    try await store.appendMessage(sessionId: cooking.id, role: .assistant, text: "A ragu wants at least three hours of simmering", createdAt: t0.addingTimeInterval(11))

    let hits = try await store.searchSessions(query: "quokka")
    #expect(hits.count == 1)
    #expect(hits.first?.sessionId == planning.id)
    #expect(hits.first?.title == "Trip planning")
    #expect(hits.first?.snippet.localizedCaseInsensitiveContains("quokka") == true)

    let none = try await store.searchSessions(query: "zeppelin")
    #expect(none.isEmpty)
}

@Test func likeFallbackSearchFindsKeywordAndSnippet() async throws {
    let ledger = try RunLedgerStore.inMemory()
    let store = SessionStore(ledger: ledger)
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    let session = try await store.createSession(title: "Ledger work", createdAt: t0)
    try await store.appendMessage(
        sessionId: session.id,
        role: .assistant,
        text: "The episodic ledger keeps every conversation searchable across sessions.",
        createdAt: t0.addingTimeInterval(1)
    )

    let hits = try await store.searchSessionsUsingLikeFallback(query: "episodic")
    #expect(hits.count == 1)
    #expect(hits.first?.sessionId == session.id)
    #expect(hits.first?.snippet.localizedCaseInsensitiveContains("episodic") == true)

    // LIKE wildcards in the query must not match everything.
    let wildcard = try await store.searchSessionsUsingLikeFallback(query: "%")
    #expect(wildcard.isEmpty)
}

@Test func searchMatchesSessionTitles() async throws {
    let ledger = try RunLedgerStore.inMemory()
    let store = SessionStore(ledger: ledger)
    let session = try await store.createSession(title: "Fuseki reload checklist")

    let hits = try await store.searchSessions(query: "Fuseki")
    #expect(hits.contains { $0.sessionId == session.id })
}

@Test func attachRunLinksTranscriptToSession() async throws {
    let ledger = try RunLedgerStore.inMemory()
    let store = SessionStore(ledger: ledger)
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    let run = makeRun(id: "run-9", prompt: "Score the opportunity board", answer: "Scored.", createdAt: t0)
    let messages = [
        HarnessMessage(id: "m-1", runId: run.id, role: .user, text: "Score the opportunity board", createdAt: t0),
        HarnessMessage(id: "m-2", runId: run.id, role: .assistant, text: "The board is scored; the bouncer holds the rest.", createdAt: t0.addingTimeInterval(1))
    ]
    try await ledger.save(makeDetail(run: run, messages: messages))

    let session = try await store.createSession(title: "Opportunity review", createdAt: t0)
    try await store.attachRun(runId: run.id, toSession: session.id, at: t0.addingTimeInterval(2))

    let thread = try await store.thread(sessionId: session.id)
    #expect(thread.map(\.id) == ["m-1", "m-2"])

    let runs = try await store.runs(inSession: session.id)
    #expect(runs.map(\.id) == [run.id])

    let hits = try await store.searchSessions(query: "bouncer")
    #expect(hits.first?.sessionId == session.id)
}

@Test func migrationFromPreSessionSchemaPreservesRuns() async throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("SessionStoreTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let path = dir.appendingPathComponent("legacy-ledger.sqlite").path

    let t0 = Date(timeIntervalSince1970: 1_690_000_000)
    let run = makeRun(id: "run-legacy", prompt: "Explain the kill switch", answer: "Spend caps are the kill switch.", createdAt: t0)
    let messages = [
        HarnessMessage(id: "legacy-m-1", runId: run.id, role: .user, text: "Explain the kill switch", createdAt: t0),
        HarnessMessage(id: "legacy-m-2", runId: run.id, role: .assistant, text: "Spend caps are the kill switch; raising them is an Adam decision.", createdAt: t0.addingTimeInterval(1))
    ]
    try RunLedgerStore.makeLegacyDatabaseForTesting(at: path, run: run, messages: messages)

    // Opening the store migrates the old schema in place.
    let ledger = try RunLedgerStore(path: path)
    let runs = try await ledger.listRuns()
    #expect(runs.map(\.id) == [run.id])
    let detail = try await ledger.runDetail(id: run.id)
    #expect(detail?.messages.map(\.id) == ["legacy-m-1", "legacy-m-2"])

    // The migrated database supports the full session feature set.
    let store = SessionStore(ledger: ledger)
    let session = try await store.createSession(title: "Restored session", createdAt: t0.addingTimeInterval(10))
    try await store.attachRun(runId: run.id, toSession: session.id, at: t0.addingTimeInterval(11))

    let thread = try await store.thread(sessionId: session.id)
    #expect(thread.count == 2)

    let hits = try await store.searchSessions(query: "kill switch")
    #expect(hits.first?.sessionId == session.id)
}

@Test func ftsMatchExpressionQuotesTokens() {
    #expect(SessionStore.ftsMatchExpression(for: "kill switch") == "\"kill\" \"switch\"")
    #expect(SessionStore.ftsMatchExpression(for: "say \"hello\"") == "\"say\" \"\"\"hello\"\"\"")
    #expect(SessionStore.ftsMatchExpression(for: "   ") == nil)
}

@Test func likeSnippetTrimsContextAroundMatch() {
    let text = String(repeating: "a", count: 100) + " needle " + String(repeating: "b", count: 100)
    let snippet = SessionStore.snippet(from: text, matching: "needle")
    #expect(snippet.contains("needle"))
    #expect(snippet.hasPrefix("…"))
    #expect(snippet.hasSuffix("…"))
    #expect(snippet.count < text.count)
}
