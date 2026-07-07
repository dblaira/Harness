import Foundation
import Testing
@testable import OntologyKit

// MARK: - Fixtures

/// Copied from the real ~/.hermes/cron/jobs.json shape (one cron job with a
/// failing last run) — the parser must survive nulls, unknown keys, and
/// Python microsecond timestamps.
private let hermesJobsFixture = """
{
  "jobs": [
    {
      "id": "e779669dc40e",
      "name": "Understood daily semantic queue",
      "prompt": "",
      "skills": [],
      "skill": null,
      "model": null,
      "provider": null,
      "provider_snapshot": null,
      "model_snapshot": null,
      "base_url": null,
      "script": "understood-daily-semantic-queue.sh",
      "no_agent": true,
      "context_from": null,
      "schedule": {
        "kind": "cron",
        "expr": "0 8 * * *",
        "display": "0 8 * * *"
      },
      "schedule_display": "0 8 * * *",
      "repeat": {
        "times": null,
        "completed": 11
      },
      "enabled": true,
      "state": "scheduled",
      "paused_at": null,
      "paused_reason": null,
      "created_at": "2026-06-25T22:26:43.272042-07:00",
      "next_run_at": "2026-07-07T08:00:00-07:00",
      "last_run_at": "2026-07-06T08:00:02.265087-07:00",
      "last_status": "error",
      "last_error": "Script exited with code 1\\nstderr:\\nGraph file not found: /Users/adamblair/Documents/Main/Ontology/Alignment/accepted-alignment-graph.ttl",
      "last_delivery_error": null,
      "deliver": "local",
      "origin": null,
      "enabled_toolsets": null,
      "workdir": null,
      "fire_claim": null
    }
  ],
  "updated_at": "2026-07-06T08:00:02.265292-07:00"
}
"""

private func makeTempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("routine-scheduler-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func writeHermesFixture(in directory: URL) throws -> URL {
    let url = directory.appendingPathComponent("hermes-jobs.json")
    try hermesJobsFixture.write(to: url, atomically: true, encoding: .utf8)
    return url
}

private final class RecordingRoutineRunner: RoutineRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [(prompt: String, routineName: String)] = []
    private var outcome: Result<String, Error> = .success("done")

    var calls: [(prompt: String, routineName: String)] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func failNextRuns(with error: Error) {
        lock.lock()
        outcome = .failure(error)
        lock.unlock()
    }

    func run(prompt: String, routineName: String) async throws -> String {
        try record(prompt: prompt, routineName: routineName).get()
    }

    private func record(prompt: String, routineName: String) -> Result<String, Error> {
        lock.lock()
        defer { lock.unlock() }
        recorded.append((prompt, routineName))
        return outcome
    }
}

private struct StubError: Error, LocalizedError {
    var errorDescription: String? { "backend unreachable" }
}

private func makeScheduler(
    in directory: URL,
    hermesURL: URL? = nil,
    runner: RecordingRoutineRunner = RecordingRoutineRunner()
) -> (RoutineScheduler, RecordingRoutineRunner, URL) {
    let storeURL = directory.appendingPathComponent("harness-routines.json")
    let scheduler = RoutineScheduler(
        store: RoutineStore(fileURL: storeURL),
        hermesReader: HermesCronReader(fileURL: hermesURL ?? directory.appendingPathComponent("missing-hermes.json")),
        runner: runner
    )
    return (scheduler, runner, storeURL)
}

// MARK: - Hermes jobs.json parsing (read-only)

@Test func hermesJobsFixtureParsesRealFormat() throws {
    let jobs = try HermesCronReader.parseJobs(data: Data(hermesJobsFixture.utf8))
    let job = try #require(jobs.first)

    #expect(jobs.count == 1)
    #expect(job.id == "e779669dc40e")
    #expect(job.name == "Understood daily semantic queue")
    #expect(job.scheduleDisplay == "0 8 * * *")
    #expect(job.enabled)
    #expect(job.state == "scheduled")
    #expect(job.script == "understood-daily-semantic-queue.sh")
    // last_status verbatim — the failing job surfaces its failure.
    #expect(job.lastStatus == "error")
    #expect(job.lastError?.contains("Script exited with code 1") == true)
    #expect(job.completedCount == 11)
    // Python microsecond timestamp parses.
    #expect(job.lastRunAt != nil)
    #expect(job.nextRunAt != nil)
}

