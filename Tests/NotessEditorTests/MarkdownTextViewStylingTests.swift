import AppKit
import Testing
@testable import NotessEditor

@MainActor
@Suite("Live Markdown formatting")
struct MarkdownTextViewStylingTests {
    /// A text view in an offscreen window, so it has an undo manager.
    @MainActor
    private final class Harness {
        let window: NSWindow
        let textView: MarkdownTextView

        init(_ text: String, style: MarkdownEditorStyle = .standard) {
            let scrollView = MarkdownTextViewFactory.makeScrollView(style: style)
            textView = scrollView.markdownTextView()
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            window.contentView = scrollView
            scrollView.frame = window.contentLayoutRect
            textView.string = text
        }

        func attribute(_ key: NSAttributedString.Key, at substring: String, offset: Int = 0) -> Any? {
            let range = (textView.string as NSString).range(of: substring)
            precondition(range.location != NSNotFound, "\(substring) not found")
            return textView.textStorage!.attribute(key, at: range.location + offset, effectiveRange: nil)
        }

        func font(at substring: String, offset: Int = 0) -> NSFont? {
            attribute(.font, at: substring, offset: offset) as? NSFont
        }

        func color(at substring: String, offset: Int = 0) -> NSColor? {
            attribute(.foregroundColor, at: substring, offset: offset) as? NSColor
        }

        /// Types `text` at `location` like the user would.
        func type(_ text: String, at location: Int) {
            textView.setSelectedRange(NSRange(location: location, length: 0))
            textView.insertText(text, replacementRange: textView.selectedRange())
        }
    }

    private let style = MarkdownEditorStyle.standard

    @Test("formatting keeps the editor on TextKit 2")
    func staysOnTextKit2() {
        let harness = Harness("# Nadpis\n\n**tučně** a [[Odkaz]] #tag")
        #expect(harness.textView.textLayoutManager != nil)
    }

    @Test("headings are larger and bold, markers stay visible but muted")
    func headings() throws {
        let harness = Harness("# Nadpis\nText")
        let heading = try #require(harness.font(at: "Nadpis"))
        let body = try #require(harness.font(at: "Text"))

        #expect(heading.pointSize > body.pointSize)
        #expect(heading.fontDescriptor.symbolicTraits.contains(.bold))
        #expect(harness.textView.string == "# Nadpis\nText")
        #expect(harness.color(at: "# ") == style.colors.syntaxMarker)
        #expect(body.pointSize == style.font.pointSize)
    }

    @Test("strong, emphasis, strikethrough and inline code")
    func inlineStyles() throws {
        let harness = Harness("**tučně** _kurzíva_ ~~pryč~~ `kód`")

        #expect(try #require(harness.font(at: "tučně")).fontDescriptor.symbolicTraits.contains(.bold))
        #expect(try #require(harness.font(at: "kurzíva")).fontDescriptor.symbolicTraits.contains(.italic))
        #expect(harness.attribute(.strikethroughStyle, at: "pryč") as? Int == NSUnderlineStyle.single.rawValue)
        #expect(try #require(harness.font(at: "kód")).isFixedPitch)
        #expect(harness.attribute(.backgroundColor, at: "kód") != nil)
        #expect(harness.color(at: "**") == style.colors.syntaxMarker)
    }

    @Test("wiki-links, links and tags are coloured; tags in code are not")
    func linksAndTags() {
        let harness = Harness("[[Poznámka#Sekce]] [web](https://x.cz) #projekt `#ne`\n```\n#taky-ne\n```")

        #expect(harness.color(at: "Poznámka") == style.colors.wikiLink)
        #expect(harness.color(at: "web") == style.colors.link)
        #expect(harness.color(at: "#projekt") == style.colors.tag)
        #expect(harness.color(at: "#ne") != style.colors.tag)
        #expect(harness.color(at: "#taky-ne") != style.colors.tag)
    }

    @Test("typing restyles the edited line")
    func typingRestyles() throws {
        let harness = Harness("Nadpis\nText")
        harness.type("# ", at: 0)

        #expect(harness.textView.string == "# Nadpis\nText")
        #expect(try #require(harness.font(at: "Nadpis")).pointSize > style.font.pointSize)

        harness.type(" #novy", at: (harness.textView.string as NSString).length)
        #expect(harness.color(at: "#novy") == style.colors.tag)
        #expect(try #require(harness.font(at: "Text")).pointSize == style.font.pointSize)
    }

