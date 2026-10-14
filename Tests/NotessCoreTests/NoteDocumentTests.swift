import Foundation
import Testing
@testable import NotessCore

@MainActor
@Suite("Opening and saving a Daily Entry")
struct NoteDocumentTests {
    let today = DailyEntry(day: Day(year: 2026, month: 10, day: 14))

    @Test("a missing Daily Entry opens with its heading and creates nothing on disk")
    func missingEntryIsNotCreated() throws {
        let temp = try TemporaryVault()
        let document = try temp.vault.openDailyEntry(today)

        #expect(document.text == "# 2026-10-14\n\n")
        #expect(document.hasUnsavedChanges == false)
        #expect(temp.fileExists("Journal") == false)
    }

    @Test("saving writes Journal/YYYY/MM/YYYY-MM-DD.md, creating folders")
    func saveCreatesFileAndFolders() throws {
        let temp = try TemporaryVault()
        let document = try temp.vault.openDailyEntry(today)
        document.text = "# 2026-10-14\n\nHello\n"

        try document.save()

        #expect(try temp.read("Journal/2026/10/2026-10-14.md") == "# 2026-10-14\n\nHello\n")
    }

    @Test("saving an untouched new Daily Entry writes its heading")
    func saveUntouchedNewEntry() throws {
        let temp = try TemporaryVault()
        let document = try temp.vault.openDailyEntry(today)

        try document.save()

        #expect(try temp.read("Journal/2026/10/2026-10-14.md") == "# 2026-10-14\n\n")
    }

    @Test("an existing Daily Entry is loaded from its file")
    func existingEntryIsLoaded() throws {
        let temp = try TemporaryVault()
        try temp.write("# 2026-10-14\n\nAlready here\n", to: "Journal/2026/10/2026-10-14.md")

        let document = try temp.vault.openDailyEntry(today)

        #expect(document.text == "# 2026-10-14\n\nAlready here\n")
        #expect(document.hasUnsavedChanges == false)
    }

    @Test("editing marks unsaved changes and saving clears them")
    func unsavedChangesLifecycle() throws {
        let temp = try TemporaryVault()
        let document = try temp.vault.openDailyEntry(today)

        document.text += "Edit"
        #expect(document.hasUnsavedChanges)

        try document.save()
        #expect(document.hasUnsavedChanges == false)
    }

    @Test("editing back to the saved text clears unsaved changes")
    func revertingEditClearsUnsavedChanges() throws {
        let temp = try TemporaryVault()
        try temp.write("Saved", to: "Journal/2026/10/2026-10-14.md")
        let document = try temp.vault.openDailyEntry(today)

        document.text = "Saved!"
        document.text = "Saved"

        #expect(document.hasUnsavedChanges == false)
    }

    @Test("nothing is written to disk until save")
    func noWriteBeforeSave() throws {
        let temp = try TemporaryVault()
        try temp.write("Original", to: "Journal/2026/10/2026-10-14.md")
        let document = try temp.vault.openDailyEntry(today)

        document.text = "Changed"

        #expect(try temp.read("Journal/2026/10/2026-10-14.md") == "Original")
    }
}