@Test func hermesReaderMissingFileMeansNoJobsNotAnError() throws {
    let directory = try makeTempDirectory()
    let reader = HermesCronReader(fileURL: directory.appendingPathComponent("nope/jobs.json"))
    #expect(try reader.loadJobs().isEmpty)
}

@Test func hermesMicrosecondTimestampParses() {
    let date = RoutineISO8601.parse("2026-07-06T08:00:02.265087-07:00")
    #expect(date != nil)
    let plain = RoutineISO8601.parse("2026-07-07T08:00:00-07:00")
    #expect(plain != nil)
    #expect(RoutineISO8601.parse(nil) == nil)
    #expect(RoutineISO8601.parse("") == nil)
}

// MARK: - Due calculation

@Test func intervalDueCalculation() {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    let schedule = RoutineSchedule.interval(minutes: 30)
    var job = RoutineJob(
        name: "sweep",
        prompt: "Sweep the queue.",
        schedule: schedule,
        nextRunAt: RoutineDueCalculator.initialNextRun(for: schedule, now: t0)
    )

    #expect(job.nextRunAt == t0.addingTimeInterval(30 * 60))
    #expect(!RoutineDueCalculator.isDue(job, now: t0))
    #expect(!RoutineDueCalculator.isDue(job, now: t0.addingTimeInterval(29 * 60)))
    #expect(RoutineDueCalculator.isDue(job, now: t0.addingTimeInterval(30 * 60)))

    // Missed runs collapse: the next anchor comes from the fire time.
    let firedAt = t0.addingTimeInterval(95 * 60)
    job.nextRunAt = RoutineDueCalculator.nextRunAfterFiring(schedule, firedAt: firedAt)
    #expect(job.nextRunAt == firedAt.addingTimeInterval(30 * 60))

    // Paused and done jobs are never due.
    job.nextRunAt = t0
    job.state = .paused
    #expect(!RoutineDueCalculator.isDue(job, now: firedAt))
    job.state = .done
    #expect(!RoutineDueCalculator.isDue(job, now: firedAt))
}

@Test func oneshotDueCalculationAndRollForward() {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    let runAt = t0.addingTimeInterval(3600)
    let schedule = RoutineSchedule.oneshot(at: runAt)

    #expect(RoutineDueCalculator.initialNextRun(for: schedule, now: t0) == runAt)
    #expect(RoutineDueCalculator.nextRunAfterFiring(schedule, firedAt: runAt) == nil)

    // A wall-clock nudge already in the past rolls forward to the future.
    let past = t0.addingTimeInterval(-3600)
    let rolled = RoutineDueCalculator.rollForward(past, now: t0)
    #expect(rolled > t0)
    #expect(rolled.timeIntervalSince(past).truncatingRemainder(dividingBy: 86_400) == 0)
    // Future times are untouched.
    #expect(RoutineDueCalculator.rollForward(runAt, now: t0) == runAt)
}

// MARK: - Scheduler firing

@Test func oneshotFiresOnceThenMarksDone() async throws {
    let directory = try makeTempDirectory()
    let (scheduler, runner, _) = makeScheduler(in: directory)
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    scheduler.add(
        RoutineDraft(
            name: "Due · Fuseki reload",
            prompt: "Reload the Fuseki graph and report the triple count.",
            schedule: .oneshot(at: t0.addingTimeInterval(60))
        ),
        now: t0
    )

    // Not due yet.
    await scheduler.tick(now: t0)
    #expect(runner.calls.isEmpty)

    // Due: fires exactly once, with the no-user-present framing.
    await scheduler.tick(now: t0.addingTimeInterval(61))
    #expect(runner.calls.count == 1)
    let call = try #require(runner.calls.first)
    #expect(call.routineName == "Due · Fuseki reload")
    #expect(call.prompt.contains("No user is present"))
    #expect(call.prompt.contains("Reload the Fuseki graph and report the triple count."))
    #expect(call.prompt.contains("proposal for Adam's review queue"))

    let job = try #require(scheduler.jobsSnapshot().first)
    #expect(job.state == .done)
    #expect(job.nextRunAt == nil)
    #expect(job.lastStatus == "ok")
    #expect(job.completedCount == 1)

    // Done means done: later ticks never fire it again.
    await scheduler.tick(now: t0.addingTimeInterval(3600))
    #expect(runner.calls.count == 1)
}

