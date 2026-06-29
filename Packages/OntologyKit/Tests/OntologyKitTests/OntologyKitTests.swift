import Testing
@testable import OntologyKit

@Test func loadsAllConnections() async throws {
    let onto = OntologyLoader.load()
    #expect(onto.connections.count >= 19)
    #expect(onto.connections.contains { $0.id == "conn-019" })
}

@Test func conn019IsTheLeverageRule() async throws {
    let onto = OntologyLoader.load()
    let c = onto.connections.first { $0.id == "conn-019" }
    #expect(c?.label.contains("reusable systems") == true)
}

@Test func loadsAxiomsWithConfidence() async throws {
    let onto = OntologyLoader.load()
    #expect(onto.axioms.count >= 15)
    let sot = onto.axioms.first { $0.id == "system-over-task" }
    #expect(sot?.confidence == 0.9)
}

@Test func patternHasEightSteps() async throws {
    let onto = OntologyLoader.load()
    #expect(onto.pattern.count == 8)
    #expect(onto.pattern.filter { $0.zone == .observational }.count == 4)
}

@Test func softMatchFindsLeverage() async throws {
    let onto = OntologyLoader.load()
    let m = onto.match("how do you feel about leverage and reusable systems")
    #expect(m?.id == "conn-019")
}
