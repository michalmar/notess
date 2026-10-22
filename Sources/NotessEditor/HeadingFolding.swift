import AppKit
import NotessCore

/// Filters paragraphs from TextKit 2 layout, never from the backing Markdown.
@MainActor
final class HeadingFolding: NSObject, NSTextContentStorageDelegate {
    private weak var textView: MarkdownTextView?
    private var sections: [HeadingSection] = []
    private var collapsed: Set<Int> = []
    private var hiddenRanges: [NSRange] = []
    private var buttons: [NSButton] = []
    private var isUpdatingLayout = false
    var onLayoutChange: (() -> Void)?

    init(textView: MarkdownTextView) {
        self.textView = textView
    }

    func reset() {
        collapsed.removeAll()
        refresh()
    }

    func refresh(editedRange: NSRange? = nil, delta: Int = 0) {
        guard let textView else { return }
        let hadFolds = !collapsed.isEmpty
        if let editedRange {
            let oldEnd = editedRange.upperBound - delta
            collapsed = Set(collapsed.compactMap { location in
                if location < editedRange.location { return location }
                if location >= oldEnd { return location + delta }
                return nil
            })
        }
        sections = HeadingSection.split(textView.string, tokens: textView.highlighter.headingTokens)
            .filter { $0.headingRange != nil && $0.bodyRange.length > 0 }
        collapsed.formIntersection(sections.map(\.range.location))
        while buttons.count > sections.count { buttons.removeLast().removeFromSuperview() }
        while buttons.count < sections.count {
            let button = NSButton(title: "", target: self, action: #selector(toggle(_:)))
            button.bezelStyle = .disclosure
            button.setButtonType(.onOff)
            textView.addSubview(button)
            buttons.append(button)
        }
        for (section, button) in zip(sections, buttons) {
            button.tag = section.range.location
            button.state = collapsed.contains(button.tag) ? .off : .on
            let title = section.title ?? ""
            button.setAccessibilityLabel("Sbalit nebo rozbalit nadpis \(title)")
            button.toolTip = title
        }
        // Ordinary typing keeps the incremental highlighter's local invalidation.
        if editedRange == nil || hadFolds || !collapsed.isEmpty {
            invalidate()
        } else {
            textView.needsLayout = true
        }
    }

    /// Where the disclosure buttons currently on screen sit, in text view coordinates.
    var visibleButtonFrames: [NSRect] {
        buttons.filter { !$0.isHidden }.map(\.frame)
    }

    func hides(_ location: Int) -> Bool {
        guard !hiddenRanges.isEmpty else { return false }
        var low = 0
        var high = hiddenRanges.count
        while low < high {
            let mid = (low + high) / 2
            if hiddenRanges[mid].location <= location { low = mid + 1 } else { high = mid }
        }
        guard low > 0 else { return false }
        let range = hiddenRanges[low - 1]
        return NSLocationInRange(location, range)
            || (location == range.upperBound && location == textView?.textStorage?.length)
    }

    nonisolated func textContentManager(
        _ textContentManager: NSTextContentManager,
        shouldEnumerate textElement: NSTextElement,
        options: NSTextContentManager.EnumerationOptions
    ) -> Bool {
        guard let range = textElement.elementRange else { return true }
        let offset = textContentManager.offset(from: textContentManager.documentRange.location, to: range.location)
        return MainActor.assumeIsolated { !hides(offset) }
    }

    @objc private func toggle(_ button: NSButton) {
        toggle(at: button.tag)
    }

    func canToggle(at location: Int) -> Bool {
        section(at: location) != nil
    }

    private func section(at location: Int) -> HeadingSection? {
        let probe = location > 0 && location == textView?.textStorage?.length ? location - 1 : location
        return sections.last { $0.range.location <= probe && probe < $0.range.upperBound }
    }

    func toggle(at location: Int) {
        guard let textView,
              textView.isSelectable,
              let section = section(at: location) else { return }
        if collapsed.contains(section.range.location) {
            collapsed.remove(section.range.location)
        } else {
            // Move the caret out before removing its paragraphs from layout.
            textView.setSelectedRange(NSRange(location: section.headingRange!.location, length: 0))
            collapsed.insert(section.range.location)
        }
        invalidate()
    }

    func reveal(_ range: NSRange) {
        let previous = collapsed
        for section in sections where collapsed.contains(section.range.location) {
            if NSLocationInRange(range.location, section.bodyRange)
                || NSIntersectionRange(range, section.bodyRange).length > 0
                || (range.length == 0 && range.location == section.bodyRange.upperBound
                    && range.location == textView?.textStorage?.length) {
                collapsed.remove(section.range.location)
            }
        }
        if collapsed != previous { invalidate() }
    }

    private func invalidate() {
        guard let textView, let manager = textView.textLayoutManager else { return }
        hiddenRanges.removeAll(keepingCapacity: true)
        for section in sections where collapsed.contains(section.range.location) {
            if let last = hiddenRanges.last, section.bodyRange.location < last.upperBound {
                hiddenRanges[hiddenRanges.count - 1] = NSUnionRange(last, section.bodyRange)
            } else {
                hiddenRanges.append(section.bodyRange)
            }
        }
        manager.invalidateLayout(for: manager.documentRange)
        textView.needsLayout = true
        textView.needsDisplay = true
        textView.scheduleInlineImageRefresh()
        onLayoutChange?()
    }

    func layoutButtons() {
        guard !isUpdatingLayout, let textView,
              let manager = textView.textLayoutManager,
              let content = manager.textContentManager else { return }
        isUpdatingLayout = true
        defer {
            isUpdatingLayout = false
            textView.refreshPointingHand()
        }
        let viewport: NSRange? = textView.enclosingScrollView.flatMap { _ in
            guard let range = manager.textViewportLayoutController.viewportRange else { return nil }
            let start = content.offset(from: content.documentRange.location, to: range.location)
            let end = content.offset(from: content.documentRange.location, to: range.endLocation)
            return NSRange(location: start, length: end - start)
        }
        for (section, button) in zip(sections, buttons) {
            button.state = collapsed.contains(section.range.location) ? .off : .on
            button.isHidden = viewport.map { !NSLocationInRange(section.range.location, $0) } == true
                || hides(section.range.location)
            guard !button.isHidden, let heading = section.headingRange,
                  let start = content.location(content.documentRange.location, offsetBy: heading.location),
                  let end = content.location(start, offsetBy: 1),
                  let range = NSTextRange(location: start, end: end) else { continue }
            manager.enumerateTextSegments(in: range, type: .standard, options: []) { _, frame, _, _ in
                button.frame = NSRect(
                    x: max(0, textView.textContainerOrigin.x - 22),
                    y: frame.minY + textView.textContainerOrigin.y,
                    width: 20, height: max(18, min(24, frame.height))
                )
                return false
            }
        }
    }
}
