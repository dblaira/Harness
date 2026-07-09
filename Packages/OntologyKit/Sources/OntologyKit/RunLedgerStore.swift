import Foundation
@preconcurrency import GRDB

public actor RunLedgerStore {
    let dbQueue: DatabaseQueue

    public static func inMemory() throws -> RunLedgerStore {
        try RunLedgerStore(queue: DatabaseQueue(path: ":memory:"))
    }

    /// The application ledger is a single shared instance per process. Opening
    /// a second `DatabaseQueue` on the same file (e.g. a headless routine run
    /// alongside the interactive app) races the app's connection and throws
    /// SQLITE_BUSY on concurrent writes — so every caller gets the same actor,
    /// which serialises all access through one queue.
    public static func applicationDefault() throws -> RunLedgerStore {
        try defaultStoreBox.get {
            let fm = FileManager.default
            let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                .appendingPathComponent("Harness", isDirectory: true)
            try fm.createDirectory(at: base, withIntermediateDirectories: true)
            return try RunLedgerStore(path: base.appendingPathComponent("harness-ledger.sqlite").path)
        }
    }

    /// Lazily-built, lock-guarded shared instance for `applicationDefault()`.
    private final class DefaultStoreBox: @unchecked Sendable {
        private let lock = NSLock()
        private var store: RunLedgerStore?
        func get(_ make: () throws -> RunLedgerStore) rethrows -> RunLedgerStore {
            lock.lock()
            defer { lock.unlock() }
            if let store { return store }
            let created = try make()
            store = created
            return created
        }
    }
    private static let defaultStoreBox = DefaultStoreBox()

    public init(path: String) throws {
        // A busy timeout lets any second connection wait out a writer instead
        // of failing outright — belt and suspenders behind the shared instance.
        var config = Configuration()
        config.busyMode = .timeout(5)
        self.dbQueue = try DatabaseQueue(path: path, configuration: config)
        try Self.migrator.migrate(dbQueue)
        Self.installMessageSearchIfAvailable(dbQueue)
    }

    private init(queue: DatabaseQueue) throws {
        self.dbQueue = queue
        try Self.migrator.migrate(dbQueue)
        Self.installMessageSearchIfAvailable(dbQueue)
    }

    public func save(_ detail: HarnessRunDetail) throws {
        try dbQueue.write { db in
            try insertRun(detail.run, db: db)
            for message in detail.messages { try insertMessage(message, db: db) }
            for hit in detail.authorityHits { try insertAuthorityHit(hit, db: db) }
            for hit in detail.memoryHits { try insertMemoryHit(hit, db: db) }
            for event in detail.traceEvents { try insertTraceEvent(event, db: db) }
            for result in detail.evalResults { try insertEvalResult(result, db: db) }
            for candidate in detail.memoryCandidates { try insertMemoryCandidate(candidate, db: db) }
            for result in detail.validationResults { try insertValidationResult(result, db: db) }
        }
    }

    public func listRuns(limit: Int = 50) throws -> [HarnessRun] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM runs ORDER BY createdAt DESC LIMIT ?", arguments: [limit])
                .map(mapRun)
        }
    }

    public func searchRuns(_ query: String, limit: Int = 50) throws -> [HarnessRun] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return try listRuns(limit: limit) }
        let like = "%\(trimmed)%"
        return try dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT DISTINCT runs.* FROM runs
                LEFT JOIN messages ON messages.runId = runs.id
                WHERE runs.prompt LIKE ? OR runs.finalAnswer LIKE ? OR messages.text LIKE ?
                ORDER BY runs.createdAt DESC
                LIMIT ?
                """,
                arguments: [like, like, like, limit]
            )
            .map(mapRun)
        }
    }

    public func runDetail(id: String) throws -> HarnessRunDetail? {
        try dbQueue.read { db in
            guard let runRow = try Row.fetchOne(db, sql: "SELECT * FROM runs WHERE id = ?", arguments: [id]) else {
                return nil
            }
            let run = mapRun(runRow)
            let messages = try Row.fetchAll(db, sql: "SELECT * FROM messages WHERE runId = ? ORDER BY createdAt ASC", arguments: [id]).map(mapMessage)
            let authorityHits = try Row.fetchAll(db, sql: "SELECT * FROM authority_hits WHERE runId = ? ORDER BY score DESC, subject ASC", arguments: [id]).map(mapAuthorityHit)
            let memoryHits = try Row.fetchAll(db, sql: "SELECT * FROM memory_hits WHERE runId = ? ORDER BY score DESC, source ASC", arguments: [id]).map(mapMemoryHit)
            let traceEvents = try Row.fetchAll(db, sql: "SELECT * FROM trace_events WHERE runId = ? ORDER BY createdAt ASC", arguments: [id]).map(mapTraceEvent)
            let evalResults = try Row.fetchAll(db, sql: "SELECT * FROM eval_results WHERE runId = ? ORDER BY checkName ASC", arguments: [id]).map(mapEvalResult)
            let memoryCandidates = try Row.fetchAll(db, sql: "SELECT * FROM memory_candidates WHERE runId = ? ORDER BY createdAt ASC", arguments: [id]).map(mapMemoryCandidate)
            let validationResults = try Row.fetchAll(db, sql: "SELECT * FROM validation_results WHERE runId = ? ORDER BY createdAt ASC", arguments: [id]).map(mapValidationResult)
            return HarnessRunDetail(
                run: run,
                messages: messages,
                authorityHits: authorityHits,
                memoryHits: memoryHits,
                traceEvents: traceEvents,
                evalResults: evalResults,
                memoryCandidates: memoryCandidates,
                validationResults: validationResults
            )
        }
    }

    public func listCandidates(limit: Int = 50) throws -> [MemoryCandidate] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM memory_candidates ORDER BY createdAt DESC LIMIT ?", arguments: [limit])
                .map(mapMemoryCandidate)
        }
    }

    public func updateCandidateStatus(id: String, status: CandidateState, validationResult: String?) throws {
        try updateCandidateReview(id: id, status: status, proposedGraph: nil, validationResult: validationResult)
    }

    public func updateCandidateReview(id: String, status: CandidateState, proposedGraph: String?, validationResult: String?) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                UPDATE memory_candidates
                SET status = ?, proposedGraph = COALESCE(?, proposedGraph), validationResult = ?
                WHERE id = ?
                """,
                arguments: [status.rawValue, proposedGraph, validationResult, id]
            )
        }
    }

    public func recordReviewQueueDecision(_ decision: ReviewQueueDecisionRecord) throws {
        try dbQueue.write { db in
            try insertReviewQueueDecision(decision, db: db)
        }
    }

    public func listReviewQueueDecisions(limit: Int = 100) throws -> [ReviewQueueDecisionRecord] {
        try dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT * FROM review_queue_decisions ORDER BY createdAt DESC LIMIT ?",
                arguments: [limit]
            )
            .map(mapReviewQueueDecision)
        }
    }

    public func recordOpportunityBoardActions(_ records: [OpportunityBoardActionRecord]) throws {
        guard !records.isEmpty else { return }
        try dbQueue.write { db in
            for record in records {
                try insertOpportunityBoardAction(record, db: db)
            }
        }
    }

    public func listOpportunityBoardActions(limit: Int = 100) throws -> [OpportunityBoardActionRecord] {
        try dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT * FROM opportunity_board_actions ORDER BY createdAt DESC LIMIT ?",
                arguments: [limit]
            )
            .map(mapOpportunityBoardAction)
        }
    }

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "runs", ifNotExists: true) { t in
                t.column("id", .text).primaryKey()
                t.column("prompt", .text).notNull()
                t.column("backend", .text).notNull()
                t.column("modelName", .text).notNull()
                t.column("invocationMethod", .text).notNull()
                t.column("promptPacketHash", .text).notNull()
                t.column("success", .boolean).notNull()
                t.column("duration", .double).notNull()
                t.column("tokenCount", .integer)
                t.column("cost", .double)
                t.column("finalAnswer", .text).notNull()
                t.column("deviceName", .text).notNull()
                t.column("createdAt", .double).notNull()
            }
            try db.create(table: "messages", ifNotExists: true) { t in
                t.column("id", .text).primaryKey()
                t.column("runId", .text).notNull().indexed().references("runs", onDelete: .cascade)
                t.column("role", .text).notNull()
                t.column("text", .text).notNull()
                t.column("createdAt", .double).notNull()
            }
            try db.create(table: "authority_hits", ifNotExists: true) { t in
                t.column("id", .text).primaryKey()
                t.column("runId", .text).notNull().indexed().references("runs", onDelete: .cascade)
                t.column("subject", .text).notNull()
                t.column("predicate", .text).notNull()
                t.column("object", .text).notNull()
                t.column("source", .text).notNull()
                t.column("queryTrace", .text).notNull()
                t.column("authorityLevel", .text).notNull()
                t.column("score", .double).notNull()
            }
            try db.create(table: "memory_hits", ifNotExists: true) { t in
                t.column("id", .text).primaryKey()
                t.column("runId", .text).notNull().indexed().references("runs", onDelete: .cascade)
                t.column("source", .text).notNull()
                t.column("excerpt", .text).notNull()
                t.column("score", .double).notNull()
                t.column("reasonSelected", .text).notNull()
                t.column("authorityLevel", .text).notNull()
                t.column("sourceCardJSON", .text)
            }
            try db.create(table: "trace_events", ifNotExists: true) { t in
                t.column("id", .text).primaryKey()
                t.column("runId", .text).notNull().indexed().references("runs", onDelete: .cascade)
                t.column("stage", .text).notNull()
                t.column("message", .text).notNull()
                t.column("createdAt", .double).notNull()
            }
            try db.create(table: "eval_results", ifNotExists: true) { t in
                t.column("id", .text).primaryKey()
                t.column("runId", .text).notNull().indexed().references("runs", onDelete: .cascade)
                t.column("checkName", .text).notNull()
                t.column("passed", .boolean).notNull()
                t.column("detail", .text).notNull()
            }
            try db.create(table: "memory_candidates", ifNotExists: true) { t in
                t.column("id", .text).primaryKey()
                t.column("runId", .text).notNull().indexed().references("runs", onDelete: .cascade)
                t.column("sourceRunIds", .text).notNull()
                t.column("evidenceText", .text).notNull()
                t.column("proposedClaim", .text).notNull()
                t.column("proposedGraph", .text)
                t.column("status", .text).notNull()
                t.column("validationResult", .text)
                t.column("createdAt", .double).notNull()
                t.column("plainEnglish", .text)
                t.column("evidenceNote", .text)
                t.column("sourceRef", .text)
                t.column("strength", .double)
                t.column("frequency", .text)
            }
            try db.create(table: "validation_results", ifNotExists: true) { t in
                t.column("id", .text).primaryKey()
                t.column("runId", .text).indexed()
                t.column("candidateId", .text).indexed()
                t.column("kind", .text).notNull()
                t.column("passed", .boolean).notNull()
                t.column("detail", .text).notNull()
                t.column("createdAt", .double).notNull()
            }
        }
        migrator.registerMigration("v2-review-queue") { db in
            let memoryCandidateColumns = try db.columns(in: "memory_candidates").map(\.name)
            if !memoryCandidateColumns.contains("plainEnglish") {
                try db.alter(table: "memory_candidates") { t in
                    t.add(column: "plainEnglish", .text)
                    t.add(column: "evidenceNote", .text)
                    t.add(column: "sourceRef", .text)
                    t.add(column: "strength", .double)
                    t.add(column: "frequency", .text)
                }
            }
            try db.create(table: "review_queue_decisions", ifNotExists: true) { t in
                t.column("id", .text).primaryKey()
                t.column("claimId", .text).notNull().indexed()
                t.column("decision", .text).notNull()
                t.column("frequency", .text)
                t.column("claim", .text).notNull()
                t.column("evidenceNote", .text).notNull()
                t.column("sourceRef", .text).notNull()
                t.column("createdAt", .double).notNull()
            }
        }
        migrator.registerMigration("v3-source-cards") { db in
            let memoryHitColumns = try db.columns(in: "memory_hits").map(\.name)
            if !memoryHitColumns.contains("sourceCardJSON") {
                try db.alter(table: "memory_hits") { t in
                    t.add(column: "sourceCardJSON", .text)
                }
            }
        }
        migrator.registerMigration("v4-opportunity-board-actions") { db in
            try db.create(table: "opportunity_board_actions", ifNotExists: true) { t in
                t.column("id", .text).primaryKey()
                t.column("batchID", .text).notNull().indexed()
                t.column("opportunityID", .text).notNull().indexed()
                t.column("canonicalResource", .text).notNull()
                t.column("action", .text).notNull().indexed()
                t.column("createdAt", .double).notNull()
            }
        }
        migrator.registerMigration("v5-sessions") { db in
            try db.create(table: "sessions", ifNotExists: true) { t in
                t.column("id", .text).primaryKey()
                t.column("title", .text).notNull()
                t.column("createdAt", .double).notNull()
                t.column("updatedAt", .double).notNull()
            }
            let runColumns = try db.columns(in: "runs").map(\.name)
            if !runColumns.contains("sessionId") {
                try db.alter(table: "runs") { t in
                    t.add(column: "sessionId", .text)
                }
                try db.create(index: "runs_on_sessionId", on: "runs", columns: ["sessionId"], ifNotExists: true)
            }
            let messageColumns = try db.columns(in: "messages").map(\.name)
            if !messageColumns.contains("sessionId") {
                // Rebuild so runId becomes nullable (session messages may exist
                // without a run) and sessionId exists. SQLite cannot drop a
                // NOT NULL constraint in place.
                try db.create(table: "messages_new") { t in
                    t.column("id", .text).primaryKey()
                    t.column("runId", .text).references("runs", onDelete: .cascade)
                    t.column("sessionId", .text)
                    t.column("role", .text).notNull()
                    t.column("text", .text).notNull()
                    t.column("createdAt", .double).notNull()
                }
                try db.execute(sql: """
                    INSERT INTO messages_new (id, runId, sessionId, role, text, createdAt)
                    SELECT id, runId, NULL, role, text, createdAt FROM messages
                    """)
                try db.drop(table: "messages")
                try db.rename(table: "messages_new", to: "messages")
                try db.create(index: "messages_on_runId", on: "messages", columns: ["runId"], ifNotExists: true)
                try db.create(index: "messages_on_sessionId", on: "messages", columns: ["sessionId"], ifNotExists: true)
            }
        }
        migrator.registerMigration("v6-eval-result-artifact-path") { db in
            let evalResultColumns = try db.columns(in: "eval_results").map(\.name)
            if !evalResultColumns.contains("artifactPath") {
                try db.alter(table: "eval_results") { t in
                    t.add(column: "artifactPath", .text)
                }
            }
        }
        return migrator
    }

    /// Probes for FTS5 support at runtime by creating the virtual table.
    /// On SQLite builds without FTS5 this fails quietly and episodic search
    /// falls back to LIKE queries (see SessionStore.searchSessions).
    static func installMessageSearchIfAvailable(_ dbQueue: DatabaseQueue) {
        try? dbQueue.write { db in
            guard try !db.tableExists("messages_fts") else { return }
            do {
                try db.execute(sql: "CREATE VIRTUAL TABLE messages_fts USING fts5(messageId UNINDEXED, text)")
            } catch {
                return // FTS5 unavailable; LIKE fallback applies.
            }
            try db.execute(sql: "INSERT INTO messages_fts (messageId, text) SELECT id, text FROM messages")
        }
    }

    /// Test seam: writes a database using the pre-session (v1-era) schema so
    /// tests can prove existing ledgers survive the sessions migration.
    static func makeLegacyDatabaseForTesting(at path: String, run: HarnessRun, messages: [HarnessMessage]) throws {
        let legacy = try DatabaseQueue(path: path)
        try legacy.write { db in
            try db.execute(sql: """
                CREATE TABLE runs (
                    id TEXT PRIMARY KEY, prompt TEXT NOT NULL, backend TEXT NOT NULL,
                    modelName TEXT NOT NULL, invocationMethod TEXT NOT NULL, promptPacketHash TEXT NOT NULL,
                    success BOOLEAN NOT NULL, duration DOUBLE NOT NULL, tokenCount INTEGER, cost DOUBLE,
                    finalAnswer TEXT NOT NULL, deviceName TEXT NOT NULL, createdAt DOUBLE NOT NULL
                )
                """)
            try db.execute(sql: """
                CREATE TABLE messages (
                    id TEXT PRIMARY KEY,
                    runId TEXT NOT NULL REFERENCES runs(id) ON DELETE CASCADE,
                    role TEXT NOT NULL, text TEXT NOT NULL, createdAt DOUBLE NOT NULL
                )
                """)
            try db.execute(sql: "CREATE INDEX messages_on_runId ON messages(runId)")
            try db.execute(sql: """
                CREATE TABLE memory_candidates (
                    id TEXT PRIMARY KEY, runId TEXT NOT NULL, sourceRunIds TEXT NOT NULL,
                    evidenceText TEXT NOT NULL, proposedClaim TEXT NOT NULL, proposedGraph TEXT,
                    status TEXT NOT NULL, validationResult TEXT, createdAt DOUBLE NOT NULL
                )
                """)
            try db.execute(sql: """
                CREATE TABLE memory_hits (
                    id TEXT PRIMARY KEY, runId TEXT NOT NULL, source TEXT NOT NULL,
                    excerpt TEXT NOT NULL, score DOUBLE NOT NULL, reasonSelected TEXT NOT NULL,
                    authorityLevel TEXT NOT NULL
                )
                """)
            try insertRun(run, db: db)
            for message in messages {
                try db.execute(
                    sql: "INSERT INTO messages (id, runId, role, text, createdAt) VALUES (?, ?, ?, ?, ?)",
                    arguments: [message.id, message.runId, message.role.rawValue, message.text, message.createdAt.timeIntervalSince1970]
                )
            }
        }
    }
}

