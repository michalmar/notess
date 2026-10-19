import AppKit
import NotessCore
import Testing
@testable import NotessEditor

/// Text zoom reaches the editor as a style whose font size is the configured
/// size times the zoom (see `AppSettings.effectiveEditorFontSize`).
@MainActor
@Suite("Text zoom in the editor")
struct MarkdownTextViewZoomTests {
    private static let baseSize: CGFloat = 15

    @MainActor
    private final class Harness {
        let window: NSWindow
        let scrollView: NSScrollView
        let textView: MarkdownTextView

        init(_ text: String, size: CGFloat = 400, fontName: String = "System", fontSize: CGFloat = MarkdownTextViewZoomTests.baseSize) {
            scrollView = MarkdownTextViewFactory.makeScrollView(
                style: MarkdownEditorStyle(fontName: fontName, fontSize: fontSize)
            )
            textView = scrollView.documentView as! MarkdownTextView
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: size), styleMask: [.titled], backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            window.contentView = scrollView
            scrollView.frame = window.contentLayoutRect
            textView.string = text
            layout()
        }

        func layout() {
            window.contentView?.layoutSubtreeIfNeeded()
            textView.layoutSubtreeIfNeeded()
        }

        func zoom(base: CGFloat = MarkdownTextViewZoomTests.baseSize, by zoom: CGFloat, fontName: String = "System") {
            textView.markdownStyle = MarkdownEditorStyle(fontName: fontName, fontSize: base * zoom)
            layout()
        }

        func font(at substring: String, offset: Int = 0) -> NSFont? {
            let range = (textView.string as NSString).range(of: substring)
            precondition(range.location != NSNotFound, "\(substring) not found")
            return textView.textStorage!.attribute(.font, at: range.location + offset, effectiveRange: nil) as? NSFont
        }

        /// The Y coordinate (view coordinates) of the line containing `substring`.
        func lineTop(of substring: String) -> CGFloat {
            let range = (textView.string as NSString).range(of: substring)
            var top: CGFloat = 0
            textView.textLayoutManager!.enumerateTextSegments(
                in: textRange(range),
                type: .standard,
                options: []
            ) { _, frame, _, _ in
                top = frame.minY + textView.textContainerOrigin.y
                return false
            }
            return top
        }

        private func textRange(_ range: NSRange) -> NSTextRange {
            let manager = textView.textLayoutManager!
            let content = manager.textContentManager!
            let start = content.location(content.documentRange.location, offsetBy: range.location)!
            let end = content.location(start, offsetBy: range.length)!
            return NSTextRange(location: start, end: end)!
        }

        var visibleTop: CGFloat { scrollView.contentView.bounds.minY }

