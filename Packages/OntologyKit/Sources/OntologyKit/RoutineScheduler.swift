import Foundation
#if canImport(Combine)
import Combine
#endif

// MARK: - Errors

public enum RoutineSchedulerError: LocalizedError, Equatable {
    /// The native store refused to write into ~/.hermes — that tree belongs
    /// to the Hermes agent and Harness only ever reads it.
    case hermesPathIsReadOnly(String)
    /// A headless routine run completed but the backend reported failure.
    case runFailed(String)

    public var errorDescription: String? {
        switch self {
        case .hermesPathIsReadOnly(let path):
            return "Refusing to write inside ~/.hermes (\(path)); Hermes files are read-only to Harness."
        case .runFailed(let message):
            return "Routine run failed: \(message)"
        }
    }
}

// MARK: - ISO8601 parsing (tolerant of Hermes microsecond timestamps)

enum RoutineISO8601 {
    private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let plain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let localFallback: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter
    }()

    /// Hermes persists Python `datetime.isoformat()` strings with microsecond
    /// precision ("2026-07-06T08:00:02.265087-07:00"). ISO8601DateFormatter
    /// only parses millisecond fractions, so trim before parsing.
    static func parse(_ raw: String?) -> Date? {
        guard var text = raw?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        if let range = text.range(of: #"\.\d+"#, options: .regularExpression) {
            let digits = text[range].dropFirst()
            if digits.count > 3 {
                text.replaceSubrange(range, with: "." + digits.prefix(3))
            }
        }
        if let date = fractional.date(from: text) { return date }
        if let date = plain.date(from: text) { return date }
        return localFallback.date(from: text)
    }

    static func string(from date: Date) -> String {
        plain.string(from: date)
    }
}

// MARK: - Hermes cron jobs (read-only mirror)

/// One job from ~/.hermes/cron/jobs.json, surfaced verbatim in the cockpit.
/// Harness never writes that file — pausing, editing, and deleting Hermes
/// jobs stays in Hermes.
public struct HermesCronJob: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let scheduleDisplay: String
    public let enabled: Bool
    public let state: String
    public let script: String?
    public let nextRunAt: Date?
    public let lastRunAt: Date?
    /// Verbatim last_status ("ok" / "error" / nil) — a failing job showing
    /// its failure is a feature, not noise.
    public let lastStatus: String?
    public let lastError: String?
    public let completedCount: Int

    public init(
        id: String,
        name: String,
        scheduleDisplay: String,
        enabled: Bool,
        state: String,
        script: String? = nil,
        nextRunAt: Date? = nil,
        lastRunAt: Date? = nil,
        lastStatus: String? = nil,
        lastError: String? = nil,
        completedCount: Int = 0
    ) {
        self.id = id
        self.name = name
        self.scheduleDisplay = scheduleDisplay
        self.enabled = enabled
        self.state = state
        self.script = script
        self.nextRunAt = nextRunAt
        self.lastRunAt = lastRunAt
        self.lastStatus = lastStatus
        self.lastError = lastError
        self.completedCount = completedCount
    }
}

/// Read-only parser for the Hermes cron store. There is deliberately no
/// write API on this type.
public struct HermesCronReader: Sendable {
    public let fileURL: URL

    public static var defaultURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".hermes/cron/jobs.json")
    }

    public init(fileURL: URL = HermesCronReader.defaultURL) {
        self.fileURL = fileURL
    }

    /// Missing file means "no Hermes install" — an empty list, not an error.
    public func loadJobs() throws -> [HermesCronJob] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        return try Self.parseJobs(data: data)
    }

    /// Tolerant parse of the real jobs.json shape: unknown keys are ignored,
    /// nulls are fine, and one malformed entry never sinks the list.
    static func parseJobs(data: Data) throws -> [HermesCronJob] {
        let root = try JSONSerialization.jsonObject(with: data)
        guard let dict = root as? [String: Any],
              let rawJobs = dict["jobs"] as? [[String: Any]] else {
            return []
        }
        return rawJobs.compactMap { raw in
            guard let id = raw["id"] as? String else { return nil }
            let schedule = raw["schedule"] as? [String: Any]
            let display = (raw["schedule_display"] as? String)
                ?? (schedule?["display"] as? String)
                ?? (schedule?["expr"] as? String)
                ?? (schedule?["kind"] as? String)
                ?? "unknown"
            let repeatInfo = raw["repeat"] as? [String: Any]
            return HermesCronJob(
                id: id,
                name: (raw["name"] as? String) ?? id,
                scheduleDisplay: display,
                enabled: (raw["enabled"] as? Bool) ?? true,
                state: (raw["state"] as? String) ?? "unknown",
                script: raw["script"] as? String,
                nextRunAt: RoutineISO8601.parse(raw["next_run_at"] as? String),
                lastRunAt: RoutineISO8601.parse(raw["last_run_at"] as? String),
                lastStatus: raw["last_status"] as? String,
                lastError: raw["last_error"] as? String,
                completedCount: (repeatInfo?["completed"] as? Int) ?? 0
            )
        }
    }
}

