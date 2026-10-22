import AppKit
import NotessCore

// MARK: Continuing lists

extension MarkdownTextView {
    /// Enter with the caret at the end of a list item's line starts the next
    /// item with the same indentation and marker (the next number), or ends
    /// the list when the item has no text. Returns false where Enter is a
    /// plain line break: anywhere else in an item, on its continuation lines,
    /// with a selection, while composing text and outside lists.
    func continueList() -> Bool {
        guard isEditable, !hasMarkedText(), let textStorage, selectedRanges.count == 1 else { return false }
        let selection = selectedRange()
        guard selection.length == 0,
              let edit = highlighter.lexer.listNewline(at: selection.location, in: textStorage.mutableString) else {
            return false
        }
        let actionName = edit.replacement.isEmpty ? "Ukončit seznam" : "Pokračovat v seznamu"
        return replace(edit.range, with: edit.replacement, selection: edit.selection, actionName: actionName)
    }
}
