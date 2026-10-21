import Foundation
import Testing
@testable import Notess
@testable import NotessCore

@MainActor
@Suite("Deleting notes through the app")
struct AppModelDeletionTests {
    @Test("the system Trash boundary moves a disposable file when explicitly enabled")
    func systemTrashIntegration() throws {
        guard ProcessInfo.processInfo.environment["NOTESS_RUN_TRASH_INTEGRATION"] == "1" else { return }
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "NotessTrashIntegration-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appending(path: "Disposable.md", directoryHint: .notDirectory)
        try "# Disposable\n".write(to: fileURL, atomically: true, encoding: .utf8)

        try FileTrash.moveToTrash(fileURL)

        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
    }

    @Test("a confirmed clean Free Note moves to Trash and disappears from app state")
    func deleteCleanFreeNote() throws {
        let fixture = try DeletionFixture()
        try fixture.write("# Delete me\n", to: "Notes/Delete me.md")
        try fixture.write("# Keep me\n", to: "Notes/Keep me.md")
        let model = fixture.makeModel()
        let document = try #require(model.openExistingNote(relativePath: "Notes/Delete me.md"))

        model.requestNoteDeletion(relativePath: "Notes/Delete me.md")

        #expect(model.noteDeletionConfirmation?.kind == .savedFile)
        model.confirmNoteDeletion(.moveToTrash)

        #expect(fixture.trashedPaths == ["Notes/Delete me.md"])
        #expect(fixture.trashedContents == ["# Delete me\n"])
        #expect(!FileManager.default.fileExists(atPath: document.fileURL.path))
        #expect(model.tabSession.document(at: document.fileURL) == nil)
        #expect(notePaths(in: model.tree.notes) == ["Notes/Keep me.md"])
        #expect(try fixture.savedTabState()?.relativePaths.contains("Notes/Delete me.md") == false)
        #expect(try String(contentsOf: fixture.url("Notes/Keep me.md"), encoding: .utf8) == "# Keep me\n")
        #expect(model.errorMessage == nil)
    }

    @Test("saving before Trash preserves a dirty note's latest text")
    func saveAndDeleteDirtyNote() throws {
        let fixture = try DeletionFixture()
        try fixture.write("# Saved\n", to: "Notes/Idea.md")
        let model = fixture.makeModel()
        let document = try #require(model.openExistingNote(relativePath: "Notes/Idea.md"))
        document.text = "# Latest\n"

        model.requestNoteDeletion(relativePath: "Notes/Idea.md")

        #expect(model.noteDeletionConfirmation?.kind == .dirtyFile)
        model.confirmNoteDeletion(.saveAndMoveToTrash)

        #expect(fixture.trashedContents == ["# Latest\n"])
        #expect(model.tabSession.document(at: document.fileURL) == nil)
        #expect(model.errorMessage == nil)
    }

    @Test("discarding before Trash preserves only a dirty note's saved text")
    func discardAndDeleteDirtyNote() throws {
        let fixture = try DeletionFixture()
        try fixture.write("# Saved\n", to: "Notes/Idea.md")
        let model = fixture.makeModel()
        let document = try #require(model.openExistingNote(relativePath: "Notes/Idea.md"))
        document.text = "# Unwanted\n"

        model.requestNoteDeletion(relativePath: "Notes/Idea.md")
        model.confirmNoteDeletion(.discardChangesAndMoveToTrash)

        #expect(fixture.trashedContents == ["# Saved\n"])
        #expect(model.tabSession.document(at: document.fileURL) == nil)
        #expect(model.errorMessage == nil)
    }

    @Test("cancelling deletion leaves the dirty note and file unchanged")
    func cancelDirtyDeletion() throws {
        let fixture = try DeletionFixture()
        try fixture.write("# Saved\n", to: "Notes/Idea.md")
        let model = fixture.makeModel()
        let document = try #require(model.openExistingNote(relativePath: "Notes/Idea.md"))
        document.text = "# Unsaved\n"

        model.requestNoteDeletion(relativePath: "Notes/Idea.md")
        model.cancelNoteDeletion()

        #expect(model.noteDeletionConfirmation == nil)
        #expect(fixture.trashedPaths.isEmpty)
        #expect(try String(contentsOf: document.fileURL, encoding: .utf8) == "# Saved\n")
        #expect(model.tabSession.document(at: document.fileURL) === document)
        #expect(document.text == "# Unsaved\n")
    }

