import Foundation

/// The single user-chosen folder that holds all notes as plain Markdown files.
public struct Vault: Hashable, Sendable {
    public let rootURL: URL

    public init(rootURL: URL) {
        self.rootURL = rootURL.standardizedFileURL
    }

    public func url(for entry: DailyEntry) -> URL {
        rootURL.appending(path: entry.relativePath, directoryHint: .notDirectory)
    }

    /// Opens a Daily Entry for editing. If its file does not exist yet, the
    /// document starts with the entry's heading and nothing is written to disk
    /// until it is saved (ADR 0003).
    @MainActor
    public func openDailyEntry(_ entry: DailyEntry) throws -> NoteDocument {
        try NoteDocument.open(fileURL: url(for: entry), newFileContent: entry.initialContent)
    }
}