func insertRun(_ run: HarnessRun, db: Database) throws {
    // Upsert (not OR REPLACE) so a re-save keeps the row's sessionId intact.
    try db.execute(
        sql: """
        INSERT INTO runs
        (id, prompt, backend, modelName, invocationMethod, promptPacketHash, success, duration, tokenCount, cost, finalAnswer, deviceName, createdAt)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
        prompt = excluded.prompt, backend = excluded.backend, modelName = excluded.modelName,
        invocationMethod = excluded.invocationMethod, promptPacketHash = excluded.promptPacketHash,
        success = excluded.success, duration = excluded.duration, tokenCount = excluded.tokenCount,
        cost = excluded.cost, finalAnswer = excluded.finalAnswer, deviceName = excluded.deviceName,
        createdAt = excluded.createdAt
        """,
        arguments: [
            run.id,
            run.prompt,
            run.backend,
            run.modelName,
            run.invocationMethod,
            run.promptPacketHash,
            run.success,
            run.duration,
            run.tokenCount,
            run.cost,
            run.finalAnswer,
            run.deviceName,
            run.createdAt.timeIntervalSince1970
        ]
    )
}

private func insertMessage(_ message: HarnessMessage, db: Database) throws {
    // Upsert (not OR REPLACE) so a re-save keeps the row's sessionId intact.
    try db.execute(
        sql: """
        INSERT INTO messages (id, runId, role, text, createdAt) VALUES (?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
        runId = excluded.runId, role = excluded.role, text = excluded.text, createdAt = excluded.createdAt
        """,
        arguments: [message.id, message.runId, message.role.rawValue, message.text, message.createdAt.timeIntervalSince1970]
    )
    try indexMessageForSearch(db, messageId: message.id, text: message.text)
}