    @Test("a never-saved Daily Entry is discarded without fabricating a Trash item")
    func discardDailyEntryDraft() throws {
        let fixture = try DeletionFixture()
        let model = fixture.makeModel()
        let document = try #require(model.document)
        let relativePath = DailyEntry(date: Date(timeIntervalSince1970: 1_760_765_000)).relativePath
        #expect(!document.existsOnDisk)

        model.requestNoteDeletion(relativePath: relativePath)

        #expect(model.noteDeletionConfirmation?.kind == .draftDailyEntry)
        model.confirmNoteDeletion(.discardDraft)

        #expect(fixture.trashedPaths.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: document.fileURL.path))
        #expect(model.tabSession.document(at: document.fileURL) == nil)
        #expect(try fixture.savedTabState()?.relativePaths.contains(relativePath) == false)
    }

    @Test("a Trash failure keeps the file and its dirty tab accessible")
    func trashFailureKeepsDocument() throws {
        let fixture = try DeletionFixture()
        try fixture.write("# Saved\n", to: "Notes/Idea.md")
        fixture.trashFailure = TestFailure.trash
        let model = fixture.makeModel()
        let document = try #require(model.openExistingNote(relativePath: "Notes/Idea.md"))
        document.text = "# Unsaved\n"

        model.requestNoteDeletion(relativePath: "Notes/Idea.md")
        model.confirmNoteDeletion(.discardChangesAndMoveToTrash)

        #expect(FileManager.default.fileExists(atPath: document.fileURL.path))
        #expect(model.tabSession.document(at: document.fileURL) === document)
        #expect(document.text == "# Unsaved\n")
        #expect(model.errorMessage?.contains("test Trash failure") == true)
    }

    @Test("save and Trash refuses to overwrite an externally changed file")
    func saveConflictKeepsDocument() throws {
        let fixture = try DeletionFixture()
        try fixture.write("# Saved\n", to: "Notes/Idea.md")
        let model = fixture.makeModel()
        let document = try #require(model.openExistingNote(relativePath: "Notes/Idea.md"))
        document.text = "# Mine\n"
        try fixture.write("# External\n", to: "Notes/Idea.md")

        model.requestNoteDeletion(relativePath: "Notes/Idea.md")
        model.confirmNoteDeletion(.saveAndMoveToTrash)

        #expect(fixture.trashedPaths.isEmpty)
        #expect(try String(contentsOf: document.fileURL, encoding: .utf8) == "# External\n")
        #expect(model.tabSession.document(at: document.fileURL) === document)
        #expect(document.text == "# Mine\n")
        #expect(document.externalChange == .modified("# External\n"))
        #expect(model.noteDeletionConfirmation == nil)
    }

    @Test("successful deletion refreshes saved search and the Tag Timeline")
    func deletionRefreshesSavedIndexes() async throws {
        let fixture = try DeletionFixture()
        let relativePath = "Journal/2026/01/2026-01-02.md"
        try fixture.write("## Vanishing #gone\nunique-delete-token\n", to: relativePath)
        let model = fixture.makeModel()
        try await waitUntil { !model.isIndexing }
        let index = try #require(model.searchIndex)
        #expect(try await index.search(SearchQuery("unique-delete-token")).flatMap(\.results).count == 1)
        model.sidebarMode = .tags
        await model.tagTimeline.refresh()
        try await waitUntil { loadedTags(model).contains("gone") }
        let revision = model.searchIndexRevision

        model.requestNoteDeletion(relativePath: relativePath)
        model.confirmNoteDeletion(.moveToTrash)

        try await waitUntil { model.searchIndexRevision > revision }
        #expect(try await index.search(SearchQuery("unique-delete-token")).isEmpty)
        try await waitUntil { !loadedTags(model).contains("gone") }
    }

