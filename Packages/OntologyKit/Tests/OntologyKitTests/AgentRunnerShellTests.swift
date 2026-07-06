#if os(macOS)
import Foundation
import Testing
@testable import OntologyKit

// WO-1 acceptance test (harness-usability-recovery-plan.md):
// "a unit test runs /bin/cat on a 1 MB temp file through shell() and gets
// the full 1 MB back in under 5 seconds. Today that exact scenario
// deadlocks and dies at 90 s."

@Test func shellReturnsOutputLargerThanPipeBufferWithoutDeadlock() throws {
    // 1 MB of 'a' — 16x the 64 KB pipe buffer that caused the deadlock.
    let payload = String(repeating: "a", count: 1_048_576)
    let file = FileManager.default.temporaryDirectory
        .appendingPathComponent("agent-runner-shell-test-\(UUID().uuidString).txt")
    try payload.write(to: file, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: file) }

    let start = Date()
    let output = try AgentRunner().shell("/bin/cat", [file.path], timeout: 5)
    let elapsed = Date().timeIntervalSince(start)

    #expect(output.count == payload.count, "Expected the full 1 MB back, got \(output.count) bytes.")
    #expect(elapsed < 5, "Drained 1 MB should complete well inside 5 s; took \(elapsed)s.")
}

@Test func shellTimeoutIncludesPartialOutput() throws {
    // A child that prints then sleeps past the timeout: the error must carry
    // what the child said so failures explain themselves.
    do {
        _ = try AgentRunner().shell("/bin/sh", ["-c", "echo partial-marker; sleep 30"], timeout: 1)
        #expect(Bool(false), "Expected a timeout error.")
    } catch let error as AgentRunner.RunError {
        guard case .failed(let message) = error else {
            #expect(Bool(false), "Expected .failed, got \(error)")
            return
        }
        #expect(message.contains("timed out"), "Message should name the timeout: \(message)")
        #expect(message.contains("partial-marker"), "Message should include partial output: \(message)")
    }
}

@Test func shellReportsStderrOnNonZeroExitWithEmptyStdout() throws {
    do {
        _ = try AgentRunner().shell("/bin/sh", ["-c", "echo boom-detail 1>&2; exit 3"], timeout: 5)
        #expect(Bool(false), "Expected a failure error.")
    } catch let error as AgentRunner.RunError {
        guard case .failed(let message) = error else {
            #expect(Bool(false), "Expected .failed, got \(error)")
            return
        }
        #expect(message.contains("boom-detail"), "Error should carry stderr text: \(message)")
    }
}
#endif
