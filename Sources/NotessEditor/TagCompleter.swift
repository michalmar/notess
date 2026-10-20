import AppKit
import NotessCore

/// Where Tag completion looks up suggestions, typically the current Vault's
/// saved Tags. `id` identifies the vocabulary (e.g. the Vault): when it
/// changes, open completion closes and pending lookups are discarded.
public struct TagSuggestionSource {
    public let id: AnyHashable
    /// Saved Tags matching a prefix (as written, without `#`). Runs off the
    /// typing path; the editor normalises, deduplicates and sorts the result.
    public let suggestions: @MainActor (String) async throws -> [String]

    public init(id: AnyHashable, suggestions: @escaping @MainActor (String) async throws -> [String]) {
        self.id = id
        self.suggestions = suggestions
    }
}

/// Tag completion in a `MarkdownTextView`: typing or deleting in a Tag prefix
/// looks up saved Tags asynchronously and shows them in a `TagSuggestionList`;
/// Tab replaces the whole Tag with the selected one.
///
/// Every lookup belongs to a generation. Any edit, caret move, dismissal,
/// acceptance or change of note or vocabulary starts a new generation, so a
/// late response can neither show stale suggestions nor edit the text.
@MainActor
final class TagCompleter {
    private unowned let textView: MarkdownTextView
    private var generation = 0
    private var lookup: Task<Void, Never>?
    /// The Tag being completed; nil when completion is closed.
    private(set) var context: TagCompletionContext?
    /// The shown suggestions; empty while closed or waiting for a lookup.
    private(set) var suggestions: [String] = []
    private(set) var selectedIndex: Int?
    /// Set after a failure has been reported, until a lookup succeeds or the
    /// vocabulary changes, so a broken index does not report every keystroke.
    private var hasReportedFailure = false
    private lazy var list = TagSuggestionList()

    init(textView: MarkdownTextView) {
        self.textView = textView
    }

    /// Whether Tab would accept a suggestion now.
    var isActionable: Bool { context != nil && selectedIndex != nil }

    /// Whether completion is open or waiting for a lookup.
    var isActive: Bool { context != nil }

    // MARK: Opening and refreshing

    /// Reacts to a text change. `editedRange` is the changed text after a
    /// typing or deleting edit; nil for changes that must not open completion
    /// (undo, redo, loading a note).
    func textDidChange(editedRange: NSRange?) {
        guard let editedRange, let source = textView.tagSuggestionSource,
              let context = currentContext(),
              editedRange.location >= context.tokenRange.location,
              NSMaxRange(editedRange) <= NSMaxRange(context.tokenRange)
        else {
            dismiss()
            return
        }
        let previous = self.context
        let previousSuggestions = suggestions
        let previousSelection = selectedIndex.map { suggestions[$0] }
        generation += 1
        lookup?.cancel()
        self.context = context

        // While the prefix only grows, the shown suggestions narrow to an exact
        // subset of what the lookup will return, so they stay usable meanwhile.
        if let previous, !previousSuggestions.isEmpty,
           context.normalizedPrefix.hasPrefix(previous.normalizedPrefix) {
            show(TagCompletion.candidates(matching: context.prefix, in: previousSuggestions), keeping: previousSelection)
        } else {
            show([], keeping: nil)
        }

        let generation = generation
        let prefix = context.prefix
        lookup = Task { [weak self] in
            let result: Result<[String], Error>
            do {
                result = .success(try await source.suggestions(prefix))
            } catch {
                result = .failure(error)
            }
            guard let self, self.generation == generation else { return }
            lookup = nil
            switch result {
            case .success(let tags):
                hasReportedFailure = false
                let selection = selectedIndex.map { suggestions[$0] }
                show(TagCompletion.candidates(matching: prefix, in: tags), keeping: selection)
                if suggestions.isEmpty { dismiss() }
            case .failure(let error):
                dismiss()
                guard !(error is CancellationError), !hasReportedFailure else { return }
                hasReportedFailure = true
                textView.onTagSuggestionFailure?(error)
            }
        }
    }

