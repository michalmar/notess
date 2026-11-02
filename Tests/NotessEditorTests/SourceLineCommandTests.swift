import AppKit
import Testing
@testable import NotessEditor

@MainActor
@Suite("Source-line commands", .serialized)
struct SourceLineCommandTests {
    private let window: NSWindow
    private let textView: MarkdownTextView
    private let undoManager: UndoManager

    init() throws {
        let scrollView = MarkdownTextViewFactory.makeScrollView()
        textView = try #require(scrollView.documentView as? MarkdownTextView)
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled], backing: .buffered, defer: true
        )
        window.isReleasedWhenClosed = false
        window.contentView = scrollView
        scrollView.frame = window.contentLayoutRect
        window.makeFirstResponder(textView)
        undoManager = try #require(textView.undoManager)
        undoManager.groupsByEvent = false
    }

    private func load(_ text: String, selection: NSRange) {
        textView.string = text
        textView.setSelectedRange(selection)
        undoManager.removeAllActions()
    }

    private func event(_ action: () -> Void) {
        undoManager.beginUndoGrouping()
        action()
        undoManager.endUndoGrouping()
    }

    @Test("moving a line through the responder preserves the caret and undo/redo selection")
    func moveAndUndo() {
        load("first\nsecond\nthird", selection: NSRange(location: 9, length: 0))
        var reported: [String] = []
        let observer = NotificationCenter.default.addObserver(
            forName: NSText.didChangeNotification, object: textView, queue: nil
        ) { [textView] _ in
            MainActor.assumeIsolated { reported.append(textView.string) }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        event {
            #expect(NSApp.sendAction(NSSelectorFromString("moveSourceLineUp:"), to: textView, from: nil))
        }
        #expect(textView.string == "second\nfirst\nthird")
        #expect(textView.selectedRange() == NSRange(location: 3, length: 0))
        undoManager.undo()
        #expect(textView.string == "first\nsecond\nthird")
        #expect(textView.selectedRange() == NSRange(location: 9, length: 0))
        #expect(!undoManager.canUndo)
        undoManager.redo()
        #expect(textView.string == "second\nfirst\nthird")
        #expect(textView.selectedRange() == NSRange(location: 3, length: 0))
        #expect(reported == ["second\nfirst\nthird", "first\nsecond\nthird", "second\nfirst\nthird"])
    }

    @Test("moving a partial multiline selection down excludes a line touched only at its start")
    func moveSelectionDown() throws {
        load("top\nalpha\nbeta\nlast", selection: NSRange(location: 6, length: 9))
        let action = NSSelectorFromString("moveSourceLineDown:")
        try #require(textView.responds(to: action))
        event { #expect(NSApp.sendAction(action, to: textView, from: nil)) }
        #expect(textView.string == "top\nlast\nalpha\nbeta")
        #expect(textView.selectedRange() == NSRange(location: 11, length: 8))
        undoManager.undo()
        #expect(textView.string == "top\nalpha\nbeta\nlast")
        #expect(textView.selectedRange() == NSRange(location: 6, length: 9))
        undoManager.redo()
        #expect(textView.string == "top\nlast\nalpha\nbeta")
        #expect(textView.selectedRange() == NSRange(location: 11, length: 8))
    }

    @Test("duplicating above follows the new partial Unicode selection and repeats on the copy")
    func duplicateAbove() throws {
        load("top\n🙂 café\nlast", selection: NSRange(location: 7, length: 4))
        let action = NSSelectorFromString("duplicateSourceLineAbove:")
        try #require(textView.responds(to: action))
        event { #expect(NSApp.sendAction(action, to: textView, from: nil)) }
        #expect(textView.string == "top\n🙂 café\n🙂 café\nlast")
        #expect(textView.selectedRange() == NSRange(location: 7, length: 4))
        event { #expect(NSApp.sendAction(action, to: textView, from: nil)) }
        #expect(textView.string == "top\n🙂 café\n🙂 café\n🙂 café\nlast")
        #expect(textView.selectedRange() == NSRange(location: 7, length: 4))
        undoManager.undo()
        #expect(textView.string == "top\n🙂 café\n🙂 café\nlast")
        undoManager.undo()
        #expect(textView.string == "top\n🙂 café\nlast")
        #expect(textView.selectedRange() == NSRange(location: 7, length: 4))
        undoManager.redo()
        #expect(textView.string == "top\n🙂 café\n🙂 café\nlast")
        #expect(textView.selectedRange() == NSRange(location: 7, length: 4))
    }

    @Test("duplicating below copies touched lines in order and selects the new copy")
    func duplicateBelow() throws {
        load("top\nalpha\nbeta\nlast", selection: NSRange(location: 6, length: 6))
        let action = NSSelectorFromString("duplicateSourceLineBelow:")
        try #require(textView.responds(to: action))
        event { #expect(NSApp.sendAction(action, to: textView, from: nil)) }
        #expect(textView.string == "top\nalpha\nbeta\nalpha\nbeta\nlast")
        #expect(textView.selectedRange() == NSRange(location: 17, length: 6))
        undoManager.undo()
        #expect(textView.string == "top\nalpha\nbeta\nlast")
        #expect(textView.selectedRange() == NSRange(location: 6, length: 6))
        undoManager.redo()
        #expect(textView.string == "top\nalpha\nbeta\nalpha\nbeta\nlast")
        #expect(textView.selectedRange() == NSRange(location: 17, length: 6))
    }

    @Test("Option-arrow shortcuts edit only newline-delimited source lines", arguments: [
        (UInt16(126), NSEvent.ModifierFlags.option, "b\na\nc", 1),
        (UInt16(125), NSEvent.ModifierFlags.option, "a\nc\nb", 5),
        (UInt16(126), NSEvent.ModifierFlags([.option, .shift]), "a\nb\nb\nc", 3),
        (UInt16(125), NSEvent.ModifierFlags([.option, .shift]), "a\nb\nb\nc", 5),
    ])
    func keyboard(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, expected: String, caret: Int) throws {
        load("a\nb\nc", selection: NSRange(location: 3, length: 0))
        let key = keyCode == 126 ? "\u{F700}" : "\u{F701}"
        let keyEvent = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers.union(.function),
            timestamp: 0, windowNumber: window.windowNumber, context: nil,
            characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: keyCode
        ))
        event { textView.keyDown(with: keyEvent) }
        #expect(textView.string == expected)
        #expect(textView.selectedRange() == NSRange(location: caret, length: 0))
        undoManager.undo()
        #expect(textView.string == "a\nb\nc")
        #expect(textView.selectedRange() == NSRange(location: 3, length: 0))
        undoManager.redo()
        #expect(textView.string == expected)
        #expect(textView.selectedRange() == NSRange(location: caret, length: 0))
    }

    @Test("menu validation follows source boundaries and read-only state without making edits")
    func validation() {
        let up = NSMenuItem(title: "", action: #selector(MarkdownTextView.moveSourceLineUp(_:)), keyEquivalent: "")
        let down = NSMenuItem(title: "", action: #selector(MarkdownTextView.moveSourceLineDown(_:)), keyEquivalent: "")
        let above = NSMenuItem(title: "", action: #selector(MarkdownTextView.duplicateSourceLineAbove(_:)), keyEquivalent: "")
        let below = NSMenuItem(title: "", action: #selector(MarkdownTextView.duplicateSourceLineBelow(_:)), keyEquivalent: "")
        load("first\nlast", selection: NSRange(location: 0, length: 0))
        #expect(!textView.validateMenuItem(up))
        #expect(textView.validateMenuItem(down))
        textView.setSelectedRange(NSRange(location: 8, length: 0))
        #expect(textView.validateMenuItem(up))
        #expect(!textView.validateMenuItem(down))
        #expect(textView.validateMenuItem(above))
        #expect(textView.validateMenuItem(below))
        textView.isEditable = false
        for item in [up, down, above, below] {
            #expect(!textView.validateMenuItem(item))
            #expect(!textView.validateUserInterfaceItem(item))
            #expect(NSApp.sendAction(item.action!, to: textView, from: item))
        }
        #expect(textView.string == "first\nlast")
        #expect(textView.selectedRange() == NSRange(location: 8, length: 0))
        #expect(!undoManager.canUndo)
    }

    @Test("native menu routing follows the focused note, never a search field or read-only Markdown")
    func focusedMenuRouting() throws {
        defer { window.close() }
        load("first\nlast", selection: NSRange(location: 8, length: 0))
        window.makeFirstResponder(textView)
        let menu = NSMenu(title: "Edit")
        for command in SourceLineCommand.all { menu.addItem(command.makeMenuItem()) }
        func target(for action: Selector) -> NSResponder? {
            var responder = window.firstResponder
            while let current = responder {
                if current.responds(to: action) { return current }
                responder = current.nextResponder
            }
            return nil
        }
        func updateMenu() {
            // Resolve this hosted window's chain, as NSApp does for a key
            // window, without relying on process-global application activation.
            for item in menu.items { item.target = target(for: item.action!) ?? window.firstResponder }
            menu.update()
        }
        updateMenu()
        #expect(menu.items.map(\.isEnabled) == [true, false, true, true])
        let key = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .option,
            timestamp: 0, windowNumber: window.windowNumber, context: nil,
            characters: "\u{F700}", charactersIgnoringModifiers: "\u{F700}", isARepeat: false, keyCode: 126
        ))
        event { #expect(menu.performKeyEquivalent(with: key)) }
        #expect(textView.string == "last\nfirst")
        #expect(textView.selectedRange() == NSRange(location: 2, length: 0))
        textView.isEditable = false
        updateMenu()
        #expect(menu.items.allSatisfy { !$0.isEnabled })
        let query = NSSearchField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        window.contentView?.addSubview(query)
        query.stringValue = "find this"
        window.makeFirstResponder(query)
        updateMenu()
        #expect(menu.items.allSatisfy { !$0.isEnabled })
        for command in SourceLineCommand.all {
            #expect(target(for: command.action) == nil)
        }
        #expect(query.stringValue == "find this")
        #expect(textView.string == "last\nfirst")
    }

    @Test("source edits reveal an adjacent hidden line and move a heading without its subtree")
    func foldedSourceLines() throws {
        load("# Topic\nhidden\n# Next\nlast", selection: NSRange(location: 0, length: 0))
        _ = textView.fittingHeight(forWidth: 350)
        let topic = try #require(textView.subviews.compactMap { $0 as? NSButton }.first)
        topic.performClick(nil)
        #expect(topic.state == .off)
        textView.setSelectedRange(NSRange(location: 17, length: 0))
        event { textView.moveSourceLineUp(nil) }
        #expect(textView.string == "# Topic\n# Next\nhidden\nlast")
        #expect(textView.selectedRange() == NSRange(location: 10, length: 0))
        #expect(textView.subviews.compactMap { $0 as? NSButton }.allSatisfy { $0.state == .on })
        #expect(textView.textLayoutManager != nil)
        undoManager.undo()
        #expect(textView.string == "# Topic\nhidden\n# Next\nlast")
        #expect(textView.selectedRange() == NSRange(location: 17, length: 0))
    }

    nonisolated private static let longLine = String(repeating: "long text ", count: 40)
    nonisolated private static let literalExamples: [(String, String)] = [
        ("before\n\(longLine)\nafter", "before\n\(longLine)\n\(longLine)\nafter"),
        ("before\n3. item\n    continuation\nafter", "before\n3. item\n3. item\n    continuation\nafter"),
        ("before\n| a | b |\n| - | - |\nafter", "before\n| a | b |\n| a | b |\n| - | - |\nafter"),
        ("before\n```\ncode\n```\nafter", "before\n```\n```\ncode\n```\nafter"),
    ]

    @Test("wrapped rows, lists, tables and fences remain literal source lines", arguments: literalExamples)
    func literalSource(source: String, expected: String) {
        load(source, selection: NSRange(location: 9, length: 0))
        event { textView.duplicateSourceLineBelow(nil) }
        #expect(textView.string == expected)
        undoManager.undo()
        #expect(textView.string == source)
        #expect(textView.selectedRange() == NSRange(location: 9, length: 0))
    }

    @Test("boundary moves create no edits and read-only shortcuts retain native navigation")
    func noOpsAndNavigation() throws {
        load("only", selection: NSRange(location: 2, length: 0))
        textView.moveSourceLineUp(nil)
        textView.moveSourceLineDown(nil)
        #expect(textView.string == "only")
        #expect(textView.selectedRange() == NSRange(location: 2, length: 0))
        #expect(!undoManager.canUndo)
        textView.isEditable = false
        let key = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.option, .function],
            timestamp: 0, windowNumber: window.windowNumber, context: nil,
            characters: "\u{F700}", charactersIgnoringModifiers: "\u{F700}", isARepeat: false, keyCode: 126
        ))
        textView.keyDown(with: key)
        #expect(textView.string == "only")
        #expect(textView.selectedRange().location == 0)
        #expect(!undoManager.canUndo)
    }

    @Test("all four commands preserve an exact partial multiline selection", arguments: [
        ("moveSourceLineUp:", "alpha\nbeta\nzero\nend\ntail", 2),
        ("moveSourceLineDown:", "zero\nend\nalpha\nbeta\ntail", 11),
        ("duplicateSourceLineAbove:", "zero\nalpha\nbeta\nalpha\nbeta\nend\ntail", 7),
        ("duplicateSourceLineBelow:", "zero\nalpha\nbeta\nalpha\nbeta\nend\ntail", 18),
    ])
    func partialSelection(action: String, expected: String, start: Int) {
        load("zero\nalpha\nbeta\nend\ntail", selection: NSRange(location: 7, length: 6))
        event { #expect(NSApp.sendAction(NSSelectorFromString(action), to: textView, from: nil)) }
        #expect(textView.string == expected)
        #expect(textView.selectedRange() == NSRange(location: start, length: 6))
        #expect((textView.string as NSString).substring(with: textView.selectedRange()) == "pha\nbe")
        undoManager.undo()
        #expect(textView.string == "zero\nalpha\nbeta\nend\ntail")
        #expect(textView.selectedRange() == NSRange(location: 7, length: 6))
        undoManager.redo()
        #expect(textView.string == expected)
        #expect(textView.selectedRange() == NSRange(location: start, length: 6))
    }

    @Test("empty notes duplicate into a blank line and undo to the empty caret", arguments: [
        ("duplicateSourceLineAbove:", 0),
        ("duplicateSourceLineBelow:", 1),
    ])
    func emptyNote(action: String, caret: Int) {
        load("", selection: NSRange(location: 0, length: 0))
        event { #expect(NSApp.sendAction(NSSelectorFromString(action), to: textView, from: nil)) }
        #expect(textView.string == "\n")
        #expect(textView.selectedRange() == NSRange(location: caret, length: 0))
        undoManager.undo()
        #expect(textView.string.isEmpty)
        #expect(textView.selectedRange() == NSRange(location: 0, length: 0))
        undoManager.redo()
        #expect(textView.string == "\n")
        #expect(textView.selectedRange() == NSRange(location: caret, length: 0))
    }

    @Test("line-command undo stays separate from typing and repeated movement follows the same text")
    func typingAndRepeatedMoves() {
        load("top\nmiddle\nlast", selection: NSRange(location: 15, length: 0))
        event { textView.insertText("!", replacementRange: textView.selectedRange()) }
        event { textView.moveSourceLineUp(nil) }
        #expect(textView.string == "top\nlast!\nmiddle")
        #expect(textView.selectedRange() == NSRange(location: 9, length: 0))
        event { textView.moveSourceLineUp(nil) }
        #expect(textView.string == "last!\ntop\nmiddle")
        #expect(textView.selectedRange() == NSRange(location: 5, length: 0))
        textView.moveSourceLineUp(nil)
        undoManager.undo()
        #expect(textView.string == "top\nlast!\nmiddle")
        #expect(textView.selectedRange() == NSRange(location: 9, length: 0))
        undoManager.undo()
        #expect(textView.string == "top\nmiddle\nlast!")
        #expect(textView.selectedRange() == NSRange(location: 16, length: 0))
        undoManager.undo()
        #expect(textView.string == "top\nmiddle\nlast")
    }
}
