import AppKit
import NotessCore

/// Finding text in the current note (Cmd+F) for a `MarkdownTextView`: a find
/// bar above the text, live case-insensitive highlighting of every match over
/// the in-memory text, and selecting the next or previous match.
///
/// Finding never edits: the highlights are drawn by the view, not stored in
/// the text, and there is no replacement.
@MainActor
final class EditorFind {
    private unowned let textView: MarkdownTextView
    private(set) var query = ""
    /// Matches of `query` while the bar is open, in note order.
    private(set) var matches: [NSRange] = []
    /// The match last selected by finding; nil before one was chosen.
    private(set) var currentIndex: Int?
    private(set) var isOpen = false
    private lazy var bar: FindBarView = {
        let bar = FindBarView()
        bar.onQueryChange = { [weak self] in self?.setQuery($0) }
        bar.onNext = { [weak self] in self?.step(forward: true) }
        bar.onPrevious = { [weak self] in self?.step(forward: false) }
        bar.onClose = { [weak self] in self?.close() }
        return bar
    }()

    init(textView: MarkdownTextView) {
        self.textView = textView
    }

    var isFieldFocused: Bool { bar.hasFocus }

    // MARK: Opening and closing

    /// Shows the bar and focuses its query field; the previous query stays and is selected.
    func show() {
        guard let scrollView = textView.enclosingScrollView else { return }
        isOpen = true
        scrollView.findBarPosition = .aboveContent
        scrollView.findBarView = bar
        scrollView.isFindBarVisible = true
        bar.setQuery(query)
        refreshMatches(selecting: false)
        bar.focus()
    }

    /// Hides the bar and the highlights, and puts the caret back in the text
    /// at the last selected match.
    func close() {
        guard isOpen else { return }
        isOpen = false
        matches = []
        currentIndex = nil
        textView.enclosingScrollView?.isFindBarVisible = false
        textView.needsDisplay = true
        textView.window?.makeFirstResponder(textView)
    }

    // MARK: Matching

    private func setQuery(_ newQuery: String) {
        query = newQuery
        refreshMatches(selecting: true)
    }

    /// The note's text changed: matches move, appear or vanish.
    func textDidChange() {
        guard isOpen else { return }
        refreshMatches(selecting: false)
    }

    private func refreshMatches(selecting: Bool) {
        matches = NoteFind.matches(of: query, in: textView.string)
        if selecting {
            let caret = textView.selectedRange().location
            currentIndex = NoteFind.indexOfFirstMatch(in: matches, atOrAfter: caret)
            if let currentIndex { select(matches[currentIndex]) }
        } else {
            // Indices shift with edits and another note's text: the current match is the selected one.
            currentIndex = matches.firstIndex(of: textView.selectedRange())
        }
        updateDisplay()
    }

    private func updateDisplay() {
        bar.showCount(matches.count, current: currentIndex, hasQuery: !query.isEmpty)
        textView.needsDisplay = true
    }

    // MARK: Navigating

    /// Selects the next or previous match, wrapping around; the focus stays where it is.
    func step(forward: Bool) {
        guard isOpen else { return show() }
        guard !matches.isEmpty else { return NSSound.beep() }
        let next: Int
        if let currentIndex {
            next = forward
                ? NoteFind.index(after: currentIndex, count: matches.count)
                : NoteFind.index(before: currentIndex, count: matches.count)
        } else {
            let caret = textView.selectedRange().location
            let first = NoteFind.indexOfFirstMatch(in: matches, atOrAfter: caret) ?? 0
            next = forward ? first : NoteFind.index(before: first, count: matches.count)
        }
        currentIndex = next
        select(matches[next])
        updateDisplay()
    }

    private func select(_ range: NSRange) {
        textView.setSelectedRange(range)
        textView.scrollRangeToVisible(range)
    }

    /// Uses the selected text as the query (Find ▸ Use Selection for Find, Cmd+E).
    func useSelectionAsQuery() {
        let selection = textView.selectedRange()
        guard selection.length > 0 else { return }
        let selected = (textView.string as NSString).substring(with: selection)
        guard !selected.contains("\n") else { return }
        query = selected
        bar.setQuery(selected)
        if isOpen { refreshMatches(selecting: false) }
    }

    // MARK: Drawing

    private static let matchColor = NSColor.findHighlightColor.withAlphaComponent(0.6)
    private static let currentColor = NSColor.systemOrange.withAlphaComponent(0.7)

    /// Where `range` is drawn, in view coordinates (one rect per line).
    func rects(for range: NSRange) -> [NSRect] {
        guard let manager = textView.textLayoutManager,
              let content = manager.textContentManager,
              let start = content.location(content.documentRange.location, offsetBy: range.location),
              let end = content.location(start, offsetBy: range.length),
              let textRange = NSTextRange(location: start, end: end) else { return [] }
        let origin = textView.textContainerOrigin
        var result: [NSRect] = []
        manager.enumerateTextSegments(in: textRange, type: .standard, options: []) { _, frame, _, _ in
            if frame.width > 0, frame.height > 0 {
                result.append(frame.offsetBy(dx: origin.x, dy: origin.y))
            }
            return true
        }
        return result
    }

