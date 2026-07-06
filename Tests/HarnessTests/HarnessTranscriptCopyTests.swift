import Foundation
import Testing
import OntologyKit
@testable import Harness

@Test func assistantAnswerPrefersLatestAssistantMessage() {
    let detail = HarnessRunDetail(
        run: HarnessRun(
            prompt: "Hello",
            backend: "Grok",
            modelName: "grok-build",
            invocationMethod: "grok-session-proxy",
            promptPacketHash: "abc",
            success: true,
            duration: 1,
            tokenCount: nil,
            cost: nil,
            finalAnswer: "fallback answer",
            deviceName: "Mac"
        ),
        messages: [
            HarnessMessage(runId: "run-1", role: .user, text: "Hello"),
            HarnessMessage(runId: "run-1", role: .assistant, text: "Chapter one\n\nChapter two"),
        ],
        authorityHits: [],
        memoryHits: [],
        traceEvents: [],
        evalResults: [],
        memoryCandidates: [],
        validationResults: []
    )

    #expect(HarnessTranscriptCopy.assistantAnswer(from: detail) == "Chapter one\n\nChapter two")
}

@Test func fullTranscriptIncludesPromptAndAnswer() {
    let detail = HarnessRunDetail(
        run: HarnessRun(
            prompt: "Hello",
            backend: "Grok",
            modelName: "grok-build",
            invocationMethod: "grok-session-proxy",
            promptPacketHash: "abc",
            success: true,
            duration: 1,
            tokenCount: nil,
            cost: nil,
            finalAnswer: "Done",
            deviceName: "Mac"
        ),
        messages: [
            HarnessMessage(runId: "run-1", role: .user, text: "Hello"),
            HarnessMessage(runId: "run-1", role: .assistant, text: "Done"),
        ],
        authorityHits: [],
        memoryHits: [],
        traceEvents: [],
        evalResults: [],
        memoryCandidates: [],
        validationResults: []
    )

    let transcript = HarnessTranscriptCopy.fullTranscript(from: detail)
    #expect(transcript.contains("You:\nHello"))
    #expect(transcript.contains("Harness:\nDone"))
}

@Test func statusCopyTextSkipsRoutineStatuses() {
    #expect(HarnessTranscriptCopy.statusCopyText(status: "Trace saved") == nil)
    #expect(
        HarnessTranscriptCopy.statusCopyText(status: "Backend failed: timeout after 90 seconds")
            == "Backend failed: timeout after 90 seconds"
    )
}