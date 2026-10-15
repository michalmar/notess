import AppKit
import Testing
@testable import NotessEditor

@MainActor
@Suite("Read-only Markdown view")
struct ReadOnlyMarkdownViewTests {
    private static let markdown = """
        ## Porada #acme
        - [ ] úkol
        Text sekce, který je dost dlouhý na to, aby se v úzkém sloupci zalomil do více řádků.
        """

    private func makeTextView(_ text: String = markdown) -> (NSWindow, MarkdownTextView) {
        let textView = MarkdownTextViewFactory.makeReadOnlyTextView()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = textView
        textView.string = text
        return (window, textView)
    }

    @Test("shows the Markdown with live formatting on TextKit 2, without its own scroll view")
    func showsFormattedText() throws {
        let (_, textView) = makeTextView()
        #expect(textView.string == Self.markdown)
        #expect(textView.textLayoutManager != nil)
        #expect(textView.enclosingScrollView == nil)
        let heading = try #require(textView.textStorage?.attribute(.font, at: 3, effectiveRange: nil) as? NSFont)
        let body = try #require(textView.textStorage?.attribute(.font, at: (Self.markdown as NSString).length - 3, effectiveRange: nil) as? NSFont)
        #expect(heading.pointSize > body.pointSize)
    }

    @Test("text can be selected and copied but not changed")
    func readOnly() {
        let (_, textView) = makeTextView()
        #expect(textView.isEditable == false)
        #expect(textView.isSelectable)
        #expect(textView.allowsUndo == false)
        #expect(textView.shouldChangeText(in: NSRange(location: 0, length: 0), replacementString: "x") == false)

        let pasteboard = NSPasteboard(name: .init("NotessReadOnlyTests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("vloženo", forType: .string)
        textView.pasteboard = pasteboard
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.paste(nil)
        #expect(textView.string == Self.markdown)
    }

    @Test("task checkboxes cannot be toggled")
    func tasksStayUnchanged() {
        let (_, textView) = makeTextView()
        let box = (Self.markdown as NSString).range(of: "[ ]").location + 1
        #expect(textView.toggleTask(at: box) == false)
        #expect(textView.string == Self.markdown)
    }

    @Test("its height fits the whole wrapped text, so nothing is cut off")
    func fittingHeight() {
        let (_, textView) = makeTextView()
        let wide = textView.fittingHeight(forWidth: 2000)
        let narrow = textView.fittingHeight(forWidth: 160)
        #expect(wide > 0)
        #expect(narrow > wide)

        let (_, longer) = makeTextView(Self.markdown + "\n\n### Další\nřádek\nřádek\nřádek\n")
        #expect(longer.fittingHeight(forWidth: 2000) > wide)
    }

    @Test("images resolve against each Section's own saved note, from saved bytes only")
    func imagesResolveRelativeToSourceNote() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        var sizes: [String: CGFloat] = [:]
        for (directory, width) in [("2026/10", 3), ("2026/09", 5)] {
            let attachments = root.appending(path: "\(directory)/attachments", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: attachments, withIntermediateDirectories: true)
            try pngData(width: width).write(to: attachments.appending(path: "image.png"))
            let (window, textView) = makeTextView("![](attachments/image.png)")
            window.makeKeyAndOrderFront(nil)
            var opened: ImagePreviewContent?
            textView.onOpenImagePreview = { opened = $0 }
            textView.noteURL = root.appending(path: "\(directory)/2026-10-15.md")
            textView.refreshInlineImages()
            #expect(textView.displayedInlineImageCount == 1)
            #expect(clickImage(in: textView, window: window))
            sizes[directory] = opened?.image.size.width
            #expect(textView.isEditable == false)
        }
        #expect(sizes == ["2026/10": 3, "2026/09": 5])
    }

    @Test("an image missing on disk is reported, never silently dropped")
    func missingImageIsReported() {
        let (_, textView) = makeTextView("![](attachments/missing.png)")
        var failures: [String] = []
        textView.onImageLoadFailure = { failures.append($0) }
        textView.noteURL = URL(filePath: "/Vault/2026/10/2026-10-15.md")
        textView.refreshInlineImages()
        #expect(failures == ["Obrázek „attachments/missing.png“ se nepodařilo načíst."])
        #expect(textView.displayedInlineImageCount == 0)
    }

    @Test("an image makes the Section taller, so it is not cut off")
    func imageAddsHeight() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let attachments = root.appending(path: "attachments", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: attachments, withIntermediateDirectories: true)
        try pngData(width: 100).write(to: attachments.appending(path: "image.png"))
        let (window, textView) = makeTextView("Text\n![](attachments/image.png)")
        window.makeKeyAndOrderFront(nil)
        let before = textView.fittingHeight(forWidth: 400)
        textView.noteURL = root.appending(path: "2026-10-15.md")
        textView.refreshInlineImages()
        #expect(textView.fittingHeight(forWidth: 400) > before)
    }

    private func clickImage(in textView: MarkdownTextView, window: NSWindow) -> Bool {
        window.makeKeyAndOrderFront(nil)
        textView.refreshInlineImages()
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        guard let imageView = textView.subviews.compactMap({ $0 as? NSImageView }).first else { return false }
        let point = textView.convert(NSPoint(x: imageView.frame.midX, y: imageView.frame.midY), to: nil)
        guard let down = NSEvent.mouseEvent(
            with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1
        ) else { return false }
        textView.mouseDown(with: down)
        return true
    }

    private func pngData(width: Int) throws -> Data {
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: 1, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        ))
        return try #require(bitmap.representation(using: .png, properties: [:]))
    }
}
