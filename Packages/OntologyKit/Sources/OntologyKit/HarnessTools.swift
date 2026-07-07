import Foundation

// MARK: - JSONValue

/// Minimal JSON tree used for tool input payloads and JSON-schema
/// declarations. Codable + Sendable so ToolSpec can travel into backend
/// request builders (WS-B1) and be persisted in trace events.
public indirect enum JSONValue: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    /// Parse a JSON document (the shape model tool-calls arrive in).
    public static func parse(_ json: String) -> JSONValue? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: data)
    }

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var intValue: Int? {
        if case .number(let value) = self { return Int(value) }
        if case .string(let value) = self { return Int(value) }
        return nil
    }

    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    public subscript(key: String) -> JSONValue? {
        objectValue?[key]
    }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral, ExpressibleByBooleanLiteral,
    ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(uniqueKeysWithValues: elements))
    }
    public init(nilLiteral: ()) { self = .null }
}

// MARK: - ToolSpec

/// One tool the model may call: a name, a behavioral description (the
/// description IS the policy surface the model reads), and a JSON-schema
/// input declaration.
public struct ToolSpec: Identifiable, Codable, Sendable, Equatable {
    public let name: String
    public let description: String
    public let inputSchema: JSONValue

    public var id: String { name }

    public init(name: String, description: String, inputSchema: JSONValue) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }
}

// MARK: - Catalog v1

/// The Harness tool catalog. Descriptions follow Hermes's tool wording where
/// it exists, adapted for the law: "Agents propose. The bouncer checks. You
/// decide." Spend, trade, contact, and commit tools deliberately DO NOT
/// EXIST in this schema — there is nothing to jailbreak toward; anything
/// that spends, trades, contacts, or commits is a proposal for Adam, and the
/// only mutation paths (write_file, dangerous shell, memory) route through
/// his approval queue.
public enum HarnessToolCatalog {
    public static func spec(named name: String) -> ToolSpec? {
        v1.first { $0.name == name }
    }

    /// Tool names that must never appear in any Harness tool schema.
    /// Kept as a public constant so tests and integrators can assert the
    /// law structurally, not just by convention.
    public static let forbiddenToolNames: Set<String> = [
        "spend", "pay", "purchase", "buy", "trade", "transfer_funds",
        "send_email", "send_message", "contact", "post", "tweet",
        "commit", "sign", "subscribe", "order",
    ]

