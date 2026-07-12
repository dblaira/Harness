import Foundation
#if canImport(Combine)
import Combine
#endif

// MARK: - Decision model

/// What the bouncer says about a proposed tool call, before Adam sees it.
public enum ToolApprovalDecision: Sendable, Equatable {
    /// Safe: run without interrupting Adam.
    case autoAllow
    /// The law: suspend the loop, render an approve/deny card, wait for Adam.
    case requiresApproval(reason: String, patternIds: [String])
    /// No recovery path (or a secrets read): refused outright, Adam is told why.
    case denied(reason: String)
}

/// How Adam resolved a pending request.
public enum ToolApprovalResolution: String, Sendable, Equatable {
    case approved
    case denied
    case cancelled
}

/// One suspended tool call waiting for Adam's decision.
public struct ToolApprovalRequest: Identifiable, Sendable, Equatable {
    public let id: String
    public let toolName: String
    /// The command / path being proposed, verbatim.
    public let summary: String
    /// Why the bouncer flagged it (pattern descriptions, joined).
    public let reason: String
    /// Stable pattern ids that fired — the allowlist keys "always allow" persists.
    public let patternIds: [String]
    /// Extra context for the card (e.g. write_file content preview).
    public let detail: String?
    public let createdAt: Date

    public init(
        id: String = UUID().uuidString,
        toolName: String,
        summary: String,
        reason: String,
        patternIds: [String] = [],
        detail: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.toolName = toolName
        self.summary = summary
        self.reason = reason
        self.patternIds = patternIds
        self.detail = detail
        self.createdAt = createdAt
    }
}

// MARK: - Dangerous patterns

/// A shell pattern the bouncer watches for. Ported from Hermes's
/// approval.py DANGEROUS_PATTERNS / HARDLINE_PATTERNS, adapted to zsh/macOS
/// (diskutil, launchctl, /dev/disk, security keychain) — Linux-only rules
/// (systemctl, telinit) dropped.
public struct DangerousShellPattern: Sendable {
    public enum Severity: Sendable, Equatable {
        /// Suspend and ask Adam. Allowlistable.
        case requiresApproval
        /// Refuse outright: destruction with no recovery path, or secrets.
        case denied
    }

    public let id: String
    public let reason: String
    public let severity: Severity
    let regex: NSRegularExpression

    init(id: String, pattern: String, reason: String, severity: Severity, caseSensitive: Bool = false) {
        self.id = id
        self.reason = reason
        self.severity = severity
        var options: NSRegularExpression.Options = [.dotMatchesLineSeparators]
        if !caseSensitive { options.insert(.caseInsensitive) }
        // Patterns are compile-time constants; a failure here is a programmer
        // error caught by the pattern-compilation test.
        // swiftlint:disable:next force_try
        self.regex = try! NSRegularExpression(pattern: pattern, options: options)
    }

    func matches(_ command: String) -> Bool {
        let range = NSRange(command.startIndex..., in: command)
        return regex.firstMatch(in: command, options: [], range: range) != nil
    }
}

extension DangerousShellPattern {
    /// Start-of-command anchor (after separators, subshell/group openers,
    /// sudo/env wrappers) so "echo reboot" and "grep shutdown log" don't fire.
    /// The separator class includes `(` `)` `{` `}` because a command position
    /// also opens after a subshell `(cmd)` or brace group `{ cmd; }` — without
    /// them, wrapping a hardline command in parentheses (which the shell tool's
    /// own workdir wrapper does automatically) slips past every anchored rule.
    fileprivate static let commandPosition =
        #"(?:^|[;&|\n`(){}]|\$\()\s*(?:sudo\s+(?:-[^\s]+\s+)*)?(?:env\s+(?:\w+=\S*\s+)*)?(?:(?:exec|nohup|time)\s+)*\s*"#

