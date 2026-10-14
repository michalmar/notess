import Foundation
import Testing
@testable import NotessCore

@MainActor
@Suite("Files changed outside Notess")
struct ExternalChangeTests {
    let path = "Notes/Idea.md"

    private func openNote(_ text: String, in temp: TemporaryVault) throws -> NoteDocument {
        try temp.write(text, to: path)
        return try temp.vault.openNote(relativePath: path)
    }

    @Test("a clean tab silently reloads an external change")
    func cleanTabReloads() throws {
        let temp = try TemporaryVault()
        let document = try openNote("old\n", in: temp)
        let revision = document.revision

        try temp.write("new\n", to: path)
        document.reconcileWithDisk()

        #expect(document.text == "new\n")
        #expect(document.hasUnsavedChanges == false)
        #expect(document.externalChange == nil)
        #expect(document.revision != revision)
    }

    @Test("an external change to a tab with unsaved edits asks instead of reloading")
    func dirtyTabShowsConflict() throws {
        let temp = try TemporaryVault()
        let document = try openNote("old\n", in: temp)
        document.text = "mine\n"

        try temp.write("theirs\n", to: path)
        let outcome = document.reconcileWithDisk()

        #expect(outcome == .conflict)
        #expect(document.externalChange == .modified("theirs\n"))
        #expect(document.text == "mine\n")
        #expect(document.hasUnsavedChanges)
    }

    @Test("Načíst discards local edits and loads the disk version")
    func reloadDiscardsLocalEdits() throws {
        let temp = try TemporaryVault()
        let document = try openNote("old\n", in: temp)
        document.text = "mine\n"
        try temp.write("theirs\n", to: path)
        document.reconcileWithDisk()
        let revision = document.revision

        try document.reloadFromDisk()

        #expect(document.text == "theirs\n")
        #expect(document.hasUnsavedChanges == false)
        #expect(document.externalChange == nil)
        #expect(document.revision != revision)
    }

    @Test("Ponechat moje hides the bar and the next save overwrites the disk")
    func keepMineThenSaveOverwrites() throws {
        let temp = try TemporaryVault()
        let document = try openNote("old\n", in: temp)
        document.text = "mine\n"
        try temp.write("theirs\n", to: path)
        document.reconcileWithDisk()

        document.keepMine()

        #expect(document.externalChange == nil)
        #expect(document.text == "mine\n")
        #expect(document.hasUnsavedChanges)
        #expect(document.reconcileWithDisk() == .unchanged)
        #expect(document.externalChange == nil)

        try document.save()

        #expect(try temp.read(path) == "mine\n")
        #expect(document.hasUnsavedChanges == false)
    }

    @Test("the app's own save is not reported as an external change")
    func ownSaveIsNotExternal() throws {
        let temp = try TemporaryVault()
        let document = try openNote("old\n", in: temp)
        document.text = "saved\n"
        try document.save()
        let revision = document.revision

        #expect(document.reconcileWithDisk() == .unchanged)
        #expect(document.externalChange == nil)
        #expect(document.revision == revision)
        #expect(document.text == "saved\n")
    }

    @Test("edits typed after a save are kept when the save is noticed on disk")
    func editsAfterSaveSurviveSync() throws {
        let temp = try TemporaryVault()
        let document = try openNote("old\n", in: temp)
        document.text = "saved\n"
        try document.save()
        document.text = "saved\nmore\n"

        #expect(document.reconcileWithDisk() == .unchanged)
        #expect(document.text == "saved\nmore\n")
        #expect(document.hasUnsavedChanges)
    }

    @Test("saving never silently overwrites a file changed on disk")
    func saveRefusesToOverwriteUnseenChange() throws {
        let temp = try TemporaryVault()
        let document = try openNote("old\n", in: temp)
        document.text = "mine\n"
        try temp.write("theirs\n", to: path)

        #expect(throws: NoteDocument.SaveError.changedOnDisk) { try document.save() }
        #expect(try temp.read(path) == "theirs\n")
        #expect(document.externalChange == .modified("theirs\n"))
        #expect(document.hasUnsavedChanges)
    }

    @Test("a file deleted outside Notess is signalled and its text is kept")
    func deletionIsSignalled() throws {
        let temp = try TemporaryVault()
        let document = try openNote("old\n", in: temp)

        try FileManager.default.removeItem(at: document.fileURL)

        #expect(document.reconcileWithDisk() == .deleted)
        #expect(document.externalChange == .deleted)
        #expect(document.existsOnDisk == false)
        #expect(document.text == "old\n")
    }

