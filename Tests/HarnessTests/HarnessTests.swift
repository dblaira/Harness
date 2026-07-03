import Testing
import OntologyKit
@testable import Harness

@Test func appCanLoadOntology() async throws {
    let onto = OntologyLoader.load()
    #expect(!onto.connections.isEmpty)
    #expect(!onto.axioms.isEmpty)
    #expect(onto.pattern.count == 8)
}

@Test func compactInspectorRailListsEverySectionWithCandidatesVisible() {
    let railOrder = WorkbenchInspectorTab.compactRailOrder

    #expect(railOrder == [
        .authority,
        .route,
        .memory,
        .candidates,
        .connectors,
        .skills,
        .trace
    ])
    #expect(railOrder.contains(.candidates))
    #expect(Set(railOrder) == Set(WorkbenchInspectorTab.allCases))
}
