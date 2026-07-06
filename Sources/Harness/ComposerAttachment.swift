import Foundation
import OntologyKit

enum ComposerAttachmentKind: String, Codable, Sendable {
    case photo
    case file
    case link
}

enum ComposerLinkKind: String, Codable, Sendable {
    case generic
    case youtube
    case githubRepo
}

struct ComposerAttachment: Identifiable, Codable, Sendable, Equatable {
    let id: UUID
    let kind: ComposerAttachmentKind
    let title: String
    let localPath: String?
    let remoteURL: String?
    let linkKind: ComposerLinkKind?
    let excerpt: String?

    init(
        id: UUID = UUID(),
        kind: ComposerAttachmentKind,
        title: String,
        localPath: String? = nil,
        remoteURL: String? = nil,
        linkKind: ComposerLinkKind? = nil,
        excerpt: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.localPath = localPath
        self.remoteURL = remoteURL
        self.linkKind = linkKind
        self.excerpt = excerpt
    }

    var chipIcon: String {
        switch kind {
        case .photo: return "photo"
        case .file: return "doc"
        case .link:
            switch linkKind {
            case .youtube: return "play.rectangle"
            case .githubRepo: return "chevron.left.forwardslash.chevron.right"
            default: return "link"
            }
        }
    }

    var chipLabel: String { title }

    func promptBlock() -> String {
        switch kind {
        case .photo:
            return "[Photo: \(title)]\nThe image bytes are attached for vision analysis."
        case .file:
            var lines = ["[File: \(title)]"]
            if let localPath { lines.append("Path: \(localPath)") }
            if let excerpt, !excerpt.isEmpty {
                lines.append("Excerpt:\n\(excerpt)")
            }
            lines.append("Use as supporting context only; not accepted graph authority.")
            return lines.joined(separator: "\n")
        case .link:
            let tag: String
            switch linkKind {
            case .youtube: tag = "YouTube"
            case .githubRepo: tag = "GitHub Repo"
            default: tag = "Link"
            }
            var lines = ["[\(tag): \(title)]"]
            if let remoteURL { lines.append("URL: \(remoteURL)") }
            lines.append("Use as supporting research context only; not accepted authority unless promoted through review.")
            return lines.joined(separator: "\n")
        }
    }

    static func parseLinkInput(_ raw: String) -> ComposerAttachment? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let repo = parseGitHubRepoReference(trimmed) {
            return ComposerAttachment(
                kind: .link,
                title: repo.displayName,
                remoteURL: repo.url.absoluteString,
                linkKind: .githubRepo
            )
        }