@Test func intervalJobFiresAndReanchorsFromFireTime() async throws {
    let directory = try makeTempDirectory()
    let (scheduler, runner, _) = makeScheduler(in: directory)
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    scheduler.add(
        RoutineDraft(name: "Queue sweep", prompt: "Sweep the review queue.", schedule: .interval(minutes: 30)),
        now: t0
    )

    let fireTime = t0.addingTimeInterval(45 * 60)
    await scheduler.tick(now: fireTime)
    #expect(runner.calls.count == 1)

    let job = try #require(scheduler.jobsSnapshot().first)
    #expect(job.state == .scheduled)
    #expect(job.nextRunAt == fireTime.addingTimeInterval(30 * 60))
    #expect(job.lastStatus == "ok")
    #expect(job.completedCount == 1)

    // Not due again until the new anchor passes.
    await scheduler.tick(now: fireTime.addingTimeInterval(60))
    #expect(runner.calls.count == 1)
    await scheduler.tick(now: fireTime.addingTimeInterval(31 * 60))
    #expect(runner.calls.count == 2)
}

@Test func failedRunRecordsErrorStatusVerbatim() async throws {
    let directory = try makeTempDirectory()
    let runner = RecordingRoutineRunner()
    runner.failNextRuns(with: StubError())
    let (scheduler, _, _) = makeScheduler(in: directory, runner: runner)
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    scheduler.add(
        RoutineDraft(name: "Flaky", prompt: "Do the thing.", schedule: .interval(minutes: 10)),
        now: t0
    )
    await scheduler.tick(now: t0.addingTimeInterval(11 * 60))

    let job = try #require(scheduler.jobsSnapshot().first)
    #expect(job.lastStatus == "error")
    #expect(job.lastError?.contains("backend unreachable") == true)
    // An error does not unschedule an interval job.
    #expect(job.state == .scheduled)
}

@Test func pauseDeleteAndRunNow() async throws {
    let directory = try makeTempDirectory()
    let (scheduler, runner, _) = makeScheduler(in: directory)
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    let paused = scheduler.add(
        RoutineDraft(name: "Paused", prompt: "Skip me.", schedule: .interval(minutes: 5)),
        now: t0
    )
    scheduler.pause(id: paused.id)
    await scheduler.tick(now: t0.addingTimeInterval(3600))
    #expect(runner.calls.isEmpty)

    // Run-now fires regardless of the schedule anchor.
    let manual = scheduler.add(
        RoutineDraft(name: "Manual", prompt: "Fire on demand.", schedule: .oneshot(at: t0.addingTimeInterval(86_400))),
        now: t0
    )
    await scheduler.runNow(id: manual.id)
    #expect(runner.calls.count == 1)
    let manualJob = try #require(scheduler.jobsSnapshot().first { $0.id == manual.id })
    #expect(manualJob.state == .done)

    scheduler.delete(id: paused.id)
    scheduler.delete(id: manual.id)
    #expect(scheduler.jobsSnapshot().isEmpty)
}

@Test func jobsPersistAcrossSchedulerInstances() async throws {
    let directory = try makeTempDirectory()
    let (first, _, storeURL) = makeScheduler(in: directory)
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    let added = first.add(
        RoutineDraft(name: "Persisted", prompt: "Survive relaunch.", schedule: .interval(minutes: 60)),
        now: t0
    )

    let (second, _, _) = makeScheduler(in: directory)
    second.reload()
    let reloaded = try #require(second.jobsSnapshot().first)
    #expect(reloaded == added)
    #expect(FileManager.default.fileExists(atPath: storeURL.path))
}

// MARK: - The Hermes file is never written

