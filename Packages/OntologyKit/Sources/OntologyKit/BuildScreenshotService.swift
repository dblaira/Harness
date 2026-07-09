import Foundation

// This whole file is macOS-only: it shells out to xcodebuild/simctl
// (via AgentRunner.shell(), itself #if os(macOS)) and uses Host, which
// doesn't exist on iOS. The only caller (MacWorkbenchModel) is already
// macOS-gated, so nothing on the iOS side needs this type to exist.
#if os(macOS)

/// WO-Q (PLAN-blueprint-cockpit-v1.md): the smallest honest build-loop
/// spike. One builder (this app, targeting the iOS Simulator), one
/// screen (a single screenshot), no parallelism -- proving the loop is
/// real before anything more ambitious gets built on top of it. Per-
/// sentence videos, the breaker agent, parallel builders, and
/// fastlane/TestFlight are each their own project, sequenced after
/// this spike, not part of it.
public struct BuildScreenshotService: Sendable {
    /// Matches AgentRunner.shell()'s parameter order so the production
    /// default below is a direct pass-through -- CLAUDE.md hard rule 2:
    /// every shell-out goes through AgentRunner.shell(), no new raw
    /// Process code. This closure exists only so tests can inject a
    /// fake and exercise the pass/fail gating logic without invoking a
    /// real multi-minute xcodebuild.
    public typealias ShellExecutor = @Sendable (
        _ launchPath: String,
        _ args: [String],
        _ timeout: TimeInterval,
        _ environment: [String: String]
    ) throws -> String

    private let shellExecutor: ShellExecutor
    private let fileManager: FileManager
    private let simulatorName: String
    private let scheme: String
    private let deviceName: String

    /// Production entry point -- always AgentRunner().shell(), the one
    /// sanctioned shell-out path (CLAUDE.md hard rule 2). Not a default
    /// parameter VALUE (that would require `shell()` itself to be public,
    /// widening its access far beyond what this one caller needs); this
    /// runs inside the init body instead, so `shell()` stays internal.
    public init(
        fileManager: FileManager = .default,
        simulatorName: String = "iPhone 17",
        scheme: String = "Harness",
        deviceName: String = Host.current().localizedName ?? "Mac"
    ) {
        self.init(
            shellExecutor: { launchPath, args, timeout, environment in
                try AgentRunner().shell(launchPath, args, timeout: timeout, environment: environment)
            },
            fileManager: fileManager,
            simulatorName: simulatorName,
            scheme: scheme,
            deviceName: deviceName
        )
    }

    /// Test entry point -- inject a fake shellExecutor to exercise the
    /// pass/fail gating logic without invoking a real xcodebuild/simctl.
    public init(
        shellExecutor: @escaping ShellExecutor,
        fileManager: FileManager = .default,
        simulatorName: String = "iPhone 17",
        scheme: String = "Harness",
        deviceName: String = Host.current().localizedName ?? "Mac"
    ) {
        self.shellExecutor = shellExecutor
        self.fileManager = fileManager
        self.simulatorName = simulatorName
        self.scheme = scheme
        self.deviceName = deviceName
    }

