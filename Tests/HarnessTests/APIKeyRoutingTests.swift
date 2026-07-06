#if os(macOS)
import Foundation
import OntologyKit
import Testing
@testable import Harness

// WO-2 acceptance (harness-usability-recovery-plan.md): a backend never
// receives another backend's key, and saved keys load without typing.

@Test func eachBackendLoadsOnlyItsOwnKeychainKey() {
    let keychain: [Backend: String] = [
        .codex: "sk-openai-test",
        .grok: "xai-test",
        .claude: "sk-ant-test"
    ]
    for backend in Backend.allCases {
        let key = MacWorkbenchModel.initialAPIKey(
            for: backend,
            environment: [:],
            keychainKey: { keychain[$0] }
        )
        let expected = backend == .codex ? "" : (keychain[backend] ?? "")
        #expect(key == expected, "\(backend.rawValue) must load only the credential path it actually uses.")
    }
}

@Test func codexNeverLoadsOpenAIAPIKey() {
    let key = MacWorkbenchModel.initialAPIKey(
        for: .codex,
        environment: ["OPENAI_API_KEY": "sk-openai-env"],
        keychainKey: { _ in "sk-openai-keychain" }
    )
    #expect(key.isEmpty)
}

@Test func environmentVariableOverridesKeychainPerBackend() {
    let claudeKey = MacWorkbenchModel.initialAPIKey(
        for: .claude,
        environment: ["OPENAI_API_KEY": "sk-openai-env"],
        keychainKey: { _ in "sk-ant-keychain" }
    )
    #expect(claudeKey == "sk-ant-keychain", "Claude must not read OpenAI's environment variable.")
}

@Test func hermesNeverLoadsAnyKey() {
    let key = MacWorkbenchModel.initialAPIKey(
        for: .hermes,
        environment: [
            "OPENAI_API_KEY": "sk-openai",
            "XAI_API_KEY": "xai",
            "ANTHROPIC_API_KEY": "sk-ant"
        ],
        keychainKey: { _ in "should-never-be-read" }
    )
    #expect(key.isEmpty)
}
#endif
