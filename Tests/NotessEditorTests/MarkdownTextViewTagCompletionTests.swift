import AppKit
import NotessCore
import Testing
@testable import NotessEditor

@MainActor
@Suite("Completing Tags with Tab")
struct MarkdownTextViewTagCompletionTests {
    private let window: NSWindow
    private let textView: MarkdownTextView
    private let undoManager: UndoManager
    private let vault = FakeTagVocabulary(tags: ["acme", "akce", "Acme-2026", "projekt", "škola", "školka", "2026-plan"])

    init() throws {
        let scrollView = MarkdownTextViewFactory.makeScrollView(style: .standard)
        textView = scrollView.documentView as! MarkdownTextView
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 400), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = scrollView
        scrollView.frame = window.contentLayoutRect
        undoManager = try #require(textView.undoManager)
        undoManager.groupsByEvent = false
        textView.tagSuggestionSource = vault.source()
    }

    // MARK: Helpers

    /// Sets the text with the caret at `‸`.
    private func load(_ text: String) {
        textView.string = text.replacingOccurrences(of: "‸", with: "")
        textView.setSelectedRange(NSRange(location: (text as NSString).range(of: "‸").location, length: 0))
    }

    /// The text with `‸` at the caret, or `[`…`]` around the selection.
    private var marked: String {
        let result = NSMutableString(string: textView.string)
        let selection = textView.selectedRange()
        if selection.length == 0 {
            result.insert("‸", at: selection.location)
        } else {
            result.insert("]", at: selection.upperBound)
            result.insert("[", at: selection.location)
        }
        return result as String
    }

    /// Runs `action` as one user event: its own undo group.
    private func event(_ action: () -> Void) {
        undoManager.beginUndoGrouping()
        action()
        undoManager.endUndoGrouping()
    }

    private func type(_ text: String) {
        for character in text {
            event { textView.insertText(String(character), replacementRange: textView.selectedRange()) }
        }
    }

    private func command(_ selector: Selector) {
        event { textView.doCommand(by: selector) }
    }

    private var rows: [String] { textView.visibleTagSuggestions }
    private var selected: String? { textView.selectedTagSuggestion }
    private var rowsInView: [String] { textView.tagSuggestionsInView }

    /// An element of the suggestion list as assistive technology sees it.
    private struct AccessibleItem {
        let label: String
        let isSelected: Bool
        /// In window coordinates.
        let frame: NSRect
    }

    /// The accessibility elements under the editor, depth first.
    private func accessibilityElements() -> [any NSAccessibilityProtocol] {
        var result: [any NSAccessibilityProtocol] = []
        func visit(_ element: any NSAccessibilityProtocol) {
            result.append(element)
            for child in element.accessibilityChildren() ?? [] {
                if let child = child as? any NSAccessibilityProtocol { visit(child) }
            }
        }
        if let scrollView = textView.enclosingScrollView { visit(scrollView) }
        return result
    }

    private func item(_ element: any NSAccessibilityProtocol) -> AccessibleItem {
        AccessibleItem(
            label: element.accessibilityLabel() ?? "",
            isSelected: element.isAccessibilitySelected(),
            frame: window.convertFromScreen(element.accessibilityFrame())
        )
    }

    /// The suggestion list as an accessibility element, if shown.
    private func suggestionList() -> AccessibleItem? {
        accessibilityElements()
            .first { $0.accessibilityRole() == .list && $0.accessibilityLabel() == "Návrhy štítků" }
            .map(item)
    }

    /// The suggestion rows as accessibility elements, in order.
    private func suggestionRows() -> [AccessibleItem] {
        accessibilityElements().filter { $0.accessibilityRole() == .row }.map(item)
    }

    /// Clicks the middle of the suggestion row reading `label`, each mouse
    /// event being one user event.
    private func click(_ label: String) throws {
        let point = try press(label)
        try release(at: point)
    }

    /// Presses the mouse on the middle of the suggestion row reading `label`.
    private func press(_ label: String) throws -> NSPoint {
        let row = try #require(suggestionRows().first { $0.label == label })
        let point = NSPoint(x: row.frame.midX, y: row.frame.midY)
        try sendMouse(.leftMouseDown, at: point)
        return point
    }

    private func release(at point: NSPoint) throws {
        try sendMouse(.leftMouseUp, at: point)
    }

    private func sendMouse(_ type: NSEvent.EventType, at point: NSPoint) throws {
        let mouse = try #require(NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1,
            pressure: type == .leftMouseDown ? 1 : 0
        ))
        event { window.sendEvent(mouse) }
    }

    // MARK: Type, filter, Tab, undo

    @Test("typing a prefix shows matching saved Tags; narrowing, broadening and Tab complete it as one undoable edit")
    func typeFilterTabUndo() async {
        load("Porada ‸ dnes")
        type("#")
        await settle()
        #expect(rows.isEmpty)
        #expect(vault.requests.isEmpty)

        type("a")
        await settle()
        #expect(rows == ["#acme", "#acme-2026", "#akce"])
        #expect(selected == "#acme")

        type("c")
        await settle()
        #expect(rows == ["#acme", "#acme-2026"])

        command(#selector(NSTextView.deleteBackward(_:)))
        await settle()
        #expect(rows == ["#acme", "#acme-2026", "#akce"])
        type("k")
        await settle()
        #expect(rows == ["#akce"])

        var changes = 0
        let observer = NotificationCenter.default.addObserver(
            forName: NSText.didChangeNotification, object: textView, queue: nil
        ) { _ in MainActor.assumeIsolated { changes += 1 } }
        defer { NotificationCenter.default.removeObserver(observer) }

        command(#selector(NSResponder.insertTab(_:)))
        #expect(marked == "Porada #akce‸ dnes")
        #expect(rows.isEmpty)
        #expect(changes == 1)
        #expect(undoManager.undoActionName == "Doplnit štítek")
        await settle()
        #expect(rows.isEmpty)

        // Typing continues normally after the completed Tag.
        type(",")
        #expect(marked == "Porada #akce,‸ dnes")

        undoManager.undo()
        #expect(marked == "Porada #akce‸ dnes")
        undoManager.undo()
        #expect(textView.string == "Porada #ak dnes")
        await settle()
        #expect(rows.isEmpty)
        undoManager.redo()
        #expect(textView.string == "Porada #akce dnes")
        #expect(changes >= 3)
    }

    @Test("an exact match is left out while longer matches stay; no match shows nothing and Tab is a tab")
    func exactAndNoMatch() async {
        load("‸")
        type("#acme")
        await settle()
        #expect(rows == ["#acme-2026"])

        type("-2026")
        await settle()
        #expect(rows.isEmpty)

        load("x ‸")
        type("#zz")
        await settle()
        #expect(rows.isEmpty)
        command(#selector(NSResponder.insertTab(_:)))
        #expect(marked == "x #zz\t‸")
    }

    @Test("digit, hyphen and underscore prefixes complete saved Tags")
    func letterlessPrefix() async {
        load("‸")
        type("#2")
        await settle()
        #expect(rows == ["#2026-plan"])
        command(#selector(NSResponder.insertTab(_:)))
        #expect(marked == "#2026-plan‸")
    }

    @Test("completing in the middle of a Tag replaces the whole Tag, keeping the text around it")
    func midToken() async {
        load("Úkol (#pr‸jekt), hotovo")
        type("o")
        await settle()
        #expect(rows == ["#projekt"])
        command(#selector(NSResponder.insertTab(_:)))
        #expect(marked == "Úkol (#projekt‸), hotovo")
    }

    @Test("Unicode before and inside a Tag is replaced safely, decomposed letters included")
    func unicode() async {
        load("😀 Příliš #S\u{30C}‸ola, dál")
        type("k")
        await settle()
        #expect(rows == ["#škola", "#školka"])
        command(#selector(NSResponder.insertTab(_:)))
        #expect(marked == "😀 Příliš #škola‸, dál")
    }

    @Test("a Tag typed in a heading, list or quote is completed")
    func blockContexts() async {
        for (prefix, expected) in [("## Porada ", "## Porada #acme‸"), ("- ", "- #acme‸"), ("> ", "> #acme‸")] {
            load(prefix + "‸")
            type("#ac")
            await settle()
            #expect(rows == ["#acme", "#acme-2026"])
            command(#selector(NSResponder.insertTab(_:)))
            #expect(marked == expected)
        }
    }

    @Test("no completion where Tags are not recognised")
    func excludedContexts() async {
        for text in ["`‸`", "C‸", "[[‸]]", "https://example.com/‸", "\\‸"] {
            load(text)
            type("#ac")
            await settle()
            #expect(rows.isEmpty, "\(text)")
        }
    }

    // MARK: Choosing a suggestion

    @Test("Up and Down move the highlight without wrapping or moving the caret; Tab accepts the highlighted Tag")
    func arrows() async {
        load("Dnes ‸")
        type("#a")
        await settle()
        #expect(rows == ["#acme", "#acme-2026", "#akce"])
        #expect(selected == "#acme")

        command(#selector(NSResponder.moveUp(_:)))
        #expect(selected == "#acme")
        #expect(marked == "Dnes #a‸")

        command(#selector(NSResponder.moveDown(_:)))
        #expect(selected == "#acme-2026")
        command(#selector(NSResponder.moveDown(_:)))
        #expect(selected == "#akce")
        command(#selector(NSResponder.moveDown(_:)))
        #expect(selected == "#akce")
        #expect(marked == "Dnes #a‸")
        command(#selector(NSResponder.moveUp(_:)))
        #expect(selected == "#acme-2026")
        #expect(rows == ["#acme", "#acme-2026", "#akce"])
        await settle()
        #expect(vault.requests == ["a"])

        command(#selector(NSResponder.insertTab(_:)))
        #expect(marked == "Dnes #acme-2026‸")
        #expect(rows.isEmpty)
        undoManager.undo()
        #expect(marked == "Dnes #a‸")
        undoManager.redo()
        #expect(textView.string == "Dnes #acme-2026")
    }

    @Test("without a list Up and Down move the caret as usual")
    func arrowsWithoutList() async {
        load("první\n#zz‸")
        command(#selector(NSResponder.moveUp(_:)))
        #expect(textView.selectedRange().location <= 5)

        vault.isSuspended = true
        load("první\n‸")
        type("#a")
        #expect(selected == nil)
        command(#selector(NSResponder.moveUp(_:)))
        #expect(textView.selectedRange().location <= 5)
        #expect(rows.isEmpty)
        vault.resumeAll()
        await settle()
        #expect(rows.isEmpty)
    }

    @Test("Up and Down over a list kept on screen during a lookup stay in the list and take effect when it answers")
    func arrowsWhileRefreshing() async {
        load("první\n‸\ndruhý")
        type("#a")
        await settle()
        vault.isSuspended = true
        type("c")
        await settle()
        #expect(vault.pendingPrefixes == ["ac"])
        #expect(rows == ["#acme", "#acme-2026"])
        #expect(selected == nil)
        command(#selector(NSResponder.moveDown(_:)))
        command(#selector(NSResponder.moveDown(_:)))
        #expect(marked == "první\n#ac‸\ndruhý")
        #expect(rows == ["#acme", "#acme-2026"])
        vault.resumeAll()
        await settle()
        #expect(selected == "#acme-2026")

        // Tab still waits for the lookup.
        load("první\n‸\ndruhý")
        vault.isSuspended = false
        type("#a")
        await settle()
        vault.isSuspended = true
        type("c")
        await settle()
        command(#selector(NSResponder.moveDown(_:)))
        command(#selector(NSResponder.insertTab(_:)))
        #expect(marked == "první\n#ac\t‸\ndruhý")
        vault.resumeAll()
        await settle()
        #expect(rows.isEmpty)
    }

    @Test("a highlighted Tag that still matches stays highlighted while the prefix changes; otherwise the first is")
    func retainedSelection() async {
        load("‸")
        type("#a")
        await settle()
        command(#selector(NSResponder.moveDown(_:)))
        #expect(selected == "#acme-2026")

        type("c")
        await settle()
        #expect(rows == ["#acme", "#acme-2026"])
        #expect(selected == "#acme-2026")

        command(#selector(NSTextView.deleteBackward(_:)))
        await settle()
        #expect(rows == ["#acme", "#acme-2026", "#akce"])
        #expect(selected == "#acme-2026")

        command(#selector(NSResponder.moveDown(_:)))
        #expect(selected == "#akce")
        type("c")
        await settle()
        #expect(rows == ["#acme", "#acme-2026"])
        #expect(selected == "#acme")

        command(#selector(NSResponder.moveDown(_:)))
        type("me")
        await settle()
        #expect(rows == ["#acme-2026"])
        #expect(selected == "#acme-2026")
        command(#selector(NSResponder.insertTab(_:)))
        #expect(marked == "#acme-2026‸")
    }

    @Test("more than eight matches: eight rows are in view, the rest scroll, and the highlight stays in view")
    func manyMatches() async {
        let tags = (1...12).map { String(format: "téma%02d", $0) }
        vault.tags = tags.reversed()
        load("‸")
        type("#té")
        await settle()
        #expect(rows == tags.map { "#" + $0 })
        #expect(rowsInView == Array(rows.prefix(8)))
        #expect(selected == "#téma01")

        for _ in 0..<10 { command(#selector(NSResponder.moveDown(_:))) }
        #expect(selected == "#téma11")
        #expect(rowsInView.count == 8)
        #expect(rowsInView.contains("#téma11"))
        #expect(!rowsInView.contains("#téma01"))

        for _ in 0..<5 { command(#selector(NSResponder.moveDown(_:))) }
        #expect(selected == "#téma12")
        #expect(rowsInView.last == "#téma12")

        for _ in 0..<11 { command(#selector(NSResponder.moveUp(_:))) }
        #expect(selected == "#téma01")
        #expect(rowsInView.first == "#téma01")

        for _ in 0..<9 { command(#selector(NSResponder.moveDown(_:))) }
        command(#selector(NSResponder.insertTab(_:)))
        #expect(marked == "#téma10‸")
    }

    @Test("clicking a row accepts it in place, keeps the editor focused and is one undoable edit")
    func click() async throws {
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        window.makeFirstResponder(textView)
        load("Porada ‸ dnes")
        type("#a")
        await settle()
        #expect(selected == "#acme")

        var changes = 0
        let observer = NotificationCenter.default.addObserver(
            forName: NSText.didChangeNotification, object: textView, queue: nil
        ) { _ in MainActor.assumeIsolated { changes += 1 } }
        defer { NotificationCenter.default.removeObserver(observer) }

        try click("#akce")
        #expect(marked == "Porada #akce‸ dnes")
        #expect(rows.isEmpty)
        #expect(window.firstResponder === textView)
        #expect(changes == 1)
        #expect(undoManager.undoActionName == "Doplnit štítek")
        await settle()
        #expect(rows.isEmpty)

        type(",")
        #expect(marked == "Porada #akce,‸ dnes")
        undoManager.undo()
        undoManager.undo()
        #expect(marked == "Porada #a‸ dnes")
        undoManager.redo()
        #expect(textView.string == "Porada #akce dnes")
        #expect(textView.selectedRange() == NSRange(location: 12, length: 0))
    }

    @Test("a row scrolled into view beyond the eighth can be clicked")
    func clickBeyondEighth() async throws {
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        window.makeFirstResponder(textView)
        vault.tags = (1...12).map { String(format: "téma%02d", $0) }
        load("‸")
        type("#t")
        await settle()
        #expect(!rowsInView.contains("#téma11"))
        for _ in 0..<10 { command(#selector(NSResponder.moveDown(_:))) }
        #expect(rowsInView.contains("#téma11"))

        try click("#téma11")
        #expect(marked == "#téma11‸")
        #expect(window.firstResponder === textView)
    }

    @Test("pressing a suggestion through accessibility accepts it")
    func accessibilityPress() async throws {
        load("x ‸")
        type("#a")
        await settle()
        let row = try #require(accessibilityElements().first { $0.accessibilityRole() == .row && $0.accessibilityLabel() == "#akce" })
        event { _ = row.accessibilityPerformPress() }
        #expect(marked == "x #akce‸")
        #expect(rows.isEmpty)
    }

    // MARK: Placement

    /// The list, the Tag `#…` and the visible editor area, in window coordinates.
    private func placement(of tag: String) throws -> (list: NSRect, tag: NSRect, visible: NSRect) {
        let list = try #require(suggestionList()).frame
        let range = (textView.string as NSString).range(of: tag, options: .backwards)
        let tagRect = window.convertFromScreen(textView.firstRect(forCharacterRange: range, actualRange: nil))
        return (list, tagRect, textView.convert(textView.visibleRect, to: nil))
    }

    @Test("the list opens under the Tag, starting where the Tag starts")
    func placementBelow() async throws {
        load("Porada ‸")
        type("#a")
        await settle()
        let (list, tag, visible) = try placement(of: "#a")
        #expect(abs(list.maxY - (tag.minY - 2)) < 1)
        #expect(abs(list.minX - tag.minX) < 1)
        #expect(visible.contains(list))
        #expect(suggestionRows().count == 3)
    }

    @Test("near the right edge the list moves left to stay in the editor")
    func placementRightEdge() async throws {
        window.setContentSize(NSSize(width: 300, height: 400))
        load("Porada s týmem na téma ‸")
        type("#a")
        await settle()
        let (list, tag, visible) = try placement(of: "#a")
        #expect(tag.minX + list.width > visible.maxX)
        #expect(visible.contains(list))
        #expect(!list.intersects(tag))
    }

    @Test("near the bottom edge the list opens above the Tag")
    func placementAbove() async throws {
        load(String(repeating: "řádek\n", count: 40) + "‸")
        type("#a")
        await settle()
        // Scrolling to the caret repositions the list; under load that can
        // take more than a few main-queue turns.
        let deadline = ContinuousClock.now + .seconds(2)
        while let (list, tag, _) = try? placement(of: "#a"), abs(list.minY - (tag.maxY + 2)) >= 1,
              ContinuousClock.now < deadline {
            await settle()
        }
        let (list, tag, visible) = try placement(of: "#a")
        #expect(visible.contains(tag))
        #expect(abs(list.minY - (tag.maxY + 2)) < 1)
        #expect(visible.contains(list))
    }

    @Test("in a short editor the list shrinks to whole rows beside the Tag, keeping the highlight in view")
    func placementShort() async throws {
        window.setContentSize(NSSize(width: 700, height: 130))
        vault.tags = (1...12).map { String(format: "téma%02d", $0) }
        load("Úvod\n‸")
        type("#t")
        await settle()
        var (list, tag, visible) = try placement(of: "#t")
        #expect(visible.contains(list))
        #expect(!list.intersects(tag))
        let shown = rowsInView.count
        #expect(shown >= 1 && shown < 8)
        #expect(abs(list.height - (CGFloat(shown) * 22 + 8)) < 1)

        for _ in 0..<6 { command(#selector(NSResponder.moveDown(_:))) }
        #expect(selected == "#téma07")
        #expect(rowsInView.contains("#téma07"))
        (list, tag, visible) = try placement(of: "#t")
        #expect(!list.intersects(tag))
    }

    // MARK: Dismissal

    @Test("assistive technology reads each suggestion by name and which one is selected")
    func accessibility() async throws {
        load("‸")
        type("#a")
        await settle()
        let list = try #require(suggestionList())
        #expect(list.label == "Návrhy štítků")
        #expect(suggestionRows().map(\.label) == ["#acme", "#acme-2026", "#akce"])
        #expect(suggestionRows().filter(\.isSelected).map(\.label) == ["#acme"])

        command(#selector(NSResponder.moveDown(_:)))
        #expect(suggestionRows().filter(\.isSelected).map(\.label) == ["#acme-2026"])

        command(#selector(NSResponder.cancelOperation(_:)))
        #expect(suggestionList() == nil)
    }

    @Test("Escape closes the list without editing; a later edit reopens it")
    func escape() async {
        load("‸")
        type("#a")
        await settle()
        #expect(!rows.isEmpty)
        command(#selector(NSResponder.cancelOperation(_:)))
        #expect(rows.isEmpty)
        #expect(marked == "#a‸")
        command(#selector(NSResponder.insertTab(_:)))
        #expect(marked == "#a\t‸")

        command(#selector(NSTextView.deleteBackward(_:)))
        await settle()
        #expect(rows == ["#acme", "#acme-2026", "#akce"])
    }

    @Test("moving the caret, selecting, losing focus or loading another note closes the list")
    func dismissals() async {
        load("‸")
        type("#a")
        await settle()
        command(#selector(NSResponder.moveLeft(_:)))
        #expect(rows.isEmpty)

        load("x ‸")
        type("#a")
        await settle()
        command(#selector(NSResponder.moveLeftAndModifySelection(_:)))
        #expect(rows.isEmpty)

        window.makeFirstResponder(textView)
        load("y ‸")
        type("#a")
        await settle()
        #expect(!rows.isEmpty)
        window.makeFirstResponder(nil)
        #expect(rows.isEmpty)

        load("z ‸")
        type("#a")
        await settle()
        load("Jiná poznámka ‸")
        #expect(rows.isEmpty)
    }

    @Test("moving into an existing Tag does not open completion")
    func navigationDoesNotOpen() async {
        load("#acm‸ text")
        command(#selector(NSResponder.moveLeft(_:)))
        command(#selector(NSResponder.moveRight(_:)))
        textView.setSelectedRange(NSRange(location: 3, length: 0))
        await settle()
        #expect(rows.isEmpty)
        #expect(vault.requests.isEmpty)
    }

    @Test("Return and Shift-Tab close the list and keep their usual behaviour")
    func returnAndBacktab() async {
        load("‸")
        type("#a")
        await settle()
        command(#selector(NSResponder.insertNewline(_:)))
        #expect(marked == "#a\n‸")
        #expect(rows.isEmpty)

        load("| x | #a‸ |\n| - | - |")
        type("c")
        await settle()
        #expect(!rows.isEmpty)
        command(#selector(NSResponder.insertBacktab(_:)))
        #expect(marked == "| [x] | #ac |\n| - | - |")
        #expect(rows.isEmpty)
    }

    @Test("after moving the highlight, Escape, Return and Shift-Tab still only do their usual thing")
    func keysAfterBrowsing() async {
        load("‸")
        type("#a")
        await settle()
        command(#selector(NSResponder.moveDown(_:)))
        command(#selector(NSResponder.cancelOperation(_:)))
        #expect(rows.isEmpty)
        #expect(marked == "#a‸")

        load("‸")
        type("#a")
        await settle()
        command(#selector(NSResponder.moveDown(_:)))
        command(#selector(NSResponder.insertNewline(_:)))
        #expect(marked == "#a\n‸")
        #expect(rows.isEmpty)

        load("| x | #a‸ |\n| - | - |")
        type("c")
        await settle()
        command(#selector(NSResponder.moveDown(_:)))
        command(#selector(NSResponder.insertBacktab(_:)))
        #expect(marked == "| [x] | #ac |\n| - | - |")
        #expect(rows.isEmpty)
    }

    @Test("a read-only view never opens completion")
    func readOnly() async {
        load("‸")
        type("#a")
        await settle()
        #expect(!rows.isEmpty)
        textView.isEditable = false
        #expect(rows.isEmpty)

        load("#a‸")
        type("c")
        command(#selector(NSResponder.insertTab(_:)))
        await settle()
        #expect(rows.isEmpty)
        #expect(textView.string == "#a")
    }

    // MARK: Tables

    @Test("in a table Tab completes first and the next Tab moves to the next cell")
    func tables() async {
        load("| #a‸ | b |\n| - | - |\n| c | d |")
        type("k")
        await settle()
        #expect(rows == ["#akce"])
        command(#selector(NSResponder.insertTab(_:)))
        #expect(marked == "| #akce‸ | b |\n| - | - |\n| c | d |")
        command(#selector(NSResponder.insertTab(_:)))
        #expect(marked == "| #akce | [b] |\n| - | - |\n| c | d |")
    }

    @Test("in a table the candidate chosen with Down or a click is completed, and the next Tab moves on")
    func tablesWithBrowsing() async throws {
        load("| #‸ | b |\n| - | - |\n| c | d |")
        type("a")
        await settle()
        #expect(selected == "#acme")
        command(#selector(NSResponder.moveDown(_:)))
        #expect(selected == rows[1])
        let second = try #require(selected)
        command(#selector(NSResponder.insertTab(_:)))
        #expect(marked == "| \(second)‸ | b |\n| - | - |\n| c | d |")
        command(#selector(NSResponder.insertTab(_:)))
        #expect(marked == "| \(second) | [b] |\n| - | - |\n| c | d |")

        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        window.makeFirstResponder(textView)
        load("| c | #a‸ |\n| - | - |\n| e | f |")
        await settle()
        type("k")
        await settle()
        try click("#akce")
        #expect(marked == "| c | #akce‸ |\n| - | - |\n| e | f |")
        command(#selector(NSResponder.insertTab(_:)))
        #expect(marked == "| c | #akce |\n| - | - |\n| [e] | f |")
    }

    @Test("in a table Tab navigates when nothing matches or the lookup is pending")
    func tablesWithoutSuggestion() async {
        load("| #z‸ | b |\n| - | - |")
        type("z")
        await settle()
        command(#selector(NSResponder.insertTab(_:)))
        #expect(marked == "| #zz | [b] |\n| - | - |")

        vault.isSuspended = true
        load("| #a‸ | b |\n| - | - |")
        type("c")
        command(#selector(NSResponder.insertTab(_:)))
        #expect(marked == "| #ac | [b] |\n| - | - |")
        vault.resumeAll()
        await settle()
        #expect(rows.isEmpty)
        #expect(textView.string == "| #ac | b |\n| - | - |")
    }

    // MARK: Asynchronous lookups

    @Test("typing and Tab do not wait for a pending lookup")
    func pendingLookup() async {
        vault.isSuspended = true
        load("‸")
        type("#a")
        #expect(rows.isEmpty)
        command(#selector(NSResponder.insertTab(_:)))
        #expect(marked == "#a\t‸")
        vault.resumeAll()
        await settle()
        #expect(rows.isEmpty)
    }

    @Test("out-of-order responses: only the current prefix's result is shown")
    func outOfOrder() async {
        vault.isSuspended = true
        load("‸")
        type("#a")
        await settle()
        type("k")
        await settle()
        #expect(vault.pendingPrefixes == ["a", "ak"])

        vault.resume("ak")
        await settle()
        #expect(rows == ["#akce"])
        vault.resume("a")
        await settle()
        #expect(rows == ["#akce"])

        command(#selector(NSResponder.insertTab(_:)))
        #expect(marked == "#akce‸")
    }

    @Test("a late response after Escape, acceptance, another note or another Vault changes nothing")
    func lateResponses() async {
        // Escape while a refresh is pending.
        load("‸")
        type("#a")
        await settle()
        vault.isSuspended = true
        type("c")
        #expect(rows == ["#acme", "#acme-2026"])
        #expect(selected == nil)
        command(#selector(NSResponder.cancelOperation(_:)))
        vault.resumeAll()
        await settle()
        #expect(rows.isEmpty)
        #expect(marked == "#ac‸")

        // Tab while a refresh is pending keeps its usual meaning.
        vault.isSuspended = false
        load("‸")
        type("#a")
        await settle()
        vault.isSuspended = true
        type("k")
        #expect(rows == ["#akce"])
        #expect(selected == nil)
        command(#selector(NSResponder.insertTab(_:)))
        #expect(marked == "#ak\t‸")
        vault.resumeAll()
        await settle()
        #expect(rows.isEmpty)
        #expect(marked == "#ak\t‸")

        // Acceptance, then a late response.
        vault.isSuspended = false
        load("‸")
        type("#ak")
        await settle()
        vault.isSuspended = true
        type("c")
        await settle()
        vault.resumeAll()
        await settle()
        #expect(selected == "#akce")
        vault.isSuspended = true
        command(#selector(NSResponder.insertTab(_:)))
        #expect(marked == "#akce‸")
        vault.resumeAll()
        await settle()
        #expect(rows.isEmpty)
        #expect(marked == "#akce‸")

        // Another note.
        load("‸")
        type("#a")
        load("Jiná ‸")
        vault.resumeAll()
        await settle()
        #expect(rows.isEmpty)

        // Another Vault.
        load("‸")
        type("#a")
        textView.tagSuggestionSource = vault.source(id: "other vault")
        vault.resumeAll()
        await settle()
        #expect(rows.isEmpty)
        #expect(marked == "#a‸")
    }

    @Test("a failed lookup is reported once, shows nothing and leaves Tab alone")
    func failure() async {
        var failures = 0
        textView.onTagSuggestionFailure = { _ in failures += 1 }
        vault.failure = FakeTagVocabulary.Failure()
        load("‸")
        type("#a")
        await settle()
        #expect(rows.isEmpty)
        #expect(failures == 1)
        type("c")
        await settle()
        #expect(failures == 1)
        command(#selector(NSResponder.insertTab(_:)))
        #expect(marked == "#ac\t‸")

        vault.failure = nil
        load("‸")
        type("#a")
        await settle()
        #expect(rows.count == 3)
    }

    // MARK: Refreshing the vocabulary

    @Test("a refreshed vocabulary reaches the open list and keeps the highlighted Tag; an emptied list closes")
    func refreshOpenList() async {
        load("‸")
        type("#a")
        await settle()
        #expect(rows == ["#acme", "#acme-2026", "#akce"])

        vault.tags = ["acme", "akce", "Acme-2026", "azur"]
        textView.tagSuggestionSource = vault.source(revision: 1)
        await settle()
        #expect(rows == ["#acme", "#acme-2026", "#akce", "#azur"])
        #expect(selected == "#acme")

        // The highlighted Tag vanished: the first one is highlighted.
        vault.tags = ["akce", "azur"]
        textView.tagSuggestionSource = vault.source(revision: 2)
        await settle()
        #expect(rows == ["#akce", "#azur"])
        #expect(selected == "#akce")

        vault.tags = ["projekt"]
        textView.tagSuggestionSource = vault.source(revision: 3)
        await settle()
        #expect(rows.isEmpty)
        #expect(marked == "#a‸")
        command(#selector(NSResponder.insertTab(_:)))
        #expect(marked == "#a\t‸")
    }

    @Test("while a refresh is pending the shown list can be browsed and clicked; the highlighted Tag survives the answer")
    func browsingDuringRefresh() async throws {
        load("první\n‸\ndruhý")
        type("#a")
        await settle()
        command(#selector(NSResponder.moveDown(_:)))
        #expect(selected == "#acme-2026")

        // A highlight chosen before the refresh is kept by Tag, not by row.
        vault.tags.append("abc")
        textView.tagSuggestionSource = vault.source(revision: 1)
        await settle()
        #expect(rows == ["#abc", "#acme", "#acme-2026", "#akce"])
        #expect(selected == "#acme-2026")

        // Up and Down during a pending refresh move the shown highlight, not the
        // caret, and the move survives the answer.
        vault.isSuspended = true
        vault.tags.append("aaa")
        textView.tagSuggestionSource = vault.source(revision: 2)
        await settle()
        #expect(vault.pendingPrefixes == ["a"])
        command(#selector(NSResponder.moveDown(_:)))
        #expect(selected == "#akce")
        #expect(marked == "první\n#a‸\ndruhý")
        vault.resumeAll()
        await settle()
        #expect(rows == ["#aaa", "#abc", "#acme", "#acme-2026", "#akce"])
        #expect(selected == "#akce")

        // A click during a pending refresh accepts the clicked row; the late
        // answer changes nothing.
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        window.makeFirstResponder(textView)
        textView.tagSuggestionSource = vault.source(revision: 3)
        await settle()
        #expect(vault.pendingPrefixes == ["a"])
        try click("#abc")
        #expect(marked == "první\n#abc‸\ndruhý")
        vault.resumeAll()
        await settle()
        #expect(rows.isEmpty)
        #expect(textView.string == "první\n#abc\ndruhý")
    }

    @Test("a refresh answer that changes the row under a pressed mouse does not accept another Tag")
    func pressAcrossRefresh() async throws {
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        window.makeFirstResponder(textView)
        load("‸")
        type("#a")
        await settle()
        #expect(rows == ["#acme", "#acme-2026", "#akce"])
        let point = try press("#acme-2026")
        vault.tags.append("abc")
        textView.tagSuggestionSource = vault.source(revision: 1)
        await settle()
        #expect(rows == ["#abc", "#acme", "#acme-2026", "#akce"])
        try release(at: point)
        #expect(marked == "#a‸")
        #expect(rows == ["#abc", "#acme", "#acme-2026", "#akce"])
        #expect(window.firstResponder === textView)
    }

    @Test("a refresh without any open completion looks nothing up and opens nothing")
    func refreshOpensNothing() async {
        load("‸")
        textView.tagSuggestionSource = vault.source(revision: 1)
        await settle()
        #expect(vault.requests.isEmpty)
        #expect(rows.isEmpty)

        // Not after dismissal by Escape, acceptance, a note change or focus loss either.
        type("#a")
        await settle()
        command(#selector(NSResponder.cancelOperation(_:)))
        vault.tags.append("azur")
        textView.tagSuggestionSource = vault.source(revision: 2)
        await settle()
        #expect(rows.isEmpty)

        load("‸")
        type("#ak")
        await settle()
        command(#selector(NSResponder.insertTab(_:)))
        let requests = vault.requests.count
        textView.tagSuggestionSource = vault.source(revision: 3)
        await settle()
        #expect(rows.isEmpty)
        #expect(vault.requests.count == requests)

        window.makeFirstResponder(textView)
        load("‸")
        type("#a")
        await settle()
        window.makeFirstResponder(nil)
        textView.tagSuggestionSource = vault.source(revision: 4)
        await settle()
        #expect(rows.isEmpty)

        // The next eligible completion simply uses the refreshed vocabulary.
        window.makeFirstResponder(textView)
        load("‸")
        type("#a")
        await settle()
        #expect(rows == ["#acme", "#acme-2026", "#akce", "#azur"])
    }

    @Test("refresh results apply only to the context they were asked for")
    func refreshSuperseded() async {
        load("‸")
        type("#a")
        await settle()

        // A refresh that is overtaken by a newer one.
        vault.isSuspended = true
        vault.tags = ["acme", "akce"]
        textView.tagSuggestionSource = vault.source(revision: 1)
        await settle()
        vault.tags = ["akce", "azur"]
        textView.tagSuggestionSource = vault.source(revision: 2)
        await settle()
        #expect(vault.pendingPrefixes == ["a", "a"])
        #expect(rows == ["#acme", "#acme-2026", "#akce"])
        vault.resumeLast("a")
        await settle()
        #expect(rows == ["#akce", "#azur"])
        vault.resume("a")
        await settle()
        #expect(rows == ["#akce", "#azur"])

        // A refresh that is overtaken by typing.
        textView.tagSuggestionSource = vault.source(revision: 3)
        await settle()
        type("z")
        await settle()
        vault.resume("a")
        await settle()
        #expect(selected == nil)
        vault.resume("az")
        await settle()
        #expect(rows == ["#azur"])
        #expect(selected == "#azur")
        #expect(marked == "#az‸")

        // Late refreshes after Escape, a caret move, another note and acceptance.
        textView.tagSuggestionSource = vault.source(revision: 4)
        await settle()
        command(#selector(NSResponder.cancelOperation(_:)))
        vault.resumeAll()
        await settle()
        #expect(rows.isEmpty)

        vault.isSuspended = false
        load("x ‸")
        type("#a")
        await settle()
        vault.isSuspended = true
        textView.tagSuggestionSource = vault.source(revision: 5)
        await settle()
        command(#selector(NSResponder.moveLeft(_:)))
        vault.resumeAll()
        await settle()
        #expect(rows.isEmpty)
        #expect(marked == "x #‸a")

        vault.isSuspended = false
        load("‸")
        type("#a")
        await settle()
        vault.isSuspended = true
        textView.tagSuggestionSource = vault.source(revision: 6)
        await settle()
        load("Jiná ‸")
        vault.resumeAll()
        await settle()
        #expect(rows.isEmpty)

        vault.isSuspended = false
        load("‸")
        type("#a")
        await settle()
        vault.isSuspended = true
        textView.tagSuggestionSource = vault.source(revision: 7)
        await settle()
        command(#selector(NSResponder.insertTab(_:)))
        #expect(marked == "#akce‸")
        vault.resumeAll()
        await settle()
        #expect(rows.isEmpty)
        #expect(marked == "#akce‸")
    }

    @Test("typing and commands stay usable while a refresh is pending")
    func refreshPending() async {
        load("| #a‸ | b |\n| - | - |")
        type("k")
        await settle()
        #expect(rows == ["#akce"])
        vault.isSuspended = true
        textView.tagSuggestionSource = vault.source(revision: 1)
        await settle()
        #expect(vault.pendingPrefixes == ["ak"])

        type("c")
        #expect(marked == "| #akc‸ | b |\n| - | - |")
        command(#selector(NSResponder.insertTab(_:)))
        #expect(marked == "| #akc | [b] |\n| - | - |")
        vault.resumeAll()
        await settle()
        #expect(rows.isEmpty)
        #expect(textView.string == "| #akc | b |\n| - | - |")
    }

    @Test("a failed refresh is reported, closes the list and leaves Tab alone; a later lookup recovers")
    func refreshFailureAndRecovery() async {
        var failures = 0
        textView.onTagSuggestionFailure = { _ in failures += 1 }
        load("‸")
        type("#a")
        await settle()
        #expect(rows.count == 3)

        vault.failure = FakeTagVocabulary.Failure()
        textView.tagSuggestionSource = vault.source(revision: 1)
        await settle()
        #expect(failures == 1)
        #expect(rows.isEmpty)
        command(#selector(NSResponder.insertTab(_:)))
        #expect(marked == "#a\t‸")

        // Recovery: refresh alone does not reopen; the next edit does.
        vault.failure = nil
        textView.tagSuggestionSource = vault.source(revision: 2)
        await settle()
        #expect(rows.isEmpty)
        load("‸")
        type("#a")
        await settle()
        #expect(rows.count == 3)
        #expect(failures == 1)

        // A failure after recovery is reported again.
        vault.failure = FakeTagVocabulary.Failure()
        textView.tagSuggestionSource = vault.source(revision: 3)
        await settle()
        #expect(failures == 2)
        #expect(rows.isEmpty)
    }

    @Test("switching Vault closes the list at once; old responses never show or edit, and new lookups use only the new Vault")
    func vaultSwitch() async {
        let other = FakeTagVocabulary(tags: ["akvarium", "cizi"])
        load("‸")
        type("#a")
        await settle()
        #expect(!rows.isEmpty)

        textView.tagSuggestionSource = other.source(id: "other vault")
        #expect(rows.isEmpty)
        command(#selector(NSResponder.insertTab(_:)))
        #expect(marked == "#a\t‸")

        // Old lookups, whether typed or refreshed, answered late.
        vault.isSuspended = true
        textView.tagSuggestionSource = vault.source(revision: 1)
        load("‸")
        type("#a")
        await settle()
        textView.tagSuggestionSource = vault.source(revision: 2)
        await settle()
        textView.tagSuggestionSource = other.source(id: "other vault")
        #expect(rows.isEmpty)
        vault.resumeAll()
        await settle()
        #expect(rows.isEmpty)
        #expect(marked == "#a‸")
        command(#selector(NSResponder.insertTab(_:)))
        #expect(marked == "#a\t‸")

        load("‸")
        type("#a")
        await settle()
        #expect(rows == ["#akvarium"])
        #expect(other.requests.last == "a")
        command(#selector(NSResponder.insertTab(_:)))
        #expect(marked == "#akvarium‸")

        // A refresh of the new Vault's vocabulary never brings the old one back.
        other.tags = ["akvarium", "azalka"]
        load("‸")
        type("#a")
        await settle()
        other.tags = ["azalka"]
        textView.tagSuggestionSource = other.source(id: "other vault", revision: 1)
        await settle()
        #expect(rows == ["#azalka"])
    }

    /// Lets queued lookups and their main-actor continuations run.
    private func settle() async {
        for _ in 0..<5 {
            await Task.yield()
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
    }
}

/// Saved Tags served like the Search Index would, optionally holding each
/// lookup until the test resumes it.
@MainActor
final class FakeTagVocabulary {
    struct Failure: Error {}

    var tags: [String]
    var isSuspended = false
    var failure: Error?
    private(set) var requests: [String] = []
    private var pending: [(prefix: String, tags: [String], continuation: CheckedContinuation<[String], Error>)] = []

    init(tags: [String]) {
        self.tags = tags
    }

    var pendingPrefixes: [String] { pending.map(\.prefix) }

    func source(id: AnyHashable = "vault", revision: Int = 0) -> TagSuggestionSource {
        TagSuggestionSource(id: id, revision: revision) { [unowned self] prefix in
            try await self.lookup(prefix)
        }
    }

    private func lookup(_ prefix: String) async throws -> [String] {
        requests.append(prefix)
        if isSuspended {
            let snapshot = tags
            return try await withCheckedThrowingContinuation { continuation in
                pending.append((prefix, snapshot, continuation))
            }
        }
        if let failure { throw failure }
        return tags.filter { Tag.normalize($0).hasPrefix(Tag.normalize(prefix)) }
    }

    /// Answers the oldest held lookup for `prefix` with the Tags as they were
    /// when it was asked.
    func resume(_ prefix: String) {
        guard let index = pending.firstIndex(where: { $0.prefix == prefix }) else { return }
        let request = pending.remove(at: index)
        request.continuation.resume(returning: request.tags)
    }

    /// Answers the newest held lookup for `prefix`.
    func resumeLast(_ prefix: String) {
        guard let index = pending.lastIndex(where: { $0.prefix == prefix }) else { return }
        let request = pending.remove(at: index)
        request.continuation.resume(returning: request.tags)
    }

    func resumeAll() {
        let requests = pending
        pending.removeAll()
        for request in requests { request.continuation.resume(returning: request.tags) }
    }
}
