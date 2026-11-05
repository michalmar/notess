import AppKit
import NotessCore

/// Compact localized chips over valid Task Due Dates (`📅 YYYY-MM-DD`), using
/// the same interpretation as saved Task queries (`TaskDueDate`).
///
/// A chip is an overlay of the unchanged source, like `TaskCheckboxes`: it
/// never edits text, attributes or Undo. On the lines the selection touches
/// in a focused editor the Markdown shows for ordinary editing; missing,
/// invalid, conflicting and wrapped dates always stay source text. Only the
/// viewport gets chips, and read-only views get none.
@MainActor
final class TaskDueDateChips {
    struct Chip: Equatable {
        /// The marker's source range, in UTF-16.
        let range: NSRange
        let frame: NSRect
        let label: String
    }

    private weak var textView: MarkdownTextView?
    private var views: [Int: TaskDueDateChipView] = [:]

    init(textView: MarkdownTextView) {
        self.textView = textView
    }

    var visibleChips: [Chip] {
        views.values.filter { !$0.isHidden }
            .sorted { $0.range.location < $1.range.location }
            .map { Chip(range: $0.range, frame: $0.frame, label: $0.label) }
    }

    func layout() {
        for view in views.values { view.isHidden = true }
        defer {
            let obsolete = views.filter { $0.value.isHidden }.map(\.key)
            for location in obsolete { views.removeValue(forKey: location)?.removeFromSuperview() }
        }
        guard let textView, textView.isEditable, let storage = textView.textStorage,
              let range = textView.viewportCharacterRange() else { return }
        let string = storage.mutableString
        let editing = textView.window?.firstResponder === textView ? textView.selectedRanges.map(\.rangeValue) : []
        storage.enumerateAttribute(.notessTaskCheckbox, in: range) { value, box, _ in
            guard value is Bool, box.length == 3, !textView.headingFolding.hides(box.location) else { return }
            var lineStart = 0
            var contentsEnd = 0
            string.getLineStart(&lineStart, end: nil, contentsEnd: &contentsEnd, for: box)
            guard !editing.contains(where: { Self.selection($0, touchesLineFrom: lineStart, to: contentsEnd) }) else { return }
            // The Task text exactly as `MarkdownTask` reports it, without surrounding whitespace.
            var text = NSRange(location: box.upperBound, length: max(0, contentsEnd - box.upperBound))
            let whitespace = CharacterSet.whitespaces.inverted
            let first = string.rangeOfCharacter(from: whitespace, range: text)
            guard first.location != NSNotFound else { return }
            let last = string.rangeOfCharacter(from: whitespace, options: .backwards, range: text)
            text = NSRange(location: first.location, length: last.upperBound - first.location)
            let dueDate = TaskDueDate.parse(in: string.substring(with: text), offset: text.location)
            guard case .valid(let day) = dueDate.state else { return }
            for marker in dueDate.markers {
                place(marker, label: day.dueDateLabel, isCompleted: value as? Bool == true, in: textView)
            }
        }
    }

    private func place(_ marker: TaskDueDate.Marker, label: String, isCompleted: Bool, in textView: MarkdownTextView) {
        // A marker split over two lines keeps its source rather than a chip in one of them.
        let frames = textView.segmentFrames(of: marker.range)
        guard frames.count == 1, let frame = frames.first?.integral,
              !frame.isEmpty, frame.intersects(textView.visibleRect) else { return }
        let view: TaskDueDateChipView
        if let existing = views[marker.range.location] {
            view = existing
        } else {
            view = TaskDueDateChipView()
            view.textView = textView
            views[marker.range.location] = view
            textView.addSubview(view)
        }
        let style = textView.markdownStyle
        view.range = marker.range
        view.label = label
        view.toolTip = marker.rawValue
        view.font = NSFont(descriptor: style.font.fontDescriptor, size: style.font.pointSize * 0.85) ?? style.font
        view.tint = isCompleted ? style.colors.completedTask : style.colors.task
        view.background = textView.backgroundColor
        view.frame = frame
        view.isHidden = false
        view.needsDisplay = true
    }

    /// Whether a selection or caret is on the line from `start` to `end`
    /// (its contents, without the line break).
    private static func selection(_ range: NSRange, touchesLineFrom start: Int, to end: Int) -> Bool {
        guard range.location <= end else { return false }
        return range.upperBound > start || (range.length == 0 && range.location == start)
    }
}

/// Covers the source date and draws the chip in its place. Clicks go to the
/// editor, which puts the caret into the date and so shows its Markdown.
@MainActor
private final class TaskDueDateChipView: NSView {
    weak var textView: MarkdownTextView?
    var range = NSRange(location: 0, length: 0)
    var label = ""
    var font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
    var tint = NSColor.secondaryLabelColor
    var background = NSColor.textBackgroundColor

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override func isAccessibilityElement() -> Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        background.setFill()
        bounds.fill()
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: tint]
        let text = NSAttributedString(string: label, attributes: attributes)
        let size = text.size()
        let height = min(bounds.height, ceil(size.height) + 2)
        let pill = NSRect(x: 0, y: (bounds.height - height) / 2, width: bounds.width, height: height)
        tint.withAlphaComponent(0.14).setFill()
        NSBezierPath(roundedRect: pill, xRadius: height / 2, yRadius: height / 2).fill()

        var content = pill.insetBy(dx: min(4, pill.width / 8), dy: 0)
        let icon = NSImage(systemSymbolName: "calendar", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: font.pointSize * 0.9, weight: .regular)
                .applying(.init(paletteColors: [tint])))
        if let icon, icon.size.width + 3 + size.width <= content.width {
            let total = icon.size.width + 3 + size.width
            let x = content.midX - total / 2
            icon.draw(in: NSRect(x: x, y: pill.midY - icon.size.height / 2, width: icon.size.width, height: icon.size.height))
            content = NSRect(x: x + icon.size.width + 3, y: content.minY, width: size.width, height: content.height)
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingTail
        var drawn = attributes
        drawn[.paragraphStyle] = paragraph
        NSAttributedString(string: label, attributes: drawn).draw(
            with: NSRect(x: content.minX, y: pill.midY - size.height / 2, width: content.width, height: size.height),
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine]
        )
    }

    override func mouseDown(with event: NSEvent) {
        textView?.mouseDown(with: event)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .iBeam)
    }
}

extension MarkdownTextView {
    /// The characters whose layout is in view: the viewport in a scroll view,
    /// everything otherwise.
    func viewportCharacterRange() -> NSRange? {
        guard let storage = textStorage, let manager = textLayoutManager,
              let content = manager.textContentManager else { return nil }
        let visible: NSTextRange
        if enclosingScrollView != nil {
            guard let viewport = manager.textViewportLayoutController.viewportRange else { return nil }
            visible = viewport
        } else {
            visible = manager.documentRange
        }
        let start = content.offset(from: content.documentRange.location, to: visible.location)
        let end = content.offset(from: content.documentRange.location, to: visible.endLocation)
        return NSIntersectionRange(
            NSRange(location: start, length: end - start), NSRange(location: 0, length: storage.length)
        )
    }
}
