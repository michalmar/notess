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

        var buttons: [NSButton] { textView.subviews.compactMap { $0 as? NSButton } }

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

    // MARK: Heading disclosure buttons

    @Test("expanded and collapsed disclosure buttons show the pointing hand over their clickable area only")
    func disclosureButtons() throws {
        let harness = Harness("# Topic\nbody\n# Next\nmore")
        let button = try #require(harness.buttons.first)
        let frame = button.frame
        #expect(frame.width == 20)
        check(harness.textView.pointingHandTarget(containing: frame.center))
        check(harness.textView.pointingHandTarget(containing: NSPoint(x: frame.minX + 1, y: frame.minY + 1)))
        check(!harness.textView.pointingHandTarget(containing: NSPoint(x: frame.maxX + 3, y: frame.midY)))
        check(!harness.hand(over: "Topic"))
        check(!harness.hand(over: "body"))

        button.performClick(nil)
        harness.layout()
        let collapsed = try #require(harness.buttons.first)
        check(harness.textView.pointingHandTarget(containing: collapsed.frame.center))
        check(!harness.hand(over: "Topic"))
        #expect(harness.textView.string == "# Topic\nbody\n# Next\nmore")
    }

    @Test("read-only views show the hand over their disclosure buttons")
    func readOnlyDisclosureButtons() throws {
        let textView = MarkdownTextViewFactory.makeReadOnlyTextView()
        textView.string = "# Topic\nbody\n# Next\nmore"
        _ = textView.fittingHeight(forWidth: 500)
        let button = try #require(textView.subviews.compactMap { $0 as? NSButton }.first)
        check(textView.pointingHandTarget(containing: button.frame.center))
        check(!textView.pointingHandTarget(containing: NSPoint(x: button.frame.maxX + 40, y: button.frame.midY)))
        button.performClick(nil)
        _ = textView.fittingHeight(forWidth: 500)
        check(textView.pointingHandTarget(containing: button.frame.center))
        #expect(textView.isEditable == false)
    }

    @Test("buttons hidden by a fold leave no hand and return on unfolding")
    func hiddenButtons() throws {
        let harness = Harness("# Parent\nintro\n## Child\nhidden\n# Next\nvisible")
        let child = try #require(harness.buttons.dropFirst().first)
        let childCenter = child.frame.center
        check(harness.textView.pointingHandTarget(containing: childCenter))

        harness.buttons[0].performClick(nil)
        harness.layout()
        check(!harness.textView.pointingHandTarget(containing: childCenter))
        check(!harness.textView.pointingHandTarget(containing: child.frame.center))

        harness.buttons[0].performClick(nil)
        harness.layout()
        check(harness.textView.pointingHandTarget(containing: child.frame.center))
    }

    @Test("button targets follow headings after edits and leave obsolete positions")
    func buttonsAfterEditing() throws {
        let harness = Harness("# Topic\nbody")
        let before = try #require(harness.buttons.first).frame.center
        check(harness.textView.pointingHandTarget(containing: before))

        let insertion = NSRange(location: 0, length: 0)
        harness.textView.setSelectedRange(insertion)
        harness.textView.insertText("intro\nmore\n", replacementRange: insertion)
        harness.layout()

        let after = try #require(harness.buttons.first).frame.center
        #expect(after.y > before.y + 20)
        check(harness.textView.pointingHandTarget(containing: after))
        check(!harness.textView.pointingHandTarget(containing: before))
    }

    @Test("only buttons of headings on screen are targets while scrolling")
    func buttonsWhileScrolling() throws {
        let sections = (0..<40).map { "# Heading \($0)\ntext \($0)" }.joined(separator: "\n")
        let harness = Harness(sections)
        let all = harness.buttons
        let top = try #require(all.first)
        check(harness.textView.pointingHandTarget(containing: top.frame.center))
        let bottomLocation = (harness.textView.string as NSString).range(of: "# Heading 39").location
        let bottomBefore = try #require(all.last).frame.center
        check(!harness.textView.pointingHandTarget(containing: bottomBefore))

        harness.textView.scrollRangeToVisible(NSRange(location: bottomLocation, length: 1))
        harness.layout()
        let visibleBottom = try #require(harness.buttons.last)
        check(!visibleBottom.isHidden)
        check(harness.textView.pointingHandTarget(containing: visibleBottom.frame.center))
        check(!harness.textView.pointingHandTarget(containing: top.frame.center))
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
