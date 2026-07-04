import Foundation
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

@Test func notebookLMComposerReferenceMarksSupportingContextOnly() {
    let source = NotebookLMSourceFile(
        url: URL(fileURLWithPath: "/Users/adamblair/Documents/Harness/NotebookLM/Market Research.md"),
        rootTitle: "NotebookLM",
        modifiedAt: .distantPast
    )
    let reference = MacWorkbenchModel.notebookLMReferenceText(for: source)

    #expect(reference.contains("[NotebookLM: Market Research]"))
    #expect(reference.contains("supporting research context only"))
    #expect(reference.contains("not accepted authority"))
}

@Test func notebookLMPowerPointImportCreatesSearchableIndexNote() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("HarnessNotebookLMImportTests-\(UUID().uuidString)", isDirectory: true)
    let downloads = root.appendingPathComponent("Downloads", isDirectory: true)
    let imports = root.appendingPathComponent("NotebookLM", isDirectory: true)
    try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: imports, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let source = downloads.appendingPathComponent("NotebookLM Strategy Deck.pptx")
    try Data([0x50, 0x4B, 0x03, 0x04]).write(to: source)

    let copied = try MacWorkbenchModel.copyFileIfNeeded(source, to: imports, fileManager: .default)
    let optionalIndex = try MacWorkbenchModel.createNotebookLMIndexIfNeeded(
        for: copied,
        originalURL: source,
        fileManager: .default
    )
    let index = try #require(optionalIndex)

    #expect(copied.deletingLastPathComponent() == imports)
    #expect(copied.lastPathComponent == "NotebookLM Strategy Deck.pptx")
    #expect(index.lastPathComponent == "NotebookLM Strategy Deck.harness.md")
    let indexText = try String(contentsOf: index, encoding: .utf8)
    #expect(indexText.contains("source-class: notebooklm-export"))
    #expect(indexText.contains("file-type: pptx"))
}

@Test func workbenchContextToolsIncludeNotebookLM() {
    let tools = WorkbenchToolGroup.defaults.flatMap(\.tools)

    #expect(tools.contains { $0.title == "NotebookLM" })
}