// MARK: - Native Harness routines

public enum RoutineState: String, Codable, Sendable {
    case scheduled
    case paused
    case done
}

/// v1 schedule kinds: recurring interval and oneshot. Cron expressions stay
/// on the Hermes side for now.
public struct RoutineSchedule: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case interval
        case oneshot
    }

    public var kind: Kind
    /// Interval period in minutes (interval kind only).
    public var minutes: Int?
    /// Absolute fire time (oneshot kind only).
    public var runAt: Date?

    public static func interval(minutes: Int) -> RoutineSchedule {
        RoutineSchedule(kind: .interval, minutes: max(1, minutes), runAt: nil)
    }

    public static func oneshot(at date: Date) -> RoutineSchedule {
        RoutineSchedule(kind: .oneshot, minutes: nil, runAt: date)
    }

    public var display: String {
        switch kind {
        case .interval:
            return "every \(minutes ?? 0)m"
        case .oneshot:
            guard let runAt else { return "once" }
            return "once at \(Self.displayFormatter.string(from: runAt))"
        }
    }

    private static let displayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()
}

/// One native scheduled routine, persisted in harness-routines.json.
public struct RoutineJob: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var prompt: String
    public var schedule: RoutineSchedule
    public var state: RoutineState
    public var createdAt: Date
    public var nextRunAt: Date?
    public var lastRunAt: Date?
    /// "ok" / "error" — mirrors the Hermes last_status vocabulary.
    public var lastStatus: String?
    public var lastError: String?
    public var completedCount: Int

    public init(
        id: String = UUID().uuidString,
        name: String,
        prompt: String,
        schedule: RoutineSchedule,
        state: RoutineState = .scheduled,
        createdAt: Date = Date(),
        nextRunAt: Date? = nil,
        lastRunAt: Date? = nil,
        lastStatus: String? = nil,
        lastError: String? = nil,
        completedCount: Int = 0
    ) {
        self.id = id
        self.name = name
        self.prompt = prompt
        self.schedule = schedule
        self.state = state
        self.createdAt = createdAt
        self.nextRunAt = nextRunAt
        self.lastRunAt = lastRunAt
        self.lastStatus = lastStatus
        self.lastError = lastError
        self.completedCount = completedCount
    }
}

/// What a caller (the composer, the Routines form) asks the scheduler to add.
public struct RoutineDraft: Equatable, Sendable {
    public var name: String
    public var prompt: String
    public var schedule: RoutineSchedule

    public init(name: String, prompt: String, schedule: RoutineSchedule) {
        self.name = name
        self.prompt = prompt
        self.schedule = schedule
    }
}

// MARK: - Due calculation (pure, testable)

public enum RoutineDueCalculator {
    public static func isDue(_ job: RoutineJob, now: Date) -> Bool {
        guard job.state == .scheduled, let next = job.nextRunAt else { return false }
        return next <= now
    }

    /// The anchor a job gets when it is created or resumed.
    public static func initialNextRun(for schedule: RoutineSchedule, now: Date) -> Date? {
        switch schedule.kind {
        case .interval:
            return now.addingTimeInterval(TimeInterval((schedule.minutes ?? 1) * 60))
        case .oneshot:
            return schedule.runAt
        }
    }

    /// The anchor after a firing. Missed runs collapse — intervals re-anchor
    /// from the fire time (same as Hermes), oneshots never fire again.
    public static func nextRunAfterFiring(_ schedule: RoutineSchedule, firedAt: Date) -> Date? {
        switch schedule.kind {
        case .interval:
            return firedAt.addingTimeInterval(TimeInterval((schedule.minutes ?? 1) * 60))
        case .oneshot:
            return nil
        }
    }

    /// Roll a wall-clock time forward day by day until it is in the future —
    /// a 9:00 nudge sent at 14:00 means 9:00 tomorrow, not "immediately".
    public static func rollForward(_ date: Date, now: Date, calendar: Calendar = .current) -> Date {
        var candidate = date
        var guardrail = 0
        while candidate <= now, guardrail < 370 {
            guard let next = calendar.date(byAdding: .day, value: 1, to: candidate) else { break }
            candidate = next
            guardrail += 1
        }
        return candidate
    }
}

