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
}
