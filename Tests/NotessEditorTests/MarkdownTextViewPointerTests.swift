import AppKit
import NotessCore
import Testing
@testable import NotessEditor

@MainActor
@Suite("Pointing-hand hover in the Markdown editor")
struct MarkdownTextViewPointerTests {
    @MainActor
    private final class Harness {
        let window: NSWindow
        let scrollView: NSScrollView
        let textView: MarkdownTextView

        init(_ text: String, isEditable: Bool = true, links: Bool = true) {
            scrollView = MarkdownTextViewFactory.makeScrollView()
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
            if links {
                textView.onOpenWebLink = { _ in }
                textView.onWikiLinkClick = { _ in }
            }
            textView.isEditable = isEditable
            textView.string = text
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(textView)
            layout()
        }

        deinit {
            MainActor.assumeIsolated { window.close() }
        }

        func layout() {
            window.contentView?.layoutSubtreeIfNeeded()
            textView.layoutSubtreeIfNeeded()
        }

        func center(of substring: String) -> NSPoint {
            let range = (textView.string as NSString).range(of: substring)
            return textView.rect(forCharacterRange: range).center
        }

        /// The pointing hand shows at the middle of `substring`.
        func hand(over substring: String) -> Bool {
            textView.pointingHandTarget(containing: center(of: substring))
        }
    }

    @Test("bare URLs, Markdown links and Wiki-links show the pointing hand without modifiers")
    func linksShowPointingHand() {
        let harness = Harness(
            "Visit https://example.com/docs today, read [the guide](http://example.com/guide) or [[Plan#Goals]] now."
        )

        check(harness.hand(over: "https://example.com/docs"))
        check(harness.hand(over: "the guide"))
        check(harness.hand(over: "http://example.com/guide"))
        check(harness.hand(over: "[[Plan#Goals]]"))
    }

    @Test("adjacent ordinary text and empty space keep the text cursor")
    func ordinaryTextHasNoTarget() {
        let harness = Harness("Visit https://example.com/docs today or [[Plan]] later.")

        check(!harness.hand(over: "Visit"))
        check(!harness.hand(over: "today"))
        check(!harness.hand(over: "later"))
        check(!harness.textView.pointingHandTarget(containing: NSPoint(x: 600, y: 300)))
    }

    @Test("code and image syntax are not link targets")
    func excludedSyntax() {
        let harness = Harness(
            "`https://example.com/code`\n\n![alt](https://example.com/a.png)\n\n```\nhttps://example.com/fence [[Fenced]]\n```\n\nhttps://example.com/real"
        )

        check(!harness.hand(over: "https://example.com/code"))
        check(!harness.hand(over: "https://example.com/a.png"))
        check(!harness.hand(over: "https://example.com/fence"))
        check(!harness.hand(over: "[[Fenced]]"))
        check(harness.hand(over: "https://example.com/real"))
    }

    @Test("read-only text views show the hand wherever links are interactive")
    func readOnly() {
        let text = "Visit https://example.com/docs and [[Plan]]."
        let interactive = Harness(text, isEditable: false)
        check(interactive.hand(over: "https://example.com/docs"))
        check(interactive.hand(over: "[[Plan]]"))
        check(!interactive.hand(over: "Visit"))

        let inert = Harness(text, isEditable: false, links: false)
        check(!inert.hand(over: "https://example.com/docs"))
        check(!inert.hand(over: "[[Plan]]"))
    }

    @Test("a link without an activation callback is not a target")
    func callbacksGateTargets() {
        let harness = Harness("https://example.com/docs and [[Plan]]")
        harness.textView.onOpenWebLink = nil
        check(!harness.hand(over: "https://example.com/docs"))
        check(harness.hand(over: "[[Plan]]"))
        harness.textView.onWikiLinkClick = nil
        check(!harness.hand(over: "[[Plan]]"))
    }

    @Test("targets follow the link after edits and leave obsolete positions")
    func editing() {
        let harness = Harness("See https://example.com/docs here")
        let before = harness.center(of: "https://example.com/docs")
        check(harness.textView.pointingHandTarget(containing: before))

        harness.textView.setSelectedRange(NSRange(location: 4, length: 0))
        harness.textView.insertText(String(repeating: "x", count: 40) + " ", replacementRange: NSRange(location: 4, length: 0))
        harness.layout()

        let after = harness.center(of: "https://example.com/docs")
        #expect(after.x > before.x + 100)
        check(harness.textView.pointingHandTarget(containing: after))
        check(!harness.textView.pointingHandTarget(containing: before))

        let link = (harness.textView.string as NSString).range(of: "https://example.com/docs")
        harness.textView.insertText("", replacementRange: link)
        harness.layout()
        check(!harness.textView.pointingHandTarget(containing: after))
    }

    @Test("only links in the visible part of a scrolled note are targets")
    func scrolling() throws {
        let filler = (0..<80).map { "line \($0)" }.joined(separator: "\n")
        let harness = Harness("https://example.com/top\n\(filler)\nhttps://example.com/bottom")
        check(harness.hand(over: "https://example.com/top"))
        let range = (harness.textView.string as NSString).range(of: "https://example.com/bottom")
        check(!harness.hand(over: "https://example.com/bottom"))

        harness.textView.scrollRangeToVisible(range)
        harness.layout()
        check(harness.hand(over: "https://example.com/bottom"))
        check(!harness.textView.pointingHandTarget(containing: harness.center(of: "https://example.com/top")))
    }

    @Test("links hidden by a folded heading are not targets until unfolded")
    func folding() throws {
        let harness = Harness("# Topic\nhttps://example.com/hidden and [[Hidden]]\n# Next\nhttps://example.com/shown")
        let hiddenPoint = harness.center(of: "https://example.com/hidden")
        check(harness.hand(over: "https://example.com/hidden"))

        harness.textView.headingFolding.toggle(at: 0)
        harness.layout()
        check(!harness.textView.pointingHandTarget(containing: hiddenPoint))
        check(!harness.hand(over: "[[Hidden]]"))
        check(harness.hand(over: "https://example.com/shown"))

        harness.textView.headingFolding.toggle(at: 0)
        harness.layout()
        check(harness.hand(over: "https://example.com/hidden"))
        check(harness.hand(over: "[[Hidden]]"))
    }

    @Test("hover feedback leaves click behavior and TextKit 2 unchanged")
    func clicksUnchanged() throws {
        let harness = Harness("Visit https://example.com/docs today.")
        var opened: [URL] = []
        harness.textView.onOpenWebLink = { opened.append($0) }
        let point = harness.center(of: "https://example.com/docs")

        func event(_ modifiers: NSEvent.ModifierFlags) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(
                with: .leftMouseDown,
                location: harness.textView.convert(point, to: nil),
                modifierFlags: modifiers,
                timestamp: 0,
                windowNumber: harness.window.windowNumber,
                context: nil,
                eventNumber: 1,
                clickCount: 1,
                pressure: 1
            ))
        }

        #expect(try harness.textView.openWebLink(with: event([]), at: point) == false)
        #expect(opened.isEmpty)
        #expect(try harness.textView.openWebLink(with: event(.command), at: point))
        #expect(opened == [URL(string: "https://example.com/docs")!])
        #expect(harness.textView.textLayoutManager != nil)
    }
}

private func check(_ condition: Bool, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(condition, sourceLocation: sourceLocation)
}

private extension NSRect {
    var center: NSPoint { NSPoint(x: midX, y: midY) }
}
