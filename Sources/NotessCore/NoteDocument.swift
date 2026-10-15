import Foundation
import Observation

/// An open note: the in-memory text being edited and the file it belongs to.
/// The file changes only when `save()` is called (ADR 0003).
///
/// The Vault is shared with git, other editors and the Agent, so the file can
/// also change on disk. `reconcileWithDisk()` compares the file with the content
/// last loaded or saved: a tab without unsaved changes reloads silently, a tab
/// with unsaved changes records an `externalChange` for the user to resolve.
/// Comparing content (not timestamps) means the app's own saves never look
/// like external changes.
@MainActor
@Observable
public final class NoteDocument: Identifiable {
    public nonisolated let id = UUID()
    /// For an unsaved Free Note this is a placeholder until the first save.
    public private(set) var fileURL: URL
    public let isReadOnly: Bool

    /// The current, possibly unsaved, text.
    public var text: String {
        didSet { refreshUnsavedChanges() }
    }

    /// True when `text` differs from what was last loaded, saved or accepted from disk,
    /// or when the file was deleted outside Notess and the text survives only here.
    public private(set) var hasUnsavedChanges = false

    /// False until the note's file exists (a new Daily Entry before its first save),
    /// and after the file was deleted outside Notess.
    public private(set) var existsOnDisk: Bool

    /// A change on disk the user has not resolved yet.
    public private(set) var externalChange: ExternalChange? {
        didSet { refreshUnsavedChanges() }
    }

    /// Increases whenever `text` is replaced from disk, so an editor showing
    /// the note knows to load the new text.
    public private(set) var revision = 0

    /// The folder a new Free Note will be saved into; its file name is
    /// derived from the `# Title` heading at the first save.
    @ObservationIgnored private var pendingFreeNoteFolder: URL?
    /// The file's content as last loaded, saved or accepted; for a file not on
    /// disk, the content the note started from.
    @ObservationIgnored private var baseline: String
    @ObservationIgnored private var stagedAttachments: [NoteAttachment] = []

    /// The files the most recent `save()` wrote, including those written before
    /// it failed; empty when it wrote nothing.
    @ObservationIgnored public private(set) var lastSaveWrittenFileURLs: [URL] = []

    /// Name shown in tabs: the file name, or the heading of an unsaved Free Note.
    public var displayName: String {
        pendingFreeNoteFolder == nil
            ? fileURL.deletingPathExtension().lastPathComponent
            : FreeNote.fileStem(forTitle: FreeNote.title(in: text))
    }

    private init(fileURL: URL, text: String, existsOnDisk: Bool, isReadOnly: Bool) {
        self.fileURL = fileURL
        self.text = text
        self.baseline = text
        self.existsOnDisk = existsOnDisk
        self.isReadOnly = isReadOnly
    }

    /// A Free Note that exists only in memory until its first save.
    public static func newFreeNote(inFolder folderURL: URL, content: String) -> NoteDocument {
        let placeholder = folderURL.appending(
            path: "\(FreeNote.defaultFileStem)-\(UUID().uuidString).md",
            directoryHint: .notDirectory
        )
        let document = NoteDocument(
            fileURL: placeholder,
            text: content,
            existsOnDisk: false,
            isReadOnly: false
        )
        document.pendingFreeNoteFolder = folderURL
        return document
    }

    /// Loads the note at `fileURL`, or starts from `newFileContent` without
    /// touching the disk if the file does not exist.
    public static func open(
        fileURL: URL,
        newFileContent: String,
        isReadOnly: Bool = false
    ) throws -> NoteDocument {
        if let text = try readDisk(fileURL) {
            return NoteDocument(fileURL: fileURL, text: text, existsOnDisk: true, isReadOnly: isReadOnly)
        }
        return NoteDocument(
            fileURL: fileURL,
            text: newFileContent,
            existsOnDisk: false,
            isReadOnly: isReadOnly
        )
    }

