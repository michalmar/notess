import AppKit
import NotessCore
import SwiftUI
import Testing
@testable import NotessEditor

/// Cmd+V in a real editor window. Tests use a private pasteboard, except one
/// that needs the real clipboard (AppKit validates Paste against it) and
/// restores the user's clipboard contents afterwards.
@MainActor
@Suite("Clipboard paste")
struct MarkdownTextViewPasteTests {
    @MainActor
    private final class Harness {
        let window: NSWindow
        let textView: MarkdownTextView
        let pasteboard: NSPasteboard
        let editMenu = NSMenu(title: "Úpravy")
        let pasteItem = NSMenuItem(title: "Vložit", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        let coordinator = MarkdownEditor.Coordinator()
        var staged: [String: Data] = [:]
        var failures: [Error] = []
        var reportedTexts: [String] = []
        var changeNotifications = 0
        private var observer: NSObjectProtocol?

        init(_ text: String, selection: NSRange? = nil, pasteboard: NSPasteboard = .withUniqueName()) {
            self.pasteboard = pasteboard
            let scrollView = MarkdownTextViewFactory.makeScrollView()
            textView = scrollView.documentView as! MarkdownTextView
            window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                styleMask: [.titled],
                backing: .buffered,
                defer: true
            )
            window.isReleasedWhenClosed = false
            window.contentView = scrollView
            scrollView.frame = window.contentLayoutRect
            textView.string = text
            textView.setSelectedRange(selection ?? NSRange(location: (text as NSString).length, length: 0))
            window.makeFirstResponder(textView)
            textView.pasteboard = pasteboard
            textView.noteURL = URL(filePath: "/NotessTests-nonexistent/Journal/2026/10/2026-10-15.md")
            textView.onPasteImage = { [unowned self] data, fileExtension in
                let path = "attachments/image-\(staged.count + 1).\(fileExtension)"
                staged[path] = data
                return "![](\(path))"
            }
            textView.inlineImageData = { [unowned self] in staged[$0] }
            textView.onPasteImageFailure = { [unowned self] in failures.append($0) }

            // The SwiftUI wrapper's delegate, which reports edits to the document.
            textView.delegate = coordinator
            coordinator.onTextChange = { [unowned self] in reportedTexts.append($0) }
            observer = NotificationCenter.default.addObserver(
                forName: NSText.didChangeNotification, object: textView, queue: nil
            ) { [unowned self] _ in MainActor.assumeIsolated { changeNotifications += 1 } }

            pasteItem.keyEquivalentModifierMask = .command
            editMenu.addItem(pasteItem)
            textView.undoManager?.groupsByEvent = false
        }

        func close() {
            if let observer { NotificationCenter.default.removeObserver(observer) }
            if pasteboard != .general { pasteboard.releaseGlobally() }
            window.close()
        }

        /// The object AppKit sends a nil-targeted menu action to when this
        /// window is key: the first responder chain, then the window.
        private func responderChainTarget(for action: Selector) -> AnyObject? {
            var responder: NSResponder? = window.firstResponder
            while let current = responder {
                if current.responds(to: action) { return current }
                responder = current.nextResponder
            }
            return nil
        }

        /// Whether Edit ▸ Paste is enabled, as validated by the menu.
        var isPasteEnabled: Bool {
            pasteItem.target = responderChainTarget(for: #selector(NSText.paste(_:)))
            editMenu.update()
            return pasteItem.isEnabled
        }

        /// Presses Cmd+V: the menu matches the key equivalent, validates the
        /// Paste item and sends `paste:` to the responder chain. One undo step.
        func pressCommandV() {
            pasteItem.target = responderChainTarget(for: #selector(NSText.paste(_:)))
            let event = NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: .command,
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                characters: "v",
                charactersIgnoringModifiers: "v",
                isARepeat: false,
                keyCode: 9
            )!
            textView.undoManager?.beginUndoGrouping()
            _ = editMenu.performKeyEquivalent(with: event)
            textView.undoManager?.endUndoGrouping()
        }

        func type(_ text: String) {
            textView.undoManager?.beginUndoGrouping()
            textView.insertText(text, replacementRange: textView.selectedRange())
            textView.undoManager?.endUndoGrouping()
        }

        func putPNG(_ data: Data) {
            pasteboard.clearContents()
            pasteboard.setData(data, forType: .png)
        }
    }