/// Mirrors a message's text into the FTS5 index when it is installed.
/// Delete-then-insert keeps the index consistent under upserts.
func indexMessageForSearch(_ db: Database, messageId: String, text: String) throws {
    guard try db.tableExists("messages_fts") else { return }
    try db.execute(sql: "DELETE FROM messages_fts WHERE messageId = ?", arguments: [messageId])
    try db.execute(sql: "INSERT INTO messages_fts (messageId, text) VALUES (?, ?)", arguments: [messageId, text])
}

private func insertAuthorityHit(_ hit: GraphAuthorityHit, db: Database) throws {
    try db.execute(
        sql: """
        INSERT OR REPLACE INTO authority_hits
        (id, runId, subject, predicate, object, source, queryTrace, authorityLevel, score)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        arguments: [hit.id, hit.runId, hit.subject, hit.predicate, hit.object, hit.source, hit.queryTrace, hit.authorityLevel.rawValue, hit.score]
    )
}

private func insertMemoryHit(_ hit: MemoryHit, db: Database) throws {
    try db.execute(
        sql: """
        INSERT OR REPLACE INTO memory_hits
        (id, runId, source, excerpt, score, reasonSelected, authorityLevel, sourceCardJSON)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        """,
        arguments: [
            hit.id,
            hit.runId,
            hit.source,
            hit.excerpt,
            hit.score,
            hit.reasonSelected,
            hit.authorityLevel.rawValue,
            try encodeSourceCard(hit.sourceCard)
        ]
    )
}

private func insertTraceEvent(_ event: TraceEvent, db: Database) throws {
    try db.execute(
        sql: "INSERT OR REPLACE INTO trace_events (id, runId, stage, message, createdAt) VALUES (?, ?, ?, ?, ?)",
        arguments: [event.id, event.runId, event.stage.rawValue, event.message, event.createdAt.timeIntervalSince1970]
    )
}

private func insertEvalResult(_ result: EvalResult, db: Database) throws {
    try db.execute(
        sql: "INSERT OR REPLACE INTO eval_results (id, runId, checkName, passed, detail, artifactPath) VALUES (?, ?, ?, ?, ?, ?)",
        arguments: [result.id, result.runId, result.checkName, result.passed, result.detail, result.artifactPath]
    )
}

private func insertMemoryCandidate(_ candidate: MemoryCandidate, db: Database) throws {
    try db.execute(
        sql: """
        INSERT OR REPLACE INTO memory_candidates
        (id, runId, sourceRunIds, evidenceText, proposedClaim, proposedGraph, status, validationResult, createdAt, plainEnglish, evidenceNote, sourceRef, strength, frequency)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        arguments: [
            candidate.id,
            candidate.runId,
            candidate.sourceRunIds.joined(separator: ","),
            candidate.evidenceText,
            candidate.proposedClaim,
            candidate.proposedGraph,
            candidate.status.rawValue,
            candidate.validationResult,
            candidate.createdAt.timeIntervalSince1970,
            candidate.plainEnglish,
            candidate.evidenceNote,
            candidate.sourceRef,
            candidate.strength,
            candidate.frequency
        ]
    )
}

