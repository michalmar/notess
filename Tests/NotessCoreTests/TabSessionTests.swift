import Foundation
import Testing
@testable import NotessCore

@MainActor
@Suite("Managing open note tabs")
struct TabSessionTests {
    @Test("opening an already open file selects its existing tab")
    func openingDuplicateSelectsExistingTab() throws {
        let temp = try TemporaryVault()
        try temp.write("First", to: "Notes/first.md")
        try temp.write("Second", to: "Notes/second.md")
        let session = TabSession()
        let firstURL = temp.vault.rootURL.appending(path: "Notes/first.md")
        let secondURL = temp.vault.rootURL.appending(path: "Notes/second.md")

        let first = try session.openNote(at: firstURL)
        _ = try session.openNote(at: secondURL)
        let reopened = try session.openNote(at: firstURL)

        #expect(session.documents.count == 2)
        #expect(reopened === first)
        #expect(session.activeDocument === first)
    }

    @Test("different paths to the same existing file share one tab")
    func existingFileIdentityPreventsDuplicateTabs() throws {
        let temp = try TemporaryVault()
        try temp.write("Plan", to: "Notes/Plan.md")
        let original = temp.vault.rootURL.appending(path: "Notes/Plan.md")
        let alias = temp.vault.rootURL.appending(path: "Notes/plan-alias.md")
        try FileManager.default.linkItem(at: original, to: alias)
        let session = TabSession()

        let first = try session.openNote(at: original)
        let reopened = try session.openNote(at: alias)

        #expect(session.documents.count == 1)
        #expect(reopened === first)
    }

    @Test("missing file paths follow their volume's case sensitivity")
    func missingFilePathsUseVolumeCaseSensitivity() throws {
        let temp = try TemporaryVault()
        let supportsCaseSensitiveNames = try #require(
            temp.vault.rootURL.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
                .volumeSupportsCaseSensitiveNames as Bool?
        )
        let session = TabSession()

        _ = try session.openNote(
            at: temp.vault.rootURL.appending(path: "Notes/Draft.md"),
            newFileContent: "Draft"
        )
        _ = try session.openNote(
            at: temp.vault.rootURL.appending(path: "Notes/draft.md"),
            newFileContent: "Draft"
        )

        #expect(session.documents.count == (supportsCaseSensitiveNames ? 2 : 1))
    }

    @Test("closing a tab preserves order and selects its next neighbor")
    func closingTabSelectsNeighbor() throws {
        let temp = try TemporaryVault()
        try temp.write("First", to: "first.md")
        try temp.write("Second", to: "second.md")
        try temp.write("Third", to: "third.md")
        let session = TabSession()
        let first = try session.openNote(at: temp.vault.rootURL.appending(path: "first.md"))
        let second = try session.openNote(at: temp.vault.rootURL.appending(path: "second.md"))
        let third = try session.openNote(at: temp.vault.rootURL.appending(path: "third.md"))
        session.select(documentID: second.id)

        session.closeTab(documentID: second.id)

        #expect(session.documents.map(\.id) == [first.id, third.id])
        #expect(session.activeDocument === third)
    }

    @Test("unsaved changes are reported per tab and across the session")
    func unsavedChangesAreReported() throws {
        let temp = try TemporaryVault()
        try temp.write("First", to: "first.md")
        try temp.write("Second", to: "second.md")
        let session = TabSession()
        let first = try session.openNote(at: temp.vault.rootURL.appending(path: "first.md"))
        let second = try session.openNote(at: temp.vault.rootURL.appending(path: "second.md"))

        first.text = "Edited"

        #expect(first.hasUnsavedChanges)
        #expect(second.hasUnsavedChanges == false)
        #expect(session.hasUnsavedChanges)
        #expect(session.unsavedDocuments.map(\.id) == [first.id])
    }

    @Test("restoration state preserves tab order and active tab")
    func restorationStatePreservesOrderAndSelection() throws {
        let temp = try TemporaryVault()
        try temp.write("First", to: "Notes/first.md")
        try temp.write("Second", to: "Notes/second.md")
        let session = TabSession()
        let first = try session.openNote(at: temp.vault.rootURL.appending(path: "Notes/first.md"))
        _ = try session.openNote(at: temp.vault.rootURL.appending(path: "Notes/second.md"))
        session.select(documentID: first.id)

        let state = session.restorationState(relativeTo: temp.vault.rootURL)

        #expect(state.relativePaths == ["Notes/first.md", "Notes/second.md"])
        #expect(state.activeRelativePath == "Notes/first.md")
    }
}