// MARK: - Composer one-shot drafts

/// Turns the composer's Due / Nudge schedule signals into oneshot routine
/// drafts. Lives in the package so the mapping is unit-testable.
public enum ComposerRoutineDrafts {
    public static func drafts(
        userText: String,
        dueDate: Date?,
        nudgeTime: Date?,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [RoutineDraft] {
        let text = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        var drafts: [RoutineDraft] = []
        if let dueDate {
            drafts.append(RoutineDraft(
                name: "Due · \(snippet(text))",
                prompt: text,
                schedule: .oneshot(at: dueDate)
            ))
        }
        if let nudgeTime {
            let runAt = RoutineDueCalculator.rollForward(nudgeTime, now: now, calendar: calendar)
            drafts.append(RoutineDraft(
                name: "Nudge · \(snippet(text))",
                prompt: text,
                schedule: .oneshot(at: runAt)
            ))
        }
        return drafts
    }

    static func snippet(_ text: String, limit: Int = 40) -> String {
        let flattened = text
            .components(separatedBy: .newlines)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        guard flattened.count > limit else { return flattened }
        return String(flattened.prefix(limit)).trimmingCharacters(in: .whitespaces) + "…"
    }
}

// MARK: - Native store

/// Load/save for harness-routines.json. Refuses to write anywhere inside
/// ~/.hermes — that tree is Hermes's, and Harness only reads it.
public struct RoutineStore: Sendable {
    public let fileURL: URL

    public static var defaultURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Documents/Harness/harness-routines.json")
    }

    public init(fileURL: URL = RoutineStore.defaultURL) {
        self.fileURL = fileURL
    }

    private struct StoreFile: Codable {
        var jobs: [RoutineJob]
        var updatedAt: Date
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    public func load() throws -> [RoutineJob] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        return try Self.makeDecoder().decode(StoreFile.self, from: data).jobs
    }

    public func save(_ jobs: [RoutineJob]) throws {
        guard !fileURL.path.contains("/.hermes/") else {
            throw RoutineSchedulerError.hermesPathIsReadOnly(fileURL.path)
        }
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try Self.makeEncoder().encode(StoreFile(jobs: jobs, updatedAt: Date()))
        try data.write(to: fileURL, options: .atomic)
    }
}

// MARK: - Running routines headlessly

/// Executes one routine's prompt as a normal Harness run. Implementations
/// must land the run in the ledger so its output surfaces in the existing
/// review queue — routines never grow a private side channel.
public protocol RoutineRunning: Sendable {
    func run(prompt: String, routineName: String) async throws -> String
}

/// Default runner: a full HarnessRunService run against the application
/// ledger. Anything the routine's agent proposes still flows through the
/// bouncer and the review queue — a scheduled run has exactly the same
/// authority as an interactive one: none.
public struct HarnessRoutineRunner: RoutineRunning {
    public let backendResolver: @Sendable () -> (backend: Backend, apiKey: String?)
    public let ledgerProvider: @Sendable () throws -> RunLedgerStore

    public init(
        backendResolver: @escaping @Sendable () -> (backend: Backend, apiKey: String?),
        ledgerProvider: @escaping @Sendable () throws -> RunLedgerStore = { try RunLedgerStore.applicationDefault() }
    ) {
        self.backendResolver = backendResolver
        self.ledgerProvider = ledgerProvider
    }

    public func run(prompt: String, routineName: String) async throws -> String {
        let (backend, apiKey) = backendResolver()
        let ledger = try ledgerProvider()
        let service = HarnessRunService(ledger: ledger)
        let ontology = await Task.detached(priority: .utility) { OntologyLoader.load() }.value
        let adapter = AgentRunnerBackendAdapter(backend: backend, apiKey: apiKey)
        let detail = try await service.createRun(prompt: prompt, ontology: ontology, backend: adapter)
        guard detail.run.success else {
            throw RoutineSchedulerError.runFailed(detail.run.finalAnswer)
        }
        return detail.run.finalAnswer
    }
}

// MARK: - Scheduler

/// Owns both routine sources: the Hermes cron store (read-only mirror) and
/// the native harness-routines.json (editable). A 60-second timer tick fires
/// due native jobs as headless Harness runs. Mirrors the ToolApprovalStore /
/// ToolLoopMonitor idiom: lock-guarded truth, `@Published` mirrors mutated
/// on the main actor for SwiftUI.
public final class RoutineScheduler: ObservableObject, @unchecked Sendable {
    /// Installed by `start()`; the composer's schedule signals register
    /// one-shots here.
    public private(set) static var shared: RoutineScheduler?