private func insertReviewQueueDecision(_ decision: ReviewQueueDecisionRecord, db: Database) throws {
    try db.execute(
        sql: """
        INSERT OR REPLACE INTO review_queue_decisions
        (id, claimId, decision, frequency, claim, evidenceNote, sourceRef, createdAt)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        """,
        arguments: [
            decision.id,
            decision.claimId,
            decision.decision,
            decision.frequency,
            decision.claim,
            decision.evidenceNote,
            decision.sourceRef,
            decision.createdAt.timeIntervalSince1970
        ]
    )
}

private func insertOpportunityBoardAction(_ record: OpportunityBoardActionRecord, db: Database) throws {
    try db.execute(
        sql: """
        INSERT OR REPLACE INTO opportunity_board_actions
        (id, batchID, opportunityID, canonicalResource, action, createdAt)
        VALUES (?, ?, ?, ?, ?, ?)
        """,
        arguments: [
            record.id,
            record.batchID,
            record.opportunityID,
            record.canonicalResource,
            record.action.rawValue,
            record.createdAt.timeIntervalSince1970
        ]
    )
}

private func insertValidationResult(_ result: ValidationResult, db: Database) throws {
    try db.execute(
        sql: """
        INSERT OR REPLACE INTO validation_results
        (id, runId, candidateId, kind, passed, detail, createdAt)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        """,
        arguments: [result.id, result.runId, result.candidateId, result.kind, result.passed, result.detail, result.createdAt.timeIntervalSince1970]
    )
}