    public static let v1: [ToolSpec] = [
        ToolSpec(
            name: "shell",
            description: """
            Execute shell commands on Adam's Mac (zsh). Each call runs in a fresh shell; \
            exported environment variables do not persist between calls.

            Do NOT use cat/head/tail to read files — use read_file instead.
            Do NOT use grep/rg/find to search — use search_files instead.
            Do NOT use ls to list directories — use search_files(target='files') instead.
            Do NOT use echo/cat heredoc to create files — use write_file instead.
            Reserve shell for: builds, installs, git, processes, scripts, and anything that needs a shell.

            THE LAW: dangerous commands (recursive deletes, force pushes, anything network-mutating, \
            writes to sensitive paths) suspend the run and render an approve/deny card for Adam — \
            the bouncer checks, Adam decides. Commands with no recovery path are refused outright.

            Foreground only in v1: commands return when done. Set timeout for long builds/scripts.
            """,
            inputSchema: [
                "type": "object",
                "properties": [
                    "command": [
                        "type": "string",
                        "description": "The command to execute",
                    ],
                    "timeout": [
                        "type": "integer",
                        "description": "Max seconds to wait (default: 120, max: 600). Returns as soon as the command finishes.",
                    ],
                    "workdir": [
                        "type": "string",
                        "description": "Working directory for this command (absolute path).",
                    ],
                ],
                "required": ["command"],
            ]
        ),
        ToolSpec(
            name: "read_file",
            description: """
            Read a text file with line numbers and pagination. Use this instead of cat/head/tail \
            in shell. Output format: 'LINE_NUM|CONTENT'. Use offset and limit for large files. \
            Reads exceeding ~100K characters are truncated on a line boundary and return a \
            next_offset; continue with offset to read the rest. Readable roots: Adam's vault \
            (~/Documents/Main), ~/Developer/GitHub, and ~/.hermes (read-only). Secrets \
            (.env, auth.json) are never readable.
            """,
            inputSchema: [
                "type": "object",
                "properties": [
                    "path": [
                        "type": "string",
                        "description": "Path to the file to read (absolute or ~/path)",
                    ],
                    "offset": [
                        "type": "integer",
                        "description": "Line number to start reading from (1-indexed, default: 1)",
                    ],
                    "limit": [
                        "type": "integer",
                        "description": "Maximum number of lines to read (default: 500, max: 2000)",
                    ],
                ],
                "required": ["path"],
            ]
        ),
        ToolSpec(
            name: "search_files",
            description: """
            Search file contents or find files by name. Use this instead of grep/rg/find/ls in shell.

            Content search (target='content'): Regex search inside files. Returns matching lines \
            with line numbers.

            File search (target='files'): Find files by glob pattern (e.g., '*.md', '*config*'). \
            Also use this instead of ls — results sorted by modification time.

            Searchable roots: Adam's vault (~/Documents/Main), ~/Developer/GitHub, and ~/.hermes \
            (read-only). Secrets (.env, auth.json) are never searchable.
            """,
            inputSchema: [
                "type": "object",
                "properties": [
                    "pattern": [
                        "type": "string",
                        "description": "Regex pattern for content search, or glob pattern (e.g., '*.md') for file search",
                    ],
                    "target": [
                        "type": "string",
                        "enum": ["content", "files"],
                        "description": "'content' searches inside file contents, 'files' searches for files by name",
                    ],
                    "path": [
                        "type": "string",
                        "description": "Directory or file to search in (must be inside a readable root)",
                    ],
                    "file_glob": [
                        "type": "string",
                        "description": "Filter files by pattern in content mode (e.g., '*.md')",
                    ],
                    "limit": [
                        "type": "integer",
                        "description": "Maximum number of results to return (default: 50)",
                    ],
                ],
                "required": ["pattern", "path"],
            ]
        ),
        ToolSpec(
            name: "write_file",
            description: """
            Write content to a file, completely replacing existing content. Use this instead of \
            echo/cat heredoc in shell. Creates parent directories automatically. OVERWRITES the \
            entire file.

            THE LAW: every write is a proposal. The call suspends and renders an approve/deny \
            card for Adam before anything touches disk — the bouncer checks, Adam decides. \
            Writable roots: ~/Documents/Main and ~/Documents/Harness only.
            """,
            inputSchema: [
                "type": "object",
                "properties": [
                    "path": [
                        "type": "string",
                        "description": "Path to the file to write (created if it doesn't exist, overwritten if it does)",
                    ],
                    "content": [
                        "type": "string",
                        "description": "Complete content to write to the file",
                    ],
                ],
                "required": ["path", "content"],
            ]
        ),
        ToolSpec(
            name: "memory",
            description: """
            Propose durable facts for persistent memory that survive across sessions. Memory is \
            injected into every future session, so keep entries compact and high-signal.

            THE LAW: nothing is written directly. Every proposal is staged as a candidate in \
            Adam's review queue — agents propose, the bouncer checks, Adam decides. An entry \
            only becomes memory after Adam approves it.

            WHEN: propose proactively when Adam states a preference, correction, or personal \
            detail, or you learn a stable fact about his environment, conventions, or workflow. \
            Priority: preferences & corrections > environment facts > procedures. The best \
            memory stops Adam repeating himself.

            SKIP: trivial/obvious info, easily re-discovered facts, raw data dumps, task \
            progress, completed-work logs, temporary TODO state (use session_search for those). \
            Reusable procedures belong in a skill, not memory.
            """,
            inputSchema: [
                "type": "object",
                "properties": [
                    "content": [
                        "type": "string",
                        "description": "The proposed memory entry, in Adam's own words wherever he supplied them.",
                    ],
                    "evidence": [
                        "type": "string",
                        "description": "What Adam said or did that supports this entry (quote or cite it).",
                    ],
                    "source": [
                        "type": "string",
                        "description": "Where the evidence came from (session id, file, message).",
                    ],
                ],
                "required": ["content"],
            ]
        ),
        ToolSpec(
            name: "skills_list",
            description: "List available skills (name + description). Use skill_view(name) to load full content.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "category": [
                        "type": "string",
                        "description": "Optional category filter to narrow results",
                    ],
                ],
                "required": [],
            ]
        ),
        ToolSpec(
            name: "skill_view",
            description: """
            Skills allow for loading information about specific tasks and workflows, as well as \
            scripts and templates. Load a skill's full content. Skill text is Adam's exact words — \
            follow it verbatim, never paraphrase it.
            """,
            inputSchema: [
                "type": "object",
                "properties": [
                    "name": [
                        "type": "string",
                        "description": "The skill name (use skills_list to see available skills).",
                    ],
                ],
                "required": ["name"],
            ]
        ),
        ToolSpec(
            name: "session_search",
            description: """
            Search past sessions stored in the local session DB. FTS5-backed retrieval over the \
            SQLite message store. No LLM calls — every result is an actual message from the DB. \
            This tool searches Harness conversation history only; it is not evidence about the \
            current contents of external sources. Do not conclude 'not found' from \
            session_search alone when a direct source was provided.
            """,
            inputSchema: [
                "type": "object",
                "properties": [
                    "query": [
                        "type": "string",
                        "description": "Full-text search query",
                    ],
                    "limit": [
                        "type": "integer",
                        "description": "Maximum number of hits (default: 20)",
                    ],
                ],
                "required": ["query"],
            ]
        ),
    ]
}
