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
    private let bundleIdentifier: String
    /// Seconds of simulator screen recording attached as the video
    /// artifact. Short on purpose: the point is proof the app runs,
    /// not a screencast.
    private let videoSeconds: Int

    /// Production entry point -- always AgentRunner().shell(), the one
    /// sanctioned shell-out path (CLAUDE.md hard rule 2). Not a default
    /// parameter VALUE (that would require `shell()` itself to be public,
    /// widening its access far beyond what this one caller needs); this
    /// runs inside the init body instead, so `shell()` stays internal.
    public init(
        fileManager: FileManager = .default,
        simulatorName: String = "iPhone 17",
        scheme: String = "Harness",
        deviceName: String = Host.current().localizedName ?? "Mac",
        bundleIdentifier: String = "com.adamblair.Harness",
        // recordVideo spends ~4s spinning up before frames land, so the
        // scripted window must be comfortably larger than the recording
        // you actually want (10s window ~= 5-6s of real footage).
        videoSeconds: Int = 10
    ) {
        self.init(
            shellExecutor: { launchPath, args, timeout, environment in
                try AgentRunner().shell(launchPath, args, timeout: timeout, environment: environment)
            },
            fileManager: fileManager,
            simulatorName: simulatorName,
            scheme: scheme,
            deviceName: deviceName,
            bundleIdentifier: bundleIdentifier,
            videoSeconds: videoSeconds
        )
    }

    /// Test entry point -- inject a fake shellExecutor to exercise the
    /// pass/fail gating logic without invoking a real xcodebuild/simctl.
    public init(
        shellExecutor: @escaping ShellExecutor,
        fileManager: FileManager = .default,
        simulatorName: String = "iPhone 17",
        scheme: String = "Harness",
        deviceName: String = Host.current().localizedName ?? "Mac",
        bundleIdentifier: String = "com.adamblair.Harness",
        videoSeconds: Int = 6
    ) {
        self.shellExecutor = shellExecutor
        self.fileManager = fileManager
        self.simulatorName = simulatorName
        self.scheme = scheme
        self.deviceName = deviceName
        self.bundleIdentifier = bundleIdentifier
        self.videoSeconds = videoSeconds
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
        // A fixed -derivedDataPath (stable across runs, so builds stay
        // incremental) makes the built .app's location deterministic --
        // needed to install + launch the app so the artifacts show it
        // RUNNING, not whatever happened to be on the booted screen.
        let derivedDataURL = outputDirectory.appendingPathComponent("DerivedData", isDirectory: true)
        let appPath = derivedDataURL
            .appendingPathComponent("Build/Products/Debug-iphonesimulator/\(scheme).app").path
        let buildOutputTail: String
        do {
            let output = try shellExecutor(
                "/usr/bin/xcodebuild",
                [
                    "-project", projectPath,
                    "-scheme", scheme,
                    "-destination", "platform=iOS Simulator,name=\(simulatorName)",
                    "-derivedDataPath", derivedDataURL.path,
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

        // Install + launch the build we just made, so both artifacts
        // show THIS app running -- a screenshot of an idle home screen
        // proves a simulator exists, not that the build works. Failures
        // land in the eval detail rather than aborting: the screenshot
        // of whatever state resulted is still honest evidence.
        var launchOutput = ""
        do {
            _ = try shellExecutor("/usr/bin/xcrun", ["simctl", "install", "booted", appPath], 60, [:])
            launchOutput = try shellExecutor("/usr/bin/xcrun", ["simctl", "launch", "booted", bundleIdentifier], 60, [:])
            traceEvents.append(TraceEvent(runId: runID, stage: .evaluation, message: "App installed and launched on \(simulatorName).", createdAt: Date()))
        } catch {
            launchOutput = "install/launch failed: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
            traceEvents.append(TraceEvent(runId: runID, stage: .evaluation, message: launchOutput, createdAt: Date()))
        }

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

        // The video: one /bin/sh invocation (still through
        // AgentRunner.shell(), hard rule 2) that starts recordVideo in
        // the background, lets it run, then stops it with SIGINT so the
        // file finalizes -- recordVideo only writes a playable mp4 on a
        // graceful stop, and shell()'s own timeout path escalates to
        // SIGKILL, which would corrupt it. The mp4 path rides as "$1"
        // so tests can read it from args rather than parsing the script.
        let videoURL = outputDirectory.appendingPathComponent("build-video-\(runID).mp4")
        let recordScript = """
        /usr/bin/xcrun simctl io booted recordVideo --codec h264 --force "$1" & \
        REC=$!; sleep \(videoSeconds); kill -INT $REC 2>/dev/null; wait $REC; exit 0
        """
        var videoOutput = ""
        do {
            videoOutput = try shellExecutor(
                "/bin/sh",
                ["-c", recordScript, "sh", videoURL.path],
                TimeInterval(videoSeconds + 30),
                [:]
            )
        } catch {
            videoOutput = "recordVideo failed: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
        }

        // CLAUDE.md hard rule 3: a Pass is invalid without an on-disk
        // artifact -- gated on the file actually existing, never on a
        // shell exit code alone. shell() can return normally (no throw)
        // even when xcodebuild's own process exit status was non-zero,
        // as long as it printed something to stdout (see shell()'s
        // `terminationStatus != 0 && text.isEmpty` guard) -- exit codes
        // alone are not a trustworthy pass signal for this caller.
        let screenshotExists = fileManager.fileExists(atPath: screenshotURL.path)
        let screenshotEval = EvalResult(
            runId: runID,
            checkName: "build-and-screenshot",
            passed: screenshotExists,
            detail: screenshotExists
                ? "Simulator screenshot captured at \(screenshotURL.path)."
                : "No screenshot file found after build+capture. Build tail: \(buildOutputTail) Screenshot output: \(screenshotOutput)",
            artifactPath: screenshotExists ? screenshotURL.path : nil
        )
        traceEvents.append(TraceEvent(runId: runID, stage: .traceSaved, message: screenshotEval.detail, createdAt: Date()))

        // Same artifact-required contract for the recording. An empty
        // file (recording started but never finalized) is not evidence.
        // Missing file or unreadable size both read as 0 and fail.
        let videoSize = ((try? fileManager.attributesOfItem(atPath: videoURL.path)[.size]) as? Int) ?? 0
        let videoExists = videoSize > 0
        let videoEval = EvalResult(
            runId: runID,
            checkName: "build-and-video",
            passed: videoExists,
            detail: videoExists
                ? "Simulator screen recording (\(videoSeconds)s) captured at \(videoURL.path). Launch: \(launchOutput.trimmingCharacters(in: .whitespacesAndNewlines))"
                : "No playable video file found after recording. Launch: \(launchOutput) Record output: \(videoOutput)",
            artifactPath: videoExists ? videoURL.path : nil
        )
        traceEvents.append(TraceEvent(runId: runID, stage: .traceSaved, message: videoEval.detail, createdAt: Date()))

        return Self.detail(runID: runID, start: start, end: Date(), evalResults: [screenshotEval, videoEval], traceEvents: traceEvents, deviceName: deviceName)
    }

    private static func detail(
        runID: String,
        start: Date,
        end: Date,
        evalResult: EvalResult,
        traceEvents: [TraceEvent],
        deviceName: String
    ) -> HarnessRunDetail {
        detail(runID: runID, start: start, end: end, evalResults: [evalResult], traceEvents: traceEvents, deviceName: deviceName)
    }

    private static func detail(
        runID: String,
        start: Date,
        end: Date,
        evalResults: [EvalResult],
        traceEvents: [TraceEvent],
        deviceName: String
    ) -> HarnessRunDetail {
        let prompt = "Build-and-screenshot spike"
        let summary = evalResults.map(\.detail).joined(separator: " ")
        let run = HarnessRun(
            id: runID,
            prompt: prompt,
            backend: "Harness",
            modelName: "build-screenshot-spike-v1",
            invocationMethod: "xcodebuild+simctl",
            promptPacketHash: "sha256:n/a",
            // The run passes only if EVERY check carried its artifact --
            // a green run with a missing video would be the exact
            // looks-enforced-while-enforcing-nothing failure the plan
            // warns about.
            success: evalResults.allSatisfy(\.passed),
            duration: end.timeIntervalSince(start),
            tokenCount: nil,
            cost: nil,
            finalAnswer: summary,
            deviceName: deviceName,
            createdAt: start
        )
        return HarnessRunDetail(
            run: run,
            messages: [
                HarnessMessage(runId: runID, role: .user, text: prompt, createdAt: start),
                HarnessMessage(runId: runID, role: .assistant, text: summary, createdAt: end)
            ],
            authorityHits: [],
            memoryHits: [],
            traceEvents: traceEvents,
            evalResults: evalResults,
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
