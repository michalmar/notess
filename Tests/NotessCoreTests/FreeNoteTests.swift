import Foundation
import Testing
@testable import NotessCore

@MainActor
struct FreeNoteTests {
    @Test func fileStemKeepsDiacriticsAndRemovesUnsafeCharacters() {
        #expect(FreeNote.fileStem(forTitle: "Příliš žluťoučký kůň") == "Příliš žluťoučký kůň")
        #expect(FreeNote.fileStem(forTitle: "a/b: c\\d") == "a b c d")
        #expect(FreeNote.fileStem(forTitle: "  ..skryté  ") == "skryté")
        #expect(FreeNote.fileStem(forTitle: String(repeating: "x", count: 300)).count == 100)
    }

    @Test func emptyTitleFallsBackToDefaultName() {
        #expect(FreeNote.fileStem(forTitle: nil) == "Bez názvu")
        #expect(FreeNote.fileStem(forTitle: "  / ") == "Bez názvu")
    }

    @Test func titleSkipsFrontMatter() {
        let text = "---\ncreated: 2026-03-14\n---\n\n# Nápad\n\ntext"
        #expect(FreeNote.title(in: text) == "Nápad")
        #expect(FreeNote.title(in: "---\ncreated: x\n---\n\n# ") == "")
        #expect(FreeNote.title(in: "bez nadpisu") == nil)
    }

    @Test func initialContentHasFrontMatterAndHeading() {
        let content = FreeNote.initialContent(createdOn: Day(year: 2026, month: 3, day: 4))
        #expect(content == "---\ncreated: 2026-03-04\n---\n\n# ")
    }

    @Test func collisionAddsNumericSuffix() throws {
        let tmp = try TemporaryVault()
        try tmp.write("x", to: "Nápad.md")
        try tmp.write("x", to: "Nápad 2.md")
        let url = FreeNote.availableURL(inFolder: tmp.vault.rootURL, stem: "Nápad")
        #expect(url.lastPathComponent == "Nápad 3.md")
    }

    @Test func firstSaveCreatesFileNamedFromTitleInSelectedFolder() throws {
        let tmp = try TemporaryVault()
        let note = try tmp.vault.newFreeNote(inFolder: "Projekty", on: Day(year: 2026, month: 3, day: 4))
        #expect(!tmp.fileExists("Projekty"))
        note.text += "Můj nápad\n"
        try note.save()
        #expect(try tmp.read("Projekty/Můj nápad.md").contains("# Můj nápad"))
        #expect(note.fileURL.lastPathComponent == "Můj nápad.md")
        note.text += "víc"
        try note.save()
        #expect(note.fileURL.lastPathComponent == "Můj nápad.md")
    }

    @Test func saveDoesNotOverwriteExistingFile() throws {
        let tmp = try TemporaryVault()
        try tmp.write("původní", to: "Nápad.md")
        let note = try tmp.vault.newFreeNote(inFolder: "", on: Day(year: 2026, month: 3, day: 4))
        note.text += "Nápad"
        try note.save()
        #expect(try tmp.read("Nápad.md") == "původní")
        #expect(tmp.fileExists("Nápad 2.md"))
    }

    @Test func emptyTitleSavesUnderDefaultName() throws {
        let tmp = try TemporaryVault()
        let note = try tmp.vault.newFreeNote(inFolder: "", on: Day(year: 2026, month: 3, day: 4))
        #expect(note.displayName == "Bez názvu")
        try note.save()
        #expect(tmp.fileExists("Bez názvu.md"))
    }

    @Test func cannotCreateInJournalOrBrain() throws {
        let tmp = try TemporaryVault()
        let day = Day(year: 2026, month: 3, day: 4)
        for folder in ["Journal", "Journal/2026", "_brain", "_brain/x", "../out", "attachments"] {
            #expect(throws: FreeNoteError.reservedFolder) {
                try tmp.vault.newFreeNote(inFolder: folder, on: day)
            }
        }
    }
}
