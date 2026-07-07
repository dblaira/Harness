import Foundation
@preconcurrency import GRDB

public struct ChatSession: Identifiable, Codable, Sendable, Equatable {
    public let id: String
    public let title: String
    public let createdAt: Date
    public let updatedAt: Date

    public init(id: String = UUID().uuidString, title: String, createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct SessionMessage: Identifiable, Codable, Sendable, Equatable {
    public let id: String
    public let sessionId: String
    public let runId: String?
    public let role: MessageRole
    public let text: String
    public let createdAt: Date

    public init(
        id: String = UUID().uuidString,
        sessionId: String,
        runId: String? = nil,
        role: MessageRole,
        text: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.sessionId = sessionId
        self.runId = runId
        self.role = role
        self.text = text
        self.createdAt = createdAt
    }
}

public struct SessionSearchHit: Identifiable, Codable, Sendable, Equatable {
    public let sessionId: String
    public let title: String
    public let snippet: String

    public var id: String { sessionId }

    public init(sessionId: String, title: String, snippet: String) {
        self.sessionId = sessionId
        self.title = title
        self.snippet = snippet
    }
}

/// Chat-session persistence and episodic search over the run ledger database.
/// Shares the ledger's DatabaseQueue so sessions, runs, and messages live in
/// one SQLite file and one connection.
public actor SessionStore {
    private let dbQueue: DatabaseQueue

    public init(ledger: RunLedgerStore) {
        self.dbQueue = ledger.dbQueue
    }

    // MARK: Sessions

    @discardableResult
    public func createSession(title: String, id: String = UUID().uuidString, createdAt: Date = Date()) throws -> ChatSession {
        let session = ChatSession(id: id, title: title, createdAt: createdAt, updatedAt: createdAt)
        try dbQueue.write { db in
            try db.execute(
                sql: "INSERT OR REPLACE INTO sessions (id, title, createdAt, updatedAt) VALUES (?, ?, ?, ?)",
                arguments: [session.id, session.title, session.createdAt.timeIntervalSince1970, session.updatedAt.timeIntervalSince1970]
            )
        }
        return session
    }

    public func listSessions(limit: Int = 100) throws -> [ChatSession] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM sessions ORDER BY updatedAt DESC LIMIT ?", arguments: [limit])
                .map(mapChatSession)
        }
    }