    private let lock = NSLock()
    /// Serialises disk writes so two overlapping persists (a completing run and
    /// an edit, say) can't write their snapshots out of order and leave stale
    /// job state on disk. Held only around snapshot+save, never with `lock`.
    private let persistLock = NSLock()
    private var jobs: [RoutineJob] = []
    private var hermes: [HermesCronJob] = []
    private var inFlight: Set<String> = []
    private var timer: Timer?
    private var started = false

    private let store: RoutineStore
    private let hermesReader: HermesCronReader
    private let runner: any RoutineRunning

    /// UI-facing mirrors; always mutated on the main actor.
    @Published public private(set) var harnessJobs: [RoutineJob] = []
    @Published public private(set) var hermesJobs: [HermesCronJob] = []
    @Published public private(set) var hermesReadError: String?
    @Published public private(set) var storeError: String?

    public init(
        store: RoutineStore = RoutineStore(),
        hermesReader: HermesCronReader = HermesCronReader(),
        runner: any RoutineRunning
    ) {
        self.store = store
        self.hermesReader = hermesReader
        self.runner = runner
    }

    deinit {
        timer?.invalidate()
    }

    // MARK: Lifecycle

    /// Idempotent. Loads both stores, runs an immediate tick, then ticks
    /// every `tickInterval` seconds. Call from the main thread (the timer
    /// needs a live run loop).
    public func start(tickInterval: TimeInterval = 60) {
        lock.lock()
        if started {
            lock.unlock()
            return
        }
        started = true
        lock.unlock()

        Self.shared = self
        reload()
        Task { [weak self] in await self?.tick() }
        let timer = Timer(timeInterval: tickInterval, repeats: true) { [weak self] _ in
            Task { [weak self] in await self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        lock.lock()
        self.timer = timer
        lock.unlock()
    }

    public func stop() {
        lock.lock()
        timer?.invalidate()
        timer = nil
        started = false
        lock.unlock()
        if Self.shared === self { Self.shared = nil }
    }

    /// Reload both sources from disk.
    public func reload() {
        var loadError: String?
        var loaded: [RoutineJob] = []
        do {
            loaded = try store.load()
        } catch {
            loadError = error.localizedDescription
        }
        lock.lock()
        jobs = loaded
        lock.unlock()
        refreshHermesJobs()
        publish(storeError: loadError)
    }

    /// Re-read ~/.hermes/cron/jobs.json (read-only) so last_status stays
    /// current in the cockpit.
    public func refreshHermesJobs() {
        var readError: String?
        var loaded: [HermesCronJob] = []
        do {
            loaded = try hermesReader.loadJobs()
        } catch {
            readError = error.localizedDescription
        }
        lock.lock()
        hermes = loaded
        lock.unlock()
        publish(hermesReadError: readError)
    }

    // MARK: Snapshots (deterministic reads for tests; @Published mirrors lag)

    public func jobsSnapshot() -> [RoutineJob] {
        lock.lock()
        defer { lock.unlock() }
        return jobs
    }

    public func hermesSnapshot() -> [HermesCronJob] {
        lock.lock()
        defer { lock.unlock() }
        return hermes
    }

    // MARK: Editing (native jobs only)

    @discardableResult
    public func add(_ draft: RoutineDraft, now: Date = Date()) -> RoutineJob {
        let job = RoutineJob(
            name: draft.name,
            prompt: draft.prompt,
            schedule: draft.schedule,
            createdAt: now,
            nextRunAt: RoutineDueCalculator.initialNextRun(for: draft.schedule, now: now)
        )
        lock.lock()
        jobs.append(job)
        lock.unlock()
        persist()
        return job
    }

    public func pause(id: String) {
        mutateJob(id: id) { job in
            guard job.state == .scheduled else { return }
            job.state = .paused
        }
    }

    public func resume(id: String, now: Date = Date()) {
        mutateJob(id: id) { job in
            guard job.state == .paused else { return }
            job.state = .scheduled
            job.nextRunAt = RoutineDueCalculator.initialNextRun(for: job.schedule, now: now)
        }
    }

    public func delete(id: String) {
        lock.lock()
        jobs.removeAll { $0.id == id }
        lock.unlock()
        persist()
    }

    // MARK: Firing

    /// Fire every due native job, then refresh the Hermes mirror. Awaits the
    /// runs it starts so tests are deterministic; the timer wraps this in a
    /// Task.
    public func tick(now: Date = Date()) async {
        refreshHermesJobs()
        let due = claimDueJobs(now: now)
        for job in due {
            await fire(job, firedAt: now)
        }
    }

    /// Manual "run now" from the cockpit. Interval anchors are untouched;
    /// a oneshot run this way is consumed (fires once, then done).
    public func runNow(id: String) async {
        guard let job = claimJob(id: id, markOneshotDone: true) else { return }
        await fire(job, firedAt: Date())
    }

    /// The headless framing every scheduled run gets. Operational text, not
    /// personality — Adam's voice files are loaded verbatim elsewhere.
    public static func headlessPrompt(for job: RoutineJob, firedAt: Date = Date()) -> String {
        """
        Scheduled routine "\(job.name)" fired automatically at \(RoutineISO8601.string(from: firedAt)). \
        No user is present: do not ask clarifying questions — produce the deliverable directly and stop. \
        Anything that would spend, contact, or commit must be returned as a proposal for Adam's review queue, never executed.

        \(job.prompt)
        """
    }

    // MARK: Private

    /// Claim due jobs under the lock: advance interval anchors from the fire
    /// time (missed runs collapse), consume oneshots (fires once, then
    /// done), and mark them in-flight so overlapping ticks skip them.
    private func claimDueJobs(now: Date) -> [RoutineJob] {
        lock.lock()
        var claimed: [RoutineJob] = []
        for index in jobs.indices {
            let job = jobs[index]
            guard RoutineDueCalculator.isDue(job, now: now), !inFlight.contains(job.id) else { continue }
            claimed.append(job)
            inFlight.insert(job.id)
            jobs[index].nextRunAt = RoutineDueCalculator.nextRunAfterFiring(job.schedule, firedAt: now)
            if job.schedule.kind == .oneshot {
                jobs[index].state = .done
            }
        }
        lock.unlock()
        if !claimed.isEmpty { persist() }
        return claimed
    }

    private func claimJob(id: String, markOneshotDone: Bool) -> RoutineJob? {
        lock.lock()
        guard let index = jobs.firstIndex(where: { $0.id == id }), !inFlight.contains(id) else {
            lock.unlock()
            return nil
        }
        let job = jobs[index]
        inFlight.insert(id)
        if markOneshotDone, job.schedule.kind == .oneshot {
            jobs[index].state = .done
            jobs[index].nextRunAt = nil
        }
        lock.unlock()
        persist()
        return job
    }

    private func fire(_ job: RoutineJob, firedAt: Date) async {
        let prompt = Self.headlessPrompt(for: job, firedAt: firedAt)
        var status = "ok"
        var lastError: String?
        do {
            _ = try await runner.run(prompt: prompt, routineName: job.name)
        } catch {
            status = "error"
            lastError = error.localizedDescription
        }
        completeRun(id: job.id, status: status, error: lastError, at: Date())
    }

    private func completeRun(id: String, status: String, error: String?, at date: Date) {
        lock.lock()
        inFlight.remove(id)
        if let index = jobs.firstIndex(where: { $0.id == id }) {
            jobs[index].lastRunAt = date
            jobs[index].lastStatus = status
            jobs[index].lastError = error
            jobs[index].completedCount += 1
        }
        lock.unlock()
        persist()
    }

    private func mutateJob(id: String, _ mutate: (inout RoutineJob) -> Void) {
        lock.lock()
        if let index = jobs.firstIndex(where: { $0.id == id }) {
            mutate(&jobs[index])
        }
        lock.unlock()
        persist()
    }

    private func persist() {
        // One writer at a time. Re-snapshot inside persistLock so whichever
        // call writes last also reflects the latest jobs — no stale overwrite.
        persistLock.lock()
        defer { persistLock.unlock() }
        lock.lock()
        let snapshot = jobs
        lock.unlock()
        var saveError: String?
        do {
            try store.save(snapshot)
        } catch {
            saveError = error.localizedDescription
        }
        publish(storeError: saveError)
    }

    private func publish(hermesReadError: String?? = nil, storeError: String?? = nil) {
        lock.lock()
        let jobsSnapshot = jobs
        let hermesSnapshot = hermes
        lock.unlock()
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.harnessJobs = jobsSnapshot
            self.hermesJobs = hermesSnapshot
            if let hermesReadError { self.hermesReadError = hermesReadError }
            if let storeError { self.storeError = storeError }
        }
    }
}