    @Test("a deleted file's tab counts as unsaved so closing or quitting asks first")
    func deletedTabIsUnsaved() throws {
        let temp = try TemporaryVault()
        let document = try openNote("old\n", in: temp)
        try FileManager.default.removeItem(at: document.fileURL)

        document.reconcileWithDisk()
        #expect(document.hasUnsavedChanges)

        try document.save()
        #expect(document.hasUnsavedChanges == false)
    }

    @Test("after a signalled deletion, saving recreates the file")
    func saveAfterDeletionRecreates() throws {
        let temp = try TemporaryVault()
        let document = try openNote("old\n", in: temp)
        try FileManager.default.removeItem(at: document.fileURL)
        document.reconcileWithDisk()

        try document.save()

        #expect(try temp.read(path) == "old\n")
        #expect(document.externalChange == nil)
        #expect(document.existsOnDisk)
    }

    @Test("saving a file deleted unnoticed signals the deletion instead of writing")
    func saveSignalsUnnoticedDeletion() throws {
        let temp = try TemporaryVault()
        let document = try openNote("old\n", in: temp)
        document.text = "mine\n"
        try FileManager.default.removeItem(at: document.fileURL)

        #expect(throws: NoteDocument.SaveError.deletedOnDisk) { try document.save() }
        #expect(temp.fileExists(path) == false)
        #expect(document.externalChange == .deleted)
    }

    @Test("a deleted file restored with the same content clears the signal")
    func restoredFileClearsDeletion() throws {
        let temp = try TemporaryVault()
        let document = try openNote("old\n", in: temp)
        document.text = "mine\n"
        try FileManager.default.removeItem(at: document.fileURL)
        document.reconcileWithDisk()

        try temp.write("old\n", to: path)

        #expect(document.reconcileWithDisk() == .unchanged)
        #expect(document.externalChange == nil)
        #expect(document.existsOnDisk)
        #expect(document.text == "mine\n")
    }

    @Test("an unsaved new Daily Entry picks up a file created elsewhere")
    func newDailyEntryLoadsExternallyCreatedFile() throws {
        let temp = try TemporaryVault()
        let entry = DailyEntry(day: Day(year: 2026, month: 10, day: 14))
        let document = try temp.vault.openDailyEntry(entry)

        try temp.write("# 2026-10-14\n\nFrom phone\n", to: entry.relativePath)

        #expect(document.reconcileWithDisk() == .reloaded)
        #expect(document.text == "# 2026-10-14\n\nFrom phone\n")
        #expect(document.existsOnDisk)
    }

    @Test("a missing file that was never saved is not reported as deleted")
    func neverSavedFileIsNotDeleted() throws {
        let temp = try TemporaryVault()
        let entry = DailyEntry(day: Day(year: 2026, month: 10, day: 14))
        let document = try temp.vault.openDailyEntry(entry)

        #expect(document.reconcileWithDisk() == .unchanged)
        #expect(document.externalChange == nil)
    }

    @Test("an unsaved new Free Note is untouched by reconciling and saves under its title")
    func pendingFreeNoteIgnoresDisk() throws {
        let temp = try TemporaryVault()
        let document = NoteDocument.newFreeNote(inFolder: temp.vault.rootURL, content: "# Plan\n")

        #expect(document.reconcileWithDisk() == .unchanged)
        #expect(document.externalChange == nil)

        try document.save()

        #expect(try temp.read("Plan.md") == "# Plan\n")
        #expect(document.reconcileWithDisk() == .unchanged)
    }

    @Test("a deleted read-only note is signalled but does not count as unsaved")
    func deletedReadOnlyNoteIsNotUnsaved() throws {
        let temp = try TemporaryVault()
        try temp.write("facts\n", to: "_brain/people/Ana.md")
        let document = try NoteDocument.open(
            fileURL: temp.vault.rootURL.appending(path: "_brain/people/Ana.md"),
            newFileContent: "",
            isReadOnly: true
        )
        try FileManager.default.removeItem(at: document.fileURL)

        #expect(document.reconcileWithDisk() == .deleted)
        #expect(document.hasUnsavedChanges == false)
    }

    @Test("a tab session syncs every open tab")
    func tabSessionSyncsAllTabs() throws {
        let temp = try TemporaryVault()
        try temp.write("a\n", to: "A.md")
        try temp.write("b\n", to: "B.md")
        let session = TabSession()
        let first = try session.openNote(at: temp.vault.rootURL.appending(path: "A.md"))
        let second = try session.openNote(at: temp.vault.rootURL.appending(path: "B.md"))
        second.text = "mine\n"

        try temp.write("a2\n", to: "A.md")
        try temp.write("b2\n", to: "B.md")
        session.reconcileWithDisk()

        #expect(first.text == "a2\n")
        #expect(second.externalChange == .modified("b2\n"))
    }
}