        guard let url = normalizedURL(from: trimmed) else { return nil }
        if isYouTubeURL(url) {
            return ComposerAttachment(
                kind: .link,
                title: youtubeTitle(from: url),
                remoteURL: url.absoluteString,
                linkKind: .youtube
            )
        }
        if let repo = parseGitHubRepoURL(url) {
            return ComposerAttachment(
                kind: .link,
                title: repo.displayName,
                remoteURL: repo.url.absoluteString,
                linkKind: .githubRepo
            )
        }
        return ComposerAttachment(
            kind: .link,
            title: url.host ?? trimmed,
            remoteURL: url.absoluteString,
            linkKind: .generic
        )
    }

    static func composedPrompt(userText: String, attachments: [ComposerAttachment]) -> String {
        let trimmed = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        let blocks = attachments.map { $0.promptBlock() }.joined(separator: "\n\n")
        switch (trimmed.isEmpty, blocks.isEmpty) {
        case (true, true): return ""
        case (false, true): return trimmed
        case (true, false): return blocks
        case (false, false): return trimmed + "\n\n---\nATTACHMENTS\n" + blocks
        }
    }

    static func canSend(userText: String, attachments: [ComposerAttachment]) -> Bool {
        !userText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty
    }

    private static func normalizedURL(from raw: String) -> URL? {
        if let url = URL(string: raw), url.scheme != nil { return url }
        if let url = URL(string: "https://\(raw)"), url.host != nil { return url }
        return nil
    }

    private static func isYouTubeURL(_ url: URL) -> Bool {
        let host = (url.host ?? "").lowercased()
        return host.contains("youtube.com") || host == "youtu.be" || host == "m.youtube.com"
    }

    private static func youtubeTitle(from url: URL) -> String {
        if let item = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "v" })?
            .value,
           !item.isEmpty {
            return "YouTube video \(item)"
        }
        let slug = url.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        return slug.isEmpty ? "YouTube video" : "YouTube video \(slug)"
    }

    private struct GitHubRepoReference {
        let displayName: String
        let url: URL
    }

    private static func parseGitHubRepoReference(_ raw: String) -> GitHubRepoReference? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("://") {
            guard let url = URL(string: trimmed) else { return nil }
            return parseGitHubRepoURL(url)
        }
        let parts = trimmed
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .split(separator: "/")
            .map(String.init)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        guard let url = URL(string: "https://github.com/\(parts[0])/\(parts[1])") else { return nil }
        return GitHubRepoReference(displayName: "\(parts[0])/\(parts[1])", url: url)
    }

    private static func parseGitHubRepoURL(_ url: URL) -> GitHubRepoReference? {
        let host = (url.host ?? "").lowercased()
        guard host == "github.com" || host == "www.github.com" else { return nil }
        let parts = url.path
            .split(separator: "/")
            .map(String.init)
            .filter { !$0.isEmpty }
        guard parts.count >= 2 else { return nil }
        let owner = parts[0]
        let repo = parts[1].replacingOccurrences(of: ".git", with: "")
        guard let normalized = URL(string: "https://github.com/\(owner)/\(repo)") else { return nil }
        return GitHubRepoReference(displayName: "\(owner)/\(repo)", url: normalized)
    }
}

enum ComposerAttachmentStore {
    static let maxTextExcerptLength = 8_192

    static func attachmentsDirectory(fileManager: FileManager = .default) throws -> URL {
        let base = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = base
            .appendingPathComponent("Harness", isDirectory: true)
            .appendingPathComponent("ComposerAttachments", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func importFile(
        from sourceURL: URL,
        kind: ComposerAttachmentKind,
        fileManager: FileManager = .default
    ) throws -> ComposerAttachment {
        let directory = try attachmentsDirectory(fileManager: fileManager)
        let destination = uniqueDestinationURL(
            for: sourceURL.lastPathComponent,
            in: directory,
            fileManager: fileManager
        )
        if sourceURL.standardizedFileURL != destination.standardizedFileURL {
            try fileManager.copyItem(at: sourceURL, to: destination)
        }
        let excerpt = textExcerpt(from: destination, kind: kind)
        return ComposerAttachment(
            kind: kind,
            title: destination.lastPathComponent,
            localPath: destination.path,
            excerpt: excerpt
        )
    }

    static func visionImages(from attachments: [ComposerAttachment]) throws -> [ModelImageAttachment] {
        var images: [ModelImageAttachment] = []
        for attachment in attachments where attachment.kind == .photo {
            guard let path = attachment.localPath else { continue }
            let url = URL(fileURLWithPath: path)
            images.append(try ModelImageAttachmentLoader.load(from: url, title: attachment.title))
        }
        return images
    }

    static func textExcerpt(from url: URL, kind: ComposerAttachmentKind) -> String? {
        guard kind == .file else { return nil }
        let textExtensions: Set<String> = [
            "txt", "md", "markdown", "json", "yaml", "yml", "csv", "ttl", "html", "htm", "swift", "py"
        ]
        let ext = url.pathExtension.lowercased()
        guard textExtensions.contains(ext),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.count <= maxTextExcerptLength { return trimmed }
        return String(trimmed.prefix(maxTextExcerptLength)) + "\n...(truncated)"
    }

    private static func uniqueDestinationURL(
        for filename: String,
        in directory: URL,
        fileManager: FileManager
    ) -> URL {
        let base = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        var candidate = directory.appendingPathComponent(filename)
        var index = 1
        while fileManager.fileExists(atPath: candidate.path) {
            let nextName = ext.isEmpty ? "\(base)-\(index)" : "\(base)-\(index).\(ext)"
            candidate = directory.appendingPathComponent(nextName)
            index += 1
        }
        return candidate
    }
}