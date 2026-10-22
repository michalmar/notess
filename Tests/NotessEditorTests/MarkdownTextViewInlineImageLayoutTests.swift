import AppKit
import Testing
@testable import NotessEditor

/// Inline image previews sit under the whole Markdown source of their
/// paragraph, including paragraphs outside the visible area (issue #104).
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

        /// The bottom of the last line of the first paragraph containing `substring`.
        func paragraphBottom(of substring: String) throws -> CGFloat {
            let text = textView.string as NSString
            let found = text.range(of: substring)
            try #require(found.location != NSNotFound)
            var paragraph = text.paragraphRange(for: found)
            while paragraph.length > 0, text.character(at: paragraph.upperBound - 1) == 10 {
                paragraph.length -= 1
            }
            let manager = try #require(textView.textLayoutManager)
            let content = try #require(manager.textContentManager)
            manager.ensureLayout(for: content.documentRange)
            manager.textViewportLayoutController.layoutViewport()
            let start = try #require(content.location(content.documentRange.location, offsetBy: paragraph.location))
            let end = try #require(content.location(start, offsetBy: paragraph.length))
            var bottom = -CGFloat.infinity
            manager.enumerateTextSegments(
                in: try #require(NSTextRange(location: start, end: end)), type: .standard, options: []
            ) { _, frame, _, _ in
                bottom = max(bottom, frame.maxY + textView.textContainerOrigin.y)
                return true
            }
            return bottom
        }

        /// The top of the first line containing `substring`.
        func lineTop(of substring: String) throws -> CGFloat {
            let text = textView.string as NSString
            let found = text.range(of: substring)
            try #require(found.location != NSNotFound)
            let manager = try #require(textView.textLayoutManager)
            let content = try #require(manager.textContentManager)
            manager.ensureLayout(for: content.documentRange)
            manager.textViewportLayoutController.layoutViewport()
            let start = try #require(content.location(content.documentRange.location, offsetBy: found.location))
            let end = try #require(content.location(start, offsetBy: 1))
            var top = CGFloat.infinity
            manager.enumerateTextSegments(
                in: try #require(NSTextRange(location: start, end: end)), type: .standard, options: []
            ) { _, frame, _, _ in
                top = min(top, frame.minY + textView.textContainerOrigin.y)
                return false
            }
            return top
        }

        func imageFrame(for substring: String) throws -> NSRect {
            let location = (textView.string as NSString).range(of: substring).location
            return try #require(
                textView.inlineImageFrames.first { NSLocationInRange(location, $0.range) }?.frame
            )
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
            let slug = name.replacingOccurrences(of: " ", with: "-")
            return "# \(name)\n![](attachments/image-dc67de7d-3977-4194-8a80-0056c338935e-\(slug).png)\n\nText under \(name).\n"
        }.joined(separator: "\n")
    }

    private static func source(of name: String) -> String {
        "0056c338935e-\(name.replacingOccurrences(of: " ", with: "-")).png"
    }

    @Test("an image sits below every wrapped line of its Markdown source")
    func belowWrappedSource() throws {
        let harness = try Harness(Self.note())
        let name = Self.sections[0]

        let frame = try harness.imageFrame(for: Self.source(of: name))

        try #expect(frame.minY >= harness.paragraphBottom(of: Self.source(of: name)))
        try #expect(frame.maxY <= harness.lineTop(of: "Text under \(name)."))
    }

    @Test("images below the visible area sit under their own source, between it and the next text")
    func offscreenImages() throws {
        let harness = try Harness(Self.note())

        try expectEachImageUnderItsSource(harness)
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
        harness.textView.insertText("Intro line that is long enough to wrap in this narrow window.\n\n", replacementRange: NSRange(location: 0, length: 0))
        harness.settle()

        try expectEachImageUnderItsSource(harness)
    }

    @Test("images stay under their source after scrolling and resizing the window")
    func afterScrollAndResize() throws {
        let harness = try Harness(Self.note())
        let clip = harness.scrollView.contentView
        clip.scroll(to: NSPoint(x: 0, y: max(0, harness.textView.bounds.height - clip.bounds.height)))
        harness.scrollView.reflectScrolledClipView(clip)
        harness.settle()
        harness.window.setContentSize(NSSize(width: 300, height: 300))
        harness.scrollView.frame = harness.window.contentLayoutRect
        harness.settle()

        try expectEachImageUnderItsSource(harness)
    }

    private func expectEachImageUnderItsSource(_ harness: Harness) throws {
        #expect(harness.textView.inlineImageFrames.count == Self.sections.count)
        for name in Self.sections {
            let frame = try harness.imageFrame(for: Self.source(of: name))
            let bottom = try harness.paragraphBottom(of: Self.source(of: name))
            let next = try harness.lineTop(of: "Text under \(name).")
            #expect(frame.height > 0, "\(name)")
            #expect(frame.minX >= harness.textView.textContainerOrigin.x, "\(name)")
            #expect(frame.maxX <= harness.textView.bounds.width, "\(name)")
            #expect(frame.minY >= bottom, "\(name): image \(frame), source bottom \(bottom)")
            #expect(frame.maxY <= next, "\(name): image \(frame), next text top \(next)")
        }
    }
}
