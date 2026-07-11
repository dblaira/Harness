import Foundation
import Testing
@testable import Harness

@Test func fascinationCarouselLoadsItsOriginalMarkdownCardsVerbatim() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("HarnessFascinationCarouselTests-\(UUID().uuidString)", isDirectory: true)
    let nested = root.appendingPathComponent("books", isDirectory: true)
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    try """
    ---
    attribution: THE MENU
    date: 2026-07-08
    ---
    You don't invent new recipes at the menu stage.
    """.write(
        to: root.appendingPathComponent("the-menu.md"),
        atomically: true,
        encoding: .utf8
    )

    try """
    ---
    attribution: NOTEBOOKLM
    date: 2026-07-09
    ---
    It never makes you remember where anything lives
    """.write(
        to: nested.appendingPathComponent("notebooklm.md"),
        atomically: true,
        encoding: .utf8
    )

    let cards = try MacWorkbenchModel.loadFascinationCards(from: root)

    #expect(cards.map(\.attribution) == ["NOTEBOOKLM", "THE MENU"])
    #expect(cards.map(\.quote) == [
        "It never makes you remember where anything lives",
        "You don't invent new recipes at the menu stage.",
    ])
}

@Test func fascinationCarouselKeepsReadableCardsWhenOneCardCannotBeRead() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("HarnessFascinationCarouselUnreadableTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let readable = root.appendingPathComponent("readable.md")
    try "Favor data not rules".write(to: readable, atomically: true, encoding: .utf8)

    let unreadable = root.appendingPathComponent("unreadable.md")
    try "This card is unavailable".write(to: unreadable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: unreadable.path)

    let cards = try MacWorkbenchModel.loadFascinationCards(from: root)

    #expect(cards.count == 1)
    #expect(cards.first?.quote == "Favor data not rules")
}

@Test func fascinationCarouselDoesNotMistakeAnUnavailableRootForNoCards() {
    let unavailable = FileManager.default.temporaryDirectory
        .appendingPathComponent("HarnessMissingFascinations-\(UUID().uuidString)", isDirectory: true)

    #expect(throws: CocoaError.self) {
        try MacWorkbenchModel.loadFascinationCards(from: unavailable)
    }
}

@Test func fascinationCarouselPreservesLastGoodStateWhenEveryCardIsUnreadable() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("HarnessUnreadableFascinations-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let unreadable = root.appendingPathComponent("unreadable.md")
    try "Existing fascination".write(to: unreadable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: unreadable.path)

    #expect(throws: CocoaError.self) {
        try MacWorkbenchModel.loadFascinationCards(from: root)
    }
}
