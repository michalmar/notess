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
        #expect(document.lastSaveWrittenFileURLs == [attachment.fileURL, noteURL])
    }

    @Test("a save reports only the files it wrote")
    func lastSaveWrittenFileURLs() throws {
        let temp = try TemporaryVault()
        try temp.write("# Idea\n", to: "Notes/Idea.md")
        let noteURL = temp.vault.rootURL.appending(path: "Notes/Idea.md")
        let document = try NoteDocument.open(fileURL: noteURL, newFileContent: "")

        try document.save()
        #expect(document.lastSaveWrittenFileURLs.isEmpty)

        document.text += "edit"
        try document.save()
        #expect(document.lastSaveWrittenFileURLs == [noteURL])

        try temp.write("# Idea\n\nchanged elsewhere\n", to: "Notes/Idea.md")
        document.text += " more"
        #expect(throws: NoteDocument.SaveError.self) { try document.save() }
        #expect(document.lastSaveWrittenFileURLs.isEmpty)
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

        document.text += attachment.markdown
        try document.save()

        #expect(try Data(contentsOf: attachment.fileURL) == Data("image".utf8))
    }
    @Test("an image gets its own line without disturbing the surrounding text", arguments: [
        ("", NSRange(location: 0, length: 0), "IMG"),
        ("text", NSRange(location: 0, length: 0), "IMG\n"),
        ("text", NSRange(location: 4, length: 0), "\nIMG"),
        ("ab cd", NSRange(location: 2, length: 0), "\nIMG\n"),
        ("line\n\nnext", NSRange(location: 5, length: 0), "IMG"),
        ("line\nnext", NSRange(location: 4, length: 0), "\nIMG"),
        ("line\nnext", NSRange(location: 5, length: 0), "IMG\n"),
        ("a sel b", NSRange(location: 2, length: 3), "\nIMG\n"),
        ("sel\nb", NSRange(location: 0, length: 3), "IMG"),
        ("a\r\nb", NSRange(location: 3, length: 0), "IMG\n"),
    ])
    func standaloneLine(text: String, range: NSRange, expected: String) {
        #expect(NoteAttachment.standaloneLine("IMG", replacing: range, in: text) == expected)
    }

    @Test("a saved image survives reopening with readable bytes and its link")
    func saveAndReopen() throws {
        let temp = try TemporaryVault()
        let noteURL = temp.vault.rootURL.appending(path: "Journal/2026/10/2026-10-15.md")
        let document = try NoteDocument.open(fileURL: noteURL, newFileContent: "# 15. 10.\n")
        let attachment = document.stageAttachment(data: pngBytes, fileExtension: "png")
        document.text += attachment.markdown

        try document.save()

        let reopened = try NoteDocument.open(fileURL: noteURL, newFileContent: "")
        #expect(reopened.text == "# 15. 10.\n\(attachment.markdown)")
        #expect(reopened.stagedAttachmentData(relativePath: attachment.relativePath) == nil)
        let imageURL = noteURL.deletingLastPathComponent().appending(path: attachment.relativePath)
        #expect(try Data(contentsOf: imageURL) == pngBytes)
        #expect(attachment.relativePath.hasPrefix("attachments/"))
    }

    @Test("discarding unsaved edits writes no image")
    func discardWritesNothing() throws {
        let temp = try TemporaryVault()
        try temp.write("# Idea\n", to: "Notes/Idea.md")
        let noteURL = temp.vault.rootURL.appending(path: "Notes/Idea.md")
        let document = try NoteDocument.open(fileURL: noteURL, newFileContent: "")
        let attachment = document.stageAttachment(data: pngBytes, fileExtension: "png")
        document.text += attachment.markdown
        #expect(document.stagedAttachmentData(relativePath: attachment.relativePath) == pngBytes)

        try document.reloadFromDisk()
        try document.save()

        #expect(document.text == "# Idea\n")
        #expect(document.stagedAttachmentData(relativePath: attachment.relativePath) == nil)
        #expect(temp.fileExists("Notes/attachments") == false)
    }

    @Test("removing a saved image link keeps the image file")
    func removingSavedLinkKeepsFile() throws {
        let temp = try TemporaryVault()
        let noteURL = temp.vault.rootURL.appending(path: "Notes/Idea.md")
        let document = try NoteDocument.open(fileURL: noteURL, newFileContent: "# Idea\n")
        let attachment = document.stageAttachment(data: pngBytes, fileExtension: "png")
        document.text += attachment.markdown
        try document.save()

        document.text = "# Idea\n"
        try document.save()

        #expect(try temp.read("Notes/Idea.md") == "# Idea\n")
        #expect(try Data(contentsOf: attachment.fileURL) == pngBytes)
    }

    @Test("a failed image write fails the save and keeps the edit")
    func imageWriteFailure() throws {
        let temp = try TemporaryVault()
        try temp.write("# Idea\n", to: "Notes/Idea.md")
        // A file where the attachments folder should be makes the image write fail.
        try temp.write("", to: "Notes/attachments")
        let noteURL = temp.vault.rootURL.appending(path: "Notes/Idea.md")
        let document = try NoteDocument.open(fileURL: noteURL, newFileContent: "")
        let attachment = document.stageAttachment(data: pngBytes, fileExtension: "png")
        document.text += attachment.markdown

        #expect(throws: (any Error).self) { try document.save() }

        #expect(try temp.read("Notes/Idea.md") == "# Idea\n")
        #expect(document.hasUnsavedChanges)
        #expect(document.stagedAttachmentData(relativePath: attachment.relativePath) == pngBytes)

        try FileManager.default.removeItem(at: temp.vault.rootURL.appending(path: "Notes/attachments"))
        try document.save()
        #expect(try Data(contentsOf: attachment.fileURL) == pngBytes)
    }

    @Test("a save conflict writes no image until the user keeps their version")
    func conflictKeepsImageStaged() throws {
        let temp = try TemporaryVault()
        try temp.write("# Idea\n", to: "Notes/Idea.md")
        let noteURL = temp.vault.rootURL.appending(path: "Notes/Idea.md")
        let document = try NoteDocument.open(fileURL: noteURL, newFileContent: "")
        let attachment = document.stageAttachment(data: pngBytes, fileExtension: "png")
        document.text += attachment.markdown
        try temp.write("# Idea\n\nchanged elsewhere\n", to: "Notes/Idea.md")

        #expect(throws: NoteDocument.SaveError.changedOnDisk) { try document.save() }
        #expect(temp.fileExists("Notes/attachments") == false)

        document.keepMine()
        try document.save()
        #expect(try Data(contentsOf: attachment.fileURL) == pngBytes)
        #expect(try temp.read("Notes/Idea.md") == "# Idea\n\(attachment.markdown)")
    }
}

/// A 1×1 PNG.
private let pngBytes = Data(base64Encoded:
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
)!