    /// Writes `text` to the file, creating intermediate folders as needed.
    ///
    /// Never silently overwrites a file changed or deleted outside Notess:
    /// such a save records `externalChange` and throws `SaveError` instead.
    /// After `keepMine()` (or once a deletion is signalled) saving writes.
    public func save() throws {
        lastSaveWrittenFileURLs = []
        guard !isReadOnly else { throw CocoaError(.fileWriteNoPermission) }
        guard hasUnsavedChanges || !existsOnDisk else { return }
        let snapshot = text
        let pendingURL = pendingFreeNoteFolder.map {
            FreeNote.availableURL(inFolder: $0, stem: FreeNote.fileStem(forTitle: FreeNote.title(in: snapshot)))
        }
        // A new Free Note gets a fresh, unused file name, so there is nothing to overwrite.
        if pendingURL == nil {
            let disk = try Self.readDisk(fileURL)
            if disk != knownDiskContent {
                if let disk, disk == snapshot {
                    accept(disk)
                    return
                }
                recordExternalChange(disk)
                throw disk == nil ? SaveError.deletedOnDisk : SaveError.changedOnDisk
            }
        }
        let fileURL = pendingURL ?? self.fileURL
        let referencedPaths = Set<String>(MarkdownSyntax.tokens(in: snapshot).compactMap { token in
            guard case .image(let source) = token.kind else { return nil }
            return source
        })
        let attachmentsToWrite = stagedAttachments.filter {
            referencedPaths.contains($0.relativePath)
        }
        for attachment in attachmentsToWrite {
            try FileManager.default.createDirectory(
                at: attachment.fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try attachment.data.write(to: attachment.fileURL, options: .atomic)
            lastSaveWrittenFileURLs.append(attachment.fileURL)
        }
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(snapshot.utf8).write(to: fileURL, options: .atomic)
        lastSaveWrittenFileURLs.append(fileURL)
        let writtenPaths = Set(attachmentsToWrite.map(\.relativePath))
        stagedAttachments.removeAll { writtenPaths.contains($0.relativePath) }
        self.fileURL = fileURL
        pendingFreeNoteFolder = nil
        accept(snapshot)
    }

    /// Compares the file with the last known content and reacts to an outside change.
    /// Unreadable files are ignored until they can be read again.
    @discardableResult
    public func reconcileWithDisk() -> ReconcileOutcome {
        let disk: String
        do {
            guard let content = try Self.readDisk(fileURL) else {
                return existsOnDisk ? recordExternalChange(nil) : .unchanged
            }
            disk = content
        } catch {
            return .unchanged
        }
        guard disk != knownDiskContent else {
            externalChange = nil
            return .unchanged
        }
        if disk == text || (externalChange == .deleted && disk == baseline) {
            accept(disk)
            return .unchanged
        }
        if !hasUnsavedChanges {
            replaceText(with: disk)
            return .reloaded
        }
        return recordExternalChange(disk)
    }

    /// "Načíst": discards local changes and loads the file as it is on disk now.
    public func reloadFromDisk() throws {
        guard let disk = try Self.readDisk(fileURL) else {
            recordExternalChange(nil)
            return
        }
        replaceText(with: disk)
    }

    /// "Ponechat moje": keeps the local text and hides the bar; the next save
    /// overwrites the file with it.
    public func keepMine() {
        guard case .modified(let disk) = externalChange else { return }
        accept(disk)
    }

    private var knownDiskContent: String? {
        existsOnDisk ? baseline : nil
    }

    private func accept(_ diskContent: String) {
        baseline = diskContent
        existsOnDisk = true
        externalChange = nil
        refreshUnsavedChanges()
    }

    private func replaceText(with diskContent: String) {
        // The editor reloads without undo history, so staged images can no longer come back.
        stagedAttachments.removeAll()
        accept(diskContent)
        text = diskContent
        revision += 1
    }

    @discardableResult
    private func recordExternalChange(_ diskContent: String?) -> ReconcileOutcome {
        guard let diskContent else {
            existsOnDisk = false
            externalChange = .deleted
            return .deleted
        }
        externalChange = .modified(diskContent)
        return .conflict
    }

    /// Stages image bytes for the next explicit save and returns their Markdown link.
    public func stageAttachment(
        data: Data,
        fileExtension: String,
        id: UUID = UUID()
    ) -> NoteAttachment {
        let attachment = NoteAttachment.plan(
            data: data,
            fileExtension: fileExtension,
            for: fileURL,
            id: id
        )
        stagedAttachments.append(attachment)
        return attachment
    }

    /// Returns bytes for an attachment waiting for the next explicit save.
    public func stagedAttachmentData(relativePath: String) -> Data? {
        stagedAttachments.last(where: { $0.relativePath == relativePath })?.data
    }

    private func refreshUnsavedChanges() {
        let changed = text != baseline || (externalChange == .deleted && !isReadOnly)
        if changed != hasUnsavedChanges { hasUnsavedChanges = changed }
    }

    /// The file's text, or `nil` if there is no file.
    private static func readDisk(_ url: URL) throws -> String? {
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        }
    }
}

extension NoteDocument {
    public enum ExternalChange: Equatable, Sendable {
        /// The file now has this content, which conflicts with unsaved local edits.
        case modified(String)
        /// The file was deleted (or moved away) outside Notess.
        case deleted
    }

    public enum ReconcileOutcome: Equatable, Sendable {
        case unchanged
        case reloaded
        case conflict
        case deleted
    }

    public enum SaveError: LocalizedError, Equatable {
        case changedOnDisk
        case deletedOnDisk

        public var errorDescription: String? {
            switch self {
            case .changedOnDisk: "Soubor byl mezitím změněn mimo Notess."
            case .deletedOnDisk: "Soubor byl mezitím smazán mimo Notess."
            }
        }
    }
}