    /// The characters laid out around the visible area, so drawing skips the other matches.
    private func viewportCharacterRange() -> NSRange? {
        guard let manager = textView.textLayoutManager,
              let content = manager.textContentManager,
              let viewport = manager.textViewportLayoutController.viewportRange else { return nil }
        let start = content.offset(from: content.documentRange.location, to: viewport.location)
        let length = content.offset(from: viewport.location, to: viewport.endLocation)
        return NSRange(location: start, length: length)
    }

    func drawHighlights(in dirtyRect: NSRect) {
        guard isOpen, !matches.isEmpty else { return }
        let viewport = viewportCharacterRange()
        for (index, match) in matches.enumerated() {
            if let viewport, NSIntersectionRange(viewport, match).length == 0 { continue }
            (index == currentIndex ? Self.currentColor : Self.matchColor).setFill()
            for rect in rects(for: match) where rect.intersects(dirtyRect) {
                NSBezierPath(roundedRect: rect.insetBy(dx: -1, dy: 0), xRadius: 3, yRadius: 3).fill()
            }
        }
    }
}

/// The compact bar above the editor: query field, match count, previous / next, close.
@MainActor
final class FindBarView: NSView, NSSearchFieldDelegate {
    var onQueryChange: (String) -> Void = { _ in }
    var onNext: () -> Void = {}
    var onPrevious: () -> Void = {}
    var onClose: () -> Void = {}

    private let field = NSSearchField()
    private let countLabel = NSTextField(labelWithString: "")
    private let previousButton = NSButton()
    private let nextButton = NSButton()
    private let closeButton = NSButton(title: "Hotovo", target: nil, action: nil)

    override init(frame: NSRect) {
        super.init(frame: NSRect(x: 0, y: 0, width: 400, height: 36))
        field.placeholderString = "Najít v poznámce"
        field.delegate = self
        field.sendsSearchStringImmediately = true
        field.setAccessibilityLabel("Najít v poznámce")
        countLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        countLabel.textColor = .secondaryLabelColor
        countLabel.alignment = .right
        countLabel.setContentHuggingPriority(.required, for: .horizontal)
        countLabel.setAccessibilityLabel("Počet shod")
        configure(previousButton, symbol: "chevron.up", label: "Předchozí shoda", action: #selector(previous))
        configure(nextButton, symbol: "chevron.down", label: "Další shoda", action: #selector(next))
        closeButton.bezelStyle = .rounded
        closeButton.controlSize = .small
        closeButton.target = self
        closeButton.action = #selector(close)
        closeButton.toolTip = "Zavřít hledání (Esc)"

        let stack = NSStackView(views: [field, countLabel, previousButton, nextButton, closeButton])
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(separator)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            field.widthAnchor.constraint(greaterThanOrEqualToConstant: 160),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("not supported")
    }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 36) }

    private func configure(_ button: NSButton, symbol: String, label: String, action: Selector) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        button.bezelStyle = .texturedRounded
        button.isBordered = true
        button.target = self
        button.action = action
        button.toolTip = label
    }

    var hasFocus: Bool {
        guard let responder = window?.firstResponder else { return false }
        return responder === field || (responder as? NSText)?.delegate === field
    }

    func focus() {
        window?.makeFirstResponder(field)
        field.selectText(nil)
    }

    func setQuery(_ query: String) {
        if field.stringValue != query { field.stringValue = query }
    }

    func showCount(_ count: Int, current: Int?, hasQuery: Bool) {
        if !hasQuery {
            countLabel.stringValue = ""
        } else if count == 0 {
            countLabel.stringValue = "Nenalezeno"
        } else if let current {
            countLabel.stringValue = "\(current + 1) / \(count)"
        } else {
            countLabel.stringValue = "\(count)"
        }
        countLabel.setAccessibilityValue(countLabel.stringValue)
        previousButton.isEnabled = count > 0
        nextButton.isEnabled = count > 0
    }

    @objc private func previous() { onPrevious() }
    @objc private func next() { onNext() }
    @objc private func close() { onClose() }

    /// Cmd+F again while the field has focus selects the query for retyping.
    @objc func showFind(_ sender: Any?) {
        focus()
    }

    /// Return in the field selects the next match, Shift+Return the previous one.
    /// Handled as a key equivalent because the field editor reports both as the same command.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard hasFocus, event.keyCode == 36 || event.keyCode == 76 else {
            return super.performKeyEquivalent(with: event)
        }
        let modifiers = event.modifierFlags.intersection([.shift, .command, .option, .control])
        guard modifiers.isEmpty || modifiers == .shift else { return super.performKeyEquivalent(with: event) }
        if modifiers == .shift { onPrevious() } else { onNext() }
        return true
    }

    func controlTextDidChange(_ notification: Notification) {
        onQueryChange(field.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.cancelOperation(_:)):
            onClose()
            return true
        default:
            return false
        }
    }
}
