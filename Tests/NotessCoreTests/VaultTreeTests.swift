import Foundation
import Testing
@testable import NotessCore

struct NoteKindTests {
    @Test(arguments: [
        ("Journal/2026/03/2026-03-14.md", NoteKind.dailyEntry),
        ("_brain/people/Jana.md", .brainNote),
        ("Ideas.md", .freeNote),
        ("Work/Acme/Kickoff.md", .freeNote),
        ("Work/Journal/x.md", .freeNote),
    ])
    func classifies(path: String, kind: NoteKind) {
        #expect(NoteKind.classify(relativePath: path) == kind)
    }

    @Test(arguments: [
        "Journal/2026/03/notes.md",
        "Journal/2026/04/2026-03-14.md",
        "Journal/2026-03-14.md",
        "Journal/2026/03/2026-13-01.md",
        "Work/attachments/a.md",
        "Work/image.png",
        "Work/.hidden.md",
        "_brain",
        ".md",
    ])
    func rejectsNonNotes(path: String) {
        #expect(NoteKind.classify(relativePath: path) == nil)
    }
}

struct VaultTreeTests {
    @Test func journalListsOnlyExistingDaysNewestFirst() throws {
        let tmp = try TemporaryVault()
        try tmp.write("", to: "Journal/2026/03/2026-03-02.md")
        try tmp.write("", to: "Journal/2026/03/2026-03-14.md")
        try tmp.write("", to: "Journal/2026/01/2026-01-05.md")
        try tmp.write("", to: "Journal/2025/12/2025-12-31.md")
        try tmp.write("", to: "Journal/2026/03/stray.md")

        let years = tmp.vault.scanTree().journal.years
        #expect(years.map(\.year) == [2026, 2025])
        #expect(years[0].months.map(\.month) == [3, 1])
        #expect(years[0].months[0].days.map(\.day) == [14, 2])
        #expect(years[1].months[0].days == [Day(year: 2025, month: 12, day: 31)])
    }

    @Test func emptyVaultHasEmptyTree() throws {
        let tmp = try TemporaryVault()
        #expect(tmp.vault.scanTree() == VaultTree.empty.withName(tmp.vault.rootURL.lastPathComponent))
    }

    @Test func notesExcludeJournalBrainAndAttachments() throws {
        let tmp = try TemporaryVault()
        try tmp.write("", to: "Root.md")
        try tmp.write("", to: "Work/Kickoff.md")
        try tmp.write("", to: "Work/Deep/Plan.md")
        try tmp.write("", to: "Work/attachments/x.md")
        try tmp.write("", to: "attachments/y.md")
        try tmp.write("", to: "_brain/people/Jana.md")
        try tmp.write("", to: "Journal/2026/03/2026-03-14.md")
        try tmp.write("x", to: "Work/pic.png")
        try FileManager.default.createDirectory(
            at: tmp.vault.rootURL.appending(path: "Empty"), withIntermediateDirectories: true)

        let root = tmp.vault.scanTree().notes
        #expect(root.notes.map(\.relativePath) == ["Root.md"])
        #expect(root.folders.map(\.relativePath) == ["Empty", "Work"])
        let work = root.folders[1]
        #expect(work.notes.map(\.title) == ["Kickoff"])
        #expect(work.folders.map(\.relativePath) == ["Work/Deep"])
        #expect(work.folders[0].notes.map(\.relativePath) == ["Work/Deep/Plan.md"])
    }

    @MainActor
    @Test func opensNoteByRelativePath() throws {
        let tmp = try TemporaryVault()
        try tmp.write("# Hi\n", to: "Work/Hi.md")
        let doc = try tmp.vault.openNote(relativePath: "Work/Hi.md")
        #expect(doc.text == "# Hi\n")
    }
}

private extension VaultTree {
    func withName(_ name: String) -> VaultTree {
        VaultTree(journal: journal, notes: NotesFolder(relativePath: "", name: name, folders: [], notes: []))
    }
}
