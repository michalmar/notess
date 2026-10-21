import AppKit
import Testing
@testable import NotessEditor

@MainActor
@Suite("Finding text in the current note", .serialized)
struct MarkdownTextViewFindTests {
    private let window: NSWindow
    private let scrollView: NSScrollView
    private let textView: MarkdownTextView

    init() {
        scrollView = MarkdownTextViewFactory.makeScrollView(style: .standard)
        textView = scrollView.documentView as! MarkdownTextView
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 400), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = scrollView
        scrollView.frame = window.contentLayoutRect
        window.makeKeyAndOrderFront(nil)
        textView.string = "První Plán\n\nDruhý plán a třetí PLÁN.\nŽádný dalši"
        window.makeFirstResponder(textView)
        runMainLoop()
    }

    // MARK: Helpers

    private var field: NSSearchField? {
        allSubviews(of: scrollView).compactMap { $0 as? NSSearchField }.first
    }

    /// Whether the query field (or its field editor) has keyboard focus.
    private var isFieldFocused: Bool {
        guard let field, let responder = window.firstResponder else { return false }
        return responder === field || (responder as? NSText)?.delegate === field
    }

    private func openFind() {
        // Cmd+F reaches the editor as a responder-chain action sent from the menu.
        #expect(window.firstResponder?.tryToPerform(#selector(MarkdownTextView.showFind(_:)), with: nil) == true)
        runMainLoop()
    }

    private func type(_ query: String) throws {
        let editor = try #require(window.fieldEditor(false, for: field) as? NSTextView)
        editor.string = query
        editor.didChangeText()
        runMainLoop()
    }

    private func press(keyCode: UInt16, characters: String, modifiers: NSEvent.ModifierFlags = []) throws {
        let event = try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode
            )
        )
        // As NSApplication does: key equivalents get the first chance.
        if !window.performKeyEquivalent(with: event) { window.sendEvent(event) }
        runMainLoop()
    }

    private func selectedText() -> String {
        (textView.string as NSString).substring(with: textView.selectedRange())
    }

    // MARK: Tests

    @Test("Find opens a bar and focuses its query field immediately")
    func opensAndFocuses() throws {
        #expect(field == nil || scrollView.isFindBarVisible == false)
        openFind()

        #expect(scrollView.isFindBarVisible)
        #expect(field != nil)
        #expect(isFieldFocused)
    }

    @Test("matches are found in unsaved text and highlighted case-insensitively as the user types")
    func highlightsLive() throws {
        openFind()
        try type("plán")
        #expect(textView.findMatches.count == 3)
        #expect(selectedText() == "Plán")

        // An unsaved edit is searched too.
        textView.insertText("plánek ", replacementRange: NSRange(location: 0, length: 0))
        #expect(textView.findMatches.count == 4)

        try type("plánek")
        #expect(textView.findMatches.count == 1)
        try type("zzz")
        #expect(textView.findMatches.isEmpty)
    }

    @Test("Enter selects the next match and Shift+Enter the previous one, wrapping around")
    func navigation() throws {
        openFind()
        try type("plán")
        let locations = textView.findMatches.map(\.location)
        #expect(textView.selectedRange().location == locations[0])

        try press(keyCode: 36, characters: "\r")
        #expect(textView.selectedRange().location == locations[1])
        try press(keyCode: 36, characters: "\r")
        #expect(textView.selectedRange().location == locations[2])
        try press(keyCode: 36, characters: "\r")
        #expect(textView.selectedRange().location == locations[0])
        try press(keyCode: 36, characters: "\r", modifiers: .shift)
        #expect(textView.selectedRange().location == locations[2])
        #expect(isFieldFocused)
    }

    @Test("finding and navigating do not change the text")
    func doesNotEdit() throws {
        let original = textView.string
        openFind()
        try type("plán")
        try press(keyCode: 36, characters: "\r")
        try press(keyCode: 53, characters: "\u{1b}")
        #expect(textView.string == original)
        #expect(textView.undoManager?.canUndo != true)
    }

    @Test("Escape closes the bar and returns focus to the editor")
    func escapeRestoresFocus() async throws {
        openFind()
        try type("plán")
        try press(keyCode: 53, characters: "\u{1b}")
        runMainLoop()
        await flushMainQueue()

        #expect(scrollView.isFindBarVisible == false)
        #expect(window.firstResponder === textView)
        #expect(textView.findMatches.isEmpty)
        // The match stays selected so writing resumes there.
        #expect(selectedText() == "Plán")
    }

    @Test("matches are drawn behind the text while the bar is open")
    func drawsHighlights() throws {
        openFind()
        try type("Druhý")
        let match = try #require(textView.findMatches.first)
        // Only the highlight, not the selection, may colour the match.
        textView.setSelectedRange(NSRange(location: textView.string.utf16.count, length: 0))
        let rect = try #require(textView.findHighlightRects(for: match).first)

        let rep = try #require(textView.bitmapImageRepForCachingDisplay(in: textView.bounds))
        textView.cacheDisplay(in: textView.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / textView.bounds.width
        let sample = rep.colorAt(x: Int((rect.minX + 1) * scale), y: Int((rect.minY + 1) * scale))
        let background = rep.colorAt(x: Int(textView.bounds.maxX * scale) - 2, y: Int((rect.minY + 1) * scale))
        #expect(sample != background)

        window.makeFirstResponder(field)
        try press(keyCode: 53, characters: "\u{1b}")
        let cleared = try #require(textView.bitmapImageRepForCachingDisplay(in: textView.bounds))
        textView.cacheDisplay(in: textView.bounds, to: cleared)
        let after = cleared.colorAt(x: Int((rect.minX + 1) * scale), y: Int((rect.minY + 1) * scale))
        #expect(after == background)
    }

    @Test("TextKit 2 stays active")
    func textKit2() throws {
        openFind()
        try type("plán")
        #expect(textView.textLayoutManager != nil)
    }
}

@MainActor
private func allSubviews(of view: NSView) -> [NSView] {
    view.subviews + view.subviews.flatMap(allSubviews)
}

@MainActor
private func runMainLoop() {
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
}

@MainActor
private func flushMainQueue() async {
    // A nested run loop cannot execute deferred focus restoration.
    await withCheckedContinuation { continuation in
        DispatchQueue.main.async { continuation.resume() }
    }
}
