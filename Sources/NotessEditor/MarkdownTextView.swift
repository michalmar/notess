import AppKit
import NotessCore

/// The editor's `NSTextView`: live Markdown formatting and clickable task boxes.
///
/// Do not access `layoutManager` here: it switches the view to TextKit 1.
public final class MarkdownTextView: NSTextView {
    let highlighter = MarkdownHighlighter()

    /// Called when the user clicks a `[[wiki-link]]`; the click then does not move the caret.
    public var onWikiLinkClick: ((WikiLink) -> Void)?

    /// Fonts and colours; setting a different style restyles the whole note.
    public var markdownStyle: MarkdownEditorStyle {
        get { highlighter.style }
        set {
            font = newValue.font
            if let textStorage {
                highlighter.setStyle(newValue, for: textStorage)
            }
            typingAttributes = highlighter.baseAttributes
        }
    }

    /// Connects the highlighter to the text storage; called once after creation.
    func attachHighlighter() {
        textStorage?.delegate = highlighter
        font = highlighter.style.font
        typingAttributes = highlighter.baseAttributes
    }

    public override func mouseDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.shift, .command, .option, .control])
        if event.clickCount == 1, modifiers.isEmpty,
           toggleTask(atPoint: convert(event.locationInWindow, from: nil)) {
            return
        }
        if event.clickCount == 1, modifiers.isEmpty || modifiers == .command,
           let link = wikiLink(atPoint: convert(event.locationInWindow, from: nil)) {
            onWikiLinkClick?(link)
            return
        }
        super.mouseDown(with: event)
    }

    /// The wiki-link whose text lies under `point` (view coordinates), if any.
    func wikiLink(atPoint point: NSPoint) -> WikiLink? {
        guard onWikiLinkClick != nil, textStorage != nil, string.contains("[[") else { return nil }
        let index = characterIndexForInsertion(at: point)
        let candidates = [index, index - 1].filter { $0 >= 0 && $0 < (string as NSString).length }
        guard !candidates.isEmpty else { return nil }
        let links = WikiLink.links(in: string)
        for candidate in candidates {
            guard let link = links.first(where: { NSLocationInRange(candidate, $0.range) }),
                  boxRect(NSRange(location: candidate, length: 1)).insetBy(dx: -2, dy: -2).contains(point)
            else { continue }
            return link
        }
        return nil
    }

    /// Toggles the task box under `point` (view coordinates), if any.
    func toggleTask(atPoint point: NSPoint) -> Bool {
        guard let textStorage else { return false }
        let index = characterIndexForInsertion(at: point)
        for candidate in [index, index - 1] {
            guard let change = highlighter.lexer.taskToggle(at: candidate, in: textStorage.mutableString) else { continue }
            // The `[`, mark and `]` around the replaced mark.
            let box = NSRange(location: change.range.location - 1, length: 3)
            if boxRect(box).insetBy(dx: -2, dy: -2).contains(point) {
                return apply(change)
            }
        }
        return false
    }

    /// Toggles the `[ ]`/`[x]` box containing the character at `index`.
    /// Changes the text like typing would (undoable, marks the note as
    /// unsaved); nothing is written to disk.
    @discardableResult
    public func toggleTask(at index: Int) -> Bool {
        guard let textStorage,
              let change = highlighter.lexer.taskToggle(at: index, in: textStorage.mutableString) else { return false }
        return apply(change)
    }

    private func apply(_ change: (range: NSRange, replacement: String)) -> Bool {
        guard let textStorage, shouldChangeText(in: change.range, replacementString: change.replacement) else {
            return false
        }
        breakUndoCoalescing()
        let selection = selectedRanges
        textStorage.replaceCharacters(in: change.range, with: change.replacement)
        didChangeText()
        selectedRanges = selection
        undoManager?.setActionName("Přepnout úkol")
        return true
    }

    /// The rectangle of `range` in view coordinates.
    private func boxRect(_ range: NSRange) -> NSRect {
        guard let window else { return .zero }
        let screenRect = firstRect(forCharacterRange: range, actualRange: nil)
        return convert(window.convertFromScreen(screenRect), from: nil)
    }
}