    @Test("typing a fence restyles the following lines as code")
    func fenceRestylesFollowingLines() throws {
        let harness = Harness("před\n#tag\npo")
        harness.type("```\n", at: 0)

        #expect(try #require(harness.font(at: "#tag")).isFixedPitch)
        #expect(harness.color(at: "#tag") != style.colors.tag)

        harness.textView.undoManager?.undo()
        #expect(harness.textView.string == "před\n#tag\npo")
        #expect(harness.color(at: "#tag") == style.colors.tag)
    }

    @Test("toggling a task changes the text, notifies and is undoable")
    func toggleTask() throws {
        let harness = Harness("- [ ] koupit mléko\n- [x] hotovo")
        var changes = 0
        let observer = NotificationCenter.default.addObserver(
            forName: NSText.didChangeNotification, object: harness.textView, queue: nil
        ) { _ in MainActor.assumeIsolated { changes += 1 } }
        defer { NotificationCenter.default.removeObserver(observer) }

        let undoManager = try #require(harness.textView.undoManager)
        undoManager.groupsByEvent = false
        // Each click is its own event, hence its own undo group.
        func click(_ index: Int) -> Bool {
            undoManager.beginUndoGrouping()
            defer { undoManager.endUndoGrouping() }
            return harness.textView.toggleTask(at: index)
        }

        #expect(click(3))
        #expect(harness.textView.string == "- [x] koupit mléko\n- [x] hotovo")
        #expect(changes == 1)
        #expect(harness.attribute(.strikethroughStyle, at: "koupit") as? Int == NSUnderlineStyle.single.rawValue)

        #expect(click(22))
        #expect(harness.textView.string == "- [x] koupit mléko\n- [ ] hotovo")
        #expect(undoManager.undoActionName == "Přepnout úkol")

        undoManager.undo()
        #expect(harness.textView.string == "- [x] koupit mléko\n- [x] hotovo")
        #expect(harness.textView.toggleTask(at: 9) == false)
    }

    @Test("clicking the box toggles the task, clicking the text does not")
    func clickTaskBox() throws {
        let harness = Harness("- [ ] koupit mléko")
        let textView = harness.textView
        func point(of range: NSRange) throws -> NSPoint {
            let window = try #require(textView.window)
            let rect = window.convertFromScreen(textView.firstRect(forCharacterRange: range, actualRange: nil))
            let local = textView.convert(rect, from: nil)
            return NSPoint(x: local.midX, y: local.midY)
        }

        #expect(textView.toggleTask(atPoint: try point(of: NSRange(location: 8, length: 3))) == false)
        #expect(textView.string == "- [ ] koupit mléko")

        #expect(textView.toggleTask(atPoint: try point(of: NSRange(location: 2, length: 3))))
        #expect(textView.string == "- [x] koupit mléko")
    }

    @Test("a new style restyles the note")
    func styleChange() throws {
        let harness = Harness("# Nadpis\nText")
        var custom = MarkdownEditorStyle(font: .systemFont(ofSize: 20))
        custom.colors.tag = .systemGreen
        harness.textView.markdownStyle = custom

        #expect(try #require(harness.font(at: "Text")).pointSize == 20)
        #expect(try #require(harness.font(at: "Nadpis")).pointSize > 20)
        #expect((harness.textView.typingAttributes[.font] as? NSFont)?.pointSize == 20)
    }

    @Test("the style is built from the Settings font, falling back to the system font")
    func styleFromSettings() {
        let menlo = MarkdownEditorStyle(fontName: "Menlo-Regular", fontSize: 18)
        #expect(menlo.font.fontName == "Menlo-Regular")
        #expect(menlo.font.pointSize == 18)
        #expect(menlo.codeFont.pointSize < 18)

        #expect(MarkdownEditorStyle(fontName: "System", fontSize: 13).font == .systemFont(ofSize: 13))
        #expect(MarkdownEditorStyle(fontName: "No Such Font", fontSize: 13).font == .systemFont(ofSize: 13))
    }

    @Test("typing in a long note restyles only nearby lines")
    func longNoteTyping() {
        let line = "- [ ] úkol s **tučným** textem, [[odkazem]] a #tagem\n"
        let harness = Harness(String(repeating: line, count: 5_000))
        let middle = (harness.textView.string as NSString).length / 2

        let clock = ContinuousClock()
        let elapsed = clock.measure {
            for _ in 0..<50 { harness.type("x", at: middle) }
        }
        #expect(elapsed < .seconds(2), "50 keystrokes took \(elapsed)")
    }
}

private extension NSScrollView {
    func markdownTextView() -> MarkdownTextView {
        documentView as! MarkdownTextView
    }
}
