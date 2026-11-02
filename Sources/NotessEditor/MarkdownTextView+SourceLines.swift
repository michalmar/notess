import AppKit
import NotessCore

public struct SourceLineCommand {
    public let command: SourceLineEdit.Command
    public let title: String
    public let action: Selector
    public let keyEquivalent: String
    public let modifiers: NSEvent.ModifierFlags

    @MainActor public static let all: [SourceLineCommand] = [
        .init(command: .moveUp, title: "Přesunout řádek nahoru", action: #selector(MarkdownTextView.moveSourceLineUp(_:)),
              keyEquivalent: "\u{F700}", modifiers: .option),
        .init(command: .moveDown, title: "Přesunout řádek dolů", action: #selector(MarkdownTextView.moveSourceLineDown(_:)),
              keyEquivalent: "\u{F701}", modifiers: .option),
        .init(command: .duplicateAbove, title: "Duplikovat řádek nad", action: #selector(MarkdownTextView.duplicateSourceLineAbove(_:)),
              keyEquivalent: "\u{F700}", modifiers: [.option, .shift]),
        .init(command: .duplicateBelow, title: "Duplikovat řádek pod", action: #selector(MarkdownTextView.duplicateSourceLineBelow(_:)),
              keyEquivalent: "\u{F701}", modifiers: [.option, .shift]),
    ]

    @MainActor public func makeMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.keyEquivalentModifierMask = modifiers
        return item
    }
}

extension MarkdownTextView {
    public override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.option, .shift, .command, .control])
        if isEditable, !hasMarkedText(),
           modifiers == .option || modifiers == [.option, .shift],
           event.keyCode == 126 || event.keyCode == 125 {
            if modifiers.contains(.shift) {
                if event.keyCode == 126 { duplicateSourceLineAbove(nil) } else { duplicateSourceLineBelow(nil) }
            } else {
                if event.keyCode == 126 { moveSourceLineUp(nil) } else { moveSourceLineDown(nil) }
            }
            return
        }
        super.keyDown(with: event)
    }

    @objc public func moveSourceLineUp(_ sender: Any?) {
        performSourceLineCommand(.moveUp, actionName: "Přesunout řádek nahoru")
    }

    @objc public func moveSourceLineDown(_ sender: Any?) {
        performSourceLineCommand(.moveDown, actionName: "Přesunout řádek dolů")
    }

    @objc public func duplicateSourceLineAbove(_ sender: Any?) {
        performSourceLineCommand(.duplicateAbove, actionName: "Duplikovat řádek nad")
    }

    @objc public func duplicateSourceLineBelow(_ sender: Any?) {
        performSourceLineCommand(.duplicateBelow, actionName: "Duplikovat řádek pod")
    }

    func validateSourceLineCommand(_ action: Selector?) -> Bool? {
        guard let command = SourceLineCommand.all.first(where: { $0.action == action }) else { return nil }
        return isEditable && !hasMarkedText()
            && SourceLineEdit.canApply(command.command, in: string, selection: selectedRange())
    }

    private func performSourceLineCommand(_ command: SourceLineEdit.Command, actionName: String) {
        guard isEditable, !hasMarkedText(),
              let edit = SourceLineEdit.edit(command, in: string, selection: selectedRange()) else { return }
        replaceSourceLines(edit.range, with: edit.replacement, selection: edit.selection, actionName: actionName)
    }

    private func replaceSourceLines(_ range: NSRange, with replacement: String, selection: NSRange, actionName: String) {
        let original = (string as NSString).substring(with: range)
        let originalSelection = selectedRange()
        let manager = undoManager
        // NSTextView's replacement undo restores a caret at the end of the
        // replacement, not the exact partial selection a line command follows.
        manager?.disableUndoRegistration()
        let changed = replace(range, with: replacement, selection: selection, actionName: actionName)
        manager?.enableUndoRegistration()
        guard changed else { return }
        manager?.registerUndo(withTarget: self) { target in
            target.replaceSourceLines(
                NSRange(location: range.location, length: (replacement as NSString).length),
                with: original, selection: originalSelection, actionName: actionName
            )
        }
        manager?.setActionName(actionName)
    }
}