func mapRun(_ row: Row) -> HarnessRun {
    HarnessRun(
        id: row["id"],
        prompt: row["prompt"],
        backend: row["backend"],
        modelName: row["modelName"],
        invocationMethod: row["invocationMethod"],
        promptPacketHash: row["promptPacketHash"],
        success: row["success"],
        duration: row["duration"],
        tokenCount: row["tokenCount"],
        cost: row["cost"],
        finalAnswer: row["finalAnswer"],
        deviceName: row["deviceName"],
        createdAt: Date(timeIntervalSince1970: row["createdAt"])
    )
}

private func mapMessage(_ row: Row) -> HarnessMessage {
    HarnessMessage(
        id: row["id"],
        runId: row["runId"],
        role: MessageRole(rawValue: row["role"]) ?? .system,
        text: row["text"],
        createdAt: Date(timeIntervalSince1970: row["createdAt"])
    )
}

private func mapAuthorityHit(_ row: Row) -> GraphAuthorityHit {
    GraphAuthorityHit(
        id: row["id"],
        runId: row["runId"],
        subject: row["subject"],
        predicate: row["predicate"],
        object: row["object"],
        source: row["source"],
        queryTrace: row["queryTrace"],
        authorityLevel: AuthorityLevel(rawValue: row["authorityLevel"]) ?? .accepted,
        score: row["score"]
    )
}