@Test func hermesFileIsNeverWritten() async throws {
    let directory = try makeTempDirectory()
    let hermesURL = try writeHermesFixture(in: directory)
    let bytesBefore = try Data(contentsOf: hermesURL)
    // Belt and braces: make the fixture read-only, like a file we must not touch.
    try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: hermesURL.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: hermesURL.path) }
    let modifiedBefore = try FileManager.default.attributesOfItem(atPath: hermesURL.path)[.modificationDate] as? Date

    let (scheduler, runner, storeURL) = makeScheduler(in: directory, hermesURL: hermesURL)
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    // Exercise every mutating path: reload, add, pause, resume, tick, delete.
    scheduler.reload()
    let job = scheduler.add(
        RoutineDraft(name: "Native", prompt: "Native job.", schedule: .oneshot(at: t0)),
        now: t0.addingTimeInterval(-60)
    )
    scheduler.pause(id: job.id)
    scheduler.resume(id: job.id, now: t0.addingTimeInterval(-60))
    await scheduler.tick(now: t0.addingTimeInterval(60))
    #expect(runner.calls.count == 1)
    scheduler.delete(id: job.id)

    // The Hermes mirror was read...
    #expect(scheduler.hermesSnapshot().count == 1)
    #expect(scheduler.hermesSnapshot().first?.lastStatus == "error")

    // ...and the Hermes file is byte-for-byte untouched.
    let bytesAfter = try Data(contentsOf: hermesURL)
    let modifiedAfter = try FileManager.default.attributesOfItem(atPath: hermesURL.path)[.modificationDate] as? Date
    #expect(bytesAfter == bytesBefore)
    #expect(modifiedAfter == modifiedBefore)
    // The native store lives elsewhere.
    #expect(storeURL != hermesURL)
    #expect(FileManager.default.fileExists(atPath: storeURL.path))
}

@Test func storeRefusesToWriteInsideHermesTree() throws {
    let directory = try makeTempDirectory()
        .appendingPathComponent(".hermes/cron", isDirectory: true)
    let store = RoutineStore(fileURL: directory.appendingPathComponent("jobs.json"))
    #expect(throws: RoutineSchedulerError.hermesPathIsReadOnly(directory.appendingPathComponent("jobs.json").path)) {
        try store.save([])
    }
}

// MARK: - Composer one-shot drafts (Due / Nudge)

@Test func composerDueDateBecomesOneshotDraft() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let due = now.addingTimeInterval(86_400)
    let drafts = ComposerRoutineDrafts.drafts(
        userText: "Ship the Fuseki reload plan to the review queue.",
        dueDate: due,
        nudgeTime: nil,
        now: now
    )

    #expect(drafts.count == 1)
    #expect(drafts.first?.schedule.kind == .oneshot)
    #expect(drafts.first?.schedule.runAt == due)
    #expect(drafts.first?.name.hasPrefix("Due · ") == true)
    #expect(drafts.first?.prompt == "Ship the Fuseki reload plan to the review queue.")
}

@Test func composerNudgeInThePastRollsForward() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let staleNudge = now.addingTimeInterval(-7200)
    let drafts = ComposerRoutineDrafts.drafts(
        userText: "Check on the Gemini re-export.",
        dueDate: nil,
        nudgeTime: staleNudge,
        now: now
    )

    #expect(drafts.count == 1)
    let runAt = drafts.first?.schedule.runAt
    #expect(runAt != nil)
    #expect(runAt! > now)
    #expect(drafts.first?.name.hasPrefix("Nudge · ") == true)
}

@Test func composerDraftsRequireText() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let drafts = ComposerRoutineDrafts.drafts(
        userText: "   \n ",
        dueDate: now.addingTimeInterval(60),
        nudgeTime: now.addingTimeInterval(120),
        now: now
    )
    #expect(drafts.isEmpty)

    let both = ComposerRoutineDrafts.drafts(
        userText: "Both signals set.",
        dueDate: now.addingTimeInterval(60),
        nudgeTime: now.addingTimeInterval(120),
        now: now
    )
    #expect(both.count == 2)
}

@Test func longDraftNamesAreSnipped() {
    let text = String(repeating: "pattern ", count: 20)
    let snippet = ComposerRoutineDrafts.snippet(text)
    #expect(snippet.count <= 41) // 40 + ellipsis
    #expect(snippet.hasSuffix("…"))
}