    /// The completion context at the caret, if the editor can complete there.
    private func currentContext() -> TagCompletionContext? {
        guard textView.isEditable, !textView.hasMarkedText(), let textStorage = textView.textStorage else { return nil }
        let selection = textView.selectedRange()
        guard selection.length == 0 else { return nil }
        return textView.highlighter.lexer.tagCompletionContext(at: selection.location, in: textStorage.mutableString)
    }

    // MARK: Closing

    /// Closes completion and discards any pending lookup.
    func dismiss() {
        generation += 1
        lookup?.cancel()
        lookup = nil
        context = nil
        show([], keeping: nil)
    }

    /// Closes completion unless the selection is still the caret it was opened at.
    func selectionDidChange() {
        guard let context else { return }
        let selection = textView.selectedRange()
        if selection.length != 0 || selection.location != context.caret {
            dismiss()
        }
    }

    /// The vocabulary changed (e.g. another Vault): old results no longer apply.
    func sourceDidChange() {
        hasReportedFailure = false
        dismiss()
    }

    // MARK: Accepting

    /// Replaces the Tag at the caret with the selected suggestion, as one
    /// undoable edit. Returns false, changing nothing, when no suggestion is
    /// actionable, so the key keeps its usual meaning.
    func acceptSelected() -> Bool {
        guard let context, let selectedIndex else { return false }
        let tag = suggestions[selectedIndex]
        guard currentContext() == context else {
            dismiss()
            return false
        }
        dismiss()
        return textView.applyTagCompletion(replacing: context.tokenRange, with: "#" + tag)
    }

    // MARK: Presentation

    private func show(_ tags: [String], keeping selection: String?) {
        suggestions = tags
        selectedIndex = tags.isEmpty ? nil : (selection.flatMap(tags.firstIndex(of:)) ?? 0)
        guard !tags.isEmpty, let context, let container = textView.enclosingScrollView else {
            list.removeFromSuperview()
            return
        }
        list.show(tags, selectedIndex: selectedIndex)
        if list.superview !== container {
            container.addSubview(list, positioned: .above, relativeTo: nil)
            observeScrolling(of: container)
        }
        position(below: context.tokenRange, in: container)
    }

    private var scrollObserver: (any NSObjectProtocol)?

    /// Keeps the list next to its Tag while the editor scrolls.
    private func observeScrolling(of container: NSScrollView) {
        if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
        container.contentView.postsBoundsChangedNotifications = true
        scrollObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: container.contentView,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reposition() }
        }
    }

    /// Places the list under the Tag (or above it near the bottom edge),
    /// inside the visible part of the editor.
    func reposition() {
        guard let context, list.superview != nil, let container = textView.enclosingScrollView else { return }
        position(below: context.tokenRange, in: container)
    }

    private func position(below range: NSRange, in container: NSScrollView) {
        let anchor = textView.rect(forCharacterRange: NSRange(location: range.location, length: min(range.length, 1)))
        let visible = textView.visibleRect
        let size = NSSize(width: min(TagSuggestionList.width, visible.width), height: min(list.preferredHeight, visible.height))
        var frame = NSRect(origin: NSPoint(x: anchor.minX, y: anchor.maxY + 2), size: size)
        if frame.maxY > visible.maxY {
            frame.origin.y = anchor.minY - 2 - size.height
        }
        frame.origin.x = max(visible.minX, min(frame.origin.x, visible.maxX - size.width))
        frame.origin.y = max(visible.minY, min(frame.origin.y, visible.maxY - size.height))
        list.frame = container.convert(frame, from: textView)
    }

    /// The shown rows as the user reads them (`#tag`), for tests and accessibility checks.
    var visibleRows: [String] {
        list.superview == nil ? [] : list.tags.map { "#" + $0 }
    }

    /// The highlighted row (`#tag`), if the list is shown.
    var selectedRow: String? {
        guard list.superview != nil, let index = list.selectedIndex else { return nil }
        return "#" + list.tags[index]
    }
}
