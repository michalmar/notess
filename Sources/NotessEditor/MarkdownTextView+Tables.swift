import AppKit
import NotessCore
import SwiftUI

/// A table command as the app menu and the editor's context menu show it.
/// The action goes to the first responder, the editor's `MarkdownTextView`.
public struct TableEditCommand: Identifiable, Sendable {
    public let command: MarkdownTable.Command
    public let title: String
    public let action: Selector
    public let key: KeyEquivalent
    public let modifiers: EventModifiers

    public var id: Selector { action }

    /// The commands in menu order, in groups separated by a divider.
    @MainActor public static let groups: [[TableEditCommand]] = [
        [
            TableEditCommand(command: .insertRowBelow, title: "Přidat řádek pod", action: #selector(MarkdownTextView.insertTableRowBelow(_:)), key: .return, modifiers: .command),
            TableEditCommand(command: .insertRowAbove, title: "Přidat řádek nad", action: #selector(MarkdownTextView.insertTableRowAbove(_:)), key: .return, modifiers: [.command, .shift]),
        ],
        [
            TableEditCommand(command: .insertColumnLeft, title: "Přidat sloupec vlevo", action: #selector(MarkdownTextView.insertTableColumnLeft(_:)), key: .leftArrow, modifiers: [.command, .option]),
            TableEditCommand(command: .insertColumnRight, title: "Přidat sloupec vpravo", action: #selector(MarkdownTextView.insertTableColumnRight(_:)), key: .rightArrow, modifiers: [.command, .option]),
        ],
        [
            TableEditCommand(command: .deleteRow, title: "Smazat řádek", action: #selector(MarkdownTextView.deleteTableRow(_:)), key: .delete, modifiers: [.command, .shift]),
            TableEditCommand(command: .deleteColumn, title: "Smazat sloupec", action: #selector(MarkdownTextView.deleteTableColumn(_:)), key: .delete, modifiers: [.command, .option, .shift]),
        ],
    ]

    /// The undo menu's name for the change `command` makes.
    static func actionName(for command: MarkdownTable.Command) -> String {
        switch command {
        case .insertRowAbove, .insertRowBelow: "Přidat řádek"
        case .insertColumnLeft, .insertColumnRight: "Přidat sloupec"
        case .deleteRow: "Smazat řádek"
        case .deleteColumn: "Smazat sloupec"
        }
    }
}

// MARK: Editing tables

extension MarkdownTextView {
    @objc public func insertTableRowBelow(_ sender: Any?) { perform(.insertRowBelow) }
    @objc public func insertTableRowAbove(_ sender: Any?) { perform(.insertRowAbove) }
    @objc public func insertTableColumnLeft(_ sender: Any?) { perform(.insertColumnLeft) }
    @objc public func insertTableColumnRight(_ sender: Any?) { perform(.insertColumnRight) }
    @objc public func deleteTableRow(_ sender: Any?) { perform(.deleteRow) }
    @objc public func deleteTableColumn(_ sender: Any?) { perform(.deleteColumn) }

    /// Enter in a table adds a row below, keeping any selected text such as a
    /// cell selected by Tab (Option+Enter is a plain line break).
    public override func insertNewline(_ sender: Any?) {
        guard let (table, index, text) = tableAtSelection(),
              let edit = table.newline(at: index, in: text) else {
            super.insertNewline(sender)
            return
        }
        applyTableEdit(edit, actionName: edit.replacement.isEmpty ? "Opustit tabulku" : "Přidat řádek")
    }

    /// Tab in a table selects the next cell (Option+Tab is a tab character).
    public override func insertTab(_ sender: Any?) {
        guard let (table, index, text) = tableAtSelection() else {
            super.insertTab(sender)
            return
        }
        if let edit = table.moveToCell(from: index, forward: true, in: text) {
            applyTableEdit(edit, actionName: "Přidat řádek")
        }
    }

    /// Shift+Tab in a table selects the previous cell.
    public override func insertBacktab(_ sender: Any?) {
        guard let (table, index, text) = tableAtSelection() else {
            super.insertBacktab(sender)
            return
        }
        if let edit = table.moveToCell(from: index, forward: false, in: text) {
            applyTableEdit(edit, actionName: "")
        }
    }

    /// The context menu starts with the table commands when clicked in a table.
    public override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        guard isEditable, !hasMarkedText() else { return menu }
        let index = characterIndexForInsertion(at: convert(event.locationInWindow, from: nil))
        let selection = selectedRange()
        if index < selection.location || index > selection.upperBound {
            setSelectedRange(NSRange(location: index, length: 0))
        }
        guard tableAtSelection() != nil else { return menu }
        var items: [NSMenuItem] = []
        for group in TableEditCommand.groups {
            if !items.isEmpty { items.append(.separator()) }
            for command in group {
                let item = NSMenuItem(title: command.title, action: command.action, keyEquivalent: "")
                item.target = self
                items.append(item)
            }
        }
        items.append(.separator())
        for item in items.reversed() { menu.insertItem(item, at: 0) }
        return menu
    }

    /// Whether a table command can run here, or `nil` for any other action.
    func validateTableCommand(_ action: Selector?) -> Bool? {
        guard let command = TableEditCommand.groups.joined().first(where: { $0.action == action })?.command else { return nil }
        guard let (table, index, text) = tableAtSelection() else { return false }
        return table.edit(command, at: index, in: text) != nil
    }

    private func perform(_ command: MarkdownTable.Command) {
        guard let (table, index, text) = tableAtSelection(),
              let edit = table.edit(command, at: index, in: text) else {
            NSSound.beep()
            return
        }
        applyTableEdit(edit, actionName: TableEditCommand.actionName(for: command))
    }

    /// The table the selection starts in, when the text can be edited.
    private func tableAtSelection() -> (MarkdownTable, Int, NSString)? {
        guard isEditable, !hasMarkedText(), let textStorage else { return nil }
        let text = textStorage.mutableString
        let index = selectedRange().location
        guard let table = highlighter.lexer.table(containing: index, in: text) else { return nil }
        return (table, index, text)
    }

    private func applyTableEdit(_ edit: MarkdownTable.Edit, actionName: String) {
        if edit.changesText {
            replace(edit.range, with: edit.replacement, selection: edit.selection, actionName: actionName)
        } else {
            setSelectedRange(edit.selection)
            scrollRangeToVisible(edit.selection)
        }
    }
}
