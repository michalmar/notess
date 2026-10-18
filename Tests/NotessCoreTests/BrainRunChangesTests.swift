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

        let changes = BrainRunChanges(since: nil, current: try VaultFileSnapshot.capture(of: temp.vault))

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
        let previous = try VaultFileSnapshot.capture(of: temp.vault)

        try temp.write("# 2026-03-14\n\nNew line\n", to: "Journal/2026/03/2026-03-14.md")
        try temp.write("# New\n", to: "New.md")
        try FileManager.default.removeItem(at: temp.vault.rootURL.appending(path: "Old.md"))
        try temp.write("# Brain\n", to: "_brain/people/Anna.md")
        try temp.write("png", to: "Projects/attachments/a.png")

        let changes = BrainRunChanges(since: previous, current: try VaultFileSnapshot.capture(of: temp.vault))

        #expect(changes.changed == ["Journal/2026/03/2026-03-14.md", "New.md"])
        #expect(changes.deleted == ["Old.md"])
    }

    @Test("nothing to process when no note changed")
    func nothingChanged() throws {
        let temp = try TemporaryVault()
        try temp.write("# Same\n", to: "Same.md")
        let snapshot = try VaultFileSnapshot.capture(of: temp.vault)

        #expect(BrainRunChanges(since: snapshot, current: try VaultFileSnapshot.capture(of: temp.vault)).isEmpty)
    }

    @Test("rewriting a note with identical content does not count as a change")
    func identicalRewriteIsNoChange() throws {
        let temp = try TemporaryVault()
        try temp.write("# Same\n", to: "Same.md")
        let snapshot = try VaultFileSnapshot.capture(of: temp.vault)
        try temp.write("# Same\n", to: "Same.md")

        #expect(BrainRunChanges(since: snapshot, current: try VaultFileSnapshot.capture(of: temp.vault)).isEmpty)
    }

    @Test(
        "an unreadable note fails the capture instead of looking deleted",
        .enabled(if: geteuid() != 0, "root ignores file permissions")
    )
    func unreadableNoteFailsCapture() throws {
        let temp = try TemporaryVault()
        try temp.write("# Plan\n", to: "Projects/Plan.md")
        try temp.write("# Other\n", to: "Other.md")
        let unreadable = try temp.makeUnreadable("Projects/Plan.md")
        defer { unreadable.restore() }

        #expect {
            try VaultFileSnapshot.capture(of: temp.vault)
        } throws: { ($0 as? VaultSnapshotError)?.relativePath == "Projects/Plan.md" }
        #expect {
            try VaultFileSnapshot.capture(of: temp.vault, under: "Projects")
        } throws: { ($0 as? VaultSnapshotError)?.relativePath == "Projects/Plan.md" }
        #expect {
            try VaultFileSnapshot.capture(of: temp.vault, under: "Projects/Plan.md")
        } throws: { ($0 as? VaultSnapshotError)?.relativePath == "Projects/Plan.md" }
    }

    @Test(
        "a folder that cannot be listed fails the capture instead of looking empty",
        .enabled(if: geteuid() != 0, "root ignores file permissions")
    )
    func unlistableFolderFailsCapture() throws {
        let temp = try TemporaryVault()
        try temp.write("# Plan\n", to: "Projects/Plan.md")
        try temp.write("# Other\n", to: "Other.md")
        let unreadable = try temp.makeUnreadable("Projects")
        defer { unreadable.restore() }

        #expect {
            try VaultFileSnapshot.capture(of: temp.vault)
        } throws: { ($0 as? VaultSnapshotError)?.relativePath == "Projects" }
        #expect {
            try VaultFileSnapshot.capture(of: temp.vault, under: "Projects")
        } throws: { ($0 as? VaultSnapshotError)?.relativePath == "Projects" }
    }

    @Test(
        "unreadable hidden items and _brain/ contents stay excluded instead of failing the capture",
        .enabled(if: geteuid() != 0, "root ignores file permissions")
    )
    func excludedItemsDoNotFailCapture() throws {
        let temp = try TemporaryVault()
        try temp.write("# Plan\n", to: "Projects/Plan.md")
        try temp.write("x", to: ".git/objects/a")
        try temp.write("# Anna\n", to: "_brain/people/Anna.md")
        let hidden = try temp.makeUnreadable(".git/objects")
        defer { hidden.restore() }
        let brain = try temp.makeUnreadable("_brain/people")
        defer { brain.restore() }

        #expect(try VaultFileSnapshot.capture(of: temp.vault).fingerprints.keys.sorted() == ["Projects/Plan.md"])
    }

    @Test("a missing scope and a symlink are confirmed absent, not failures")
    func missingScopeAndSymlinkAreAbsent() throws {
        let temp = try TemporaryVault()
        try temp.write("# Plan\n", to: "Projects/Plan.md")
        try FileManager.default.createSymbolicLink(
            at: temp.vault.rootURL.appending(path: "Link.md"),
            withDestinationURL: temp.vault.rootURL.appending(path: "Projects/Plan.md")
        )
        try FileManager.default.createSymbolicLink(
            at: temp.vault.rootURL.appending(path: "Dangling.md"),
            withDestinationURL: temp.vault.rootURL.appending(path: "Nowhere.md")
        )

        #expect(try VaultFileSnapshot.capture(of: temp.vault, under: "Gone.md").fingerprints.isEmpty)
        #expect(try VaultFileSnapshot.capture(of: temp.vault, under: "Gone/Deeper").fingerprints.isEmpty)
        #expect(try VaultFileSnapshot.capture(of: temp.vault, under: "Link.md").fingerprints.isEmpty)
        #expect(try VaultFileSnapshot.capture(of: temp.vault, under: "Dangling.md").fingerprints.isEmpty)
        #expect(try VaultFileSnapshot.capture(of: temp.vault).fingerprints.keys.sorted() == ["Projects/Plan.md"])
    }

    @Test(
        "a note readable again after a failed capture is processed, and real deletion is still detected",
        .enabled(if: geteuid() != 0, "root ignores file permissions")
    )
    func recoveryAfterFailedCapture() throws {
        let temp = try TemporaryVault()
        try temp.write("# Plan\n", to: "Projects/Plan.md")
        try temp.write("# Old\n", to: "Old.md")
        let previous = try VaultFileSnapshot.capture(of: temp.vault)
        try temp.write("# Plan\n\nMore\n", to: "Projects/Plan.md")
        let unreadable = try temp.makeUnreadable("Projects/Plan.md")
        #expect(throws: VaultSnapshotError.self) { try VaultFileSnapshot.capture(of: temp.vault) }
        unreadable.restore()
        try FileManager.default.removeItem(at: temp.vault.rootURL.appending(path: "Old.md"))

        let changes = BrainRunChanges(since: previous, current: try VaultFileSnapshot.capture(of: temp.vault))

        #expect(changes.changed == ["Projects/Plan.md"])
        #expect(changes.deleted == ["Old.md"])
    }
}

