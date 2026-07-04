import Foundation
@preconcurrency import GRDB

public actor RunLedgerStore {
    private let dbQueue: DatabaseQueue

    public static func inMemory() throws -> RunLedgerStore {
        try RunLedgerStore(queue: DatabaseQueue(path: ":memory:"))
    }

    public static func applicationDefault() throws -> RunLedgerStore {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Harness", isDirectory: true)
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        return try RunLedgerStore(path: base.appendingPathComponent("harness-ledger.sqlite").path)
    }

    public init(path: String) throws {
        self.dbQueue = try DatabaseQueue(path: path)
        try Self.migrator.migrate(dbQueue)
    }

    private init(queue: DatabaseQueue) throws {
        self.dbQueue = queue
        try Self.migrator.migrate(dbQueue)
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
        return migrator
    }
}

private func insertRun(_ run: HarnessRun, db: Database) throws {
    try db.execute(
        sql: """
        INSERT OR REPLACE INTO runs
        (id, prompt, backend, modelName, invocationMethod, promptPacketHash, success, duration, tokenCount, cost, finalAnswer, deviceName, createdAt)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
    try db.execute(
        sql: "INSERT OR REPLACE INTO messages (id, runId, role, text, createdAt) VALUES (?, ?, ?, ?, ?)",
        arguments: [message.id, message.runId, message.role.rawValue, message.text, message.createdAt.timeIntervalSince1970]
    )
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
        sql: "INSERT OR REPLACE INTO eval_results (id, runId, checkName, passed, detail) VALUES (?, ?, ?, ?, ?)",
        arguments: [result.id, result.runId, result.checkName, result.passed, result.detail]
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

private func mapRun(_ row: Row) -> HarnessRun {
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
        detail: row["detail"]
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
