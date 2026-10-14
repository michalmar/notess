import Foundation
import Testing
@testable import NotessCore

@MainActor
@Suite("Note attachments")
struct NoteAttachmentTests {
    @Test("attachment paths are unique, relative, and beside the note")
    func attachmentPath() {
        let noteURL = URL(filePath: "/Vault/Journal/2026/10/2026-10-14.md")

        let first = NoteAttachment.plan(
            data: Data("first".utf8),
            fileExtension: "PNG",
            for: noteURL,
            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        )
        let second = NoteAttachment.plan(
            data: Data("second".utf8),
            fileExtension: "png",
            for: noteURL,
            id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        )

        #expect(first.relativePath == "attachments/image-aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee.png")
        #expect(first.fileURL.path == "/Vault/Journal/2026/10/attachments/image-aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee.png")
        #expect(first.markdown == "![](attachments/image-aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee.png)")
        #expect(first.relativePath != second.relativePath)
    }

    @Test("a staged attachment is written only when the note is saved")
    func attachmentFollowsExplicitSave() throws {
        let temp = try TemporaryVault()
        let noteURL = temp.vault.rootURL.appending(path: "Notes/Idea.md")
        let document = try NoteDocument.open(fileURL: noteURL, newFileContent: "# Idea\n\n")
        let bytes = Data([0x89, 0x50, 0x4E, 0x47])

        let attachment = document.stageAttachment(
            data: bytes,
            fileExtension: "png",
            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        )
        document.text += attachment.markdown

        #expect(temp.fileExists(attachment.fileURL.path) == false)

        try document.save()

        #expect(try Data(contentsOf: attachment.fileURL) == bytes)
        #expect(try temp.read("Notes/Idea.md") == "# Idea\n\n\(attachment.markdown)")
    }

    @Test("removing a staged image link before save does not create an orphan")
    func removedAttachmentIsNotSaved() throws {
        let temp = try TemporaryVault()
        let noteURL = temp.vault.rootURL.appending(path: "Notes/Idea.md")
        let document = try NoteDocument.open(fileURL: noteURL, newFileContent: "# Idea\n\n")
        let attachment = document.stageAttachment(data: Data("image".utf8), fileExtension: "png")
        document.text += "another edit"

        try document.save()

        #expect(FileManager.default.fileExists(atPath: attachment.fileURL.path) == false)
    }
}
