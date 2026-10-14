import Foundation
import Testing
@testable import NotessCore

@Suite("Brain Run: notes to process")
struct BrainRunChangesTests {
    @Test("the first Brain Run processes every Daily Entry and Free Note, nothing in _brain/")
    func firstRunProcessesAllNotes() throws {
        let temp = try TemporaryVault()
        try temp.write("# 2026-03-14\n", to: "Journal/2026/03/2026-03-14.md")
        try temp.write("# Plan\n", to: "Projects/Plan.md")
        try temp.write("# Anna\n", to: "_brain/people/Anna.md")
        try temp.write("rules", to: "_brain/AGENTS.md")
        try temp.write("png", to: "Projects/attachments/a.png")
        try temp.write("x", to: ".git/config")

        let changes = BrainRunChanges(since: nil, current: VaultFileSnapshot.capture(of: temp.vault))

        #expect(changes.changed == ["Journal/2026/03/2026-03-14.md", "Projects/Plan.md"])
        #expect(changes.deleted == [])
    }

    @Test("later runs process only notes added, modified or deleted since the last successful run")
    func processesOnlyChangedNotes() throws {
        let temp = try TemporaryVault()
        try temp.write("# 2026-03-14\n", to: "Journal/2026/03/2026-03-14.md")
        try temp.write("# Plan\n", to: "Projects/Plan.md")
        try temp.write("# Old\n", to: "Old.md")
        try temp.write("# Same\n", to: "Same.md")
        let previous = VaultFileSnapshot.capture(of: temp.vault)

        try temp.write("# 2026-03-14\n\nNew line\n", to: "Journal/2026/03/2026-03-14.md")
        try temp.write("# New\n", to: "New.md")
        try FileManager.default.removeItem(at: temp.vault.rootURL.appending(path: "Old.md"))
        try temp.write("# Brain\n", to: "_brain/people/Anna.md")
        try temp.write("png", to: "Projects/attachments/a.png")

        let changes = BrainRunChanges(since: previous, current: VaultFileSnapshot.capture(of: temp.vault))

        #expect(changes.changed == ["Journal/2026/03/2026-03-14.md", "New.md"])
        #expect(changes.deleted == ["Old.md"])
    }

    @Test("nothing to process when no note changed")
    func nothingChanged() throws {
        let temp = try TemporaryVault()
        try temp.write("# Same\n", to: "Same.md")
        let snapshot = VaultFileSnapshot.capture(of: temp.vault)

        #expect(BrainRunChanges(since: snapshot, current: VaultFileSnapshot.capture(of: temp.vault)).isEmpty)
    }

    @Test("rewriting a note with identical content does not count as a change")
    func identicalRewriteIsNoChange() throws {
        let temp = try TemporaryVault()
        try temp.write("# Same\n", to: "Same.md")
        let snapshot = VaultFileSnapshot.capture(of: temp.vault)
        try temp.write("# Same\n", to: "Same.md")

        #expect(BrainRunChanges(since: snapshot, current: VaultFileSnapshot.capture(of: temp.vault)).isEmpty)
    }
}
