import Foundation
import Testing
@testable import OntologyKit

/// The Satisfaction Gate, seed version: Adam's real question through the full
/// live pipeline — Fuseki accepted-graph authority, supporting memory, and the
/// local Hermes model — exactly the path the app's chat uses, with no
/// interactive deadline so the complete synthesis is captured.
///
/// Ordinary deterministic CI excludes this test by name. The signed Mac
/// handoff runs it with `HARNESS_REQUIRE_LIVE_SATISFACTION=1`, making absent
/// Ollama or Fuseki a hard failure and requiring an on-disk proof artifact.
private func liveEndpointUp(_ urlString: String) async -> Bool {
    guard let url = URL(string: urlString) else { return false }
    var request = URLRequest(url: url)
    request.timeoutInterval = 3
    guard let (_, response) = try? await URLSession.shared.data(for: request) else { return false }
    guard let status = (response as? HTTPURLResponse)?.statusCode else { return false }
    return (200..<500).contains(status)
}

@Test func satisfactionGateAdamRealQuestionGetsCompleteAnswer() async throws {
    let environment = ProcessInfo.processInfo.environment
    let requireLiveProof = environment["HARNESS_REQUIRE_LIVE_SATISFACTION"] == "1"
    let ollamaAvailable = await liveEndpointUp("http://127.0.0.1:11434/api/tags")
    let fusekiAvailable = await liveEndpointUp("http://127.0.0.1:3030/$/ping")
    let dependenciesAvailable = ollamaAvailable && fusekiAvailable
    guard dependenciesAvailable else {
        if requireLiveProof {
            struct MissingLiveDependency: Error {}
            throw MissingLiveDependency()
        }
        return
    }

    let ledger = try RunLedgerStore.inMemory()
    let service = HarnessRunService(
        ledger: ledger,
        authorityRetriever: CanonicalAcceptedGraphAuthorityRetriever()
    )
    let ontology = OntologyLoader.load()
    let backend = AgentRunnerBackendAdapter(backend: .hermes, apiKey: nil)

    // Adam's own question, verbatim from the app ledger — the one that
    // repeatedly hit the response ceiling on 2026-07-11.
    let prompt = "what information do I have approved already that confirms the importance of capturing value?"

    let started = Date()
    let detail = try await service.createRun(
        prompt: prompt,
        ontology: ontology,
        backend: backend
    )
    let elapsed = Date().timeIntervalSince(started)

    let answer = detail.messages.last(where: { $0.role == .assistant })?.text
        ?? detail.run.finalAnswer
    #expect(!answer.isEmpty)
    #expect(detail.run.success)
    #expect(!answer.hasPrefix("Harness stopped "))

    let defaultOutput = "/Users/adamblair/Developer/GitHub/Harness/output/satisfaction-gate"
    let dir = URL(fileURLWithPath: environment["HARNESS_SATISFACTION_OUTPUT_DIR"] ?? defaultOutput)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let stamp = ISO8601DateFormatter().string(from: Date())
        .replacingOccurrences(of: ":", with: "-")
    let artifact = dir.appendingPathComponent("gate-\(stamp).md")
    let report = """
    # Satisfaction Gate — live full-pipeline proof

    - Question (Adam's words, verbatim): \(prompt)
    - Backend: Hermes local (Ollama), no interactive deadline
    - Authority hits from accepted graph: \(detail.authorityHits.count)
    - Supporting memory hits: \(detail.memoryHits.count)
    - Elapsed: \(String(format: "%.1f", elapsed)) seconds
    - Run id: \(detail.run.id)
    - Run success: \(detail.run.success)

    ## Answer as produced

    \(answer)
    """
    try report.write(to: artifact, atomically: true, encoding: .utf8)

    print("SATISFACTION_GATE_ARTIFACT: \(artifact.path)")
    print("ELAPSED_SECONDS: \(String(format: "%.1f", elapsed))")
    print("AUTHORITY_HITS: \(detail.authorityHits.count)")
    print("ANSWER_BEGIN")
    print(answer)
    print("ANSWER_END")
}
