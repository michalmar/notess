import AppKit
import NotessCore
import Testing
@testable import NotessEditor

@MainActor
@Suite("Clickable Tags in the Markdown editor")
struct MarkdownTextViewTagClickTests {
    @MainActor
    private final class Harness {
        let window: NSWindow
        let textView: MarkdownTextView
        var clicked: [String] = []

        init(_ text: String, isEditable: Bool = true, callback: Bool = true) {
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
            textView.isEditable = isEditable
            textView.string = text
            if callback {
                textView.onTagClick = { [unowned self] in clicked.append($0) }
            }
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

        func center(of substring: String, occurrence: Int = 0) -> NSPoint {
            textView.rect(forCharacterRange: range(of: substring, occurrence: occurrence)).center
        }

        func range(of substring: String, occurrence: Int = 0) -> NSRange {
            let text = textView.string as NSString
            var range = text.range(of: substring)
            for _ in 0..<occurrence {
                let start = NSMaxRange(range)
                range = text.range(of: substring, range: NSRange(location: start, length: text.length - start))
            }
            return range
        }

        func event(at point: NSPoint, modifiers: NSEvent.ModifierFlags, clickCount: Int = 1) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(
                with: .leftMouseDown,
                location: textView.convert(point, to: nil),
                modifierFlags: modifiers,
                timestamp: 0,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 1,
                clickCount: clickCount,
                pressure: 1
            ))
        }

        /// A full `mouseDown`; only for clicks that activate a Tag, since an
        /// unconsumed click starts `NSTextView`'s mouse tracking loop.
        func click(_ substring: String, occurrence: Int = 0, modifiers: NSEvent.ModifierFlags = []) throws {
            textView.mouseDown(with: try event(at: center(of: substring, occurrence: occurrence), modifiers: modifiers))
        }

        /// Whether the Tag-click gesture consumes this click.
        func activates(
            _ substring: String,
            occurrence: Int = 0,
            modifiers: NSEvent.ModifierFlags = [],
            clickCount: Int = 1
        ) throws -> Bool {
            let point = center(of: substring, occurrence: occurrence)
            return textView.openTag(with: try event(at: point, modifiers: modifiers, clickCount: clickCount), at: point)
        }

