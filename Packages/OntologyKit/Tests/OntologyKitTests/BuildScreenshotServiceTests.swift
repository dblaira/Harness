#if os(macOS)
import Foundation
import Testing
@testable import OntologyKit

/// BuildScreenshotService.ShellExecutor is synchronous (it mirrors
/// AgentRunner.shell()'s own throws-but-not-async signature), so test
/// closures can't `await` an actor -- this is a plain lock-protected
/// box instead.
private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value
    init(_ value: Value) { storage = value }
    var value: Value {
        get { lock.lock(); defer { lock.unlock() }; return storage }
        set { lock.lock(); defer { lock.unlock() }; storage = newValue }
    }
}

private func tempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("BuildScreenshotServiceTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// hard rule 3: "A verification Pass is invalid without an on-disk
/// artifact path." This is the one property that actually matters for
/// WO-Q -- passed must track the file's real existence, never a shell
/// exit code, since shell() can return without throwing even when
/// xcodebuild's own exit status was non-zero.
@Test func buildScreenshotPassesOnlyWhenBothArtifactsActuallyExist() async throws {
    let projectDir = try tempDirectory()
    let outputDir = try tempDirectory()

    let service = BuildScreenshotService(
        shellExecutor: { launchPath, args, _, _ in
            if args.contains("screenshot") {
                // Simulate simctl actually writing the file, the way the
                // real CLI does as a side effect of a "successful" call.
                if let pathArg = args.last {
                    try "fake-png-bytes".write(toFile: pathArg, atomically: true, encoding: .utf8)
                }
                return ""
            }
            // The record script carries the mp4 path as "$1" = args.last,
            // exactly so this fake (and any future one) never has to
            // parse the shell script text.
            if args.contains(where: { $0.contains("recordVideo") }) {
                if let pathArg = args.last {
                    try "fake-mp4-bytes".write(toFile: pathArg, atomically: true, encoding: .utf8)
                }
                return ""
            }
            return "xcodebuild output"
        }
    )

    let detail = service.run(outputDirectory: outputDir, projectDirectory: projectDir)

    #expect(detail.evalResults.count == 2)
    let screenshotEval = try #require(detail.evalResults.first { $0.checkName == "build-and-screenshot" })
    #expect(screenshotEval.passed == true)
    let screenshotPath = try #require(screenshotEval.artifactPath)
    #expect(FileManager.default.fileExists(atPath: screenshotPath))

    let videoEval = try #require(detail.evalResults.first { $0.checkName == "build-and-video" })
    #expect(videoEval.passed == true)
    let videoPath = try #require(videoEval.artifactPath)
    #expect(FileManager.default.fileExists(atPath: videoPath))

    #expect(detail.run.success == true)
}

/// The whole-run pass is the CONJUNCTION of the checks: a run whose
/// screenshot exists but whose recording never finalized must read
/// failed, or the ledger shows green with missing evidence.
@Test func buildVideoFailureFailsTheRunEvenWhenTheScreenshotSucceeded() async throws {
    let projectDir = try tempDirectory()
    let outputDir = try tempDirectory()

    let service = BuildScreenshotService(
        shellExecutor: { _, args, _, _ in
            if args.contains("screenshot"), let pathArg = args.last {
                try "fake-png-bytes".write(toFile: pathArg, atomically: true, encoding: .utf8)
            }
            // recordVideo "succeeds" (no throw) but writes nothing --
            // the never-started / never-finalized case.
            return ""
        }
    )

    let detail = service.run(outputDirectory: outputDir, projectDirectory: projectDir)

    let screenshotEval = try #require(detail.evalResults.first { $0.checkName == "build-and-screenshot" })
    #expect(screenshotEval.passed == true)
    let videoEval = try #require(detail.evalResults.first { $0.checkName == "build-and-video" })
    #expect(videoEval.passed == false)
    #expect(videoEval.artifactPath == nil)
    #expect(detail.run.success == false)
}

/// An empty mp4 (recording started, killed before finalizing) is not
/// evidence -- zero bytes must not pass, even though the file exists.
@Test func buildVideoEmptyFileDoesNotPass() async throws {
    let projectDir = try tempDirectory()
    let outputDir = try tempDirectory()

    let service = BuildScreenshotService(
        shellExecutor: { _, args, _, _ in
            if args.contains("screenshot"), let pathArg = args.last {
                try "fake-png-bytes".write(toFile: pathArg, atomically: true, encoding: .utf8)
            }
            if args.contains(where: { $0.contains("recordVideo") }), let pathArg = args.last {
                try Data().write(to: URL(fileURLWithPath: pathArg))
            }
            return ""
        }
    )

    let detail = service.run(outputDirectory: outputDir, projectDirectory: projectDir)

    let videoEval = try #require(detail.evalResults.first { $0.checkName == "build-and-video" })
    #expect(videoEval.passed == false)
    #expect(detail.run.success == false)
}

/// The recording must stop itself gracefully INSIDE the one shell call
/// (background + sleep + SIGINT) -- never by letting shell()'s timeout
/// fire, whose escalation path ends in SIGKILL and a corrupt file.
@Test func buildVideoRecordScriptStopsItselfWithSigintNotTheShellTimeout() async throws {
    let projectDir = try tempDirectory()
    let outputDir = try tempDirectory()

    let recordScript = LockedBox<String?>(nil)
    let recordTimeout = LockedBox<TimeInterval>(0)

    let service = BuildScreenshotService(
        shellExecutor: { _, args, timeout, _ in
            if let script = args.first(where: { $0.contains("recordVideo") }) {
                recordScript.value = script
                recordTimeout.value = timeout
            }
            return ""
        },
        videoSeconds: 6
    )

    _ = service.run(outputDirectory: outputDir, projectDirectory: projectDir)

    let script = try #require(recordScript.value)
    #expect(script.contains("kill -INT"))
    // The shell timeout must comfortably outlast the scripted sleep, so
    // the graceful stop always wins the race against SIGKILL.
    #expect(recordTimeout.value > 6)
}

@Test func buildScreenshotFailsWhenScreenshotCommandExitsCleanButNoFileAppears() async throws {
    let projectDir = try tempDirectory()
    let outputDir = try tempDirectory()

    // The screenshot shell call "succeeds" (returns normally, no throw)
    // but never actually writes a file -- exactly the exit-code-lies
    // scenario hard rule 3 exists to catch.
    let service = BuildScreenshotService(
        shellExecutor: { _, _, _, _ in "" }
    )

    let detail = service.run(outputDirectory: outputDir, projectDirectory: projectDir)

    let evalResult = try #require(detail.evalResults.first)
    #expect(evalResult.passed == false)
    #expect(evalResult.artifactPath == nil)
    #expect(detail.run.success == false)
}

@Test func buildScreenshotFailsClosedWhenXcodebuildThrowsAndNeverAttemptsScreenshot() throws {
    let projectDir = try tempDirectory()
    let outputDir = try tempDirectory()

    let screenshotAttempted = LockedBox(false)

    let service = BuildScreenshotService(
        shellExecutor: { _, args, _, _ in
            if args.contains("screenshot") {
                screenshotAttempted.value = true
            }
            if args.contains("build") {
                throw AgentRunner.RunError.failed("simulated xcodebuild crash")
            }
            return ""
        }
    )

    let detail = service.run(outputDirectory: outputDir, projectDirectory: projectDir)

    let evalResult = try #require(detail.evalResults.first)
    #expect(evalResult.passed == false)
    #expect(evalResult.artifactPath == nil)
    #expect(evalResult.detail.contains("xcodebuild build failed"))
    #expect(screenshotAttempted.value == false)
}

@Test func buildScreenshotFailsClosedWhenProjectDirectoryCannotBeFound() throws {
    let outputDir = try tempDirectory()
    let service = BuildScreenshotService(shellExecutor: { _, _, _, _ in "" })

    // No projectDirectory override and no real Harness.xcodeproj at the
    // fake HARNESS_REPO_ROOT this test doesn't set -- exercised instead
    // by asserting the explicit-nil-search path never crashes and still
    // fails closed. We can't force locateProjectDirectory() to miss on a
    // machine that legitimately has the repo checked out, so this
    // documents the guard's presence via the artifact-required contract
    // instead: even the "not found" branch produces a well-formed,
    // failed EvalResult rather than a crash or a false pass.
    let detail = service.run(outputDirectory: outputDir, projectDirectory: URL(fileURLWithPath: "/nonexistent/does-not-exist-\(UUID().uuidString)"))
    let evalResult = try #require(detail.evalResults.first)
    #expect(evalResult.passed == false)
}

@Test func buildScreenshotExportsOntologyAcceptedDirToTheBuildEnvironment() throws {
    let projectDir = try tempDirectory()
    let outputDir = try tempDirectory()

    let captured = LockedBox<[String: String]?>(nil)

    setenv("ONTOLOGY_ACCEPTED_DIR", "/tmp/fake-accepted-dir", 1)
    defer { unsetenv("ONTOLOGY_ACCEPTED_DIR") }

    let service = BuildScreenshotService(
        shellExecutor: { _, args, _, environment in
            if args.contains("build") {
                captured.value = environment
            }
            return ""
        }
    )

    _ = service.run(outputDirectory: outputDir, projectDirectory: projectDir)

    #expect(captured.value?["ONTOLOGY_ACCEPTED_DIR"] == "/tmp/fake-accepted-dir")
}
#endif