    @Test("Brain Notes and folders are not deletion targets")
    func excludedDeletionTargets() throws {
        let fixture = try DeletionFixture()
        try fixture.write("# Brain\n", to: "_brain/People/Ada.md")
        try FileManager.default.createDirectory(
            at: fixture.url("Notes/Folder"),
            withIntermediateDirectories: true
        )
        let model = fixture.makeModel()

        #expect(!model.canDeleteNote(relativePath: "_brain/People/Ada.md"))
        #expect(!model.canDeleteNote(relativePath: "Notes/Folder"))
        model.requestNoteDeletion(relativePath: "_brain/People/Ada.md")
        #expect(model.noteDeletionConfirmation == nil)
        #expect(fixture.trashedPaths.isEmpty)
    }

    @Test("a clean-file confirmation cannot discard edits made before it is accepted")
    func cleanConfirmationDoesNotDiscardNewEdits() throws {
        let fixture = try DeletionFixture()
        try fixture.write("# Saved\n", to: "Notes/Idea.md")
        let model = fixture.makeModel()
        let document = try #require(model.openExistingNote(relativePath: "Notes/Idea.md"))
        model.requestNoteDeletion(relativePath: "Notes/Idea.md")
        document.text = "# Newly edited\n"

        model.confirmNoteDeletion(.moveToTrash)

        #expect(fixture.trashedPaths.isEmpty)
        #expect(model.tabSession.document(at: document.fileURL) === document)
        #expect(model.noteDeletionConfirmation?.kind == .dirtyFile)
        #expect(document.text == "# Newly edited\n")
    }

    private func notePaths(in folder: NotesFolder) -> [String] {
        (folder.notes.map(\.relativePath) + folder.folders.flatMap(notePaths)).sorted()
    }

    private func loadedTags(_ model: AppModel) -> [String] {
        guard case .loaded(let tags) = model.tagTimeline.tags else { return [] }
        return tags
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(20)
        while !condition() {
            try #require(ContinuousClock.now < deadline, "timed out")
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

private final class DeletionFixture {
    let rootURL: URL
    private let defaultsSuiteName: String
    private let defaults: UserDefaults
    var trashFailure: Error?
    private(set) var trashedPaths: [String] = []
    private(set) var trashedContents: [String] = []

    init() throws {
        rootURL = FileManager.default.temporaryDirectory
            .appending(path: "NotessDeletionTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defaultsSuiteName = "NotessDeletionTests-\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: defaultsSuiteName))
    }

    deinit {
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        let databaseURL = SearchIndex.defaultDatabaseURL(for: Vault(rootURL: rootURL))
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: databaseURL.path + suffix)
        }
        try? FileManager.default.removeItem(at: rootURL)
    }

    func url(_ relativePath: String) -> URL {
        rootURL.appending(path: relativePath, directoryHint: .notDirectory)
    }

    func write(_ text: String, to relativePath: String) throws {
        let fileURL = url(relativePath)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try text.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    @MainActor
    func makeModel() -> AppModel {
        let vault = Vault(rootURL: rootURL)
        VaultLocationStore(defaults: defaults).remember(vault)
        return AppModel(
            vaultLocationStore: VaultLocationStore(defaults: defaults),
            tabRestorationStore: TabRestorationStore(defaults: defaults),
            settings: AppSettings(defaults: defaults),
            brainRunStateStore: BrainRunStateStore(
                directoryURL: rootURL.appending(path: ".test-brain-runs", directoryHint: .isDirectory)
            ),
            moveToTrash: { [weak self] fileURL in
                guard let self else { return }
                if let trashFailure { throw trashFailure }
                trashedPaths.append(relativePath(for: fileURL))
                trashedContents.append(try String(contentsOf: fileURL, encoding: .utf8))
                try FileManager.default.removeItem(at: fileURL)
            },
            now: { Date(timeIntervalSince1970: 1_760_765_000) }
        )
    }

    func savedTabState() throws -> TabRestorationState? {
        try TabRestorationStore(defaults: defaults).savedState(for: Vault(rootURL: rootURL))
    }

    private func relativePath(for fileURL: URL) -> String {
        String(fileURL.path.dropFirst(rootURL.path.count + 1))
    }
}

private enum TestFailure: LocalizedError {
    case trash

    var errorDescription: String? { "test Trash failure" }
}