    /// Unconditional floor — no recovery path. Adapted from Hermes
    /// HARDLINE_PATTERNS with macOS spellings (diskutil, /dev/disk).
    public static let hardline: [DangerousShellPattern] = [
        .init(
            id: "hardline.rm-root",
            pattern: commandPosition + #"rm\s+(?:-[^\s]*\s+)*(?:["'](?:/(?:(?:\.\.?)?/)*\**|~|\$\{?HOME\}?)["']|/(?:(?:\.\.?)?/)*\**(?:\s|$|[)`;|&])|/ \*)"#,
            reason: "recursive delete of root filesystem",
            severity: .denied
        ),
        .init(
            id: "hardline.rm-system-dir",
            pattern: commandPosition + #"rm\s+(?:-[^\s]*\s+)*["']?/(System|Library|Applications|Users|usr|bin|sbin|etc|var|private)/?\**["']?(?:\s|$|[)`;|&])"#,
            reason: "recursive delete of system directory",
            severity: .denied
        ),
        .init(
            id: "hardline.rm-home",
            pattern: commandPosition + #"rm\s+(?:-[^\s]*\s+)*["']?(?:~|\$\{?HOME\}?)(?:/?|/\*)["']?(?:\s|$|[)`;|&])"#,
            reason: "recursive delete of home directory",
            severity: .denied
        ),
        .init(id: "hardline.mkfs", pattern: #"\bmkfs(\.[a-z0-9]+)?\b"#, reason: "format filesystem (mkfs)", severity: .denied),
        .init(
            id: "hardline.dd-block-device",
            pattern: #"\bdd\b[^\n]*\bof=/dev/(disk|rdisk|sd|nvme|hd)[a-z0-9]*"#,
            reason: "dd to raw block device",
            severity: .denied
        ),
        .init(
            id: "hardline.redirect-block-device",
            pattern: #">\s*/dev/(disk|rdisk|sd|nvme|hd)[a-z0-9]*\b"#,
            reason: "redirect to raw block device",
            severity: .denied
        ),
        .init(
            id: "hardline.diskutil-erase",
            pattern: #"\bdiskutil\s+(eraseDisk|eraseVolume|partitionDisk|zeroDisk|secureErase|reformat)\b"#,
            reason: "diskutil erase/reformat (destroys a volume)",
            severity: .denied
        ),
        .init(
            id: "hardline.fork-bomb",
            pattern: #":\(\)\s*\{\s*:\s*\|\s*:\s*&\s*\}\s*;\s*:"#,
            reason: "fork bomb",
            severity: .denied
        ),
        .init(id: "hardline.kill-all", pattern: #"\bkill\s+(-[^\s]+\s+)*-1\b"#, reason: "kill all processes", severity: .denied),
        .init(
            id: "hardline.shutdown",
            pattern: commandPosition + #"(shutdown|reboot|halt)\b"#,
            reason: "system shutdown/reboot",
            severity: .denied
        ),
    ]

    /// Secrets floor — never read, never echo. Harness law, not Hermes's.
    /// These match the secret token ANYWHERE in the command (no command-position
    /// anchor), so metacharacter games (`x=$(cat ~/.ssh/id_rsa)`, `a && cat
    /// .env`) can't slip a secret read past the bouncer: the path itself has to
    /// appear, and when it does the whole call is refused. Defence in depth on
    /// top of env-scrubbing (the app's own API keys are stripped from the shell
    /// child's environment, so `echo $XAI_API_KEY` / `env` come back empty).
    public static let secrets: [DangerousShellPattern] = [
        .init(
            id: "secrets.dotenv",
            pattern: #"\.env(\.[\w-]+)?\b"#,
            reason: "environment/secret files (.env) are off-limits to agents",
            severity: .denied
        ),
        .init(
            id: "secrets.auth-json",
            pattern: #"\bauth\.json\b"#,
            reason: "auth.json holds credentials and is off-limits to agents",
            severity: .denied
        ),
        .init(
            id: "secrets.ssh-private-key",
            pattern: #"(\.ssh/|\bid_(rsa|ed25519|ecdsa|dsa)\b|\bidentity\b|\.pem\b|\.p12\b|\.pfx\b)"#,
            reason: "SSH/private keys are off-limits to agents",
            severity: .denied
        ),
        .init(
            id: "secrets.cloud-credentials",
            pattern: #"(\.aws/credentials|\.config/gcloud|\.kube/config|\.docker/config\.json|\.config/gh/hosts)"#,
            reason: "cloud/service credential files are off-limits to agents",
            severity: .denied
        ),
        .init(
            id: "secrets.dotfiles",
            pattern: #"\.(netrc|pgpass|npmrc|pypirc)\b"#,
            reason: "credential dotfiles (.netrc, .pgpass, …) are off-limits to agents",
            severity: .denied
        ),
        .init(
            id: "secrets.keychain",
            pattern: #"\bsecurity\s+(dump-keychain|find-generic-password|find-internet-password)\b"#,
            reason: "reading keychain secrets is off-limits to agents",
            severity: .denied
        ),
    ]

    /// Approval tier — recoverable but costly, or network-mutating. Suspends
    /// the loop for Adam's decision. Ported from Hermes DANGEROUS_PATTERNS.
    public static let dangerous: [DangerousShellPattern] = [
        .init(id: "rm.root-path", pattern: #"\brm\s+(-[^\s]*\s+)*/"#, reason: "delete in root path", severity: .requiresApproval),
        .init(id: "rm.recursive", pattern: #"\brm\s+-[^\s]*r"#, reason: "recursive delete", severity: .requiresApproval),
        .init(id: "rm.recursive-long", pattern: #"\brm\s+--recursive\b"#, reason: "recursive delete (long flag)", severity: .requiresApproval),
        .init(
            id: "chmod.world-writable",
            pattern: #"\bchmod\s+(-[^\s]*\s+)*(777|666|o\+[rwx]*w|a\+[rwx]*w)\b"#,
            reason: "world/other-writable permissions",
            severity: .requiresApproval
        ),
        .init(id: "chown.root", pattern: #"\bchown\s+(-[^\s]*)?R\s+root"#, reason: "recursive chown to root", severity: .requiresApproval),
        .init(id: "dd.disk-copy", pattern: #"\bdd\s+.*if="#, reason: "disk copy", severity: .requiresApproval),
        .init(id: "sql.drop", pattern: #"\bDROP\s+(TABLE|DATABASE)\b"#, reason: "SQL DROP", severity: .requiresApproval),
        .init(
            id: "sql.delete-no-where",
            pattern: #"\bDELETE\s+FROM\b(?![^\n]*\bWHERE\b)"#,
            reason: "SQL DELETE without WHERE",
            severity: .requiresApproval
        ),
        .init(id: "sql.truncate", pattern: #"\bTRUNCATE\s+(TABLE)?\s*\w"#, reason: "SQL TRUNCATE", severity: .requiresApproval),
        .init(
            id: "write.system-config",
            pattern: #">\s*/(private/)?(etc|var)/"#,
            reason: "overwrite system config",
            severity: .requiresApproval
        ),
        .init(
            id: "write.sensitive-target",
            pattern: #"(\btee\b[^\n]*\s|>>?\s*)["']?(~|\$\{?HOME\}?)/\.(ssh|zshrc|zprofile|bashrc|bash_profile|profile|netrc|npmrc|pypirc)"#,
            reason: "overwrite shell rc / SSH / credential file",
            severity: .requiresApproval
        ),
        .init(
            id: "edit.sensitive-in-place",
            pattern: #"\b(sed\s+-[^\s]*i|sed\s+--in-place|perl\s+-[^\s]*i|ruby\s+-[^\s]*i)\b.*(~|\$\{?HOME\}?)/\.(ssh|zshrc|zprofile|bashrc|bash_profile|profile|netrc|npmrc|pypirc)"#,
            reason: "in-place edit of shell rc / SSH / credential file",
            severity: .requiresApproval
        ),
        .init(
            id: "launchctl.lifecycle",
            pattern: #"\blaunchctl\s+(stop|kickstart|bootout|unload|kill|disable|remove)\b"#,
            reason: "stop/unload a launchd service",
            severity: .requiresApproval
        ),
        .init(id: "kill.pkill9", pattern: #"\bpkill\s+-9\b"#, reason: "force kill processes", severity: .requiresApproval),
        .init(
            id: "kill.killall9",
            pattern: #"\bkillall\s+(-[^\s]*\s+)*-(9|KILL|SIGKILL)\b"#,
            reason: "force kill processes (killall -KILL)",
            severity: .requiresApproval
        ),
        .init(
            id: "shell.dash-c",
            pattern: #"\b(bash|sh|zsh|ksh)\s+-[^\s]*c(\s+|$)"#,
            reason: "shell command via -c/-lc flag",
            severity: .requiresApproval
        ),
        .init(
            id: "script.dash-e",
            pattern: #"\b(python[23]?|perl|ruby|node|osascript)\s+-[ec]\s+"#,
            reason: "script execution via -e/-c flag",
            severity: .requiresApproval
        ),
        .init(
            id: "remote.pipe-to-shell",
            pattern: #"\b(curl|wget)\b.*\|\s*(?:[/\w]*/)?(?:ba|z)?sh(?:\s|$|-c)"#,
            reason: "pipe remote content to shell",
            severity: .requiresApproval
        ),
        .init(
            id: "remote.process-substitution",
            pattern: #"\b(bash|sh|zsh|ksh)\s+<\s*<?\s*\(\s*(curl|wget)\b"#,
            reason: "execute remote script via process substitution",
            severity: .requiresApproval
        ),
        .init(
            id: "remote.command-substitution",
            pattern: #"(?:\beval\b|\bsource\b|\.)\s*(?:\$\(\s*|`\s*)(?:curl|wget)\b"#,
            reason: "execute remote content via command substitution",
            severity: .requiresApproval
        ),
        .init(
            id: "obfuscation.base64-to-shell",
            pattern: #"\b(base64|base32|base16)\s+(-d\b|--decode\b).*\|\s*(bash|sh|zsh|ksh|dash)\b"#,
            reason: "pipe decoded content to shell (possible command obfuscation)",
            severity: .requiresApproval
        ),
        .init(
            id: "obfuscation.xxd-to-shell",
            pattern: #"\bxxd\s+-r\b.*\|\s*(bash|sh|zsh|ksh|dash)\b"#,
            reason: "pipe xxd-decoded content to shell (possible command obfuscation)",
            severity: .requiresApproval
        ),
        .init(
            id: "obfuscation.tr-to-shell",
            pattern: #"\becho\b[^|]*\|\s*\btr\b[^|]*\|\s*(bash|sh|zsh|ksh|dash)\b"#,
            reason: "pipe tr-transformed output to shell (possible command obfuscation)",
            severity: .requiresApproval
        ),
        .init(
            id: "heredoc.script",
            pattern: #"\b(python[23]?|perl|ruby|node)\s+<<"#,
            reason: "script execution via heredoc",
            severity: .requiresApproval
        ),
        .init(
            id: "heredoc.shell",
            pattern: #"\b(bash|sh|zsh|ksh)\s+<<"#,
            reason: "shell execution via heredoc",
            severity: .requiresApproval
        ),
        .init(id: "xargs.rm", pattern: #"\bxargs\s+.*\brm\b"#, reason: "xargs with rm", severity: .requiresApproval),
        .init(
            id: "find.exec-rm",
            pattern: #"\bfind\b.*-exec(dir)?\s+(/\S*/)?rm\b"#,
            reason: "find -exec/-execdir rm",
            severity: .requiresApproval
        ),
        .init(id: "find.delete", pattern: #"\bfind\b.*-delete\b"#, reason: "find -delete", severity: .requiresApproval),
        .init(
            id: "git.reset-hard",
            pattern: #"\bgit\s+reset\s+--h(a(r(d)?)?)?\b"#,
            reason: "git reset --hard (destroys uncommitted changes)",
            severity: .requiresApproval
        ),
        .init(
            id: "git.force-push",
            pattern: #"\bgit\s+push\b.*(--forc[a-z]*\b|\s-f\b)"#,
            reason: "git force push (rewrites remote history)",
            severity: .requiresApproval
        ),
        .init(
            id: "git.clean-force",
            pattern: #"\bgit\s+clean\s+-[^\s]*f"#,
            reason: "git clean with force (deletes untracked files)",
            severity: .requiresApproval
        ),
        .init(
            id: "git.branch-force-delete",
            pattern: #"\bgit\s+branch\s+-D\b"#,
            reason: "git branch force delete",
            severity: .requiresApproval,
            caseSensitive: true
        ),
        .init(
            id: "chmod.plus-x-then-run",
            pattern: #"\bchmod\s+\+x\b.*[;&|]+\s*\./"#,
            reason: "chmod +x followed by immediate execution",
            severity: .requiresApproval
        ),
        .init(
            id: "sudo.privilege-flags",
            pattern: #"\bsudo\b[^;|&\n]*?\s+(-s\b|-S\b|--st[a-z]*\b|-a\b|--a[a-z]*\b)"#,
            reason: "sudo with privilege flag (stdin/askpass/shell)",
            severity: .requiresApproval
        ),
        // Network-mutating: anything that spends, trades, contacts, or
        // commits is a proposal for Adam.
        .init(
            id: "net.curl-mutate",
            pattern: #"\bcurl\b[^\n]*\s(-X|--request)\s+["']?(?i:POST|PUT|PATCH|DELETE)\b"#,
            reason: "network-mutating HTTP request",
            severity: .requiresApproval,
            caseSensitive: true
        ),
        .init(
            id: "net.curl-data",
            pattern: #"\bcurl\b[^\n]*\s(-d\b|--data\S*\b|-F\b|--form\b|-T\b|--upload-file\b)"#,
            reason: "HTTP request that sends data",
            severity: .requiresApproval,
            caseSensitive: true
        ),
        .init(
            id: "net.wget-post",
            pattern: #"\bwget\b.*--post-(data|file)"#,
            reason: "HTTP POST via wget",
            severity: .requiresApproval
        ),
        .init(
            id: "net.git-push",
            pattern: #"\bgit\s+push\b"#,
            reason: "git push commits work to a remote — Adam decides",
            severity: .requiresApproval
        ),
        .init(
            id: "net.gh-mutate",
            pattern: #"\bgh\s+(pr|issue|release|repo|api)\s"#,
            reason: "GitHub mutation via gh CLI",
            severity: .requiresApproval
        ),
        .init(
            id: "net.publish",
            pattern: #"\b(npm|yarn|pnpm)\s+publish\b"#,
            reason: "package publish",
            severity: .requiresApproval
        ),
        .init(
            id: "net.remote-shell",
            pattern: #"\b(ssh|scp|sftp)\s"#,
            reason: "remote shell / file transfer",
            severity: .requiresApproval
        ),
        .init(
            id: "net.rsync-remote",
            pattern: #"\brsync\b.*\s[^\s]+:[^\s]"#,
            reason: "rsync to a remote host",
            severity: .requiresApproval
        ),
        .init(
            id: "net.mail",
            pattern: #"\b(mail|sendmail|msmtp)\s"#,
            reason: "sending mail contacts someone — Adam decides",
            severity: .requiresApproval
        ),
        .init(
            id: "net.osascript",
            pattern: #"\bosascript\b"#,
            reason: "osascript can message, mail, and drive apps — Adam decides",
            severity: .requiresApproval
        ),
        .init(
            id: "net.raw-socket",
            pattern: #"\b(nc|ncat|netcat|socat|telnet|tftp)\s"#,
            reason: "raw-socket / netcat-style networking is an exfiltration channel — Adam decides",
            severity: .requiresApproval
        ),
        .init(
            id: "net.ftp",
            pattern: #"\b(ftp|lftp|sftp)\s"#,
            reason: "FTP transfer sends or fetches data over the network — Adam decides",
            severity: .requiresApproval
        ),
        .init(
            id: "net.curl-upload-file",
            pattern: #"\bcurl\b[^\n]*\s(--upload-file\b|-T\b)"#,
            reason: "curl upload sends a local file over the network — Adam decides",
            severity: .requiresApproval
        ),
        // Dumping the whole environment can surface any secret the shell child
        // still holds. The app's own API keys are scrubbed before the child
        // starts, but Adam decides on a full dump regardless.
        .init(
            id: "secrets.env-dump",
            pattern: commandPosition + #"(printenv|env|set|export)(\s*$|\s+-|\s+[|;&])"#,
            reason: "dumping the full environment can expose secrets — Adam decides",
            severity: .requiresApproval
        ),
    ]
}

// MARK: - ToolApprovalStore

/// The bouncer. Classifies proposed tool calls (autoAllow / requiresApproval
/// / denied), holds suspended calls in a pending queue the chat UI renders
/// as approve/deny cards, and resolves them when Adam decides. "Agents
/// propose. The bouncer checks. You decide."
public final class ToolApprovalStore: ObservableObject, @unchecked Sendable {
    public static let allowlistDefaultsKey = "harness.tool-approval.allowlist"

    private let lock = NSLock()
    private var continuations: [String: CheckedContinuation<ToolApprovalResolution, Never>] = [:]
    private var pending: [ToolApprovalRequest] = []
    /// Monotonic publish sequence, assigned under `lock` at the same instant a
    /// snapshot is taken, so the main-actor mirror applies snapshots in the
    /// order the queue actually changed — an earlier `Task` can't land after a
    /// later one and resurrect a resolved card.
    private var publishSeq: UInt64 = 0
    private let defaults: UserDefaults

    /// Highest publish sequence already applied to `pendingRequests`. Only
    /// touched on the main actor.
    @MainActor private var appliedPublishSeq: UInt64 = 0

    /// UI-facing mirror of the pending queue; always mutated on the main
    /// actor so SwiftUI observation is safe.
    @Published public private(set) var pendingRequests: [ToolApprovalRequest] = []

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: Classification

    /// Classify a proposed tool call. `payload` is the shell command for
    /// `shell`, the destination path for `write_file`.
    public func decision(toolName: String, payload: String) -> ToolApprovalDecision {
        switch toolName {
        case "write_file":
            // ALL writes route through Adam. The allowlist never bypasses
            // this — mutations are proposals, always.
            return .requiresApproval(
                reason: "every write_file is a proposal for Adam",
                patternIds: ["write_file"]
            )
        case "shell":
            return shellDecision(command: payload)
        default:
            return .autoAllow
        }
    }

    private func shellDecision(command: String) -> ToolApprovalDecision {
        // NFKC normalization defeats unicode-spacing/homoglyph evasion;
        // control characters (other than tab/newline) are stripped.
        let scalars = command
            .precomposedStringWithCompatibilityMapping
            .unicodeScalars
            .filter { $0.value >= 0x20 || $0 == "\t" || $0 == "\n" }
        let normalized = String(String.UnicodeScalarView(scalars))

        for pattern in DangerousShellPattern.hardline where pattern.matches(normalized) {
            return .denied(reason: pattern.reason)
        }
        for pattern in DangerousShellPattern.secrets where pattern.matches(normalized) {
            return .denied(reason: pattern.reason)
        }

        let hits = DangerousShellPattern.dangerous.filter { $0.matches(normalized) }
        guard !hits.isEmpty else { return .autoAllow }

        let allowlisted = allowlistedPatternIds()
        if hits.allSatisfy({ allowlisted.contains($0.id) }) {
            return .autoAllow
        }
        return .requiresApproval(
            reason: hits.map(\.reason).joined(separator: "; "),
            patternIds: hits.map(\.id)
        )
    }

    // MARK: Pending queue

    /// Suspend the caller until Adam approves, denies, or the waiting task is
    /// cancelled. Cancellation removes the request so a stale card cannot
    /// later authorize abandoned work.
    public func awaitDecision(_ request: ToolApprovalRequest) async -> ToolApprovalResolution {
        if Task.isCancelled { return .cancelled }

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                lock.lock()
                if Task.isCancelled {
                    lock.unlock()
                    continuation.resume(returning: .cancelled)
                    return
                }
                continuations[request.id] = continuation
                pending.append(request)
                publishSeq &+= 1
                let seq = publishSeq
                let snapshot = pending
                lock.unlock()
                publish(snapshot, seq: seq)
            }
        } onCancel: {
            self.cancelPending(id: request.id)
        }
    }

    /// Adam approves. `always: true` also persists the request's pattern ids
    /// to the allowlist so the same class of command auto-flows next time
    /// (write_file is never allowlistable — see `decision`).
    public func approve(id: String, always: Bool = false) {
        guard let (request, continuation) = take(id: id) else { return }
        if always {
            addToAllowlist(patternIds: request.patternIds.filter { $0 != "write_file" })
        }
        continuation.resume(returning: .approved)
    }

    /// Adam denies. The suspended tool call returns a denial result.
    public func deny(id: String) {
        guard let (_, continuation) = take(id: id) else { return }
        continuation.resume(returning: .denied)
    }

    private func cancelPending(id: String) {
        guard let (_, continuation) = take(id: id) else { return }
        continuation.resume(returning: .cancelled)
    }

    /// Lock-guarded snapshot of the pending queue (deterministic for tests;
    /// `pendingRequests` mirrors it asynchronously on the main actor).
    public func pendingSnapshot() -> [ToolApprovalRequest] {
        lock.lock()
        defer { lock.unlock() }
        return pending
    }

    private func take(id: String) -> (ToolApprovalRequest, CheckedContinuation<ToolApprovalResolution, Never>)? {
        lock.lock()
        guard let continuation = continuations.removeValue(forKey: id),
              let index = pending.firstIndex(where: { $0.id == id }) else {
            lock.unlock()
            return nil
        }
        let request = pending.remove(at: index)
        publishSeq &+= 1
        let seq = publishSeq
        let snapshot = pending
        lock.unlock()
        publish(snapshot, seq: seq)
        return (request, continuation)
    }

    private func publish(_ snapshot: [ToolApprovalRequest], seq: UInt64) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            // Drop snapshots that a newer publish already superseded.
            guard seq > self.appliedPublishSeq else { return }
            self.appliedPublishSeq = seq
            self.pendingRequests = snapshot
        }
    }

    // MARK: Persistent allowlist

    public func allowlistedPatternIds() -> Set<String> {
        Set(defaults.stringArray(forKey: Self.allowlistDefaultsKey) ?? [])
    }

    public func addToAllowlist(patternIds: [String]) {
        guard !patternIds.isEmpty else { return }
        var current = allowlistedPatternIds()
        current.formUnion(patternIds)
        defaults.set(current.sorted(), forKey: Self.allowlistDefaultsKey)
    }

    public func removeFromAllowlist(patternId: String) {
        var current = allowlistedPatternIds()
        current.remove(patternId)
        defaults.set(current.sorted(), forKey: Self.allowlistDefaultsKey)
    }
}
