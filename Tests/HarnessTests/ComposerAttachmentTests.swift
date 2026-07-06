import Foundation
import Testing
@testable import Harness

@Test func composerAttachmentDetectsYouTubeLink() {
    let attachment = ComposerAttachment.parseLinkInput("https://www.youtube.com/watch?v=dQw4w9WgXcQ")
    #expect(attachment?.linkKind == .youtube)
    #expect(attachment?.remoteURL?.contains("youtube.com") == true)
}

@Test func composerAttachmentDetectsGitHubRepoURL() {
    let attachment = ComposerAttachment.parseLinkInput("https://github.com/dblaira/Harness")
    #expect(attachment?.linkKind == .githubRepo)
    #expect(attachment?.title == "dblaira/Harness")
}

@Test func composerAttachmentDetectsGitHubRepoShorthand() {
    let attachment = ComposerAttachment.parseLinkInput("dblaira/Harness")
    #expect(attachment?.linkKind == .githubRepo)
    #expect(attachment?.remoteURL == "https://github.com/dblaira/Harness")
}

@Test func composedPromptIncludesAttachmentBlocks() {
    let prompt = ComposerAttachment.composedPrompt(
        userText: "Summarize this",
        attachments: [
            ComposerAttachment(
                kind: .link,
                title: "dblaira/Harness",
                remoteURL: "https://github.com/dblaira/Harness",
                linkKind: .githubRepo
            )
        ]
    )
    #expect(prompt.contains("Summarize this"))
    #expect(prompt.contains("ATTACHMENTS"))
    #expect(prompt.contains("GitHub Repo"))
}

@Test func photoPromptBlockDoesNotExposeLocalPath() {
    let block = ComposerAttachment(
        kind: .photo,
        title: "Untitled 10.png",
        localPath: "/Users/adamblair/Desktop/Untitled 10.png"
    ).promptBlock()
    #expect(block.contains("vision analysis"))
    #expect(!block.contains("/Users/adamblair"))
}

@Test func canSendWithAttachmentsOnly() {
    #expect(
        ComposerAttachment.canSend(
            userText: "",
            attachments: [
                ComposerAttachment(kind: .file, title: "notes.md", localPath: "/tmp/notes.md")
            ]
        )
    )
}