private func mapMemoryHit(_ row: Row) -> MemoryHit {
    let sourceCardJSON: String? = row["sourceCardJSON"]
    return MemoryHit(
        id: row["id"],
        runId: row["runId"],
        source: row["source"],
        excerpt: row["excerpt"],
        score: row["score"],
        reasonSelected: row["reasonSelected"],
        authorityLevel: AuthorityLevel(rawValue: row["authorityLevel"]) ?? .supporting,
        sourceCard: decodeSourceCard(sourceCardJSON)
    )
}

private func encodeSourceCard(_ sourceCard: SourceCard?) throws -> String? {
    guard let sourceCard else { return nil }
    let data = try JSONEncoder().encode(sourceCard)
    return String(data: data, encoding: .utf8)
}

private func decodeSourceCard(_ json: String?) -> SourceCard? {
    guard let json,
          let data = json.data(using: .utf8) else {
        return nil
    }
    return try? JSONDecoder().decode(SourceCard.self, from: data)
}

private func mapTraceEvent(_ row: Row) -> TraceEvent {
    TraceEvent(
        id: row["id"],
        runId: row["runId"],
        stage: TraceStage(rawValue: row["stage"]) ?? .traceSaved,
        message: row["message"],
        createdAt: Date(timeIntervalSince1970: row["createdAt"])
    )
}