        func hand(over substring: String, occurrence: Int = 0) -> Bool {
            textView.pointingHandTarget(containing: center(of: substring, occurrence: occurrence))
        }
    }

    @Test("a plain click and a Command+click on a Tag report its normalised name without editing or moving the caret")
    func clickReportsNormalisedTag() throws {
        let text = "Porada #Acme a #Beta-2 dnes"
        let harness = Harness(text)
        let caret = NSRange(location: 2, length: 0)
        harness.textView.setSelectedRange(caret)

        try harness.click("Acme")
        try harness.click("#Beta-2", modifiers: .command)

        #expect(harness.clicked == ["acme", "beta-2"])
        #expect(harness.textView.string == text)
        #expect(harness.textView.selectedRange() == caret)
        #expect(harness.textView.textLayoutManager != nil)
    }

    @Test("#Acme, #ACME and #acme all report the same Tag")
    func caseInsensitive() throws {
        let harness = Harness("#Acme #ACME #acme #Čaj")

        try harness.click("#Acme")
        try harness.click("#ACME")
        try harness.click("#acme")
        try harness.click("#Čaj")

        #expect(harness.clicked == ["acme", "acme", "acme", "čaj"])
    }

    @Test("Tags in code, URLs, link targets and Wiki-links, numbers and headings do not activate")
    func excludedSyntax() throws {
        let harness = Harness(
            "# Heading\n`#inline`\n```\n#fenced\n```\nhttps://example.com/#anchor [label](https://example.com/#target) [[Note#Section]] #2026 #real"
        )

        #expect(try !harness.activates("Heading"))
        #expect(try !harness.activates("# "))
        #expect(try !harness.activates("inline"))
        #expect(try !harness.activates("fenced"))
        #expect(try !harness.activates("anchor"))
        #expect(try !harness.activates("target"))
        #expect(try !harness.activates("Section"))
        #expect(try !harness.activates("2026"))
        #expect(try harness.activates("#real"))
        #expect(harness.clicked == ["real"])
    }

    @Test("other modifiers and a double-click fall through to text selection")
    func otherGesturesSelectText() throws {
        let harness = Harness("Porada #acme dnes")

        #expect(try !harness.activates("acme", modifiers: .option))
        #expect(try !harness.activates("acme", modifiers: .shift))
        #expect(try !harness.activates("acme", modifiers: .control))
        #expect(try !harness.activates("acme", modifiers: [.command, .shift]))
        #expect(try !harness.activates("acme", clickCount: 2))
        #expect(harness.clicked.isEmpty)
        #expect(try harness.activates("acme", modifiers: .command))
    }

    @Test("ordinary text next to a Tag does not activate")
    func adjacentText() throws {
        let harness = Harness("Porada #acme dnes")

        #expect(try !harness.activates("Porada"))
        #expect(try !harness.activates("dnes"))
        #expect(harness.clicked.isEmpty)
    }

    @Test("without a callback a Tag is inert and shows no hand")
    func noCallback() throws {
        let harness = Harness("Porada #acme dnes", callback: false)

        #expect(try !harness.activates("#acme"))
        #expect(!harness.hand(over: "#acme"))
    }

    @Test("Tags hidden by a folded heading neither activate nor show the hand until unfolded")
    func folding() throws {
        let harness = Harness("# Topic\nhidden #secret here\n# Next\nshown #open")
        let hiddenPoint = harness.center(of: "#secret")
        #expect(harness.hand(over: "#secret"))

        harness.textView.headingFolding.toggle(at: 0)
        harness.layout()
        #expect(!harness.textView.pointingHandTarget(containing: hiddenPoint))
        #expect(harness.textView.tag(atPoint: hiddenPoint) == nil)
        #expect(harness.hand(over: "#open"))

        harness.textView.headingFolding.toggle(at: 0)
        harness.layout()
        #expect(try harness.activates("#secret"))
        #expect(harness.clicked == ["secret"])
    }

    @Test("the pointing hand covers Tags only while the callback is set")
    func pointingHand() throws {
        let harness = Harness("# Heading\nPorada #acme `#code` #2026 dnes")

        #expect(harness.hand(over: "#acme"))
        #expect(!harness.hand(over: "Porada"))
        #expect(!harness.hand(over: "dnes"))
        #expect(!harness.hand(over: "#code"))
        #expect(!harness.hand(over: "#2026"))
        #expect(!harness.hand(over: "Heading"))

        harness.textView.onTagClick = nil
        #expect(!harness.hand(over: "#acme"))
    }

    @Test("Tag targets follow edits and the real cursor shows the hand over a Tag")
    func cursorFollowsTags() throws {
        let harness = Harness("See #acme here")
        let before = harness.center(of: "#acme")
        #expect(harness.textView.pointingHandTarget(containing: before))

        harness.textView.setSelectedRange(NSRange(location: 4, length: 0))
        harness.textView.insertText(String(repeating: "x", count: 40) + " ", replacementRange: NSRange(location: 4, length: 0))
        harness.layout()
        let after = harness.center(of: "#acme")
        #expect(harness.textView.pointingHandTarget(containing: after))
        #expect(!harness.textView.pointingHandTarget(containing: before))

        NSCursor.arrow.set()
        harness.textView.mouseMoved(with: try #require(NSEvent.mouseEvent(
            with: .mouseMoved, location: harness.textView.convert(after, to: nil), modifierFlags: [], timestamp: 0,
            windowNumber: harness.window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)))
        #expect(NSCursor.current == .pointingHand)
        harness.textView.mouseMoved(with: try #require(NSEvent.mouseEvent(
            with: .mouseMoved, location: harness.textView.convert(harness.center(of: "here"), to: nil),
            modifierFlags: [], timestamp: 0, windowNumber: harness.window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 0, pressure: 0)))
        #expect(NSCursor.current == .iBeam)
    }

    @Test("Tags in a read-only Brain Note are clickable")
    func readOnly() throws {
        let text = "## Fakt #Acme"
        let harness = Harness(text, isEditable: false)

        #expect(harness.hand(over: "#Acme"))
        try harness.click("#Acme")

        #expect(harness.clicked == ["acme"])
        #expect(harness.textView.string == text)
    }

    @Test("Wiki-link and task clicks keep working beside Tags")
    func otherTargetsUnchanged() throws {
        let harness = Harness("- [ ] #todo [[Plan]]")
        var wiki: [String] = []
        harness.textView.onWikiLinkClick = { wiki.append($0.target) }

        try harness.click("Plan")
        try harness.click("#todo")

        #expect(wiki == ["Plan"])
        #expect(harness.clicked == ["todo"])
    }
}

private extension NSRect {
    var center: NSPoint { NSPoint(x: midX, y: midY) }
}