    @Test("Cmd+V is enabled for an image-only clipboard and inserts a standalone image", arguments: [
        ("", NSRange(location: 0, length: 0), "![](attachments/image-1.png)", 28),
        ("text", NSRange(location: 0, length: 0), "![](attachments/image-1.png)\ntext", 29),
        ("ab cd", NSRange(location: 2, length: 0), "ab\n![](attachments/image-1.png)\n cd", 32),
        ("text", NSRange(location: 4, length: 0), "text\n![](attachments/image-1.png)", 33),
        ("one\ntwo", NSRange(location: 4, length: 0), "one\n![](attachments/image-1.png)\ntwo", 33),
        ("keep REPLACE keep", NSRange(location: 5, length: 7), "keep \n![](attachments/image-1.png)\n keep", 35),
        ("REPLACE\nkeep", NSRange(location: 0, length: 7), "![](attachments/image-1.png)\nkeep", 28),
    ])
    func pasteImage(text: String, selection: NSRange, expected: String, caret: Int) throws {
        let harness = Harness(text, selection: selection)
        defer { harness.close() }
        let png = try #require(makePNG(width: 3, height: 2))
        harness.putPNG(png)

        #expect(harness.isPasteEnabled)
        harness.pressCommandV()

        #expect(harness.textView.string == expected)
        #expect(harness.textView.selectedRange() == NSRange(location: caret, length: 0))
        #expect(harness.staged == ["attachments/image-1.png": png])
        #expect(harness.failures.isEmpty)
    }

