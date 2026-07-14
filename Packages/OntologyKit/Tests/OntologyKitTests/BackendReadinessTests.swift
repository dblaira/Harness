import Foundation
import Testing
@testable import OntologyKit

// Acceptance (harness-usability-recovery-plan.md, backend preflight):
// selecting a backend that can't answer shows the explanation instantly —
// with the one named action — never a 90-second spin.

@Test func claudeIsLiveWithKeyAndPendingWithout() {
    #expect(BackendReadiness.evaluate(
        backend: .claude, keyPresent: true, cliFound: false, cliProbe: nil, localServerReachable: false
    ) == .live)
    #expect(BackendReadiness.evaluate(
        backend: .claude, keyPresent: false, cliFound: false, cliProbe: nil, localServerReachable: false
    ) == .pending(action: "paste Claude API key"))
}

@Test func hermesFollowsLocalServerReachability() {
    #expect(BackendReadiness.evaluate(
        backend: .hermes, keyPresent: false, cliFound: false, cliProbe: nil, localServerReachable: true
    ) == .live)
    #expect(BackendReadiness.evaluate(
        backend: .hermes, keyPresent: false, cliFound: false, cliProbe: nil, localServerReachable: false
    ) == .pending(action: "run ollama serve"))
}

@Test func codexIgnoresAPIKeyAndRequiresCLI() {
    #expect(BackendReadiness.evaluate(
        backend: .codex, keyPresent: true, cliFound: false, cliProbe: nil, localServerReachable: false
    ) == .pending(action: "install codex CLI and run codex login --device-auth"))
}

@Test func codexWithoutCLINamesChatGPTAuthorization() {
    let readiness = BackendReadiness.evaluate(
        backend: .codex, keyPresent: false, cliFound: false, cliProbe: nil, localServerReachable: false
    )
    #expect(readiness == .pending(action: "install codex CLI and run codex login --device-auth"))
}

@Test func codexUsesChatGPTSessionProxyInvocation() {
    #expect(Backend.codex.invocationMethod == "chatgpt-session-proxy")
}

@Test func grokWithoutKeyOrCLINamesBothOptions() {
    let readiness = BackendReadiness.evaluate(
        backend: .grok, keyPresent: false, cliFound: false, cliProbe: nil, localServerReachable: false
    )
    #expect(readiness == .pending(action: "install grok CLI or paste xAI API key"))
}

@Test func grokAuthorizationActionIsNamed() {
    #expect(BackendReadiness.grokAuthorizationAction == "run grok login --oauth")
}

@Test func cliProbeFailureBecomesFailedWithMessage() {
    struct ProbeError: LocalizedError {
        var errorDescription: String? { "codex timed out after 5 seconds." }
    }
    let readiness = BackendReadiness.evaluate(
        backend: .codex, keyPresent: false, cliFound: true,
        cliProbe: .failure(ProbeError()), localServerReachable: false
    )
    #expect(readiness == .failed(message: "codex timed out after 5 seconds."))
    #expect(readiness.statusWord == "failed (codex timed out after 5 seconds.)")
}

@Test func statusWordsMatchSAVYVocabulary() {
    #expect(BackendReadiness.live.statusWord == "live")
    #expect(BackendReadiness.pending(action: "run ollama serve").statusWord == "pending")
    #expect(BackendReadiness.checking.statusWord == "Checking gateway…")
}

@Test func actionNeededOnlyForPending() {
    #expect(BackendReadiness.pending(action: "paste Claude API key").actionNeeded == "paste Claude API key")
    #expect(BackendReadiness.live.actionNeeded == nil)
    #expect(BackendReadiness.failed(message: "x").actionNeeded == nil)
    #expect(BackendReadiness.checking.actionNeeded == nil)
}

@Test func explicitConnectionCheckNamesMissingClaudeCredential() async {
    let result = await AgentRunner().checkConnection(backend: .claude, apiKey: "")
    #expect(result == .pending(action: "paste Claude API key"))
}
