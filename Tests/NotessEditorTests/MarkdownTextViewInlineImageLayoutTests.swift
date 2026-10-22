import AppKit
import Testing
@testable import NotessEditor

/// Inline image previews are drawn under the whole Markdown source of their
/// paragraph, on open and once scrolled to (issue #104).
@MainActor
@Suite("Inline image layout")
struct MarkdownTextViewInlineImageLayoutTests {
    @MainActor
    private final class Harness {
        let window: NSWindow
        let scrollView: NSScrollView
        let textView: MarkdownTextView

        init(_ text: String, width: CGFloat = 400, height: CGFloat = 300) throws {
            scrollView = MarkdownTextViewFactory.makeScrollView()
            textView = try #require(scrollView.documentView as? MarkdownTextView)
            window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                styleMask: [.titled, .resizable], backing: .buffered, defer: false
            )
            window.isReleasedWhenClosed = false
            window.contentView = scrollView
            scrollView.frame = window.contentLayoutRect
            textView.string = text
            textView.noteURL = URL(filePath: "/Vault/Notes/Idea.md")
            let png = try #require(Self.png(width: 1_600, height: 900))
            textView.inlineImageData = { _ in png }
            textView.refreshInlineImages()
            settle()
        }

        func settle() {
            window.contentView?.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        }

        func scroll(toY y: CGFloat) {
            let clip = scrollView.contentView
            clip.scroll(to: NSPoint(x: 0, y: min(max(0, y), max(0, textView.bounds.height - clip.bounds.height))))
            scrollView.reflectScrolledClipView(clip)
            settle()
        }

        func scrollToVisible(_ substring: String) {
            textView.scrollRangeToVisible((textView.string as NSString).range(of: substring))
            settle()
        }

        /// The drawn line rect of the character at `offset` from where `substring`
        /// starts (a negative offset counts back from its end), via the screen rect
        /// AppKit reports for it, so independent of how the editor places images.
        func lineRect(of substring: String, at offset: Int = 0) throws -> NSRect {
            let found = (textView.string as NSString).range(of: substring)
            try #require(found.location != NSNotFound)
            let index = offset >= 0 ? found.location + offset : found.upperBound + offset
            let rect = textView.rect(forCharacterRange: NSRange(location: index, length: 1))
            try #require(rect.height > 0, "\(substring) is not on screen")
            return rect
        }

        func imageFrame(for substring: String) -> NSRect? {
            let location = (textView.string as NSString).range(of: substring).location
            return textView.visibleInlineImageFrames.first { NSLocationInRange(location, $0.range) }?.frame
        }

        static func png(width: Int, height: Int) -> Data? {
            guard let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 0, bitsPerPixel: 0
            ) else { return nil }
            return bitmap.representation(using: .png, properties: [:])
        }
    }

    private static let sections = ["Foundry IQ", "Work IQ", "Web IQ", "Fabric IQ", "Graph IQ"]

    /// Headings each followed by an image whose long Markdown source wraps.
    private static func note() -> String {
        sections.map { name in
            "# \(name)\n![](attachments/image-dc67de7d-3977-4194-8a80-0056c338935e-\(slug(name)).png)\n\nText under \(name).\n"
        }.joined(separator: "\n")
    }

    private static func slug(_ name: String) -> String {
        name.replacingOccurrences(of: " ", with: "-")
    }

    private static func source(of name: String) -> String {
        "![](attachments/image-dc67de7d-3977-4194-8a80-0056c338935e-\(slug(name)).png)"
    }

    @Test("an image is drawn below every wrapped line of its Markdown source")
    func belowWrappedSource() throws {
        let harness = try Harness(Self.note())

        try expectImageUnderItsSource(Self.sections[0], harness)
    }

    @Test("images below the visible area are drawn under their source once scrolled to")
    func offscreenImages() throws {
        let harness = try Harness(Self.note())

        try expectEachImageUnderItsSource(harness)
    }

    @Test("an image whose source is scrolled just above the visible area is still drawn")
    func sourceScrolledAbove() throws {
        let harness = try Harness(Self.note())
        let name = Self.sections[2]
        harness.scrollToVisible(Self.source(of: name))
        let sourceBottom = try harness.lineRect(of: Self.source(of: name), at: -1).maxY

        harness.scroll(toY: sourceBottom + 20)

        let frame = try #require(harness.imageFrame(for: Self.source(of: name)))
        #expect(frame.minY >= sourceBottom)
        #expect(frame.intersects(harness.textView.visibleRect))
    }

    @Test("refreshing the previews of a laid-out note keeps each under its source")
    func refreshAfterLayout() throws {
        let harness = try Harness(Self.note())

        harness.textView.refreshInlineImages()

        try expectEachImageUnderItsSource(harness)
    }

    @Test("typing above the images moves them with their source")
    func editAbove() throws {
        let harness = try Harness(Self.note())
        harness.textView.setSelectedRange(NSRange(location: 0, length: 0))
        harness.textView.insertText(
            "Intro line that is long enough to wrap in this narrow window.\n\n",
            replacementRange: NSRange(location: 0, length: 0)
        )
        harness.settle()

        try expectEachImageUnderItsSource(harness)
    }

    @Test("images stay under their source after scrolling and resizing the window")
    func afterScrollAndResize() throws {
        let harness = try Harness(Self.note())
        harness.scroll(toY: .greatestFiniteMagnitude)
        harness.window.setContentSize(NSSize(width: 300, height: 300))
        harness.scrollView.frame = harness.window.contentLayoutRect
        harness.settle()

        try expectEachImageUnderItsSource(harness)
    }

    private func expectEachImageUnderItsSource(_ harness: Harness) throws {
        #expect(harness.textView.displayedInlineImageCount == Self.sections.count)
        for name in Self.sections {
            harness.scrollToVisible(Self.source(of: name))
            try expectImageUnderItsSource(name, harness)
        }
    }

    private func expectImageUnderItsSource(_ name: String, _ harness: Harness) throws {
        let source = Self.source(of: name)
        let frame = try #require(harness.imageFrame(for: source), "\(name) is not drawn")
        let sourceBottom = try harness.lineRect(of: source, at: -1).maxY
        harness.scrollToVisible("Text under \(name).")
        let nextTop = try harness.lineRect(of: "Text under \(name).").minY
        #expect(frame.height > 0, "\(name)")
        #expect(frame.minX >= harness.textView.textContainerOrigin.x, "\(name)")
        #expect(frame.maxX <= harness.textView.bounds.width, "\(name)")
        #expect(frame.minY >= sourceBottom, "\(name): image \(frame), source bottom \(sourceBottom)")
        #expect(frame.maxY <= nextTop, "\(name): image \(frame), next text top \(nextTop)")
    }
}