private func mapEvalResult(_ row: Row) -> EvalResult {
    EvalResult(
        id: row["id"],
        runId: row["runId"],
        checkName: row["checkName"],
        passed: row["passed"],
        detail: row["detail"],
        artifactPath: row["artifactPath"]
    )
}

private func mapMemoryCandidate(_ row: Row) -> MemoryCandidate {
    let sourceRunIds: String = row["sourceRunIds"]
    return MemoryCandidate(
        id: row["id"],
        runId: row["runId"],
        sourceRunIds: sourceRunIds.split(separator: ",").map(String.init),
        evidenceText: row["evidenceText"],
        proposedClaim: row["proposedClaim"],
        proposedGraph: row["proposedGraph"],
        status: CandidateState(rawValue: row["status"]) ?? .suggested,
        validationResult: row["validationResult"],
        createdAt: Date(timeIntervalSince1970: row["createdAt"]),
        plainEnglish: row["plainEnglish"],
        evidenceNote: row["evidenceNote"],
        sourceRef: row["sourceRef"],
        strength: row["strength"],
        frequency: row["frequency"]
    )
}

private func mapReviewQueueDecision(_ row: Row) -> ReviewQueueDecisionRecord {
    ReviewQueueDecisionRecord(
        id: row["id"],
        claimId: row["claimId"],
        decision: row["decision"],
        frequency: row["frequency"],
        claim: row["claim"],
        evidenceNote: row["evidenceNote"],
        sourceRef: row["sourceRef"],
        createdAt: Date(timeIntervalSince1970: row["createdAt"])
    )
}

private func mapOpportunityBoardAction(_ row: Row) -> OpportunityBoardActionRecord {
    OpportunityBoardActionRecord(
        id: row["id"],
        batchID: row["batchID"],
        opportunityID: row["opportunityID"],
        canonicalResource: row["canonicalResource"],
        action: OpportunityBoardAction(rawValue: row["action"]) ?? .hold,
        createdAt: Date(timeIntervalSince1970: row["createdAt"])
    )
}

private func mapValidationResult(_ row: Row) -> ValidationResult {
    ValidationResult(
        id: row["id"],
        runId: row["runId"],
        candidateId: row["candidateId"],
        kind: row["kind"],
        passed: row["passed"],
        detail: row["detail"],
        createdAt: Date(timeIntervalSince1970: row["createdAt"])
    )
}
