import Foundation
import Observation

/// An open note: the in-memory text being edited and the file it belongs to.
/// The file changes only when `save()` is called (ADR 0003).
@MainActor
@Observable
public final class NoteDocument: Identifiable {
    public nonisolated let id = UUID()
    /// For an unsaved Free Note this is a placeholder until the first save.
    public private(set) var fileURL: URL

    /// The current, possibly unsaved, text.
    public var text: String {
        didSet { refreshUnsavedChanges() }
    }

    /// True when `text` differs from what was last loaded or saved.
    public private(set) var hasUnsavedChanges = false

    /// False until the note's file exists (a new Daily Entry before its first save).
    public private(set) var existsOnDisk: Bool

    /// The folder a new Free Note will be saved into; its file name is
    /// derived from the `# Title` heading at the first save.
    @ObservationIgnored private var pendingFreeNoteFolder: URL?
    @ObservationIgnored private var baseline: String

    /// Name shown in tabs: the file name, or the heading of an unsaved Free Note.
    public var displayName: String {
        pendingFreeNoteFolder == nil
            ? fileURL.deletingPathExtension().lastPathComponent
            : FreeNote.fileStem(forTitle: FreeNote.title(in: text))
    }

    private init(fileURL: URL, text: String, existsOnDisk: Bool) {
        self.fileURL = fileURL
        self.text = text
        self.baseline = text
        self.existsOnDisk = existsOnDisk
    }

    /// A Free Note that exists only in memory until its first save.
    public static func newFreeNote(inFolder folderURL: URL, content: String) -> NoteDocument {
        let placeholder = folderURL.appending(
            path: "\(FreeNote.defaultFileStem)-\(UUID().uuidString).md",
            directoryHint: .notDirectory
        )
        let document = NoteDocument(fileURL: placeholder, text: content, existsOnDisk: false)
        document.pendingFreeNoteFolder = folderURL
        return document
    }

    /// Loads the note at `fileURL`, or starts from `newFileContent` without
    /// touching the disk if the file does not exist.
    public static func open(fileURL: URL, newFileContent: String) throws -> NoteDocument {
        do {
            let text = try String(contentsOf: fileURL, encoding: .utf8)
            return NoteDocument(fileURL: fileURL, text: text, existsOnDisk: true)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return NoteDocument(fileURL: fileURL, text: newFileContent, existsOnDisk: false)
        }
    }

    /// Writes `text` to the file, creating intermediate folders as needed.
    public func save() throws {
        guard hasUnsavedChanges || !existsOnDisk else { return }
        let snapshot = text
        let pendingURL = pendingFreeNoteFolder.map {
            FreeNote.availableURL(inFolder: $0, stem: FreeNote.fileStem(forTitle: FreeNote.title(in: snapshot)))
        }
        let fileURL = pendingURL ?? self.fileURL
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(snapshot.utf8).write(to: fileURL, options: .atomic)
        self.fileURL = fileURL
        pendingFreeNoteFolder = nil
        baseline = snapshot
        existsOnDisk = true
        refreshUnsavedChanges()
    }

    private func refreshUnsavedChanges() {
        let changed = text != baseline
        if changed != hasUnsavedChanges { hasUnsavedChanges = changed }
    }
}
