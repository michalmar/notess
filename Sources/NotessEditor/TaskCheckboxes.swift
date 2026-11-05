import AppKit

extension NSAttributedString.Key {
    static let notessTaskCheckbox = NSAttributedString.Key("NotessTaskCheckbox")
}

/// Native controls over the unchanged source markers. Only the viewport gets
/// views; caret movement never swaps a Task between source and rendered modes.
@MainActor
final class TaskCheckboxes {
    private weak var textView: MarkdownTextView?
    private var buttons: [Int: TaskCheckboxButton] = [:]
    private var isLayingOut = false

    init(textView: MarkdownTextView) {
        self.textView = textView
    }

    var hitRects: [NSRect] {
        buttons.values.filter { !$0.isHidden && $0.isEnabled }.map(\.frame)
    }

    var accessibilityChildren: [NSButton] {
        buttons.values.filter { !$0.isHidden }.sorted { $0.sourceLocation < $1.sourceLocation }
    }

    func toggle(at point: NSPoint) -> Bool {
        guard let button = buttons.values.first(where: {
            !$0.isHidden && $0.isEnabled && $0.frame.contains(point)
        }) else { return false }
        return activate(button)
    }

    func layout() {
        guard !isLayingOut, let textView, let storage = textView.textStorage,
              let manager = textView.textLayoutManager,
              let content = manager.textContentManager else { return }
        isLayingOut = true
        defer { isLayingOut = false }
        for button in buttons.values { button.isHidden = true }
        let visible: NSTextRange
        if textView.enclosingScrollView != nil {
            guard let viewport = manager.textViewportLayoutController.viewportRange else { return }
            visible = viewport
        } else {
            visible = manager.documentRange
        }
        let start = content.offset(from: content.documentRange.location, to: visible.location)
        let end = content.offset(from: content.documentRange.location, to: visible.endLocation)
        let range = NSIntersectionRange(
            NSRange(location: start, length: end - start), NSRange(location: 0, length: storage.length)
        )
        storage.enumerateAttribute(.notessTaskCheckbox, in: range) { value, box, _ in
            guard let checked = value as? Bool, box.length == 3,
                  !textView.headingFolding.hides(box.location) else { return }
            let rect = textView.rect(forCharacterRange: box)
            guard !rect.isEmpty, rect.intersects(textView.visibleRect) else { return }
            let button: TaskCheckboxButton
            if let existing = buttons[box.location] {
                button = existing
            } else {
                button = TaskCheckboxButton()
                button.textView = textView
                button.target = self
                button.action = #selector(press(_:))
                button.onPress = { [weak self, weak button] in
                    guard let self, let button else { return false }
                    return activate(button)
                }
                buttons[box.location] = button
                textView.addSubview(button)
            }
            button.sourceLocation = box.location
            button.state = checked ? .on : .off
            button.isEnabled = textView.isEditable
            button.contentTintColor = textView.markdownStyle.colors.task
            button.isHidden = false
            let fontSize = textView.markdownStyle.font.pointSize
            button.controlSize = fontSize < 13 ? .mini : .small
            let side = min(rect.height, max(18, fontSize))
            button.frame = NSRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side)
            let line = storage.mutableString.lineRange(for: box)
            let label = storage.mutableString.substring(
                with: NSRange(location: box.upperBound, length: line.upperBound - box.upperBound)
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            button.setAccessibilityLabel(label.isEmpty ? "Úkol" : label)
            button.toolTip = checked ? "Otevřít úkol" : "Dokončit úkol"
        }
        let obsolete = buttons.filter { $0.value.isHidden }.map(\.key)
        for location in obsolete { buttons.removeValue(forKey: location)?.removeFromSuperview() }
    }

    @objc private func press(_ button: TaskCheckboxButton) {
        activate(button)
    }

    @discardableResult
    private func activate(_ button: TaskCheckboxButton) -> Bool {
        guard let textView, textView.toggleTask(at: button.sourceLocation) else {
            layout()
            return false
        }
        textView.window?.makeFirstResponder(textView)
        layout()
        return true
    }
}

@MainActor
private final class TaskCheckboxButton: NSButton {
    weak var textView: MarkdownTextView?
    var sourceLocation = 0
    var onPress: (() -> Bool)?

    init() {
        super.init(frame: .zero)
        setButtonType(.switch)
        title = ""
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyDown
        controlSize = .small
        setAccessibilityElement(true)
        setAccessibilityRole(.checkBox)
        cell?.setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) {
        fatalError("not supported")
    }

    override var acceptsFirstResponder: Bool { false }

    override func accessibilityValue() -> Any? { state.rawValue }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        return onPress?() ?? false
    }

    // Let the editor distinguish clicks from selection/modifier gestures.
    override func mouseDown(with event: NSEvent) {
        textView?.mouseDown(with: event)
    }

    override func resetCursorRects() {
        if isEnabled { addCursorRect(bounds, cursor: .pointingHand) }
    }
}