        func scroll(toTopOf substring: String) {
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: lineTop(of: substring)))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }

    private final class Counter: @unchecked Sendable { var value = 0 }

    private static let document = """
    # Nadpis 1
    ## Nadpis 2
    ### Nadpis 3
    Text s `kódem` a **tučným** a *kurzívou*.

    ```
    blok kódu
    ```

    | A | B |
    | --- | --- |
    | bunka | druhá |
    """

    @Test("body, headings, code and tables scale from the base size", arguments: [0.5, 1.0, 1.5, 3.0])
    func scalesProportionally(zoom: Double) throws {
        let zoom = CGFloat(zoom)
        let harness = Harness(Self.document)
        harness.zoom(by: zoom)
        let size = Self.baseSize * zoom
        let codeBase = MarkdownEditorStyle(fontName: "System", fontSize: size).codeFont.pointSize

        #expect(try #require(harness.font(at: "Text s")).pointSize == size)
        #expect(try #require(harness.font(at: "Nadpis 1")).pointSize == size * 1.6)
        #expect(try #require(harness.font(at: "Nadpis 2")).pointSize == size * 1.35)
        #expect(try #require(harness.font(at: "Nadpis 3")).pointSize == size * 1.15)
        #expect(try #require(harness.font(at: "kódem")).pointSize == codeBase)
        #expect(try #require(harness.font(at: "blok kódu")).pointSize == codeBase)
        #expect(try #require(harness.font(at: "bunka")).pointSize == size)
        let header = try #require(harness.font(at: "A", offset: 0))
        #expect(header.pointSize == size)
        #expect(try #require(harness.font(at: "tučným")).fontDescriptor.symbolicTraits.contains(.bold))
        #expect(try #require(harness.font(at: "kurzívou")).fontDescriptor.symbolicTraits.contains(.italic))
        #expect(harness.textView.string == Self.document)
    }

    @Test("zoom keeps the configured font family and follows a base size change")
    func keepsFamilyAndBaseSize() throws {
        let harness = Harness("Text", fontName: "Menlo-Regular", fontSize: 12)
        harness.zoom(base: 12, by: 1.5, fontName: "Menlo-Regular")
        #expect(try #require(harness.font(at: "Text")).fontName == "Menlo-Regular")
        #expect(try #require(harness.font(at: "Text")).pointSize == 18)

        harness.zoom(base: 20, by: 1.5, fontName: "Menlo-Regular")
        #expect(try #require(harness.font(at: "Text")).pointSize == 30)
    }

    @Test("text reflows to the editor width: more lines when zoomed in")
    func reflows() throws {
        let words = String(repeating: "slovo ", count: 200)
        let harness = Harness(words)
        func height() -> CGFloat {
            harness.textView.textLayoutManager!.usageBoundsForTextContainer.height
        }
        let normal = height()
        harness.zoom(by: 2)
        let zoomed = height()
        #expect(zoomed > normal * 3)
        harness.scrollView.frame.size.width = 900
        harness.window.setContentSize(NSSize(width: 900, height: 400))
        harness.scrollView.frame = harness.window.contentLayoutRect
        harness.layout()
        #expect(height() < zoomed)
    }

    @Test("zooming changes neither the text, the selection, nor the editing state")
    func preservesSelectionAndState() {
        let harness = Harness("Jeden dva tři čtyři")
        harness.textView.setSelectedRange(NSRange(location: 5, length: 3))
        harness.window.makeFirstResponder(harness.textView)

        harness.zoom(by: 1.5)

        #expect(harness.textView.string == "Jeden dva tři čtyři")
        #expect(harness.textView.selectedRange() == NSRange(location: 5, length: 3))
        #expect(harness.textView.isEditable)
        #expect(harness.window.firstResponder === harness.textView)
        #expect(harness.textView.textLayoutManager != nil)

        harness.textView.isEditable = false
        harness.zoom(by: 2)
        #expect(!harness.textView.isEditable)
    }

    @Test("zoom does not add an undo step or notify about a text change")
    func zoomIsNotAnEdit() throws {
        let harness = Harness("abc")
        let counter = Counter()
        let observer = NotificationCenter.default.addObserver(
            forName: NSText.didChangeNotification, object: harness.textView, queue: nil
        ) { _ in counter.value += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }
        let undoManager = try #require(harness.textView.undoManager)
        undoManager.groupsByEvent = false
        undoManager.beginUndoGrouping()
        harness.textView.setSelectedRange(NSRange(location: 3, length: 0))
        harness.textView.insertText("d", replacementRange: harness.textView.selectedRange())
        undoManager.endUndoGrouping()
        #expect(counter.value == 1)

        harness.zoom(by: 2)
        harness.zoom(by: 0.5)

        #expect(counter.value == 1)
        #expect(undoManager.canUndo)
        undoManager.undo()
        #expect(harness.textView.string == "abc")
    }

    @Test("text typed after zooming uses the effective font")
    func typingUsesEffectiveFont() throws {
        let harness = Harness("abc")
        harness.zoom(by: 2)
        harness.textView.setSelectedRange(NSRange(location: 3, length: 0))
        harness.textView.insertText("d", replacementRange: harness.textView.selectedRange())

        #expect(harness.textView.string == "abcd")
        #expect(try #require(harness.font(at: "abcd", offset: 3)).pointSize == Self.baseSize * 2)
    }

    @Test("inline image display sizes do not change with text zoom")
    func imagesKeepSize() throws {
        let harness = Harness("before\n![](attachments/image.png)\nafter")
        harness.textView.noteURL = URL(filePath: "/Vault/Notes/Idea.md")
        let png = try #require(Self.png())
        harness.textView.inlineImageData = { _ in png }
        harness.textView.refreshInlineImages()
        harness.layout()
        let imageView = try #require(harness.textView.subviews.compactMap { $0 as? NSImageView }.first)
        let before = imageView.frame.size

        harness.zoom(by: 3)
        harness.textView.refreshInlineImages()
        harness.layout()

        let after = try #require(harness.textView.subviews.compactMap { $0 as? NSImageView }.first).frame.size
        #expect(after == before)
    }

    @Test("a pinch reports its magnification and leaves the note untouched")
    func pinchReportsMagnification() {
        let harness = Harness("Text")
        var reported: [CGFloat] = []
        harness.textView.onMagnify = { reported.append($0) }

        harness.textView.handleMagnification(0.2)
        harness.textView.handleMagnification(-0.1)

        #expect(reported == [0.2, -0.1])
        #expect(harness.textView.string == "Text")
    }

    @Test("the reading position survives zooming, even with the caret off-screen")
    func keepsReadingAnchor() {
        let text = (1...300).map { "Řádek \($0) a nějaký delší text, aby se řádek zalomil při větším zvětšení." }.joined(separator: "\n")
        let harness = Harness(text)
        harness.textView.setSelectedRange(NSRange(location: 0, length: 0))
        harness.scroll(toTopOf: "Řádek 150 ")
        #expect(abs(harness.lineTop(of: "Řádek 150 ") - harness.visibleTop) < 5)

        for zoom in [1.5, 3.0, 0.5, 1.0] as [CGFloat] {
            harness.zoom(by: zoom)
            let offset = harness.lineTop(of: "Řádek 150 ") - harness.visibleTop
            #expect(abs(offset) < 30 * zoom, "line 150 moved by \(offset) at \(zoom)x")
            #expect(harness.textView.selectedRange() == NSRange(location: 0, length: 0))
        }
    }

    private static func png() -> Data? {
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 1, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }
}
