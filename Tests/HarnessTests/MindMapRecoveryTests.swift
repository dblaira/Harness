import Foundation
import Testing
@testable import Harness

@Test func mindMapDataDoesNotMistakeAnUnavailableRootForZeroRows() {
    let unavailable = FileManager.default.temporaryDirectory
        .appendingPathComponent("HarnessMissingDelegations-\(UUID().uuidString)", isDirectory: true)

    #expect(throws: CocoaError.self) {
        try MacWorkbenchModel.loadOpportunityBoardRows(from: unavailable)
    }
}

@Test func harnessFolderAliasesResolveToTheSameRecoveryRoot() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("HarnessDocumentsAlias-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let canonical = root.appendingPathComponent("Documents/Harness", isDirectory: true)
    let alias = root.appendingPathComponent("Harness-alias", isDirectory: true)
    try FileManager.default.createDirectory(at: canonical, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: canonical)

    #expect(MacWorkbenchModel.harnessDocumentsDirectoryURLsReferToSameResource(alias, canonical))
}

@Test func mindMapPreservesLastGoodStateWhenEveryCardIsUnreadable() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("HarnessUnreadableDelegations-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let unreadable = root.appendingPathComponent("unreadable.md")
    try "Existing delegation".write(to: unreadable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: unreadable.path)

    #expect(throws: CocoaError.self) {
        try MacWorkbenchModel.loadOpportunityBoardRows(from: root)
    }
}
