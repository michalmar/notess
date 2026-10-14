import Foundation
import Testing
@testable import NotessCore

@Suite struct BrainTests {
    @Test func createsDefaultInstructionsWhenMissing() throws {
        let tv = try TemporaryVault()
        #expect(try tv.vault.ensureBrainInstructions())
        #expect(try tv.read("_brain/AGENTS.md") == BrainInstructions.defaultContent)
    }

    @Test func neverOverwritesExistingInstructions() throws {
        let tv = try TemporaryVault()
        try tv.write("my own rules", to: "_brain/AGENTS.md")
        #expect(try tv.vault.ensureBrainInstructions() == false)
        #expect(try tv.read("_brain/AGENTS.md") == "my own rules")
    }

    @Test func defaultInstructionsListDefaultEntityTypes() {
        #expect(BrainInstructions.entityTypes(in: BrainInstructions.defaultContent) == EntityType.defaults)
        #expect(BrainInstructions.defaultContent.contains("[[YYYY-MM-DD#Section heading]]"))
        #expect(BrainInstructions.defaultContent.contains("aliases:"))
    }

    @Test func parsesCustomEntityTypes() {
        let text = """
        # Rules
        - `ignored/`
        ## Entity types
        Intro text.
        - `people/` — a person
        * `books`
        - not a folder
        - `a/b/`
        - `people/` duplicate
        ```
        - `fenced/`
        ```
        ## Other
        - `later/`
        """
        #expect(BrainInstructions.entityTypes(in: text).map(\.folder) == ["people", "books"])
    }

    @Test func fallsBackToDefaultsWithoutList() throws {
        let tv = try TemporaryVault()
        #expect(tv.vault.entityTypes() == EntityType.defaults)
        try tv.write("# No list here", to: "_brain/AGENTS.md")
        #expect(tv.vault.entityTypes() == EntityType.defaults)
    }

    @Test func groupsBrainNotesByEntityType() throws {
        let tv = try TemporaryVault()
        try tv.write("## Entity types\n- `people/`\n- `books/`\n", to: "_brain/AGENTS.md")
        try tv.write("x", to: "_brain/people/Anna.md")
        try tv.write("x", to: "_brain/people/Bob.md")
        try tv.write("x", to: "_brain/people/readme.txt")
        try tv.write("x", to: "_brain/misc/Thing.md")
        try tv.write("x", to: "_brain/Loose.md")

        let groups = tv.vault.scanTree().brain.groups
        #expect(groups.map(\.title) == ["People", "Books", "Ostatní"])
        #expect(groups[0].notes.map(\.title) == ["Anna", "Bob"])
        #expect(groups[0].notes.map(\.relativePath) == ["_brain/people/Anna.md", "_brain/people/Bob.md"])
        #expect(groups[1].notes.isEmpty)
        #expect(Set(groups[2].notes.map(\.title)) == ["Thing", "Loose"])
    }

    @Test func instructionsFileIsEditableButBrainNotesAreReadOnly() async throws {
        let tv = try TemporaryVault()
        try tv.vault.ensureBrainInstructions()
        try tv.write("x", to: "_brain/people/Anna.md")
        #expect(NoteKind.classify(relativePath: "_brain/AGENTS.md") == .freeNote)
        let instructions = try await tv.vault.openNote(relativePath: "_brain/AGENTS.md")
        let note = try await tv.vault.openNote(relativePath: "_brain/people/Anna.md")
        #expect(await instructions.isReadOnly == false)
        #expect(await note.isReadOnly)
        #expect(tv.vault.scanTree().notes.folders.isEmpty)
    }
}

@Suite struct BrainReviewFixTests {
    @Test func crlfInstructionsAreParsed() {
        let text = "## Entity types\r\n- `books/`\r\n"
        #expect(BrainInstructions.entityTypes(in: text).map(\.folder) == ["books"])
    }

    @Test func symlinkedEntityFolderIsNotScanned() throws {
        let tv = try TemporaryVault()
        let outside = try TemporaryVault()
        try outside.write("x", to: "Secret.md")
        try tv.write("## Entity types\n- `people/`\n", to: "_brain/AGENTS.md")
        try FileManager.default.createSymbolicLink(
            at: tv.vault.rootURL.appendingPathComponent("_brain/people"),
            withDestinationURL: outside.vault.rootURL
        )
        try FileManager.default.createSymbolicLink(
            at: tv.vault.rootURL.appendingPathComponent("_brain/other"),
            withDestinationURL: outside.vault.rootURL
        )
        #expect(tv.vault.scanTree().brain.groups.allSatisfy { $0.notes.isEmpty })
    }

    @MainActor @Test func tabSessionHonoursReadOnlyFlag() throws {
        let tv = try TemporaryVault()
        try tv.write("x", to: "_brain/people/Anna.md")
        let session = TabSession()
        let doc = try session.openNote(
            at: tv.vault.rootURL.appendingPathComponent("_brain/people/Anna.md"),
            isReadOnly: true
        )
        #expect(doc.isReadOnly)
    }
}

@Suite struct BrainSymlinkRootTests {
    @Test func symlinkedBrainFolderIsNeverWrittenOrRead() throws {
        let tv = try TemporaryVault()
        let outside = try TemporaryVault()
        try outside.write("## Entity types\n- `x/`\n", to: "AGENTS.md")
        try outside.write("n", to: "people/A.md")
        try FileManager.default.createSymbolicLink(
            at: tv.vault.rootURL.appendingPathComponent("_brain"),
            withDestinationURL: outside.vault.rootURL
        )
        #expect(throws: (any Error).self) { try tv.vault.ensureBrainInstructions() }
        #expect(tv.vault.entityTypes() == EntityType.defaults)
        #expect(tv.vault.scanTree().brain.groups.allSatisfy { $0.notes.isEmpty })
    }
}
