import Testing
import OntologyKit

@Test func appCanLoadOntology() async throws {
    let onto = OntologyLoader.load()
    #expect(!onto.connections.isEmpty)
    #expect(!onto.axioms.isEmpty)
    #expect(onto.pattern.count == 8)
}
