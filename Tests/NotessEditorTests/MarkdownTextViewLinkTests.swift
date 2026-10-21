import AppKit
import NotessCore
import Testing
@testable import NotessEditor

@MainActor
@Suite("Web links in the Markdown editor")
struct MarkdownTextViewLinkTests {
    @MainActor
    private final class Harness {
        let window: NSWindow
        let textView: MarkdownTextView

        init(_ text: String) {
            let scrollView = MarkdownTextViewFactory.makeScrollView()
            textView = scrollView.documentView as! MarkdownTextView
            window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 700, height: 400),
                styleMask: [.titled],
                backing: .buffered,
                defer: true
            )
            window.isReleasedWhenClosed = false
            window.contentView = scrollView
            scrollView.frame = window.contentLayoutRect
            textView.string = text
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(textView)
            window.contentView?.layoutSubtreeIfNeeded()
        }

        func click(_ substring: String, modifiers: NSEvent.ModifierFlags) throws {
            let range = (textView.string as NSString).range(of: substring)
            try click(range: range, modifiers: modifiers)
        }

        func click(range: NSRange, modifiers: NSEvent.ModifierFlags) throws {
            let screenRect = textView.firstRect(forCharacterRange: range, actualRange: nil)
            let point = window.convertFromScreen(screenRect).center
            let down = try #require(NSEvent.mouseEvent(
                with: .leftMouseDown,
                location: point,
                modifierFlags: modifiers,
                timestamp: 0,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 1,
                clickCount: 1,
                pressure: 1
            ))
            textView.mouseDown(with: down)
        }

        func webLinkEvent(_ substring: String, modifiers: NSEvent.ModifierFlags) throws -> Bool {
            let range = (textView.string as NSString).range(of: substring)
            return try webLinkEvent(range: range, modifiers: modifiers)
        }

        func webLinkEvent(range: NSRange, modifiers: NSEvent.ModifierFlags) throws -> Bool {
            let point = point(for: range)
            let event = try #require(NSEvent.mouseEvent(
                with: .leftMouseDown,
                location: textView.convert(point, to: nil),
                modifierFlags: modifiers,
                timestamp: 0,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 1,
                clickCount: 1,
                pressure: 1
            ))
            return textView.openWebLink(with: event, at: point)
        }

        func point(for substring: String) -> NSPoint {
            point(for: (textView.string as NSString).range(of: substring))
        }

        private func point(for range: NSRange) -> NSPoint {
            let screenRect = textView.firstRect(forCharacterRange: range, actualRange: nil)
            return textView.convert(window.convertFromScreen(screenRect).center, from: nil)
        }
    }

    @Test("Command-clicking a bare HTTPS address requests opening it")
    func commandClickBareAddress() throws {
        let text = "Visit https://example.com/docs today."
        let harness = Harness(text)
        var opened: [URL] = []
        harness.textView.onOpenWebLink = {
            opened.append($0)
        }

        try harness.click("https://example.com/docs", modifiers: .command)

        #expect(opened == [URL(string: "https://example.com/docs")!])
        #expect(harness.textView.string == text)
        #expect(harness.textView.textLayoutManager != nil)
    }

    @Test("Command-clicking a Markdown link label opens its HTTP destination")
    func commandClickMarkdownLabel() throws {
        let harness = Harness("Read [the documentation](http://example.com/docs \"Docs\").")
        var opened: [URL] = []
        harness.textView.onOpenWebLink = {
            opened.append($0)
        }

        try harness.click("the documentation", modifiers: .command)
        try harness.click("http://example.com/docs", modifiers: .command)

        #expect(opened == [
            URL(string: "http://example.com/docs")!,
            URL(string: "http://example.com/docs")!
        ])
    }

    @Test("an ordinary click edits instead of opening a web link")
    func ordinaryClickPlacesCaret() throws {
        let harness = Harness("Visit https://example.com/docs today.")
        var opened: [URL] = []
        harness.textView.onOpenWebLink = {
            opened.append($0)
        }
        let consumed = try harness.webLinkEvent("https://example.com/docs", modifiers: [])

        #expect(opened.isEmpty)
        #expect(consumed == false)
    }

    @Test("URL-like text in code and scheme-less addresses stay inactive")
    func codeAndSchemeLessStayInactive() throws {
        let harness = Harness("`https://inline.example`\n```\nhttp://fenced.example\n```\nwww.example.com")
        var opened: [URL] = []
        harness.textView.onOpenWebLink = {
            opened.append($0)
        }

        #expect(try harness.webLinkEvent("https://inline.example", modifiers: .command) == false)
        #expect(try harness.webLinkEvent("http://fenced.example", modifiers: .command) == false)
        #expect(try harness.webLinkEvent("www.example.com", modifiers: .command) == false)

        #expect(opened.isEmpty)
    }

    @Test("web-link handling preserves ordinary and Command-click Wiki-link navigation")
    func wikiLinksRemainUnchanged() throws {
        let harness = Harness("See [[Acme#Plan]] and https://example.com.")
        var wikiLinks: [WikiLink] = []
        var webLinks: [URL] = []
        harness.textView.onWikiLinkClick = { wikiLinks.append($0) }
        harness.textView.onOpenWebLink = {
            webLinks.append($0)
        }

        try harness.click("Acme", modifiers: [])
        try harness.click("Plan", modifiers: .command)

        #expect(wikiLinks.map(\.target) == ["Acme", "Acme"])
        #expect(wikiLinks.map(\.section) == ["Plan", "Plan"])
        #expect(webLinks.isEmpty)
    }

}

private extension NSRect {
    var center: NSPoint { NSPoint(x: midX, y: midY) }
}
