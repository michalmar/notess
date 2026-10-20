import AppKit
import Testing
@testable import NotessEditor

@MainActor
@Suite("Heading folding")
struct HeadingFoldingTests {
    @Test("the keyboard command folds the heading at the end-of-document caret")
    func keyboardFoldAtEnd() throws {
        let textView = MarkdownTextViewFactory.makeReadOnlyTextView()
        textView.string = "## Last\nbody\nmore text"
        let expanded = textView.fittingHeight(forWidth: 500)
        textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
        let item = NSMenuItem(
            title: "Fold", action: #selector(MarkdownTextView.toggleHeadingFold(_:)), keyEquivalent: ""
        )
        #expect(textView.validateMenuItem(item))
        textView.toggleHeadingFold(nil)
        #expect(textView.fittingHeight(forWidth: 500) < expanded - 15)
        textView.toggleHeadingFold(nil)
        #expect(abs(textView.fittingHeight(forWidth: 500) - expanded) < 1)
    }

    @Test("fold controls follow heading edits, ignore code and reset for another document")
    func headingEdits() throws {
        let textView = MarkdownTextViewFactory.makeReadOnlyTextView()
        textView.string = "Title\r\n=====\r\ntext\r\n```\r\n# Code\r\n```\r\n###### Deep\r\nbody"
        _ = textView.fittingHeight(forWidth: 500)
        let buttons = textView.subviews.compactMap { $0 as? NSButton }
        #expect(buttons.count == 2)
        let fullHeight = textView.fittingHeight(forWidth: 500)
        buttons[0].performClick(nil)
        #expect(textView.fittingHeight(forWidth: 500) < fullHeight - 30)
        textView.string = "# Another\nbody"
        #expect(textView.subviews.compactMap { $0 as? NSButton }.first?.state == .on)

        textView.isEditable = true
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.insertText("## New\nbody\n", replacementRange: NSRange(location: 0, length: 0))
        #expect(textView.subviews.compactMap { $0 as? NSButton }.count == 2)
        let newHeading = try #require(textView.subviews.compactMap { $0 as? NSButton }.first)
        newHeading.performClick(nil)
        let foldedHeight = textView.fittingHeight(forWidth: 500)
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.insertText("prefix\n", replacementRange: NSRange(location: 0, length: 0))
        let movedHeading = try #require(textView.subviews.compactMap { $0 as? NSButton }.first)
        #expect(movedHeading.state == .off)
        #expect(textView.fittingHeight(forWidth: 500) > foldedHeight)
        movedHeading.performClick(nil)
        #expect(movedHeading.state == .on)
    }

    @Test("folding also hides trailing inline images and their reserved height")
    func foldedImages() throws {
        let textView = MarkdownTextViewFactory.makeReadOnlyTextView()
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 80, pixelsHigh: 80, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        ))
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        textView.inlineImageData = { _ in data }
        textView.noteURL = URL(filePath: "/Vault/Journal/note.md")
        textView.string = "# Images\n![](attachments/image.png)"
        textView.refreshInlineImages()
        let expanded = textView.fittingHeight(forWidth: 500)
        let button = try #require(textView.subviews.compactMap { $0 as? NSButton }.first)
        button.performClick(nil)
        textView.refreshInlineImages()
        #expect(textView.fittingHeight(forWidth: 500) < expanded - 80)
        #expect(textView.subviews.compactMap { $0 as? NSImageView }.allSatisfy { $0.isHidden })
        button.performClick(nil)
        textView.refreshInlineImages()
        #expect(abs(textView.fittingHeight(forWidth: 500) - expanded) < 1)
    }

    @Test("nested folds survive folding their parent and reveal safely for editing")
    func nestedEditableFolding() throws {
        let scrollView = MarkdownTextViewFactory.makeScrollView()
        let textView = try #require(scrollView.documentView as? MarkdownTextView)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled], backing: .buffered, defer: true
        )
        window.isReleasedWhenClosed = false
        window.contentView = scrollView
        defer { window.close() }
        let markdown = "# Parent\nintro\n## Child\nhidden\n### Grandchild\nnested\n# Next\nvisible"
        textView.string = markdown
        let expanded = textView.fittingHeight(forWidth: 500)
        let buttons = textView.subviews.compactMap { $0 as? NSButton }
        try #require(buttons.count == 4)
        buttons[1].performClick(nil)
        let childFolded = textView.fittingHeight(forWidth: 500)
        #expect(childFolded < expanded)
        buttons[0].performClick(nil)
        #expect(textView.fittingHeight(forWidth: 500) < childFolded)
        buttons[0].performClick(nil)
        #expect(abs(textView.fittingHeight(forWidth: 500) - childFolded) < 1)
        #expect(textView.string == markdown)
        #expect(textView.undoManager?.canUndo != true)

        let hidden = (markdown as NSString).range(of: "hidden")
        textView.setSelectedRange(hidden)
        #expect(abs(textView.fittingHeight(forWidth: 500) - expanded) < 1)
        textView.insertText("changed", replacementRange: hidden)
        #expect(textView.string.contains("## Child\nchanged\n### Grandchild\nnested"))
        textView.undoManager?.undo()
        #expect(textView.string == markdown)
    }

    @Test("read-only headings collapse their subtree without changing Markdown")
    func readOnlyFolding() throws {
        let textView = MarkdownTextViewFactory.makeReadOnlyTextView()
        textView.string = "# Topic 1\nbody\n## Child\nchild text\n# Topic 2\nother text"
        let expanded = textView.fittingHeight(forWidth: 500)
        let button = try #require(textView.subviews.compactMap { $0 as? NSButton }.first)
        button.performClick(nil)
        let collapsed = textView.fittingHeight(forWidth: 500)
        #expect(collapsed < expanded - 20)
        #expect(textView.string == "# Topic 1\nbody\n## Child\nchild text\n# Topic 2\nother text")
        #expect(textView.isEditable == false)
        button.performClick(nil)
        #expect(abs(textView.fittingHeight(forWidth: 500) - expanded) < 1)
        #expect(textView.textLayoutManager != nil)
    }
}
