import Foundation
import Testing
@testable import OntologyKit

// MARK: - Fixtures

private func makeTempHome() throws -> URL {
    let home = FileManager.default.temporaryDirectory
        .appendingPathComponent("prompt-assembler-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    return home
}

@discardableResult
private func write(_ text: String, to url: URL) throws -> URL {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try text.write(to: url, atomically: true, encoding: .utf8)
    return url
}

private func occurrences(of needle: String, in haystack: String) -> Int {
    guard !needle.isEmpty else { return 0 }
    var count = 0
    var searchRange = haystack.startIndex..<haystack.endIndex
    while let found = haystack.range(of: needle, range: searchRange) {
        count += 1
        searchRange = found.upperBound..<haystack.endIndex
    }
    return count
}

// MARK: - Tier ordering and identity

@Test func assembledPromptPutsSoulFirst() throws {
    let home = try makeTempHome()
    defer { try? FileManager.default.removeItem(at: home) }

    let assembler = PromptAssembler(homeDirectory: home, environment: [:])
    let soul = SoulDocument(path: "/tmp/SOUL.md", text: "Be direct with Adam.")
    let tiers = assembler.assemble(sessionId: "soul-first", ontology: OntologyLoader.load(), soul: soul)

    #expect(tiers.stable.hasPrefix("IDENTITY ANCHOR (SOUL.md"))
    #expect(tiers.joined.hasPrefix("IDENTITY ANCHOR (SOUL.md"))
    let soulRange = try #require(tiers.stable.range(of: "Be direct with Adam."))
    let doerRange = try #require(tiers.stable.range(of: "# Finishing the job"))
    #expect(soulRange.lowerBound < doerRange.lowerBound)
}

@Test func assembledPromptContainsDoerIdentityBlock() throws {
    let home = try makeTempHome()
    defer { try? FileManager.default.removeItem(at: home) }

    let assembler = PromptAssembler(homeDirectory: home, environment: [:])
    let tiers = assembler.assemble(sessionId: "doer", ontology: OntologyLoader.load(), soul: nil)

    #expect(tiers.stable.contains("Never end your turn with a promise of future action — execute it now"))
    #expect(tiers.stable.contains("a working artifact backed by real tool output — not a description of one"))
    #expect(tiers.stable.contains("anything that spends, trades, contacts, or commits is a proposal for Adam"))
}

// MARK: - Skills index

@Test func assembledPromptContainsSkillsIndex() throws {
    let home = try makeTempHome()
    defer { try? FileManager.default.removeItem(at: home) }

    try write("""
    ---
    title: booth-fixture-skill
    type: skill
    summary: Fixture skill for the assembler test.
    ---

    # Booth Fixture Skill
    """, to: home.appendingPathComponent("Documents/Main/Skills/booth-fixture-skill.md"))

    let assembler = PromptAssembler(homeDirectory: home, environment: [:])
    let tiers = assembler.assemble(sessionId: "skills", ontology: OntologyLoader.load(), soul: nil)

    #expect(tiers.stable.contains("## Skills (mandatory)"))
    #expect(tiers.stable.contains("Err on the side of loading"))
    #expect(tiers.stable.contains("<available_skills>"))
    #expect(tiers.stable.contains("booth-fixture-skill: Fixture skill for the assembler test."))
}

@Test func skillsIndexFiltersOtherPlatformsAndPrefersVault() throws {
    let home = try makeTempHome()
    defer { try? FileManager.default.removeItem(at: home) }

    try write("""
    ---
    name: android-only-skill
    description: Should never appear on macOS.
    platforms: [android, linux]
    ---
    body
    """, to: home.appendingPathComponent(".hermes/skills/android-only-skill/SKILL.md"))
    try write("""
    ---
    name: shared-name-skill
    description: Hermes copy — replica, must lose to the vault.
    ---
    body
    """, to: home.appendingPathComponent(".hermes/skills/shared-name-skill/SKILL.md"))
    try write("""
    ---
    title: shared-name-skill
    type: skill
    summary: Vault copy — canonical, must win.
    ---
    body
    """, to: home.appendingPathComponent("Documents/Main/Skills/shared-name-skill.md"))

    let capabilities = HarnessCapabilityRegistry.defaultCapabilities(homeDirectory: home)
    let index = HarnessCapabilityRegistry.skillsIndexPrompt(capabilities: capabilities)

    #expect(!index.contains("android-only-skill"))
    #expect(index.contains("Vault copy — canonical, must win."))
    #expect(!index.contains("Hermes copy — replica, must lose to the vault."))
}

// MARK: - Response-rule skills, verbatim

@Test func responseRuleSkillFileInjectedVerbatimVaultFirst() throws {
    let home = try makeTempHome()
    defer { try? FileManager.default.removeItem(at: home) }

    let sentinel = "SENTINEL: \"When you use your own words or add words to it, it loses all its meaning.\""
    try write("""
    ---
    title: adams-words
    type: skill
    ---

    \(sentinel)
    """, to: home.appendingPathComponent("Documents/Main/Skills/adams-words.md"))

    let assembler = PromptAssembler(homeDirectory: home, environment: [:])
    let tiers = assembler.assemble(sessionId: "verbatim", ontology: OntologyLoader.load(), soul: nil)

    #expect(tiers.responseFormat.contains("loaded verbatim"))
    #expect(tiers.responseFormat.contains(sentinel))
    #expect(tiers.responseFormat.contains(home.appendingPathComponent("Documents/Main/Skills/adams-words.md").path))
}

@Test func responseRuleSkillFallsBackToDocsSkillsWhenVaultMissing() throws {
    let home = try makeTempHome()
    defer { try? FileManager.default.removeItem(at: home) }

    let sentinel = "DOCS-FALLBACK: never estimate how long anything will take Adam."
    try write(sentinel, to: home.appendingPathComponent("Developer/GitHub/Harness/Docs/skills/no-time-estimates/SKILL.md"))

    let assembler = PromptAssembler(homeDirectory: home, environment: [:])
    let loaded = try #require(assembler.loadResponseRuleSkill(named: "no-time-estimates"))
    #expect(loaded.text == sentinel)
}

// MARK: - Memory snapshot freezing

@Test func memorySnapshotFrozenWithinSessionRefreshedOnNewSession() throws {
    let home = try makeTempHome()
    defer { try? FileManager.default.removeItem(at: home) }

    let memoryFile = home.appendingPathComponent(".hermes/memories/MEMORY.md")
    try write("alpha memory fact", to: memoryFile)

    let assembler = PromptAssembler(homeDirectory: home, environment: [:])
    let ontology = OntologyLoader.load()

    let first = assembler.assemble(sessionId: "session-1", ontology: ontology, soul: nil)
    #expect(first.volatile.contains("alpha memory fact"))

    try write("beta memory fact", to: memoryFile)

    let second = assembler.assemble(sessionId: "session-1", ontology: ontology, soul: nil)
    #expect(second.volatile.contains("alpha memory fact"))
    #expect(!second.volatile.contains("beta memory fact"))
    #expect(first.volatile == second.volatile)

    let fresh = assembler.assemble(sessionId: "session-2", ontology: ontology, soul: nil)
    #expect(fresh.volatile.contains("beta memory fact"))
}

@Test func memorySnapshotLoadsVaultHubNotesWhole() throws {
    let home = try makeTempHome()
    defer { try? FileManager.default.removeItem(at: home) }

    try write("hermes memory line", to: home.appendingPathComponent(".hermes/memories/MEMORY.md"))
    try write("response rules whole file", to: home.appendingPathComponent("Documents/Main/Memory/Response Rules.md"))
    try write("vocabulary whole file", to: home.appendingPathComponent("Documents/Main/Memory/Harness Vocabulary.md"))

    let snapshot = MemorySnapshot.capture(homeDirectory: home)
    #expect(snapshot.entries.count == 3)
    #expect(snapshot.promptBlock.contains("hermes memory line"))
    #expect(snapshot.promptBlock.contains("response rules whole file"))
    #expect(snapshot.promptBlock.contains("vocabulary whole file"))
}

@Test func memorySnapshotHandlesMissingFilesGracefully() throws {
    let home = try makeTempHome()
    defer { try? FileManager.default.removeItem(at: home) }

    let snapshot = MemorySnapshot.capture(homeDirectory: home)
    #expect(snapshot.isEmpty)
    #expect(snapshot.promptBlock.isEmpty)
}

// MARK: - Cage removal and marker discipline

@Test func markerMandateAppearsAtMostOnceAndCageIsGone() throws {
    let home = try makeTempHome()
    defer { try? FileManager.default.removeItem(at: home) }

    let assembler = PromptAssembler(homeDirectory: home, environment: [:])
    let packet = PromptPacketBuilder.makePacket(
        prompt: "Implement the next coding agent feature.",
        ontology: OntologyLoader.load(),
        authorityHits: [],
        memoryHits: [],
        soul: nil,
        sessionId: "markers",
        assembler: assembler
    )

    #expect(occurrences(of: "Adam Pattern Step:", in: packet.system) <= 1)
    #expect(packet.system.contains("belong in the Supporting Evidence chapter only"))
    #expect(!packet.system.contains("Reason INSIDE"))
    #expect(!packet.system.contains("constrained by his confirmed personal ontology"))
    #expect(!packet.system.contains("When no confirmed rule applies, say so plainly"))
    #expect(packet.system.contains("When the graph is silent, help anyway and say the graph is silent."))
    #expect(packet.system.contains("This graph is Adam's confirmed truth"))
}

// MARK: - Volatile stamp

@Test func dateStampIsDateOnlyWithNoClockTime() throws {
    let home = try makeTempHome()
    defer { try? FileManager.default.removeItem(at: home) }

    var components = DateComponents()
    components.year = 2026; components.month = 7; components.day = 6
    components.hour = 14; components.minute = 37
    components.timeZone = TimeZone.current
    let date = try #require(Calendar(identifier: .gregorian).date(from: components))

    let assembler = PromptAssembler(homeDirectory: home, environment: [:])
    let tiers = assembler.assemble(sessionId: "stamp", ontology: OntologyLoader.load(), soul: nil, date: date)

    let stampLine = try #require(
        tiers.volatile
            .components(separatedBy: .newlines)
            .first { $0.hasPrefix("Conversation started:") }
    )
    #expect(stampLine == "Conversation started: Monday, July 6, 2026")
    #expect(stampLine.range(of: #"\d{1,2}:\d{2}"#, options: .regularExpression) == nil)
}