    @Test("Cmd+V pastes a screenshot from the real clipboard, which is then restored")
    func generalClipboard() throws {
        let general = NSPasteboard.general
        let saved = ClipboardSnapshot(general)
        defer { saved.restore(to: general) }

        let harness = Harness("Ráno", pasteboard: general)
        defer { harness.close() }
        general.clearContents()
        general.setData(try #require(makePNG(width: 2, height: 2)), forType: .png)

        // AppKit's own validation disables Paste here: a plain-text view reads no images.
        #expect(harness.isPasteEnabled)
        harness.pressCommandV()

        #expect(harness.textView.string == "Ráno\n![](attachments/image-1.png)")
        #expect(harness.staged.count == 1)
        #expect(harness.textView.displayedInlineImageCount == 1)
    }

    @Test("a pasted image renders inline at once from staged bytes and reports the edit")
    func pastedImageRendersAndNotifies() throws {
        let harness = Harness("Poznámka\n")
        defer { harness.close() }
        harness.putPNG(try #require(makePNG(width: 40, height: 20)))

        harness.pressCommandV()

        let expected = "Poznámka\n![](attachments/image-1.png)"
        #expect(harness.textView.string == expected)
        #expect(harness.textView.displayedInlineImageCount == 1)
        #expect(harness.changeNotifications == 1)
        #expect(harness.reportedTexts == [expected])
        #expect(FileManager.default.fileExists(atPath: "/NotessTests-nonexistent") == false)
    }

    @Test("a TIFF clipboard image is converted to a lossless PNG")
    func tiffIsConvertedToPNG() throws {
        let harness = Harness("")
        defer { harness.close() }
        let bitmap = try #require(makeBitmap(width: 5, height: 3))
        bitmap.setColor(NSColor(deviceRed: 1, green: 0.5, blue: 0.25, alpha: 1), atX: 1, y: 1)
        let tiff = try #require(bitmap.tiffRepresentation)
        harness.pasteboard.clearContents()
        harness.pasteboard.setData(tiff, forType: .tiff)

        #expect(harness.isPasteEnabled)
        harness.pressCommandV()

        #expect(harness.textView.string == "![](attachments/image-1.png)")
        let png = try #require(harness.staged["attachments/image-1.png"])
        #expect(png.starts(with: [0x89, 0x50, 0x4E, 0x47]))
        let decoded = try #require(NSBitmapImageRep(data: png))
        #expect(decoded.pixelsWide == 5)
        #expect(decoded.pixelsHigh == 3)
        let pixel = try #require(decoded.colorAt(x: 1, y: 1))
        let original = try #require(bitmap.colorAt(x: 1, y: 1))
        #expect(pixel.redComponent == original.redComponent)
        #expect(pixel.greenComponent == original.greenComponent)
        #expect(pixel.blueComponent == original.blueComponent)
    }

    @Test("an image paste is undone and redone as one step")
    func undoRedo() throws {
        let harness = Harness("ab")
        defer { harness.close() }
        harness.type("c")
        harness.putPNG(try #require(makePNG(width: 2, height: 2)))
        harness.pressCommandV()
        let pasted = "abc\n![](attachments/image-1.png)"
        #expect(harness.textView.string == pasted)
        let undoManager = try #require(harness.textView.undoManager)

        undoManager.undo()
        #expect(harness.textView.string == "abc")
        #expect(harness.reportedTexts.last == "abc")
        #expect(harness.textView.displayedInlineImageCount == 0)

        undoManager.redo()
        #expect(harness.textView.string == pasted)
        #expect(harness.reportedTexts.last == pasted)
        #expect(harness.textView.displayedInlineImageCount == 1)

        undoManager.undo()
        undoManager.undo()
        #expect(harness.textView.string == "ab")
        #expect(harness.reportedTexts.last == "ab")
    }

    @Test("plain text pastes as before, even when an image preview comes with it")
    func textPaste() throws {
        let harness = Harness("before  after", selection: NSRange(location: 7, length: 0))
        defer { harness.close() }
        harness.pasteboard.clearContents()
        harness.pasteboard.setString("plain text", forType: .string)
        harness.pasteboard.setData(try #require(makePNG(width: 2, height: 2)), forType: .png)

        #expect(harness.isPasteEnabled)
        harness.pressCommandV()

        #expect(harness.textView.string == "before plain text after")
        #expect(harness.staged.isEmpty)
        #expect(harness.reportedTexts == ["before plain text after"])

        harness.textView.undoManager?.undo()
        #expect(harness.textView.string == "before  after")
    }

    @Test("an unreadable clipboard image is reported and inserts nothing")
    func unreadableImage() {
        let harness = Harness("text")
        defer { harness.close() }
        harness.putPNG(Data("not an image".utf8))

        #expect(harness.isPasteEnabled)
        harness.pressCommandV()

        #expect(harness.textView.string == "text")
        #expect(harness.staged.isEmpty)
        #expect(harness.failures.map { $0 as? ImagePasteError } == [.unreadableImage])
        #expect(harness.changeNotifications == 0)
    }

    @Test("Paste stays disabled where an image cannot go")
    func pasteDisabled() throws {
        let png = try #require(makePNG(width: 2, height: 2))

        let readOnly = Harness("Brain Note")
        defer { readOnly.close() }
        readOnly.textView.isEditable = false
        readOnly.putPNG(png)
        #expect(readOnly.isPasteEnabled == false)

        let noHandler = Harness("")
        defer { noHandler.close() }
        noHandler.textView.onPasteImage = nil
        noHandler.putPNG(png)
        #expect(noHandler.isPasteEnabled == false)

        let emptyClipboard = Harness("")
        defer { emptyClipboard.close() }
        emptyClipboard.pasteboard.clearContents()
        #expect(emptyClipboard.isPasteEnabled == false)
    }

    @Test("a file copied in Finder is not pasted as an image")
    func fileURLIsNotAnImage() throws {
        let harness = Harness("")
        defer { harness.close() }
        harness.pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(URL(filePath: "/tmp/screenshot.png").absoluteString, forType: .fileURL)
        item.setData(try #require(makeBitmap(width: 2, height: 2)?.tiffRepresentation), forType: .tiff)
        harness.pasteboard.writeObjects([item])

        harness.pressCommandV()

        #expect(harness.staged.isEmpty)
        #expect(harness.textView.string.contains("![](") == false)
    }

    /// The SwiftUI editor wired to a `NoteDocument` like the app's editor screen.
    @Test("pasting into the hosted editor stages the image until explicit save")
    func hostedEditorStagesUntilSave() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "NotessEditorTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let noteURL = root.appending(path: "Journal/2026/10/2026-10-15.md")
        let document = try NoteDocument.open(fileURL: noteURL, newFileContent: "# 15. 10. 2026\n")
        var failures: [Error] = []
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        func host() throws -> MarkdownTextView {
            window.contentView = NSHostingView(rootView: MarkdownEditor(
                documentID: UUID(),
                initialText: { document.text },
                noteURL: document.fileURL,
                onPasteImage: { data, fileExtension in
                    document.stageAttachment(data: data, fileExtension: fileExtension).markdown
                },
                onPasteImageFailure: { failures.append($0) },
                inlineImageData: { document.stagedAttachmentData(relativePath: $0) },
                onTextChange: { document.text = $0 }
            ))
            window.contentView?.layoutSubtreeIfNeeded()
            let textView = try #require(window.contentView?.firstSubview(of: MarkdownTextView.self))
            window.makeFirstResponder(textView)
            return textView
        }
        let textView = try host()
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        textView.pasteboard = pasteboard
        let png = try #require(makePNG(width: 8, height: 4))
        pasteboard.clearContents()
        pasteboard.setData(png, forType: .png)
        let item = NSMenuItem(title: "Vložit", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        #expect(textView.validateMenuItem(item))

        NSApp.sendAction(#selector(NSText.paste(_:)), to: textView, from: item)

        let link = try #require(textView.string.firstMatch(of: /!\[\]\((attachments\/image-[0-9a-f-]+\.png)\)/))
        let relativePath = String(link.output.1)
        #expect(textView.string == "# 15. 10. 2026\n\(link.output.0)")
        #expect(document.text == textView.string)
        #expect(document.hasUnsavedChanges)
        #expect(textView.displayedInlineImageCount == 1)
        #expect(FileManager.default.fileExists(atPath: root.path) == false)
        #expect(failures.isEmpty)

        try document.save()

        let imageURL = noteURL.deletingLastPathComponent().appending(path: relativePath)
        #expect(try Data(contentsOf: imageURL) == png)
        #expect(try String(contentsOf: noteURL, encoding: .utf8) == document.text)

        let reopened = try NoteDocument.open(fileURL: noteURL, newFileContent: "")
        let reopenedView = MarkdownTextViewFactory.makeScrollView().documentView as! MarkdownTextView
        window.contentView = reopenedView.enclosingScrollView
        reopenedView.string = reopened.text
        reopenedView.noteURL = noteURL
        reopenedView.inlineImageData = { reopened.stagedAttachmentData(relativePath: $0) }
        reopenedView.refreshInlineImages()
        #expect(reopenedView.displayedInlineImageCount == 1)
    }
}

private func makeBitmap(width: Int, height: Int) -> NSBitmapImageRep? {
    NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: width,
        pixelsHigh: height,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )
}

private func makePNG(width: Int, height: Int) -> Data? {
    makeBitmap(width: width, height: height)?.representation(using: .png, properties: [:])
}

private extension NSView {
    func firstSubview<T: NSView>(of type: T.Type) -> T? {
        for subview in subviews {
            if let match = subview as? T ?? subview.firstSubview(of: type) { return match }
        }
        return nil
    }
}

/// A copy of a pasteboard's items, written back after a test changes it.
@MainActor
private struct ClipboardSnapshot {
    private let items: [[(NSPasteboard.PasteboardType, Data)]]

    init(_ pasteboard: NSPasteboard) {
        items = (pasteboard.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
    }

    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let restored = items.map { entries in
            let item = NSPasteboardItem()
            for (type, data) in entries { item.setData(data, forType: type) }
            return item
        }
        if !restored.isEmpty { pasteboard.writeObjects(restored) }
    }
}
