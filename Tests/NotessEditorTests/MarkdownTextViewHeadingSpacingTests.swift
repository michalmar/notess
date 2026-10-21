import AppKit
import Testing
@testable import NotessEditor

/// Headings get half a body-text line above and below, measured in the real
/// TextKit 2 layout; the text itself never changes.
@MainActor
@Suite("Heading spacing in the editor")
struct MarkdownTextViewHeadingSpacingTests {
    private func makeView(_ text: String, fontSize: CGFloat) -> (NSWindow, MarkdownTextView) {
        let scrollView = MarkdownTextViewFactory.makeScrollView(
            style: MarkdownEditorStyle(fontName: "System", fontSize: fontSize)
        )
        let textView = scrollView.documentView as! MarkdownTextView
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = scrollView
        scrollView.frame = window.contentLayoutRect
        textView.string = text
        window.contentView?.layoutSubtreeIfNeeded()
        textView.layoutSubtreeIfNeeded()
        return (window, textView)
    }

    /// Text height of `text` minus its lines' own heights: the paragraph spacing.
    private func addedSpace(_ text: String, fontSize: CGFloat) -> CGFloat {
        let (window, view) = makeView(text, fontSize: fontSize)
        _ = window
        let manager = view.textLayoutManager!
        manager.ensureLayout(for: manager.documentRange)
        var lines: CGFloat = 0
        manager.enumerateTextSegments(in: manager.documentRange, type: .standard, options: []) { _, frame, _, _ in
            lines += frame.height
            return true
        }
        return manager.usageBoundsForTextContainer.height - lines
    }

    @Test("every heading level gains half a body line above and below", arguments: 1...6, [12.0, 15.0, 22.5, 45.0])
    func halfBodyLineEachSide(level: Int, size: Double) {
        let size = CGFloat(size)
        let half = MarkdownEditorStyle(fontName: "System", fontSize: size).headingSpacing
        let body = NSFont.systemFont(ofSize: size)
        #expect(abs(half - (body.ascender - body.descender + body.leading) / 2) < 1)

        let heading = String(repeating: "#", count: level) + " Nadpis"
        let space = addedSpace("tělo\n\(heading)\ntělo", fontSize: size)
        let plain = addedSpace("tělo\ntělo\ntělo", fontSize: size)
        #expect(abs((space - plain) - 2 * half) < 0.01)
    }

    @Test("a heading at the very top still gets space below, and no text is added")
    func topHeading() {
        let size: CGFloat = 15
        let text = "# Nadpis\ntělo"
        let (_, view) = makeView(text, fontSize: size)
        #expect(view.string == text)
        let half = MarkdownEditorStyle(fontName: "System", fontSize: size).headingSpacing
        #expect(addedSpace(text, fontSize: size) - addedSpace("Nadpis\ntělo", fontSize: size) >= half)
    }

    @Test("a setext heading keeps its underline together and spaces the pair")
    func setext() {
        let size: CGFloat = 15
        let half = MarkdownEditorStyle(fontName: "System", fontSize: size).headingSpacing
        let space = addedSpace("tělo\nNadpis\n===\ntělo", fontSize: size)
        let plain = addedSpace("tělo\ntělo\ntělo\ntělo", fontSize: size)
        #expect(abs((space - plain) - 2 * half) < 0.01)
    }

    @Test("the spacing scales with font size, not with the heading size")
    func scales() {
        let small = MarkdownEditorStyle(fontName: "System", fontSize: 15).headingSpacing
        let zoomed = MarkdownEditorStyle(fontName: "System", fontSize: 30).headingSpacing
        #expect(abs(zoomed - 2 * small) <= 1)
    }

    @Test("changing the style recomputes the spacing")
    func restyle() {
        let (_, view) = makeView("tělo\n# Nadpis\ntělo", fontSize: 15)
        view.markdownStyle = MarkdownEditorStyle(fontName: "System", fontSize: 30)
        view.layoutSubtreeIfNeeded()
        let range = (view.string as NSString).range(of: "Nadpis")
        let style = view.textStorage!.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle
        #expect(style?.paragraphSpacingBefore == MarkdownEditorStyle(fontName: "System", fontSize: 30).headingSpacing)
        #expect(style?.paragraphSpacing == style?.paragraphSpacingBefore)
    }
}
