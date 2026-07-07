import Foundation
import Testing
@testable import OntologyKit

@Test func soulLoaderPrefersHarnessSoulPathOverride() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: home) }

    let override = home.appendingPathComponent("override/SOUL.md")
    try FileManager.default.createDirectory(at: override.deletingLastPathComponent(), withIntermediateDirectories: true)
    try "override soul".write(to: override, atomically: true, encoding: .utf8)

    let vaultSoul = home.appendingPathComponent("Documents/Main/Memory/SOUL.md")
    try FileManager.default.createDirectory(at: vaultSoul.deletingLastPathComponent(), withIntermediateDirectories: true)
    try "vault soul".write(to: vaultSoul, atomically: true, encoding: .utf8)

    let loaded = SoulLoader.load(
        homeDirectory: home,
        environment: ["HARNESS_SOUL_PATH": override.path]
    )

    #expect(loaded?.path == override.path)
    #expect(loaded?.text == "override soul")
}

@Test func soulLoaderFallsBackToVaultMemorySoul() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: home) }

    let vaultSoul = home.appendingPathComponent("Documents/Main/Memory/SOUL.md")
    try FileManager.default.createDirectory(at: vaultSoul.deletingLastPathComponent(), withIntermediateDirectories: true)
    try "# Harness soul".write(to: vaultSoul, atomically: true, encoding: .utf8)

    let loaded = SoulLoader.load(homeDirectory: home, environment: [:])
    #expect(loaded?.path == vaultSoul.path)
    #expect(loaded?.text == "# Harness soul")
}

@Test func promptPacketInjectsSoulBeforeOntology() {
    let soul = SoulDocument(path: "/tmp/SOUL.md", text: "Be direct with Adam.")
    let ontology = OntologyLoader.load()
    let packet = PromptPacketBuilder.makePacket(
        prompt: "What should I build next?",
        ontology: ontology,
        authorityHits: [],
        memoryHits: [],
        soul: soul
    )

    #expect(packet.system.hasPrefix("IDENTITY ANCHOR (SOUL.md"))
    #expect(packet.system.contains("Be direct with Adam."))
    #expect(packet.system.contains("CONFIRMED CONNECTIONS:"))
    #expect(packet.soulPath == "/tmp/SOUL.md")
}

@Test func promptPacketAddsChatContinuityWhenHistoryPresent() {
    let ontology = OntologyLoader.load()
    let packet = PromptPacketBuilder.makePacket(
        prompt: "Follow up question",
        ontology: ontology,
        authorityHits: [],
        memoryHits: [],
        soul: nil,
        conversationHistory: [
            ConversationTurn(role: .user, text: "First question"),
            ConversationTurn(role: .assistant, text: "First answer")
        ]
    )

    #expect(packet.system.contains("CHAT CONTINUITY"))
    #expect(packet.conversationHistory.count == 2)
}

@Test func conversationHistoryCapsAtTwentyFourTurns() {
    let turns = (0..<30).map { index in
        ConversationTurn(role: index.isMultiple(of: 2) ? .user : .assistant, text: "turn \(index)")
    }
    let capped = ConversationTurn.cappedHistory(turns)
    #expect(capped.count == 24)
    #expect(capped.first?.text == "turn 6")
}