// MARK: - Packet integration

@Test func packetKeepsRetrievalHitsOutOfStableTiers() throws {
    let home = try makeTempHome()
    defer { try? FileManager.default.removeItem(at: home) }

    let assembler = PromptAssembler(homeDirectory: home, environment: [:])
    let ontology = OntologyLoader.load()
    let hit = GraphAuthorityHit(
        subject: "understood:connection/conn-019",
        predicate: "understood:label",
        object: "Reusable systems over one-time wins",
        source: "unit-test accepted graph",
        queryTrace: "unit-test",
        authorityLevel: .accepted,
        score: 1
    )

    let tiers = assembler.assemble(sessionId: "retrieval", ontology: ontology, soul: nil)
    let packet = PromptPacketBuilder.makePacket(
        prompt: "What compounds?",
        ontology: ontology,
        authorityHits: [hit],
        memoryHits: [],
        soul: nil,
        sessionId: "retrieval",
        assembler: assembler
    )

    // The assembled tiers are a byte-stable prefix; per-query hits come after.
    #expect(packet.system.hasPrefix(tiers.joined))
    #expect(!tiers.joined.contains("ACCEPTED GRAPH AUTHORITY RETRIEVED FIRST"))
    #expect(packet.system.contains("ACCEPTED GRAPH AUTHORITY RETRIEVED FIRST"))
    #expect(packet.system.contains("Reusable systems over one-time wins"))
}