    public func session(id: String) throws -> ChatSession? {
        try dbQueue.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM sessions WHERE id = ?", arguments: [id])
                .map(mapChatSession)
        }
    }

    public func renameSession(id: String, title: String, at date: Date = Date()) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE sessions SET title = ?, updatedAt = MAX(updatedAt, ?) WHERE id = ?",
                arguments: [title, date.timeIntervalSince1970, id]
            )
        }
    }

    /// Launch restore: the session touched most recently, if any.
    public func mostRecentSession() throws -> ChatSession? {
        try dbQueue.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM sessions ORDER BY updatedAt DESC LIMIT 1")
                .map(mapChatSession)
        }
    }

    // MARK: Messages

    @discardableResult
    public func appendMessage(
        sessionId: String,
        role: MessageRole,
        text: String,
        runId: String? = nil,
        id: String = UUID().uuidString,
        createdAt: Date = Date()
    ) throws -> SessionMessage {
        let message = SessionMessage(id: id, sessionId: sessionId, runId: runId, role: role, text: text, createdAt: createdAt)
        try dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO messages (id, runId, sessionId, role, text, createdAt) VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                runId = excluded.runId, sessionId = excluded.sessionId, role = excluded.role,
                text = excluded.text, createdAt = excluded.createdAt
                """,
                arguments: [message.id, message.runId, message.sessionId, message.role.rawValue, message.text, message.createdAt.timeIntervalSince1970]
            )
            try indexMessageForSearch(db, messageId: message.id, text: message.text)
            try db.execute(
                sql: "UPDATE sessions SET updatedAt = MAX(updatedAt, ?) WHERE id = ?",
                arguments: [message.createdAt.timeIntervalSince1970, sessionId]
            )
        }
        return message
    }

    /// The full conversation for a session, oldest first.
    public func thread(sessionId: String) throws -> [SessionMessage] {
        try dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT * FROM messages WHERE sessionId = ? ORDER BY createdAt ASC, rowid ASC",
                arguments: [sessionId]
            )
            .map(mapSessionMessage)
        }
    }

    // MARK: Runs

    /// Links an existing ledger run (and its transcript messages) to a session
    /// so episodic search covers the run's conversation.
    public func attachRun(runId: String, toSession sessionId: String, at date: Date = Date()) throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE runs SET sessionId = ? WHERE id = ?", arguments: [sessionId, runId])
            try db.execute(sql: "UPDATE messages SET sessionId = ? WHERE runId = ?", arguments: [sessionId, runId])
            try db.execute(
                sql: "UPDATE sessions SET updatedAt = MAX(updatedAt, ?) WHERE id = ?",
                arguments: [date.timeIntervalSince1970, sessionId]
            )
        }
    }

    public func runs(inSession sessionId: String) throws -> [HarnessRun] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM runs WHERE sessionId = ? ORDER BY createdAt ASC", arguments: [sessionId])
                .map(mapRun)
        }
    }

    // MARK: Search

    /// Episodic search across sessions. Uses the FTS5 index when the runtime
    /// SQLite installed it (see RunLedgerStore.installMessageSearchIfAvailable),
    /// otherwise a LIKE scan. Session titles match in both modes. Returns one
    /// hit per session, most recently matched first.
    public func searchSessions(query: String, limit: Int = 20) throws -> [SessionSearchHit] {
        try search(query: query, limit: limit, useFTSIfAvailable: true)
    }

    /// Internal seam so the LIKE fallback stays testable on FTS5-capable builds.
    func searchSessionsUsingLikeFallback(query: String, limit: Int = 20) throws -> [SessionSearchHit] {
        try search(query: query, limit: limit, useFTSIfAvailable: false)
    }

    private func search(query: String, limit: Int, useFTSIfAvailable: Bool) throws -> [SessionSearchHit] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, limit > 0 else { return [] }
        return try dbQueue.read { db in
            var hits: [SessionSearchHit] = []
            if useFTSIfAvailable,
               try db.tableExists("messages_fts"),
               let match = Self.ftsMatchExpression(for: trimmed) {
                do {
                    hits = try Self.ftsHits(db, match: match, limit: limit)
                } catch {
                    hits = try Self.likeHits(db, query: trimmed, limit: limit)
                }
            } else {
                hits = try Self.likeHits(db, query: trimmed, limit: limit)
            }
            let titleRows = try Row.fetchAll(
                db,
                sql: "SELECT id, title FROM sessions WHERE title LIKE ? ESCAPE '\\' ORDER BY updatedAt DESC LIMIT ?",
                arguments: [Self.likePattern(for: trimmed), limit]
            )
            for row in titleRows {
                let sessionId: String = row["id"]
                guard !hits.contains(where: { $0.sessionId == sessionId }) else { continue }
                let title: String = row["title"]
                hits.append(SessionSearchHit(sessionId: sessionId, title: title, snippet: title))
            }
            return Array(hits.prefix(limit))
        }
    }

    private static func ftsHits(_ db: Database, match: String, limit: Int) throws -> [SessionSearchHit] {
        try Row.fetchAll(
            db,
            sql: """
            SELECT sessions.id AS sessionId, sessions.title AS title,
                   snippet(messages_fts, 1, '[', ']', '…', 12) AS snippet,
                   MAX(messages.createdAt) AS lastMatchedAt
            FROM messages_fts
            JOIN messages ON messages.id = messages_fts.messageId
            JOIN sessions ON sessions.id = messages.sessionId
            WHERE messages_fts MATCH ?
            GROUP BY sessions.id
            ORDER BY lastMatchedAt DESC
            LIMIT ?
            """,
            arguments: [match, limit]
        )
        .map { row in
            SessionSearchHit(sessionId: row["sessionId"], title: row["title"], snippet: row["snippet"])
        }
    }

    private static func likeHits(_ db: Database, query: String, limit: Int) throws -> [SessionSearchHit] {
        try Row.fetchAll(
            db,
            sql: """
            SELECT sessions.id AS sessionId, sessions.title AS title, messages.text AS text,
                   MAX(messages.createdAt) AS lastMatchedAt
            FROM messages
            JOIN sessions ON sessions.id = messages.sessionId
            WHERE messages.text LIKE ? ESCAPE '\\'
            GROUP BY sessions.id
            ORDER BY lastMatchedAt DESC
            LIMIT ?
            """,
            arguments: [likePattern(for: query), limit]
        )
        .map { row in
            SessionSearchHit(
                sessionId: row["sessionId"],
                title: row["title"],
                snippet: snippet(from: row["text"], matching: query)
            )
        }
    }

    /// Turns free text into an FTS5 MATCH expression: each whitespace-separated
    /// token is quoted (implicit AND), so user punctuation cannot break syntax.
    static func ftsMatchExpression(for query: String) -> String? {
        let tokens = query.split(whereSeparator: { $0.isWhitespace })
            .map { String($0).replacingOccurrences(of: "\"", with: "\"\"") }
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return nil }
        return tokens.map { "\"\($0)\"" }.joined(separator: " ")
    }

    static func likePattern(for query: String) -> String {
        var escaped = query.replacingOccurrences(of: "\\", with: "\\\\")
        escaped = escaped.replacingOccurrences(of: "%", with: "\\%")
        escaped = escaped.replacingOccurrences(of: "_", with: "\\_")
        return "%\(escaped)%"
    }

    /// Hand-rolled snippet for the LIKE fallback: context around the first
    /// match of the query (or its first token).
    static func snippet(from text: String, matching query: String, radius: Int = 40) -> String {
        let flattened = text.replacingOccurrences(of: "\n", with: " ")
        let needles = [query] + query.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard let range = needles.lazy.compactMap({ flattened.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) }).first else {
            return String(flattened.prefix(80))
        }
        let start = flattened.index(range.lowerBound, offsetBy: -radius, limitedBy: flattened.startIndex) ?? flattened.startIndex
        let end = flattened.index(range.upperBound, offsetBy: radius, limitedBy: flattened.endIndex) ?? flattened.endIndex
        var snippet = String(flattened[start..<end]).trimmingCharacters(in: .whitespaces)
        if start > flattened.startIndex { snippet = "…" + snippet }
        if end < flattened.endIndex { snippet += "…" }
        return snippet
    }
}

private func mapChatSession(_ row: Row) -> ChatSession {
    ChatSession(
        id: row["id"],
        title: row["title"],
        createdAt: Date(timeIntervalSince1970: row["createdAt"]),
        updatedAt: Date(timeIntervalSince1970: row["updatedAt"])
    )
}

private func mapSessionMessage(_ row: Row) -> SessionMessage {
    SessionMessage(
        id: row["id"],
        sessionId: row["sessionId"],
        runId: row["runId"],
        role: MessageRole(rawValue: row["role"]) ?? .system,
        text: row["text"],
        createdAt: Date(timeIntervalSince1970: row["createdAt"])
    )
}
