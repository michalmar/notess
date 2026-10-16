import AppKit
import NotessCore
import Testing
@testable import NotessEditor

@MainActor
@Suite("Editing tables in the editor")
struct MarkdownTextViewTableEditingTests {
    private let window: NSWindow
    private let textView: MarkdownTextView
    private let undoManager: UndoManager

    init() throws {
        let scrollView = MarkdownTextViewFactory.makeScrollView(style: .standard)
        textView = scrollView.documentView as! MarkdownTextView
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 400), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = scrollView
        scrollView.frame = window.contentLayoutRect
        undoManager = try #require(textView.undoManager)
        undoManager.groupsByEvent = false
    }

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

    @Test("Enter adds a row with the caret in its first cell, notifies, and is one undo step")
    func enterAddsRow() {
        load("| a | b |\n| - | - |\n| c | d‸ |")
        var changes = 0
        let observer = NotificationCenter.default.addObserver(
            forName: NSText.didChangeNotification, object: textView, queue: nil
        ) { _ in MainActor.assumeIsolated { changes += 1 } }
        defer { NotificationCenter.default.removeObserver(observer) }

        event { textView.insertNewline(nil) }
        #expect(marked == "| a | b |\n| - | - |\n| c | d |\n| ‸ |  |")
        #expect(changes == 1)
        #expect(undoManager.undoActionName == "Přidat řádek")

        // Typing goes into the new cell; Enter on an empty last row leaves the table.
        event { textView.insertText("e", replacementRange: textView.selectedRange()) }
        #expect(marked == "| a | b |\n| - | - |\n| c | d |\n| e‸ |  |")
        undoManager.undo()
        event { textView.insertNewline(nil) }
        #expect(marked == "| a | b |\n| - | - |\n| c | d |\n‸")

        undoManager.undo()
        undoManager.undo()
        #expect(textView.string == "| a | b |\n| - | - |\n| c | d |")
    }

    @Test("Enter outside a table and Option+Enter break the line as usual")
    func enterOutsideTable() {
        load("text‸\n| a |\n| - |")
        event { textView.insertNewline(nil) }
        #expect(marked == "text\n‸\n| a |\n| - |")

        load("| a | b |\n| - | - |\n| c‸ | d |")
        event { textView.insertNewlineIgnoringFieldEditor(nil) }
        #expect(marked == "| a | b |\n| - | - |\n| c\n‸ | d |")
    }

    @Test("Tab and Shift+Tab move between cells; Tab in the last cell adds a row")
    func tab() {
        load("| a‸ | bb |\n| - | - |\n| c | d |")
        event { textView.insertTab(nil) }
        #expect(marked == "| a | [bb] |\n| - | - |\n| c | d |")
        event { textView.insertTab(nil) }
        #expect(marked == "| a | bb |\n| - | - |\n| [c] | d |")
        event { textView.insertBacktab(nil) }
        #expect(marked == "| a | [bb] |\n| - | - |\n| c | d |")

        load("| a | bb |\n| - | - |\n| c | d‸ |")
        event { textView.insertTab(nil) }
        #expect(marked == "| a | bb |\n| - | - |\n| c | d |\n| ‸ |  |")

        // Enter after Tab keeps the selected cell's text and adds a row.
        load("| a‸ | bb |\n| - | - |")
        event { textView.insertTab(nil) }
        event { textView.insertNewline(nil) }
        #expect(marked == "| a | bb |\n| - | - |\n| ‸ |  |")

        load("text‸")
        event { textView.insertTab(nil) }
        #expect(marked == "text\t‸")
    }

    @Test("each table command changes the table in one undo step")
    func commands() {
        let table = "| a | b |\n| :- | -: |\n| c‸ | d |"
        let expected: [(MarkdownTable.Command, String)] = [
            (.insertRowBelow, "| a | b |\n| :- | -: |\n| c | d |\n| ‸ |  |"),
            (.insertRowAbove, "| a | b |\n| :- | -: |\n| ‸ |  |\n| c | d |"),
            (.insertColumnLeft, "|  | a | b |\n| --- | :- | -: |\n| ‸ | c | d |"),
            (.insertColumnRight, "| a |  | b |\n| :- | --- | -: |\n| c | ‸ | d |"),
            (.deleteRow, "| ‸a | b |\n| :- | -: |"),
            (.deleteColumn, "| b |\n| -: |\n| ‸d |"),
        ]
        for (command, result) in expected {
            load(table)
            let item = NSMenuItem(title: "", action: action(for: command), keyEquivalent: "")
            #expect(textView.validateMenuItem(item))
            event { #expect(NSApplication.shared.sendAction(action(for: command), to: textView, from: nil)) }
            #expect(marked == result, "\(command)")
            #expect(undoManager.undoActionName == TableEditCommand.actionName(for: command))
            undoManager.undo()
            #expect(textView.string == table.replacingOccurrences(of: "‸", with: ""), "\(command)")
        }
    }

    @Test("table commands are disabled outside a table and in a read-only view")
    func disabledCommands() {
        let item = NSMenuItem(title: "", action: #selector(MarkdownTextView.insertTableRowBelow(_:)), keyEquivalent: "")
        load("text‸\n\n| a |\n| - |")
        #expect(!textView.validateMenuItem(item))

        load("| a |\n| -‸ |")
        textView.isEditable = false
        #expect(!textView.validateMenuItem(item))
        event { textView.insertTableRowBelow(nil) }
        #expect(textView.string == "| a |\n| - |")
    }

    @Test("the context menu starts with the table commands in a table only")
    func contextMenu() throws {
        textView.string = "| a | b |\n| - | - |\n| c | d |\n\ntext"
        func menu(at substring: String) throws -> NSMenu {
            let range = (textView.string as NSString).range(of: substring)
            let rect = window.convertFromScreen(textView.firstRect(forCharacterRange: range, actualRange: nil))
            let event = try #require(NSEvent.mouseEvent(
                with: .rightMouseDown, location: NSPoint(x: rect.midX, y: rect.midY), modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            ))
            return try #require(textView.menu(for: event))
        }

        let inTable = try menu(at: "d")
        #expect(inTable.items.first?.title == "Přidat řádek pod")
        #expect(inTable.items.contains { $0.title == "Smazat sloupec" })
        let d = (textView.string as NSString).range(of: "d").location
        #expect((d...d + 1).contains(textView.selectedRange().location))

        #expect(try !menu(at: "text").items.contains { $0.title == "Přidat řádek pod" })
    }

    private func action(for command: MarkdownTable.Command) -> Selector {
        TableEditCommand.groups.joined().first { $0.command == command }!.action
    }
}