    /// Synchronous and potentially long-running (xcodebuild build can
    /// take minutes) -- callers must run this off the main thread, e.g.
    /// `Task.detached(priority: .userInitiated) { service.run(...) }`,
    /// mirroring ToolExecutor.swift's convention for shell()-backed work.
    /// `projectDirectory` overrides auto-detection -- tests pass one so
    /// they don't depend on Harness.xcodeproj existing on the test
    /// machine; production callers leave it nil.
    public func run(outputDirectory: URL, projectDirectory: URL? = nil) -> HarnessRunDetail {
        let runID = UUID().uuidString
        let start = Date()
        var traceEvents = [
            TraceEvent(
                runId: runID,
                stage: .createRun,
                message: "Build-and-screenshot spike started: \(scheme) -> \(simulatorName).",
                createdAt: start
            )
        ]

        guard let projectDirectory = projectDirectory ?? Self.locateProjectDirectory() else {
            let evalResult = EvalResult(
                runId: runID,
                checkName: "build-and-screenshot",
                passed: false,
                detail: "Couldn't find Harness.xcodeproj in any repository-root candidate. Set HARNESS_REPO_ROOT to the repo checkout.",
                artifactPath: nil
            )
            traceEvents.append(TraceEvent(runId: runID, stage: .traceSaved, message: evalResult.detail, createdAt: Date()))
            return Self.detail(runID: runID, start: start, end: Date(), evalResult: evalResult, traceEvents: traceEvents, deviceName: deviceName)
        }

        // WO-B dependency: export ONTOLOGY_ACCEPTED_DIR to the nested
        // "Sync Canonical Ontology" pre-build script phase so a fresh
        // machine without the iCloud folder still builds (warn-and-
        // continue, not the old hard fail).
        var shellEnvironment: [String: String] = [:]
        if let acceptedDir = ProcessInfo.processInfo.environment["ONTOLOGY_ACCEPTED_DIR"] {
            shellEnvironment["ONTOLOGY_ACCEPTED_DIR"] = acceptedDir
        }

        let projectPath = projectDirectory.appendingPathComponent("Harness.xcodeproj").path
        let buildOutputTail: String
        do {
            let output = try shellExecutor(
                "/usr/bin/xcodebuild",
                [
                    "-project", projectPath,
                    "-scheme", scheme,
                    "-destination", "platform=iOS Simulator,name=\(simulatorName)",
                    "build"
                ],
                600,
                shellEnvironment
            )
            buildOutputTail = String(output.suffix(600))
            traceEvents.append(TraceEvent(runId: runID, stage: .evaluation, message: "xcodebuild build finished.", createdAt: Date()))
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            let evalResult = EvalResult(
                runId: runID,
                checkName: "build-and-screenshot",
                passed: false,
                detail: "xcodebuild build failed: \(message)",
                artifactPath: nil
            )
            traceEvents.append(TraceEvent(runId: runID, stage: .traceSaved, message: evalResult.detail, createdAt: Date()))
            return Self.detail(runID: runID, start: start, end: Date(), evalResult: evalResult, traceEvents: traceEvents, deviceName: deviceName)
        }

        // Idempotent best-effort boot. An already-booted simulator makes
        // `simctl boot` throw ("Unable to boot device in current state:
        // Booted") -- expected, not a failure of this step, so it's
        // deliberately swallowed with try? rather than aborting the run.
        _ = try? shellExecutor("/usr/bin/xcrun", ["simctl", "boot", simulatorName], 60, [:])

        try? fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let screenshotURL = outputDirectory.appendingPathComponent("build-screenshot-\(runID).png")
        var screenshotOutput = ""
        do {
            screenshotOutput = try shellExecutor(
                "/usr/bin/xcrun",
                ["simctl", "io", "booted", "screenshot", screenshotURL.path],
                30,
                [:]
            )
        } catch {
            screenshotOutput = "simctl screenshot failed: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
        }

        // CLAUDE.md hard rule 3: a Pass is invalid without an on-disk
        // artifact -- gated on the file actually existing, never on a
        // shell exit code alone. shell() can return normally (no throw)
        // even when xcodebuild's own process exit status was non-zero,
        // as long as it printed something to stdout (see shell()'s
        // `terminationStatus != 0 && text.isEmpty` guard) -- exit codes
        // alone are not a trustworthy pass signal for this caller.
        let exists = fileManager.fileExists(atPath: screenshotURL.path)
        let evalResult = EvalResult(
            runId: runID,
            checkName: "build-and-screenshot",
            passed: exists,
            detail: exists
                ? "Simulator screenshot captured at \(screenshotURL.path)."
                : "No screenshot file found after build+capture. Build tail: \(buildOutputTail) Screenshot output: \(screenshotOutput)",
            artifactPath: exists ? screenshotURL.path : nil
        )
        traceEvents.append(TraceEvent(runId: runID, stage: .traceSaved, message: evalResult.detail, createdAt: Date()))

        return Self.detail(runID: runID, start: start, end: Date(), evalResult: evalResult, traceEvents: traceEvents, deviceName: deviceName)
    }

    private static func detail(
        runID: String,
        start: Date,
        end: Date,
        evalResult: EvalResult,
        traceEvents: [TraceEvent],
        deviceName: String
    ) -> HarnessRunDetail {
        let prompt = "Build-and-screenshot spike"
        let run = HarnessRun(
            id: runID,
            prompt: prompt,
            backend: "Harness",
            modelName: "build-screenshot-spike-v1",
            invocationMethod: "xcodebuild+simctl",
            promptPacketHash: "sha256:n/a",
            success: evalResult.passed,
            duration: end.timeIntervalSince(start),
            tokenCount: nil,
            cost: nil,
            finalAnswer: evalResult.detail,
            deviceName: deviceName,
            createdAt: start
        )
        return HarnessRunDetail(
            run: run,
            messages: [
                HarnessMessage(runId: runID, role: .user, text: prompt, createdAt: start),
                HarnessMessage(runId: runID, role: .assistant, text: evalResult.detail, createdAt: end)
            ],
            authorityHits: [],
            memoryHits: [],
            traceEvents: traceEvents,
            evalResults: [evalResult],
            memoryCandidates: [],
            validationResults: []
        )
    }

    /// Reuses PythonSHACLConnectionValidator's HARNESS_REPO_ROOT / CWD-
    /// ancestor / common-dev-path candidate search (the same "where is my
    /// own repo" problem its python venv resolution already solves),
    /// narrowed to the candidate that actually contains Harness.xcodeproj.
    private static func locateProjectDirectory() -> URL? {
        PythonSHACLConnectionValidator.repositoryRootCandidates().first {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("Harness.xcodeproj").path)
        }
    }
}
#endif
