import Foundation

public struct AppleNotesExportResult: Codable, Sendable, Equatable {
    public let outputDirectory: URL
    public let exportedCount: Int
    public let rawOutput: String

    public init(outputDirectory: URL, exportedCount: Int, rawOutput: String) {
        self.outputDirectory = outputDirectory
        self.exportedCount = exportedCount
        self.rawOutput = rawOutput
    }
}

public struct AppleNotesExporter: Sendable {
    public let outputDirectory: URL

    public init(outputDirectory: URL = AppleNotesExporter.defaultOutputDirectory()) {
        self.outputDirectory = outputDirectory
    }

    public static func defaultOutputDirectory(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        homeDirectory.appendingPathComponent("Documents/Harness/Apple Notes Export", isDirectory: true)
    }

    public static func appleScript(outputDirectory: URL) -> String {
        let outputPath = outputDirectory.path.replacingOccurrences(of: "\"", with: "\\\"")
        return """
        set outputPath to "\(outputPath)"
        do shell script "/bin/mkdir -p " & quoted form of outputPath

        on sanitizeName(rawName)
            set allowedCharacters to "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789- _"
            set cleanName to ""
            repeat with currentCharacter in characters of rawName
                if allowedCharacters contains currentCharacter then
                    set cleanName to cleanName & currentCharacter
                else
                    set cleanName to cleanName & "-"
                end if
            end repeat
            if cleanName is "" then set cleanName to "untitled"
            if length of cleanName > 80 then set cleanName to text 1 thru 80 of cleanName
            return cleanName
        end sanitizeName

        tell application "Notes"
            set exportedCount to 0
            repeat with currentNote in every note
                set exportedCount to exportedCount + 1
                set noteName to name of currentNote
                set noteBody to body of currentNote
                set safeName to my sanitizeName(noteName)
                set filePath to outputPath & "/" & exportedCount & "-" & safeName & ".html"
                set fileReference to open for access POSIX file filePath with write permission
                set eof of fileReference to 0
                write noteBody to fileReference as «class utf8»
                close access fileReference
            end repeat
        end tell

        return exportedCount as text
        """
    }

    public func export() async throws -> AppleNotesExportResult {
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        #if os(macOS)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", Self.appleScript(outputDirectory: outputDirectory)]

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        let output = String(
            data: outputPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        let error = String(
            data: errorPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""

        guard process.terminationStatus == 0 else {
            let message = error.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? output
                : error
            throw NSError(
                domain: "HarnessAppleNotesExporter",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: message.trimmingCharacters(in: .whitespacesAndNewlines)]
            )
        }

        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return AppleNotesExportResult(
            outputDirectory: outputDirectory,
            exportedCount: Int(trimmed) ?? 0,
            rawOutput: trimmed
        )
        #else
        throw NSError(
            domain: "HarnessAppleNotesExporter",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Apple Notes export is only available on macOS."]
        )
        #endif
    }
}
